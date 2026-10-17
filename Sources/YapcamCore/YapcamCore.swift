@_exported import CYapcamCore
import Foundation

public enum YapcamCore {
    public static var abiVersion: UInt32 { yc_abi_version() }
}

/// Rust serializes mutations and publishes complete states under a brief lock.
/// Reads can run during journal IO. A snapshot owns independent edit/capture
/// state. Notifications are posted after Rust releases its writer gate.
public final class Project: @unchecked Sendable {
    public let packageURL: URL
    public let session: SessionInfo
    public static let didChange = Notification.Name("YapcamCore.Project.didChange")
    private let handle: OpaquePointer
    // Only mutations use this gate. Frame/query reads never wait for journal IO.
    private let mutationGate = NSLock()
    private var closed = false
    private var mutationRevision: UInt64 = 0
    private var savedRevision: UInt64 = 0
    private init(handle: OpaquePointer, package: URL, session: SessionInfo, dirty: Bool = false) {
        self.handle = handle; packageURL = package; self.session = session
        mutationRevision = dirty ? 1 : 0
    }
    deinit { yc_project_free(handle) }
    private static func check(_ status: YcStatus) throws {
        guard status == YC_OK else {
            let message = String(cString: yc_last_error())
            switch status {
            case YC_ERR_MISSING_MEDIA:
                let paths = (try? JSONDecoder().decode([String].self, from: Data(message.utf8))) ?? [message]
                throw CoreError.missingMedia(paths)
            case YC_ERR_UNSUPPORTED_VERSION:
                let version = message.split(whereSeparator: { !$0.isNumber }).last.flatMap { Int($0) } ?? 0
                throw CoreError.unsupportedVersion(version)
            default: throw CoreError.status(Int32(status.rawValue), message)
            }
        }
    }
    private static func stringResult(_ call: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> YcStatus) throws -> Data {
        var text: UnsafeMutablePointer<CChar>?
        try check(call(&text))
        guard let text else { throw CoreError.status(99, "Core returned no JSON") }
        defer { yc_string_free(text) }
        return Data(String(cString: text).utf8)
    }
    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase; return decoder
    }
    private static func load(package: URL, create: Bool) throws -> Project {
        guard package.isFileURL else { throw CoreError.status(1, "Project package must be a file URL") }
        var raw: OpaquePointer?
        try package.path.withCString { path in try check(create ? yc_project_create(path, &raw) : yc_project_open(path, &raw)) }
        guard let raw else { throw CoreError.status(99, "Core returned no project") }
        do {
            let bytes = try "{\"q\":\"session\"}".withCString { query in try stringResult { yc_query(raw, query, $0) } }
            let session = try decoder().decode(SessionInfo.self, from: bytes)
            return Project(handle: raw, package: package, session: session, dirty: create || FileManager.default.fileExists(atPath: package.appendingPathComponent("autosave/project.json").path))
        } catch { yc_project_free(raw); throw error }
    }
    public static func create(package: URL) throws -> Project { try load(package: package, create: true) }
    public static func open(package: URL) throws -> Project { try load(package: package, create: false) }
    /// Permanently stop this wrapper from editing or saving. Waits for its active
    /// mutation to finish; does not save, free the handle, or close export snapshots.
    /// Reads remain available. Call after the document's final save, before reopen.
    public func close() {
        mutationGate.lock(); defer { mutationGate.unlock() }
        closed = true
    }
    private func withMutation<T>(_ body: () throws -> T) throws -> T {
        mutationGate.lock(); defer { mutationGate.unlock() }
        guard !closed else { throw CoreError.status(6, "Project is closed") }
        return try body()
    }
    public func save() throws {
        try withMutation {
            try packageURL.path.withCString { try Self.check(yc_project_save(handle, $0)) }
            savedRevision = mutationRevision
        }
    }
    /// A timer may save only the revision it observed. Stale timers do no IO.
    @discardableResult public func save(ifRevision expected: UInt64) throws -> Bool {
        try withMutation {
            guard mutationRevision == expected else { return false }
            try packageURL.path.withCString { try Self.check(yc_project_save(handle, $0)) }
            savedRevision = mutationRevision
            return true
        }
    }
    public var isClosed: Bool {
        mutationGate.lock(); defer { mutationGate.unlock() }
        return closed
    }
    public var revision: UInt64 {
        mutationGate.lock(); defer { mutationGate.unlock() }
        return mutationRevision
    }
    public var isDirty: Bool {
        mutationGate.lock(); defer { mutationGate.unlock() }
        return mutationRevision != savedRevision
    }
    @discardableResult public func apply(_ command: EditCommand) throws -> ChangeSet {
        let bytes = try JSONEncoder().encode(command)
        let changes = try withMutation {
            let result = try String(decoding: bytes, as: UTF8.self).withCString { c in try Self.stringResult { yc_apply(handle, c, $0) } }
            let changes = try JSONDecoder().decode(ChangeSet.self, from: result)
            if !changes.changed.isEmpty { mutationRevision &+= 1 }
            return changes
        }
        if !changes.changed.isEmpty { NotificationCenter.default.post(name: Self.didChange, object: self) }
        return changes
    }
    public func undo() throws {
        let did = try withMutation {
            var did: UInt8 = 0; try Self.check(yc_undo(handle, &did)); if did != 0 { mutationRevision &+= 1 }; return did
        }
        if did != 0 { NotificationCenter.default.post(name: Self.didChange, object: self) }
    }
    public func redo() throws {
        let did = try withMutation {
            var did: UInt8 = 0; try Self.check(yc_redo(handle, &did)); if did != 0 { mutationRevision &+= 1 }; return did
        }
        if did != 0 { NotificationCenter.default.post(name: Self.didChange, object: self) }
    }
    public var canUndo: Bool { yc_can_undo(handle) != 0 }
    public var canRedo: Bool { yc_can_redo(handle) != 0 }
    public var durationNs: Int64 { var value: Int64 = 0; guard yc_timeline_duration(handle, &value) == YC_OK else { return 0 }; return value }
    public func frame(atNs: Int64) throws -> YcFrame {
        var frame = YcFrame(); try Self.check(yc_frame_at(handle, atNs, &frame)); return frame
    }
    public func frameExtras(atNs: Int64) throws -> YcFrameExtras {
        var extras = YcFrameExtras(); try Self.check(yc_frame_extras_at(handle, atNs, &extras)); return extras
    }
    public func frameMotion(atNs: Int64) throws -> YcFrameMotion {
        var motion = YcFrameMotion(); try Self.check(yc_frame_motion_at(handle, atNs, &motion)); return motion
    }
    public func query<T: Decodable>(_ query: String, as: T.Type) throws -> T {
        let data = try query.withCString { c in try Self.stringResult { yc_query(handle, c, $0) } }
        return try Self.decoder().decode(T.self, from: data)
    }
    public func snapshot() throws -> Project {
        var clone: OpaquePointer?
        try Self.check(yc_project_clone(handle, &clone))
        guard let clone else { throw CoreError.status(99, "Core returned no snapshot") }
        return Project(handle: clone, package: packageURL, session: session)
    }
    public func toJSON() throws -> Data { try Self.stringResult { yc_project_to_json(handle, $0) } }
}
