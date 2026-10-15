import Foundation
import YapcamCapture

/// An iPhone or iPad that can be recorded over USB (capture's `CaptureSources.loadDeviceScreens`).
struct IOSDevice: Identifiable, Equatable {
    let id: String
    let name: String
}

/// USB device screens, refreshed while the Device source is in use. Discovery runs off the main
/// thread; nothing is listed unless capture reports it.
@MainActor final class DeviceScreensModel: ObservableObject {
    static let shared = DeviceScreensModel()
    @Published private(set) var devices: [IOSDevice] = []
    @Published private(set) var error: String?
    @Published private(set) var loaded = false
    private var timer: Timer?
    private var loading = false

    func reload() {
        guard !loading else { return }
        loading = true
        Task {
            let result = await Task.detached(priority: .utility) { Result { try CaptureSources.loadDeviceScreens() } }.value
            switch result {
            case .success(let list):
                devices = list.map { IOSDevice(id: $0.id, name: $0.name) }
                error = nil
            case .failure(let e):
                devices = []
                error = UserMessage.describe(e)
            }
            loaded = true
            loading = false
        }
    }

    /// Poll while the Device source is selected or its popover is open (phones appear a moment after plugging in).
    func startPolling() {
        reload()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    func stopPolling() { timer?.invalidate(); timer = nil }

    /// Synchronous fresh look, used right before a recording starts.
    nonisolated static func currentDevices() throws -> [IOSDevice] {
        try CaptureSources.loadDeviceScreens().map { IOSDevice(id: $0.id, name: $0.name) }
    }

    nonisolated static let notFoundMessage = "No iPhone or iPad found. Connect it with a USB cable, unlock it and tap Trust if it asks, then try again."
}
