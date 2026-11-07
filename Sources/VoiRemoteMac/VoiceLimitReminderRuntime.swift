import Combine
import Foundation
import VoiRemoteCore

@MainActor public protocol VoiceLimitDeadline: AnyObject {
    func cancel()
}

@MainActor final class SleepingDeadline: VoiceLimitDeadline {
    private var task: Task<Void, Never>?
    init(delay: TimeInterval, action: @escaping @MainActor () -> Void) {
        task = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard !Task.isCancelled else { return }
            action()
        }
    }
    func cancel() { task?.cancel(); task = nil }
    deinit { task?.cancel() }
}

public struct VoiceLimitReminderState: Equatable, Sendable {
    public var presentation: VoiceLimitPresentation = .hidden
    public var position: VoiceLimitReminderPosition = .bottomCenter
    /// Changes once per segment/preview, never once per tick.
    public var displayEpoch: UInt64 = 0
    public var isPreview = false
    public var showsReleaseHint = false
    /// Follow throughout a live segment, including an unconfirmed estimated expiry.
    public var mayFollowCapsule: Bool {
        switch presentation {
        case .countdown, .approachingLimit: return !isPreview
        default: return false
        }
    }
    public init() {}
}

/// Schedules only visible changes. Never accesses HID, audio, input selection or a window.
@MainActor public final class VoiceLimitReminderRuntime: ObservableObject {
    public typealias Schedule = @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> any VoiceLimitDeadline
    @Published public private(set) var state = VoiceLimitReminderState()
    private let clock: @MainActor () -> TimeInterval
    private let schedule: Schedule
    private var deadline: (any VoiceLimitDeadline)?
    private var generation: UInt64 = 0
    private var displayEpoch: UInt64 = 0
    private var policy = VoiceLimitIndicator()
    private var configuration = AppConfiguration()
    private var previewPolicy: VoiceLimitIndicator?
    private var previewUntil: TimeInterval?
    private var suspended = false
    private var stopped = false
    private var blockedSegment: UInt64?

    public init(clock: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                schedule: Schedule? = nil) {
        self.clock = clock
        self.schedule = schedule ?? { delay, action in SleepingDeadline(delay: delay, action: action) }
    }
    public func configure(_ value: AppConfiguration) {
        guard !stopped else { return }
        configuration = value
        // Turning a real feature off also closes an outstanding preview.
        previewPolicy = nil; previewUntil = nil
        refresh()
    }
    public func update(_ value: VoiceLimitIndicator) {
        guard !stopped, !suspended, value != policy else { return }
        if let id = value.segmentID, let blockedSegment, id <= blockedSegment { return }
        if value.segmentID != policy.segmentID { displayEpoch &+= 1 }
        policy = value; previewPolicy = nil; previewUntil = nil
        refresh()
    }
    public func preview() {
        guard !stopped, !suspended else { return }
        let now = clock()
        guard now.isFinite else { return }
        var sample = VoiceLimitIndicator()
        sample.begin(segment: 1, at: now - 48, hasRC003Limit: true)
        previewPolicy = sample; previewUntil = now + 5; displayEpoch &+= 1
        refresh()
    }
    public func suspend() {
        guard !stopped else { return }
        if let id = policy.segmentID { blockedSegment = max(blockedSegment ?? 0, id) }
        suspended = true; policy.cancel(); previewPolicy = nil; previewUntil = nil
        refresh()
    }
    public func resume() { guard !stopped else { return }; suspended = false; refresh() }
    public func shutdown() {
        stopped = true; policy.cancel(); previewPolicy = nil; previewUntil = nil; refresh()
    }
    private func refresh() {
        generation &+= 1; let token = generation
        deadline?.cancel(); deadline = nil
        let now = clock()
        if let until = previewUntil, now >= until { previewPolicy = nil; previewUntil = nil }
        let enabled = configuration.voiceLimitReminderEnabled && configuration.voiceEnabled && configuration.remoteAudioEnabled
        let active = !stopped && !suspended && now.isFinite && (previewPolicy != nil || enabled)
        let selected = previewPolicy ?? policy
        // Preview crosses the default hint threshold; the stored key now controls
        // expansion only, so existing configurations need no destructive migration.
        let startAfter = previewPolicy != nil ? VoiceLimitIndicator.defaultStartSeconds : configuration.voiceLimitReminderStartSeconds
        var next = VoiceLimitReminderState()
        next.position = configuration.voiceLimitReminderPosition; next.displayEpoch = displayEpoch
        next.isPreview = previewPolicy != nil
        if active {
            next.presentation = selected.presentation(at: now)
            next.showsReleaseHint = next.presentation.showsReleaseHint(after: startAfter)
        }
        if next != state { state = next }
        guard active else { return }
        let times = [selected.nextUpdate(at: now), previewUntil].compactMap { $0 }.filter { $0 > now }
        guard let due = times.min() else { return }
        deadline = schedule(due - now) { [weak self] in
            guard let self, self.generation == token else { return }
            self.refresh()
        }
    }
}
