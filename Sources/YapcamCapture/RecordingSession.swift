import AppKit
@preconcurrency import AVFoundation
import Combine
import ScreenCaptureKit

@MainActor public final class RecordingSession: ObservableObject {
    @Published public private(set) var state: RecordingState = .idle
    @Published public private(set) var elapsed: TimeInterval = 0
    @Published public private(set) var micLevel: Float = 0
    @Published public private(set) var warnings: [String] = []
    public private(set) var packageURL: URL?
    private let options: RecordingOptions
    private let services: CaptureSessionServices
    private var manifest: SessionManifest?
    private var packageLease: RecordingPackageLease?
    private var stream: (any CaptureSessionStream)?
    private var writer: SegmentWriter?
    private var events: InputEventRecorder?
    private var devices: AuxiliaryCapture?
    private var timer: Timer?
    private let operationGate = CaptureOperationGate()
    private var busy: Bool {
        get { operationGate.isBusy }
        set { operationGate.setBusy(newValue) }
    }
    private var monitoring = false
    private var pendingFailure: CaptureError?
    private var completedNs: Int64 = 0
    private var activeStartNs: Int64?
    private var activeHostStartNs: Int64?

    public convenience init(options: RecordingOptions) { self.init(options: options, services: .live) }

    init(options: RecordingOptions, services: CaptureSessionServices) {
        self.options = options; self.services = services
    }

    private var isDeviceScreen: Bool { if case .device = options.target { return true }; return false }
    private func requireSourcePermissions() throws {
        let required: [Permission] = isDeviceScreen ? (options.systemAudio ? [.camera, .microphone] : [.camera]) : [.screen]
        for permission in required where services.permissionState(permission) != .granted {
            throw CaptureError.permissionDenied(permission)
        }
    }

