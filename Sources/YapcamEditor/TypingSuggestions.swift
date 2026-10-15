import Foundation

/// Keystroke bursts that are worth speeding up: key gaps under 0.5 s, at least 1.5 s long, at least 2 keys per second.
public enum TypingBursts {
    public static func detect(_ keyTimesNs: [Int64], maxGapNs: Int64 = 500_000_000, minDurationNs: Int64 = 1_500_000_000, minKeysPerSecond: Double = 2) -> [TimeSpan] {
        let times = keyTimesNs.sorted()
        var out: [TimeSpan] = []
        var group: [Int64] = []
        func flush() {
            defer { group = [] }
            guard let first = group.first, let last = group.last, last - first >= minDurationNs else { return }
            let rate = Double(group.count) / (Double(last - first) / 1e9)
            if rate >= minKeysPerSecond { out.append(TimeSpan(startNs: first, endNs: last)) }
        }
        for t in times {
            if let prev = group.last, t - prev >= maxGapNs { flush() }
            group.append(t)
        }
        flush()
        return out
    }
}

extension EditorModel {
    public static let typingSpeedKey = "yapcam.typingSpeed"
    public static let typingSpeedRange = 1.5...8.0

    /// Remembered speed for typing suggestions (default 3x).
    public var typingSpeed: Double {
        get { let v = defaults.double(forKey: Self.typingSpeedKey); return v == 0 ? 3 : min(max(v, Self.typingSpeedRange.lowerBound), Self.typingSpeedRange.upperBound) }
        set { defaults.set(min(max(newValue, Self.typingSpeedRange.lowerBound), Self.typingSpeedRange.upperBound), forKey: Self.typingSpeedKey); objectWillChange.send() }
    }

    /// Open suggestions on the current timeline (from core: source-stable ids, dismissals persist in the project).
    public var typingSuggestions: [TimeSpan] { project.typingRecords.map(\.span) }

    public func applyTypingSuggestion(_ span: TimeSpan) {
        if let r = project.typingRecords.first(where: { $0.span.startNs == span.startNs }) {
            perform(.applyTypingSuggestion(id: r.id, speed: typingSpeed))
        } else {
            perform(.processSilence(spans: [span], speed: typingSpeed))               // a stretch core does not list as a burst
        }
        typingPopover = nil
    }
    public func applyAllTypingSuggestions() {
        guard !typingSuggestions.isEmpty else { return }
        perform(.autoSpeedTyping(speed: typingSpeed)); typingPopover = nil
    }
    public func dismissTypingSuggestion(_ span: TimeSpan) {
        if let r = project.typingRecords.first(where: { $0.span.startNs == span.startNs }) { perform(.dismissTypingSuggestion(id: r.id)) }
        typingPopover = nil
    }
    public func restoreTypingSuggestions() { perform(.restoreTypingSuggestions) }
}
