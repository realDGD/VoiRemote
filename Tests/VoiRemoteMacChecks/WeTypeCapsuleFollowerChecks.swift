import Combine
import Foundation
import VoiRemoteCore
import VoiRemoteMac

@MainActor private final class GeometrySource: WeTypeWindowSource {
    var reads = 0
    var completions: [@MainActor @Sendable (WeTypeGeometrySnapshot) -> Void] = []
    func read(_ completion: @escaping @MainActor @Sendable (WeTypeGeometrySnapshot) -> Void) {
        reads += 1; completions.append(completion)
    }
    func finish(_ snapshot: WeTypeGeometrySnapshot) { completions.removeFirst()(snapshot) }
}
@MainActor private final class GeometryDeadline: VoiceLimitDeadline {
    var cancelled = false
    let action: @MainActor () -> Void
    init(_ action: @escaping @MainActor () -> Void) { self.action = action }
    func cancel() { cancelled = true }
}
@MainActor private final class GeometryHarness {
    let source = GeometrySource()
    var jobs: [(Double, GeometryDeadline)] = []
    lazy var follower = WeTypeCapsuleFollower(source: source, schedule: { [weak self] delay, action in
        let job = GeometryDeadline(action); self?.jobs.append((delay, job)); return job
    })
    func countdown(epoch: UInt64 = 1) -> VoiceLimitReminderState {
        var state = VoiceLimitReminderState(); state.presentation = .countdown(seconds: 10, urgent: false); state.displayEpoch = epoch; return state
    }
}

