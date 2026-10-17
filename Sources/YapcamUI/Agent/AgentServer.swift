import Foundation
import Network
import YapcamEditor
import YapcamCore

/// JSON response mode of Streamable HTTP. Each request closes its TCP connection;
/// MCP sessions are independent of TCP and all document access is main-actor isolated.
@objc(YapcamAgentServer) @MainActor public final class AgentServer: NSObject, AgentServerStarting {
    private static let shared = AgentServer()
    private var listener: NWListener?
    private var receiving: Set<ObjectIdentifier> = []
    private var activeCalls: [ObjectIdentifier: Int] = [:]
    private var clients: [String: String] = [:]
    public static func startServer() { shared.start() }
    private func start() {
        guard listener == nil else { return }
        do {
            let config = AgentConnection.shared
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: config.port)!)
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.stateUpdateHandler = { state in
                Task { @MainActor in
                    if case .ready = state { config.running = true }
                    if case .failed(let error) = state { config.error = error.localizedDescription; config.running = false }
                }
            }
            listener.newConnectionHandler = { connection in
                Task { @MainActor in Self.shared.receive(connection, buffer: Data()) }
            }
            listener.start(queue: .main)
        } catch { AgentConnection.shared.error = error.localizedDescription }
    }
    private func receive(_ connection: NWConnection, buffer: Data) {
        if connection.state == .setup {
            guard receiving.count < 64 else { connection.cancel(); return }
            receiving.insert(ObjectIdentifier(connection))
            connection.start(queue: .main)
            // This deadline covers request reception only, never speech recognition.
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                if Self.shared.receiving.remove(ObjectIdentifier(connection)) != nil { connection.cancel() }
            }
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
            Task { @MainActor in
                var bytes = buffer
                if let data { bytes.append(data) }
                guard bytes.count <= 4_194_304 else { Self.shared.reply(connection, status: 413); return }
                if let boundary = bytes.range(of: Data("\r\n\r\n".utf8)) {
                    guard boundary.lowerBound <= 16_384 else { Self.shared.reply(connection, status: 431); return }
                    let header = String(decoding: bytes[..<boundary.lowerBound], as: UTF8.self)
                    let lines = header.components(separatedBy: "\r\n")
                    var headers: [String: String] = [:]
                    for line in lines.dropFirst() {
                        let pair = line.split(separator: ":", maxSplits: 1).map(String.init)
                        guard pair.count == 2, headers[pair[0].lowercased()] == nil else { Self.shared.reply(connection, status: 400); return }
                        headers[pair[0].lowercased()] = pair[1].trimmingCharacters(in: .whitespaces)
                    }
                    guard headers["authorization"] == "Bearer " + AgentConnection.shared.token else { Self.shared.reply(connection, status: 401); return }
                    if let origin = headers["origin"], origin != "http://127.0.0.1:\(AgentConnection.shared.port)" { Self.shared.reply(connection, status: 403); return }
                    guard headers["transfer-encoding"] == nil,
                          let length = Int(headers["content-length"] ?? "0"), length >= 0, length <= 4_000_000 else { Self.shared.reply(connection, status: 400); return }
                    let first = lines[0].split(separator: " ")
                    guard first.count == 3, first[1] == "/mcp" else { Self.shared.reply(connection, status: 404); return }
                    if first[0] == "DELETE" {
                        guard let key = headers["mcp-session-id"], Self.shared.clients.removeValue(forKey: key) != nil else { Self.shared.reply(connection, status: 404); return }
                        Self.shared.reply(connection, status: 204); return
                    }
                    guard first[0] == "POST" else { Self.shared.reply(connection, status: 405); return }
                    guard headers["content-type"]?.hasPrefix("application/json") == true else { Self.shared.reply(connection, status: 415); return }
                    if let version = headers["mcp-protocol-version"], version != "2025-06-18" { Self.shared.reply(connection, status: 400); return }
                    if bytes.count >= boundary.upperBound + length {
                        let body = bytes.subdata(in: boundary.upperBound..<(boundary.upperBound + length))
                        Self.shared.receiving.remove(ObjectIdentifier(connection))
                        await Self.shared.dispatch(connection, data: body, session: headers["mcp-session-id"], scopedProject: headers["x-yapcam-project"]?.removingPercentEncoding)
                        return
                    }
                } else if bytes.count > 16_384 { Self.shared.reply(connection, status: 431); return }
                if complete || error != nil { connection.cancel() }
                else { Self.shared.receive(connection, buffer: bytes) }
            }
        }
    }
    private func reply(_ connection: NWConnection, status: Int = 200, object: [String: Any]? = nil, session: String? = nil) {
        receiving.remove(ObjectIdentifier(connection))
        let body = object.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) } ?? Data()
        var header = "HTTP/1.1 \(status) Response\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        if let session { header += "Mcp-Session-Id: \(session)\r\n" }
        connection.send(content: Data((header + "\r\n").utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }
    private func dispatch(_ connection: NWConnection, data: Data, session: String?, scopedProject: String?) async {
        guard var request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], request["jsonrpc"] as? String == "2.0", let method = request["method"] as? String else {
            reply(connection, object: ["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Invalid JSON-RPC request"]]); return
        }
        let id = request["id"] ?? NSNull()
        func rpc(_ result: [String: Any]) { reply(connection, object: ["jsonrpc": "2.0", "id": id, "result": result]) }
        func fail(_ message: String) { rpc(["isError": true, "content": [["type": "text", "text": message]]]) }
        var params = request["params"] as? [String: Any] ?? [:]
        if method == "initialize" {
            guard request["id"] != nil, params["protocolVersion"] is String, params["capabilities"] is [String: Any], let info = params["clientInfo"] as? [String: Any], let name = info["name"] as? String else { reply(connection, status: 400); return }
            guard clients.count < 128 else { reply(connection, status: 503); return }
            let key = UUID().uuidString; clients[key] = name
            for doc in EditorWindows.openDocuments { doc.model.agentLog.connection = name }
            let capabilities: [String: Any] = ["tools": ["listChanged": false], "resources": ["listChanged": false], "prompts": ["listChanged": false]]
            var result: [String: Any] = ["protocolVersion": "2025-06-18", "capabilities": capabilities, "serverInfo": ["name": "yapcam", "version": "1.0"]]
            result["instructions"] = Project.agentDoc("app_instructions")
            reply(connection, object: ["jsonrpc": "2.0", "id": id, "result": result], session: key); return
        }
        guard let session, let client = clients[session] else { reply(connection, status: 404); return }
        if request["id"] == nil { reply(connection, status: 202); return }
        if method == "ping" { rpc([:]); return }
        // The handbook (resources/*, prompts/*) is compiled into the core; no document needed.
        if method.hasPrefix("resources/") || method.hasPrefix("prompts/") {
            if let response = try? Project.agentDocsRPC(data), let object = try? JSONSerialization.jsonObject(with: response) as? [String: Any] { reply(connection, object: object) }
            else { reply(connection, object: ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]]) }
            return
        }
        if method == "tools/list", let bytes = try? Project.mcpCatalog(), var tools = try? JSONSerialization.jsonObject(with: bytes) as? [[String: Any]] {
                tools += Self.extraTools
                for i in tools.indices {
                    var schema = tools[i]["inputSchema"] as? [String: Any] ?? [:]
                    var properties = schema["properties"] as? [String: Any] ?? [:]
                    properties["project"] = ["type": "string", "description": "Open document name or full path; defaults to frontmost editor."]
                    schema["properties"] = properties; tools[i]["inputSchema"] = schema
                    if tools[i]["name"] as? String == "read_transcript" { tools[i]["description"] = (tools[i]["description"] as? String ?? "") + " Use transcribe to generate a missing transcript in the open editor." }
                }
                rpc(["tools": tools]); return
            }
        if let arguments = params["arguments"], !(arguments is [String: Any]) { fail("arguments must be an object"); return }
        var args = params["arguments"] as? [String: Any] ?? [:]
        if let project = args["project"], !(project is String) { fail("project must be a document name or path"); return }
        let name = params["name"] as? String ?? ""
        if method == "tools/call", name == "list_documents" {
            rpc(Self.result(["documents": EditorWindows.openDocuments.map { ["name": $0.title, "path": $0.project.packageURL.path, "frontmost": $0 === EditorWindows.frontDocument] as [String: Any] }])); return
        }
        let requestedProject = args.removeValue(forKey: "project") as? String
        if let scopedProject, let requestedProject, scopedProject != requestedProject { fail("This chat is bound to a different document."); return }
        let selector = scopedProject ?? requestedProject
        let matches = EditorWindows.openDocuments.filter { $0.title == selector || $0.project.packageURL.path == selector }
        guard let doc = selector == nil ? EditorWindows.frontDocument : (matches.count == 1 ? matches.first : nil) else { fail("No matching open editor. Open a project in Yapcam, or select an unambiguous project name/path."); return }
        let model = doc.model
        model.agentLog.connection = client
        let activityID = ObjectIdentifier(model)
        activeCalls[activityID, default: 0] += 1
        model.agentLog.isWorking = true
        defer {
            activeCalls[activityID, default: 1] -= 1
            model.agentLog.isWorking = model.agentHooks.promptRunning || activeCalls[activityID, default: 0] > 0
            if activeCalls[activityID, default: 0] == 0 { activeCalls[activityID] = nil }
        }
        do {
            if method == "tools/call", AgentVision.names.contains(name) {
                rpc(try await AgentVision.handle(name: name, arguments: args, project: doc.project))
                return
            }
            if method == "tools/call", ["seek", "select", "transcribe", "transcription_status"].contains(name) {
                switch name {
                case "seek":
                    guard let ns = args["time_ns"] as? NSNumber, ns.doubleValue >= 0, ns.doubleValue <= Double(model.durationNs), ns.doubleValue == Double(ns.int64Value) else { fail("time_ns must be an integer within the timeline"); return }
                    model.seek(toNs: ns.int64Value)
                case "select":
                    guard let item = args["id"] as? String, let kind = args["kind"] as? String else { fail("kind and id required"); return }
                    if kind == "clip", model.project.clips.contains(where: { $0.id == item }) { model.selection = .clip(item) }
                    else if kind == "zoom", model.project.zooms.contains(where: { $0.id == item }) { model.selection = .zoom(item) }
                    else if kind == "highlight", model.highlights.contains(where: { $0.id == item }) { model.selection = .highlight(item) }
                    else if kind == "music", model.music.contains(where: { $0.id == item }) { model.selection = .music(item) }
                    else if let text = model.allText.first(where: { $0.id == item && $0.kind.rawValue == kind }) { model.selection = .text(text.kind, item) }
                    else { fail("Unknown item id or kind"); return }
                case "transcribe":
                    model.generateCaptions()
                    await model.waitForCaptions()
                    guard !model.isClosed else { fail("The editor closed while transcribing"); return }
                    if case .failed(let message) = model.captionState { fail(message); return }
                default:
                    if case .failed(let message) = model.captionState { fail(message); return }
                }
                rpc(Self.result(["status": model.captionState == .working ? "working" : "complete", "playhead_ns": model.playheadNs]))
                if name != "transcription_status" { log(doc, name: name, args: args, client: client) }
                return
            }
            if method == "tools/call", ["moments", "zoom_on_click", "check"].contains(name) {
                args = try await AgentVision.enrich(name: name, arguments: args, project: doc.project)
                guard !model.isClosed else { fail("The editor closed during pixel analysis"); return }
            }
            params["arguments"] = args; request["params"] = params
            let bytes = try JSONSerialization.data(withJSONObject: request)
            let response = try JSONSerialization.jsonObject(with: doc.handleMCP(bytes)) as? [String: Any] ?? [:]
            reply(connection, object: response)
            if method == "tools/call", let result = response["result"] as? [String: Any], result["isError"] as? Bool == false { log(doc, name: name, args: args, client: client, result: result["structuredContent"] as? [String: Any]) }
        } catch { fail(error.localizedDescription) }
    }
    private static func result(_ value: [String: Any]) -> [String: Any] {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data()
        return ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]], "structuredContent": value, "isError": false]
    }
    private static var extraTools: [[String: Any]] {
        [("list_documents", "List open editor documents and the frontmost target.", [:]),
         ("seek", "Show a timeline position in the live preview. time_ns is integer nanoseconds.", ["time_ns": ["type": "integer", "minimum": 0]]),
         ("select", "Select a clip, zoom, highlight, music, caption or text item by its id from read_project.", ["kind": ["type": "string", "enum": ["clip", "zoom", "highlight", "music", "caption", "annotation", "reaction"]], "id": ["type": "string"]]),
         ("transcribe", "Generate captions using the editor's on-device speech recognizer. Waits for completion, one undo step. Uses existing recording transcript when available.", [:]),
         ("transcription_status", "Read transcription status.", [:])].map { name, description, properties in
            ["name": name, "description": description, "inputSchema": ["type": "object", "properties": properties, "additionalProperties": false]]
        } + AgentVision.tools
    }
    private func log(_ doc: EditorDocument, name: String, args: [String: Any], client: String, result: [String: Any]? = nil) {
        let changes = Self.changeLabels(name: name, args: args, result: result)
        guard !changes.isEmpty else { return }
        struct History: Decodable { var undoSteps: Int }
        let depth = try? doc.project.query("{\"q\":\"history\"}", as: History.self).undoSteps
        doc.model.agentLog.append(AgentEntry(role: .agent, source: client + " via MCP", text: changes.map(\.label).joined(separator: ", "), changes: changes, undoMarker: depth))
    }

    /// Pure label mapping, kept beside logging so reads/navigation cannot become edits.
    static func changeLabels(name: String, args: [String: Any], result: [String: Any]? = nil) -> [AgentChange] {
        let reads: Set<String> = ["initialize", "project_summary", "list_documents", "seek", "select", "capture", "grab", "filmstrip", "waveform", "moments", "check", "transcription_status", "save"]
        guard !name.hasPrefix("read_"), !reads.contains(name), result?["changed"] as? Bool != false else { return [] }
        if let changed = result?["changed"] as? [String], changed.isEmpty { return [] }
        func flatten(_ command: [String: Any]) -> [[String: Any]] {
            if command["op"] as? String == "batch", let commands = command["commands"] as? [[String: Any]] { return commands.flatMap(flatten) }
            if command["op"] as? String == "coalesced_edit", let nested = command["command"] as? [String: Any] { return flatten(nested) }
            return [command]
        }
        func time(_ ns: Int64) -> String { String(format: "%lld:%02lld", ns / 1_000_000_000 / 60, ns / 1_000_000_000 % 60) }
        func scalar(_ value: Any?, fallback: Double = 0) -> String { String(format: "%g", (value as? NSNumber)?.doubleValue ?? fallback) }
        func seconds(_ value: Any?) -> Int64? {
            guard let value = (value as? NSNumber)?.doubleValue, value.isFinite, value >= 0, value < Double(Int64.max) / 1e9 else { return nil }
            return Int64((value * 1e9).rounded())
        }
        func quote(_ text: String) -> String {
            let compact = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return "‘" + String(compact.prefix(70)) + (compact.count > 70 ? "…" : "") + "’"
        }
        var fallback = args; fallback["op"] = name
        let commands = (args["commands"] as? [[String: Any]] ?? (args["command"].map { [$0 as? [String: Any] ?? [:]] } ?? [fallback])).flatMap(flatten)
        return commands.compactMap { command in
            let op = command["op"] as? String ?? name
            guard !op.hasPrefix("read_"), !reads.contains(op) else { return nil }
            let record = command["record"] as? [String: Any] ?? command
            let ns = (command["tl_start_ns"] as? NSNumber)?.int64Value ?? (command["at_tl_ns"] as? NSNumber)?.int64Value ?? (record["tl_start_ns"] as? NSNumber)?.int64Value ?? seconds(result?["at_s"] ?? command["at_s"] ?? command["from_s"])
            let end = (command["tl_end_ns"] as? NSNumber)?.int64Value
            let at = ns.map { " " + time($0) } ?? ""
            let count = (result?["removed_count"] as? NSNumber)?.intValue
            var label: String
            var symbol = "sparkles"
            switch op {
            case "delete_range":
                label = "Cut" + (ns.flatMap { start in end.map { " \(time(start))–\(time($0))" } } ?? " selection")
                if let text = command["text"] as? String { label += " " + quote(text) }
                symbol = "scissors"
            case "cut_words":
                label = "Cut words"
                if let text = result?["text"] as? String, !text.isEmpty { label += " " + quote(text) }
                symbol = "scissors"
            case "tighten_pauses": label = count.map { "Tightened \($0) pauses" } ?? "Tightened pauses"; symbol = "scissors"
            case "remove_fillers": label = count.map { "Removed \($0) filler ranges" } ?? "Removed fillers"; symbol = "scissors"
            case "trim_start_to_first_word": label = "Trimmed opening to first word"; symbol = "scissors"
            case "zoom_on_click": label = "Zoom \(scalar(command["scale"], fallback: 1.8))× on click" + at; symbol = "plus.magnifyingglass"
            case "add_zoom": label = "Zoom \(scalar(command["scale"], fallback: 2))×" + at; symbol = "plus.magnifyingglass"
            case "update_zoom": label = "Adjusted zoom"; symbol = "plus.magnifyingglass"
            case "remove_zoom": label = "Removed zoom"; symbol = "minus.magnifyingglass"
            case "auto_zooms": label = "Added automatic zooms"; symbol = "plus.magnifyingglass"
            case "add_caption", "add_annotation", "add_reaction":
                let title = op == "add_caption" ? "Caption" : op == "add_annotation" ? "Text" : "Reaction"
                label = title + ((record["text"] as? String).map { " " + quote($0) } ?? "") + at
                symbol = "text.bubble"
            case "update_caption": label = "Edited caption"; symbol = "text.bubble"
            case "remove_caption": label = "Removed caption"; symbol = "text.bubble"
            case "import_transcript", "transcribe": label = "Generated captions"; symbol = "text.bubble"
            case "set":
                let path = command["path"] as? String ?? "setting"
                let value = command["value"]
                if path == "canvas.padding_ratio" { label = "Padding \(scalar((value as? NSNumber).map { $0.doubleValue * 100 })) %" }
                else if path == "canvas.padding" { label = "Padding \(scalar(value)) px" }
                else if path == "canvas.background" {
                    let background = value as? [String: Any] ?? [:]
                    if let wallpaper = background["wallpaper_id"] as? String { label = "Background: wallpaper " + wallpaper.replacingOccurrences(of: "-", with: " ").capitalized }
                    else { label = "Background: " + (background["kind"] as? String ?? "updated").replacingOccurrences(of: "_", with: " ") }
                } else if path == "canvas.background.wallpaper_id", let wallpaper = value as? String { label = "Background: wallpaper " + wallpaper.replacingOccurrences(of: "-", with: " ").capitalized }
                else if path == "canvas.background.kind", let kind = value as? String { label = "Background: " + kind.replacingOccurrences(of: "_", with: " ") }
                else if path == "notes" { label = "Updated speaker notes" }
                else if let visible = value as? Bool { label = path.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ").capitalized + (visible ? ": on" : ": off") }
                else { label = "Adjusted " + path.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ") }
            case "split": label = "Split clip" + at; symbol = "scissors"
            case "set_speed": label = "Clip speed \(scalar(command["speed"], fallback: 1))×"
            case "process_silence": label = "Tightened silence"; symbol = "scissors"
            case "apply_preset": label = "Applied visual preset"
            case "auto_speed_typing", "apply_typing_suggestion": label = "Sped up typing"
            case "undo": label = "Undid last edit"; symbol = "arrow.uturn.backward"
            case "redo": label = "Redid last edit"; symbol = "arrow.uturn.forward"
            default: label = op.replacingOccurrences(of: "_", with: " ").capitalized
            }
            return AgentChange(label: label, timeNs: ns, symbol: symbol)
        }
    }
}