    public func start() async throws {
        guard state == .idle, !busy else { throw invalidState("start") }
        busy = true; state = .preparing
        defer { busy = false }
        do {
            try requireSourcePermissions()
            try FileManager.default.createDirectory(at: options.outputDirectory, withIntermediateDirectories: true)
            try PackageIO.requireSpace(services.availableBytes(options.outputDirectory))
            let resolved = try await services.prepare(options)
            _ = try Self.outputSize(resolved.source)
            let name = "Recording-\(Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).dateSeparator(.dash).timeSeparator(.omitted)))-\(UUID().uuidString.prefix(6)).yapcam"
            let package = options.outputDirectory.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: package.appendingPathComponent("recording"), withIntermediateDirectories: true)
            packageURL = package
            packageLease = try RecordingPackageLease(package: package)
            manifest = SessionManifest(source: resolved.source, tracks: TrackMetadata(
                screen: ScreenMetadata(pixelSize: [resolved.geometry.pixelWidth, resolved.geometry.pixelHeight], maxFPS: resolved.maxFPS),
                systemAudio: options.systemAudio ? AudioMetadata(sampleRate: 48_000, channels: 2) : nil))
            try persist()
            try await beginSegment(resolved)
            try Task.checkCancellation()
            if let pendingFailure { throw pendingFailure }
            state = .recording
            startTimer()
        } catch {
            let captureError = asCaptureError(error)
            await fail(captureError)
            throw captureError
        }
    }

    public func pause() async throws {
        guard state == .recording, !busy else { throw invalidState("pause") }
        busy = true; state = .finishing
        defer { busy = false }
        do {
            try await endSegment()
            state = .paused
        } catch {
            let error = asCaptureError(error); await fail(error); throw error
        }
    }

    /// UI invokes this from the rebindable marker shortcut while recording.
    @discardableResult public func addMarker() throws -> RecordingMarker {
        try addMarker(atHostNs: CaptureClock.now)
    }

    @discardableResult func addMarker(atHostNs host: Int64) throws -> RecordingMarker {
        guard state == .recording, !busy, let events, let index = manifest?.segments.last?.index,
              let origin = activeHostStartNs, host >= origin,
              host - origin <= Int64.max - completedNs else { throw invalidState("add marker") }
        let id = UUID().uuidString
        let time = try events.addMarker(id: id, hostNs: host)
        guard time <= Int64.max - completedNs else { throw invalidState("add marker") }
        return RecordingMarker(id: id, segmentIndex: index, segmentNs: time, srcNs: completedNs + time)
    }

    public func resume() async throws {
        guard state == .paused, !busy else { throw invalidState("resume") }
        busy = true; state = .preparing
        defer { busy = false }
        do {
            try requireSourcePermissions()
            guard let packageURL else { throw invalidState("resume") }
            try PackageIO.requireSpace(services.availableBytes(packageURL))
            guard let initial = manifest?.tracks.screen else { throw invalidState("resume") }
            // A window can move onto a different-refresh display while paused.
            // Keep the first display's rate and manifest clock for the whole take.
            var resumeOptions = options
            resumeOptions.maxFPS = initial.maxFPS
            let resolved = try await services.prepare(resumeOptions)
            switch options.target {
            case .window: break // Resized windows retain the initial encoded surface.
            default:
                guard initial.pixelSize == [resolved.geometry.pixelWidth, resolved.geometry.pixelHeight],
                      manifest?.source.scale == resolved.source.scale else {
                    throw CaptureError.writerFailed("Capture source dimensions or scale changed while paused; start a new recording")
                }
            }
            try await beginSegment(resolved)
            try Task.checkCancellation()
            if let pendingFailure { throw pendingFailure }
            state = .recording
            startTimer()
        } catch {
            let error = asCaptureError(error); await fail(error); throw error
        }
    }

    public func stop() async throws -> URL {
        if case .finished(let url) = state { return url }
        // A stop requested while stream startup/finalization is suspended must be
        // remembered, not rejected as a transient invalid-state button click.
        await operationGate.acquire()
        defer { busy = false }
        if case .finished(let url) = state { return url }
        if case .failed(let error) = state { throw error }
        guard (state == .recording || state == .paused), let packageURL else { throw invalidState("stop") }
        state = .finishing
        do {
            if writer != nil { try await endSegment() }
            manifest?.status = "complete"
            try persist()
            packageLease = nil
            state = .finished(packageURL)
            return packageURL
        } catch {
            let error = asCaptureError(error); await fail(error); throw error
        }
    }

    public func cancel() async {
        // Serialize cancellation with a potentially in-flight SCStream start/stop.
        await operationGate.acquire()
        state = .finishing
        defer { busy = false }
        if writer != nil { try? await endSegment() }
        timer?.invalidate(); timer = nil
        do {
            if let packageURL { try FileManager.default.removeItem(at: packageURL) }
            packageURL = nil; manifest = nil; state = .cancelled
        } catch { state = .failed(asCaptureError(error)) }
        packageLease = nil
    }

    private func beginSegment(_ resolved: CaptureSessionPlan) async throws {
        guard let packageURL, var manifest else { throw invalidState("begin segment") }
        completedNs = try SegmentTimeline.nextSourceStart(after: manifest.segments)
        let index = manifest.segments.count
        let dir = String(format: "seg-%03d", index)
        let directory = packageURL.appendingPathComponent("recording/\(dir)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let start = CaptureClock.now
        activeStartNs = start
        var metadata = SegmentMetadata(index: index, dir: dir, srcStartNs: completedNs, hostStartNs: start)
        metadata.files = ["screen": "\(dir)/screen.mov", "events": "\(dir)/events.jsonl", "cursors": "\(dir)/cursors.json"]
        if options.systemAudio { metadata.files["system_audio"] = "\(dir)/system.m4a" }
        manifest.segments.append(metadata)
        self.manifest = manifest
        try persist()
        let writer = services.makeWriter(directory, start, manifest.tracks.screen.maxFPS)
        pendingFailure = nil
        writer.onWarning = { [weak self] message in
            Task { @MainActor in
                guard let self, self.activeStartNs == start else { return }
                self.warn(message)
            }
        }
        writer.onFailure = { [weak self] error in
            Task { @MainActor in
                guard let self, self.activeStartNs == start else { return }
                await self.handleFailure(error)
            }
        }
        writer.onMicLevel = { [weak self] level in
            Task { @MainActor in
                guard let self, self.activeStartNs == start else { return }
                self.micLevel = level
            }
        }
        writer.onAudioFormat = { [weak self] key, format in
            Task { @MainActor in
                guard let self, self.activeStartNs == start else { return }
                self.updateAudioFormat(format, key: key)
                do { try self.persist() } catch { await self.handleFailure(self.asCaptureError(error)) }
            }
        }
        writer.onTrackStarted = { [weak self] key, offset in
            Task { @MainActor in
                guard let self, self.activeStartNs == start, self.manifest?.segments.indices.contains(index) == true else { return }
                self.manifest?.segments[index].trackStartNs[key] = offset
                let filename = key == "system_audio" ? "system.m4a" : key == "mic" ? "mic.m4a" : "\(key).mov"
                self.manifest?.segments[index].files[key] = "\(dir)/\(filename)"
                do { try self.persist() } catch { await self.handleFailure(self.asCaptureError(error)) }
            }
        }
        self.writer = writer
        let outputSize = try Self.outputSize(manifest.source)
        // Start the screen before auxiliary-device setup can delay it. Nothing is
        // exposed as recording until an actual written screen frame defines t=0.
        let stream = try resolved.makeStream(writer, manifest.tracks.screen.pixelSize)
        self.stream = stream
        try await stream.startCapture()
        let origin = try await writer.firstScreenStart()
        activeHostStartNs = origin
        self.manifest?.segments[index].hostStartNs = origin
        try persist()
        let events = InputEventRecorder(directory: directory, rect: resolved.geometry.rect, hostStartNs: origin,
                                        keys: options.recordKeystrokes && services.permissionState(.inputMonitoring) == .granted,
                                        outputSize: outputSize)
        events.warning = { [weak self] in self?.warn($0) }
        events.failure = { [weak self] error in
            Task { @MainActor in
                guard let self, self.activeStartNs == start else { return }
                await self.handleFailure(error)
            }
        }
        self.events = events
        if case .window = options.target {
            let initialScale = CGFloat(manifest.source.scale)
            writer.onGeometry = { [weak self] screen, content, scale in
                Task { @MainActor in
                    guard let self, self.activeStartNs == start else { return }
                    let ratio = scale / initialScale
                    let destination = CGRect(x: content.minX * ratio, y: content.minY * ratio,
                                             width: content.width * ratio, height: content.height * ratio)
                    self.events?.updateContentRect(screen, destination: destination)
                }
            }
        }
        // The Mac's cursor/keys do not describe touches on the USB device screen.
        if isDeviceScreen { try events.openEventLog() }
        else { try services.startEvents(events) }
        // Camera devices commonly offer 30/60, independently of the screen's refresh.
        let devices = AuxiliaryCapture(writer: writer, fps: manifest.tracks.screen.maxFPS >= 60 ? 60 : 30)
        devices.onWarning = writer.onWarning
        self.devices = devices
        let deviceMetadata = await devices.start(microphoneID: options.microphoneID, cameraID: options.cameraID, cameraMaxResolution: options.cameraMaxResolution)
        if let mic = deviceMetadata.mic { self.manifest?.tracks.mic = mic }
        if let camera = deviceMetadata.camera { self.manifest?.tracks.camera = camera }
        try persist()
    }

    private func endSegment() async throws {
        timer?.invalidate(); timer = nil
        let end = CaptureClock.now
        writer?.end(at: end)
        var failure: CaptureError?
        do { try events?.stop() } catch { failure = asCaptureError(error) }
        events = nil
        if let stream {
            do { try await stream.stopCapture() } catch { failure = asCaptureError(error) }
        }
        self.stream = nil
        await devices?.stop(); devices = nil; micLevel = 0
        if let writer {
            let result = await writer.finish()
            let origin = result.hostStartNs ?? end
            let duration = max(0, end - origin)
            if let index = manifest?.segments.indices.last, let dir = manifest?.segments[index].dir {
                manifest?.segments[index].hostStartNs = origin
                manifest?.segments[index].durationNs = duration
                manifest?.segments[index].trackStartNs = result.starts
                var files = result.files.mapValues { "\(dir)/\($0)" }
                files["events"] = "\(dir)/events.jsonl"; files["cursors"] = "\(dir)/cursors.json"
                manifest?.segments[index].files = files
            }
            for (key, format) in result.audioFormats { updateAudioFormat(format, key: key) }
            completedNs = try SegmentTimeline.nextSourceStart(after: manifest?.segments ?? [])
            failure = failure ?? result.error ?? pendingFailure
        }
        writer = nil; activeStartNs = nil; activeHostStartNs = nil; pendingFailure = nil
        elapsed = Double(completedNs) / 1_000_000_000
        try persist()
        if let failure { throw failure }
    }

    private func updateAudioFormat(_ format: AudioMetadata, key: String) {
        var format = format
        if key == "system_audio" {
            format.deviceName = isDeviceScreen ? manifest?.source.deviceName : manifest?.tracks.systemAudio?.deviceName
            manifest?.tracks.systemAudio = format
        } else if key == "mic" {
            format.deviceName = manifest?.tracks.mic?.deviceName
            manifest?.tracks.mic = format
        }
    }

    private func startTimer() {
        guard services.automaticHealthChecks else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state == .recording, let start = self.activeHostStartNs else { return }
                self.elapsed = Double(self.completedNs + max(0, CaptureClock.now - start)) / 1_000_000_000
                if !self.monitoring {
                    self.monitoring = true
                    Task { @MainActor in
                        defer { self.monitoring = false }
                        await self.checkHealth()
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
            }
        }
    }

    func checkHealth() async {
        guard state == .recording, !busy, let packageURL, let generation = activeStartNs else { return }
        do {
            try PackageIO.requireSpace(services.availableBytes(packageURL))
            try requireSourcePermissions()
            if let validateSource = services.validateSource {
                try await validateSource(options)
                guard state == .recording, !busy, activeStartNs == generation else { return }
                return
            }
            switch options.target {
            case .display(let id), .area(let id, _):
                guard CGDisplayIsActive(id) != 0 else { throw CaptureError.sourceUnavailable }
                let bounds = CGDisplayBounds(id)
                switch options.target {
                case .display:
                    if let source = manifest?.source,
                       try Self.outputSize(source) != bounds.size {
                        throw CaptureError.writerFailed("Display dimensions changed during recording")
                    }
                    events?.updateContentRect(bounds)
                case .area(_, let area):
                    guard CGRect(origin: .zero, size: bounds.size).contains(area) else { throw CaptureError.sourceUnavailable }
                    events?.updateContentRect(area.offsetBy(dx: bounds.minX, dy: bounds.minY))
                case .window, .device: break
                }
                if options.hideDesktopIcons || !options.captureNotifications {
                    // Newly opened Finder folders must remain visible, while
                    // Finder's desktop-icon surfaces remain excluded.
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    guard state == .recording, !busy, activeStartNs == generation else { return }
                    guard let display = content.displays.first(where: { $0.displayID == id }) else { throw CaptureError.sourceUnavailable }
                    try await stream?.updateContentFilter(CaptureFilterPolicy(options: options).filter(display: display, content: content))
                }
            case .window(let id):
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard state == .recording, !busy, activeStartNs == generation else { return }
                guard let window = content.windows.first(where: { $0.windowID == id }) else { throw CaptureError.sourceUnavailable }
                events?.updateContentRect(window.frame)
            case .device:
                break // AVCaptureSession/device notifications report source loss.
            }
        } catch {
            guard activeStartNs == generation else { return }
            await handleFailure(asCaptureError(error))
        }
    }

    private func handleFailure(_ error: CaptureError) async {
        if busy {
            if state == .preparing || state == .recording || state == .finishing { pendingFailure = pendingFailure ?? error }
            return
        }
        guard state == .recording else { return }
        busy = true; state = .finishing
        await fail(error)
        busy = false
    }
    private func fail(_ error: CaptureError) async {
        if writer != nil { try? await endSegment() }
        timer?.invalidate(); timer = nil
        manifest?.status = "interrupted"
        do { try persist() } catch { warn("Could not persist interrupted recording: \(error.localizedDescription)") }
        packageLease = nil
        state = .failed(error)
    }
    private func persist() throws {
        guard let packageURL, let manifest else { return }
        try PackageIO.write(manifest, to: packageURL.appendingPathComponent("recording/session.json"))
    }
    private static func outputSize(_ source: SourceMetadata) throws -> CGSize {
        guard source.contentRectPoints.count == 4 else {
            throw CaptureError.writerFailed("Capture source geometry is invalid")
        }
        let width = source.contentRectPoints[2]
        let height = source.contentRectPoints[3]
        guard width.isFinite, height.isFinite, width > 0, height > 0 else {
            throw CaptureError.writerFailed("Capture source geometry is invalid")
        }
        return CGSize(width: width, height: height)
    }
    private func warn(_ text: String) { if !warnings.contains(text) { warnings.append(text) } }
    private func invalidState(_ op: String) -> CaptureError { .writerFailed("Cannot \(op) in state \(state)") }
    private func asCaptureError(_ error: Error) -> CaptureError { .from(error) }
}