@MainActor func weTypeCapsuleFollowerChecks() -> [(String, @MainActor () throws -> Void)] {
    func window(_ id: UInt32 = 1, _ rect: CGRect = CGRect(x: 100, y: 200, width: 350, height: 130), layer: Int = 2147483629, alpha: Double = 1, visible: Bool = true) -> WeTypeWindowGeometry {
        WeTypeWindowGeometry(id: id, bounds: rect, layer: layer, alpha: alpha, onScreen: visible)
    }
    func snapshot(_ windows: [WeTypeWindowGeometry], version: String? = "3.0.0") -> WeTypeGeometrySnapshot {
        WeTypeGeometrySnapshot(version: version, windows: windows)
    }
    return [
        ("capsule profile rejects wide candidates unknown versions and ambiguity", {
            var matcher = WeTypeCapsuleMatcher()
            let wide = window(2, CGRect(x: 0, y: 0, width: 510, height: 32))
            try check(matcher.select(snapshot([wide])) == nil, "Typing candidate became capsule")
            try check(matcher.select(snapshot([window()], version: "3.1.0")) == nil, "Unknown version guessed")
            try check(matcher.select(snapshot([window(), window(3)])) == nil, "Ambiguous windows guessed")
            try check(matcher.select(snapshot([wide, window()])) == window().bounds, "Compact profile missed")
            try check(matcher.select(snapshot([window(), window(3)])) == nil, "Cached identity overrode ambiguity")
        }),
        ("known capsule follows motion text growth and new IDs but never hidden invalid windows", {
            var matcher = WeTypeCapsuleMatcher()
            _ = matcher.select(snapshot([window()]))
            let moved = window(1, CGRect(x: -900, y: 300, width: 245, height: 300))
            try check(matcher.select(snapshot([moved])) == moved.bounds, "Movement/text growth lost")
            try check(matcher.select(snapshot([window(1, visible: false)])) == nil, "Hidden anchor retained")
            try check(matcher.select(snapshot([window(9)])) == window(9).bounds, "New ID not discovered")
            try check(matcher.select(snapshot([window(9, alpha: 0)])) == nil, "Transparent window accepted")
            try check(matcher.select(snapshot([window(9, layer: 0)])) == nil, "Preferences window accepted")
            try check(matcher.select(snapshot([window(9, CGRect(x: CGFloat.nan, y: 0, width: 300, height: 130))])) == nil, "Invalid geometry accepted")
        }),
        ("follower performs no work before countdown or during preview end and inspection", {
            let h = GeometryHarness(); defer { h.follower.shutdown() }
            h.follower.update(VoiceLimitReminderState())
            var state = h.countdown(); state.isPreview = true; h.follower.update(state)
            state.isPreview = false
            state.presentation = .endedUnconfirmed; h.follower.update(state)
            h.follower.update(h.countdown(), allowed: false)
            try check(h.source.reads == 0 && h.jobs.isEmpty, "Inactive mode queried another app")
        }),
        ("live tracking begins at START independently of hint timing and ends only with the segment", {
            for start in [0, 5, 50, 55] {
            let h = GeometryHarness()
            var now = 0.0
            var jobs: [(Double, GeometryDeadline)] = []
            let runtime = VoiceLimitReminderRuntime(clock: { now }, schedule: { delay, action in
                let job = GeometryDeadline(action); jobs.append((now + delay, job)); return job
            })
            let observation = runtime.$state.sink { h.follower.update($0) }
            defer { observation.cancel(); runtime.shutdown(); h.follower.shutdown() }
            var config = AppConfiguration()
            config.voiceEnabled = true; config.remoteAudioEnabled = true; config.voiceLimitReminderEnabled = true
            config.voiceLimitReminderStartSeconds = start
            runtime.configure(config)
            var segment = VoiceLimitIndicator(); segment.begin(segment: 1, at: 0, hasRC003Limit: true)
            runtime.update(segment)
            try check(h.source.reads == 1 && runtime.state.presentation == .countdown(seconds: 60, urgent: false), "Persistent countdown did not query at START")
            h.source.finish(snapshot([window()])); let pending = h.jobs.last!.1
            now = 60; jobs.last!.1.action()
            pending.action()
            try check(runtime.state.presentation == .approachingLimit && h.source.reads == 2 && !pending.cancelled, "Estimated expiry prematurely stopped tracking")
            segment.end(segment: 1, reason: .reportedDeviceLimit, at: now); runtime.update(segment)
            let jobCount = h.jobs.count
            h.source.finish(snapshot([window()]))
            try check(h.follower.anchor == nil && h.jobs.count == jobCount, "Actual STOP retained an anchor or scheduled a stale query")
            runtime.preview()
            try check(h.source.reads == 2 && runtime.state.isPreview, "Preview queried live windows")
            }
        }),
        ("follower bounds reads refreshes movement and falls back on disappearance", {
            let h = GeometryHarness(); defer { h.follower.shutdown() }
            h.follower.update(h.countdown()); h.follower.update(h.countdown())
            try check(h.source.reads == 1 && h.jobs.isEmpty, "Duplicated in-flight read")
            h.source.finish(snapshot([window()]))
            try check(h.follower.anchor == window().bounds && h.jobs.last!.0 == 0.2, "Follow/refresh missing")
            h.jobs.last!.1.action(); try check(h.source.reads == 2, "No periodic refresh")
            let moved = window(1, CGRect(x: 400, y: 300, width: 300, height: 130))
            h.source.finish(snapshot([moved])); try check(h.follower.anchor == moved.bounds, "Position stayed stale")
            h.jobs.last!.1.action(); h.source.finish(.unavailable)
            try check(h.follower.anchor == nil, "Lost target did not fall back")
            let pending = h.jobs.last!.1
            h.follower.update(VoiceLimitReminderState()); pending.action()
            try check(pending.cancelled && h.source.reads == 3, "Hidden follower kept polling")
        }),
        ("old read and deadline cannot affect a replacement segment or shutdown", {
            let h = GeometryHarness()
            h.follower.update(h.countdown()); h.follower.update(h.countdown(epoch: 2))
            h.source.finish(snapshot([window()]))
            try check(h.follower.anchor == nil && h.jobs.isEmpty, "Old segment result survived")
            h.source.finish(snapshot([window(9)])); let stale = h.jobs.last!.1
            h.follower.shutdown(); stale.action(); h.follower.update(h.countdown(epoch: 3))
            try check(h.follower.anchor == nil && h.source.reads == 2 && stale.cancelled, "Shutdown revived polling")
        }),
        ("cancellation during anchor delivery cannot retain an anchor or schedule stale work", {
            let h = GeometryHarness(); defer { h.follower.shutdown() }
            let observation = h.follower.anchors.sink { value in
                if value != nil { h.follower.update(VoiceLimitReminderState()) }
            }
            h.follower.update(h.countdown()); h.source.finish(snapshot([window()]))
            try check(h.follower.anchor == nil && h.jobs.isEmpty && h.source.reads == 1, "Reentrant cancellation left stale state")
            observation.cancel()
        }),
        ("shutdown is terminal even when a subscriber tries to restart during anchor clearing", {
            let h = GeometryHarness()
            h.follower.update(h.countdown()); h.source.finish(snapshot([window()]))
            var restartOnNil = false
            let observation = h.follower.anchors.sink { value in
                if restartOnNil && value == nil { h.follower.update(h.countdown(epoch: 2)) }
            }
            restartOnNil = true; h.follower.shutdown()
            try check(h.source.reads == 1 && h.follower.anchor == nil && h.jobs.last!.1.cancelled, "Subscriber restarted shutdown")
            observation.cancel()
        }),
        ("segment change during anchor clearing cannot start the replacement read twice", {
            let h = GeometryHarness(); defer { h.follower.shutdown() }
            h.follower.update(h.countdown()); h.source.finish(snapshot([window()]))
            var replaceOnNil = false
            let observation = h.follower.anchors.sink { value in
                if replaceOnNil && value == nil { replaceOnNil = false; h.follower.update(h.countdown(epoch: 3)) }
            }
            replaceOnNil = true; h.follower.update(h.countdown(epoch: 2))
            try check(h.source.reads == 2 && h.source.completions.count == 1, "Reentrant segment duplicated query")
            h.source.finish(snapshot([window(3)]))
            try check(h.follower.anchor == window(3).bounds, "Replacement segment lost")
            observation.cancel()
        })
    ]
}
