import Foundation

/// Every window position Yapcam remembers, so one button can put them all back.
@MainActor enum WindowPositions {
    static let fixedKeys = ["cameraPreviewOrigin", "NSWindow Frame YapcamHome"]

    /// Keys in `store` that hold a remembered window position.
    static func keys(in store: UserDefaults) -> [String] {
        store.dictionaryRepresentation().keys.filter { fixedKeys.contains($0) || $0.hasPrefix(ToolbarPanelController.positionKeyPrefix) }
    }

    @discardableResult
    static func resetAll(in store: UserDefaults = AppDefaults.store) -> Int {
        let found = keys(in: store)
        found.forEach { store.removeObject(forKey: $0) }
        return found.count
    }
}
