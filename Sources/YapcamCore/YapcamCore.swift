@_exported import CYapcamCore
import Foundation

public enum YapcamCore {
    public static var abiVersion: UInt32 { yc_abi_version() }
}

/// Calls are serialized; a snapshot owns independent immutable capture data and
/// its own edit state. Notifications are posted after releasing the project lock.
public final class Project: @unchecked Sendable {
    public let packageURL: URL
    public let session: SessionInfo
    public static let didChange = Notification.Name("YapcamCore.Project.didChange")
    private let handle: OpaquePointer
    private let lock = NSLock()
    private init(handle: OpaquePointer, package: URL, session: SessionInfo) {
        self.handle = handle; packageURL = package; self.session = session
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
            return Project(handle: raw, package: package, session: session)
        } catch { yc_project_free(raw); throw error }
    }
    public static func create(package: URL) throws -> Project { try load(package: package, create: true) }
    public static func open(package: URL) throws -> Project { try load(package: package, create: false) }
    private func locked<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }
    public func save() throws {
        try locked { try packageURL.path.withCString { try Self.check(yc_project_save(handle, $0)) } }
    }
    @discardableResult public func apply(_ command: EditCommand) throws -> ChangeSet {
        let bytes = try JSONEncoder().encode(command)
        let changes: ChangeSet = try locked {
            let result = try String(decoding: bytes, as: UTF8.self).withCString { c in try Self.stringResult { yc_apply(handle, c, $0) } }
            return try JSONDecoder().decode(ChangeSet.self, from: result)
        }
        if !changes.changed.isEmpty { NotificationCenter.default.post(name: Self.didChange, object: self) }
        return changes
    }
    public func undo() throws {
        let did: Bool = try locked { var did: UInt8 = 0; try Self.check(yc_undo(handle, &did)); return did != 0 }
        if did { NotificationCenter.default.post(name: Self.didChange, object: self) }
    }
    public func redo() throws {
        let did: Bool = try locked { var did: UInt8 = 0; try Self.check(yc_redo(handle, &did)); return did != 0 }
        if did { NotificationCenter.default.post(name: Self.didChange, object: self) }
    }
    public var canUndo: Bool { locked { yc_can_undo(handle) != 0 } }
    public var canRedo: Bool { locked { yc_can_redo(handle) != 0 } }
    public var durationNs: Int64 { locked { var value: Int64 = 0; guard yc_timeline_duration(handle, &value) == YC_OK else { return 0 }; return value } }
    public func frame(atNs: Int64) throws -> YcFrame {
        try locked { var frame = YcFrame(); try Self.check(yc_frame_at(handle, atNs, &frame)); return frame }
    }
    public func query<T: Decodable>(_ query: String, as: T.Type) throws -> T {
        try locked {
            let data = try query.withCString { c in try Self.stringResult { yc_query(handle, c, $0) } }
            return try Self.decoder().decode(T.self, from: data)
        }
    }
    public func snapshot() throws -> Project {
        try locked {
            var clone: OpaquePointer?
            try Self.check(yc_project_clone(handle, &clone))
            guard let clone else { throw CoreError.status(99, "Core returned no snapshot") }
            return Project(handle: clone, package: packageURL, session: session)
        }
    }
    public func toJSON() throws -> Data { try locked { try Self.stringResult { yc_project_to_json(handle, $0) } } }
}
