@preconcurrency import AVFoundation
import CoreMediaIO
import Foundation

/// Capability-based identification avoids depending on a phone's user-chosen name.
/// iOS screen inputs are external/muxed devices after CoreMediaIO's process opt-in;
/// Continuity Camera and ordinary external video cameras are separate sources.
enum DeviceScreenDiscovery {
    struct Device: Sendable, Equatable {
        var id: String
        var name: String
        var width: Int
        var height: Int

        func geometry() throws -> CaptureGeometry {
            try CaptureGeometry(rect: CGRect(x: 0, y: 0, width: width, height: height), scale: 1)
        }

        func source() throws -> SourceMetadata {
            var source = try geometry().sourceMetadata(kind: "device", displayID: 0, displayNames: [0: name])
            source.deviceID = id
            source.deviceName = name
            return source
        }
    }

    struct Candidate: Sendable {
        var device: Device
        var external: Bool
        var muxed: Bool
        var connected: Bool
        var continuityCamera: Bool
    }

    static func enableScreenDevices() throws {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var enabled: UInt32 = 1
        let status = CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address,
                                             0, nil, UInt32(MemoryLayout<UInt32>.size), &enabled)
        guard status == noErr else {
            throw CaptureError.writerFailed("USB screen discovery unavailable (CoreMediaIO \(status))")
        }
        // Wireless screen discovery is deliberately not enabled.
    }

    static func isScreenDevice(_ device: AVCaptureDevice) -> Bool {
        device.deviceType == .external && device.hasMediaType(.muxed) && !device.isContinuityCamera
    }

    static func candidates() -> [Candidate] {
        // Query both media types: some external devices advertise muxed capability
        // while being enumerated in the video discovery list. Deduplicate by UID.
        return rawDevices().map { device in
            let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            return Candidate(device: Device(id: device.uniqueID, name: device.localizedName,
                                            width: Int(dimensions.width), height: Int(dimensions.height)),
                             external: device.deviceType == .external, muxed: device.hasMediaType(.muxed),
                             connected: device.isConnected, continuityCamera: device.isContinuityCamera)
        }
    }

    private static func rawDevices() -> [AVCaptureDevice] {
        var devices: [AVCaptureDevice] = []
        for media in [AVMediaType.muxed, AVMediaType.video] {
            devices.append(contentsOf: AVCaptureDevice.DiscoverySession(
                deviceTypes: [.external], mediaType: media, position: .unspecified).devices)
        }
        return devices
    }

    static func load(enable: () throws -> Void = enableScreenDevices,
                     discover: () -> [Candidate] = candidates) throws -> [Device] {
        try enable()
        var seen = Set<String>()
        return discover().filter {
            $0.external && $0.muxed && $0.connected && !$0.continuityCamera
                && $0.device.width >= 2 && $0.device.height >= 2
                && !$0.device.id.isEmpty && seen.insert($0.device.id).inserted
        }.map(\.device).sorted { $0.id < $1.id }
    }

    static func require(_ id: String, devices: [Device]) throws -> Device {
        guard let device = devices.first(where: { $0.id == id }) else { throw CaptureError.deviceLost(id) }
        _ = try device.geometry()
        return device
    }

    static func captureDevice(_ id: String) throws -> AVCaptureDevice {
        try enableScreenDevices()
        guard let device = rawDevices().first(where: { $0.uniqueID == id && $0.isConnected && isScreenDevice($0) }) else {
            throw CaptureError.deviceLost(id)
        }
        return device
    }
}
