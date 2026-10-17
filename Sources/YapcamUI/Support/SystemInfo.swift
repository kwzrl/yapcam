@preconcurrency import AVFoundation
import Foundation

/// The machine facts the diagnostics report lists; injectable so the report is testable.
struct SystemInfo {
    var model: String, chip: String, memoryGB: Int, architecture: String
    var cameras: [String], microphones: [String], defaultMicrophone: String?

    static func sysctl(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: buf)
    }

    static func current() -> SystemInfo {
        let cams = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external], mediaType: .video, position: .unspecified).devices.map(\.localizedName)
        let mics = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices.map(\.localizedName)
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        return SystemInfo(model: sysctl("hw.model"), chip: sysctl("machdep.cpu.brand_string"),
                          memoryGB: Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded()), architecture: arch,
                          cameras: cams, microphones: mics, defaultMicrophone: AVCaptureDevice.default(for: .audio)?.localizedName)
    }
}
