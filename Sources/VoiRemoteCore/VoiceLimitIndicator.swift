import Foundation

public enum VoiceLimitEndReason: Equatable, Sendable {
    /// The caller has positively identified the device's limit event, not just a timer expiry.
    case deviceLimit
    /// The device reported a code associated with a limit; local semantics remain unverified.
    case reportedDeviceLimit
    case released, interrupted, unknown
}

public enum VoiceLimitPresentation: Equatable, Sendable {
    case hidden
    case countdown(seconds: Int, urgent: Bool)
    /// Estimated duration elapsed, but no device stop event has confirmed an end.
    case approachingLimit
    case ended
    case endedUnconfirmed

    public func showsReleaseHint(after seconds: Int) -> Bool {
        guard VoiceLimitIndicator.startSecondsRange.contains(seconds) else { return false }
        switch self {
        case .countdown(let remaining, _): return remaining <= 60 - seconds
        case .approachingLimit, .ended, .endedUnconfirmed: return true
        case .hidden: return false
        }
    }
}

/// Pure presentation policy. Owns no timers, windows, Bluetooth, audio or input devices.
/// Segment IDs must increase for every real voice segment; old events cannot revive or hide a new one.
public struct VoiceLimitIndicator: Equatable, Sendable {
    public static let defaultStartSeconds = 50
    public static let startSecondsRange = 0...55
    public private(set) var segmentID: UInt64?
    private var latestID: UInt64?
    private var beganAt: TimeInterval?
    private var endedAt: TimeInterval?
    private var supported = false
    private var confirmedEnd = false
    public init() {}

    @discardableResult
    public mutating func begin(segment id: UInt64, at time: TimeInterval, hasRC003Limit: Bool) -> Bool {
        guard time.isFinite, latestID.map({ id > $0 }) ?? true else { return false }
        latestID = id; segmentID = id; beganAt = time; endedAt = nil; supported = hasRC003Limit
        return true
    }
    @discardableResult
    public mutating func end(segment id: UInt64, reason: VoiceLimitEndReason, at time: TimeInterval) -> Bool {
        guard segmentID == id, endedAt == nil, let beganAt, time.isFinite, time >= beganAt else { return false }
        if (reason == .deviceLimit || reason == .reportedDeviceLimit) && supported {
            endedAt = time; confirmedEnd = reason == .deviceLimit
        }
        else { clearActive() }
        return true
    }
    @discardableResult
    public mutating func cancel(segment id: UInt64? = nil) -> Bool {
        if let id, id != segmentID { return false }
        clearActive()
        return true
    }
    private mutating func clearActive() { segmentID = nil; beganAt = nil; endedAt = nil; supported = false }

    public func presentation(at time: TimeInterval) -> VoiceLimitPresentation {
        guard time.isFinite, supported, let beganAt, time >= beganAt else { return .hidden }
        if let endedAt { return time >= endedAt && time < endedAt + 3 ? (confirmedEnd ? .ended : .endedUnconfirmed) : .hidden }
        let elapsed = time - beganAt
        guard elapsed < 60 else { return .approachingLimit }
        let seconds = Int(ceil(60 - elapsed))
        return .countdown(seconds: seconds, urgent: elapsed >= 55)
    }
    /// The owner can sleep until the next visible change instead of polling throughout a recording.
    public func nextUpdate(at time: TimeInterval) -> TimeInterval? {
        guard time.isFinite, supported, let beganAt, time >= beganAt else { return nil }
        if let endedAt { return time < endedAt + 3 ? endedAt + 3 : nil }
        let elapsed = time - beganAt
        if elapsed < 60 { return beganAt + min(60, floor(elapsed) + 1) }
        return nil
    }
}
