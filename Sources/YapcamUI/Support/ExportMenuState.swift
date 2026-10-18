import Foundation

/// The Export menu's editor items need a front editor and no export already running.
enum ExportMenuState {
    static func enabled(hasEditor: Bool, exportRunning: Bool) -> Bool { hasEditor && !exportRunning }
}
