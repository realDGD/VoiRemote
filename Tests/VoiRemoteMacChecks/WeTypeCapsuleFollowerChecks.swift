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
    var polls: [(Double, GeometryDeadline)] { jobs.filter { $0.0 == 0.2 } }
    var initialWaits: [(Double, GeometryDeadline)] { jobs.filter { $0.0 == 2 } }
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
        ("initial search hides presentation until a delayed voice window is located", {
            let h = GeometryHarness(); defer { h.follower.shutdown() }
            h.follower.update(h.countdown())
            let wait = h.initialWaits.last!.1
            try check(!h.follower.state.canPresent && h.initialWaits.last!.0 == 2, "Initial fallback was immediately visible")
            h.source.finish(.unavailable)
            try check(!h.follower.state.canPresent, "First empty read exposed fallback")
            h.polls.last!.1.action(); h.source.finish(snapshot([window()]))
            try check(h.follower.state.canPresent && h.follower.anchor == window().bounds && wait.cancelled, "Located capsule did not release presentation or cancel wait")
            wait.action()
            try check(h.follower.anchor == window().bounds, "Cancelled wait replaced the located anchor")
        }),
        ("initial search timeout allows fallback and still follows a later window", {
            let h = GeometryHarness(); defer { h.follower.shutdown() }
            h.follower.update(h.countdown())
            h.initialWaits.last!.1.action()
            try check(h.follower.state.canPresent && h.follower.anchor == nil && h.polls.isEmpty, "Pending first read suppressed reminder forever")
            h.source.finish(.unavailable)
            h.polls.last!.1.action(); h.source.finish(snapshot([window()]))
            try check(h.follower.state.canPresent && h.follower.anchor == window().bounds, "Late capsule could not replace fallback")
        }),
        ("release and repress invalidate old initial deadlines and reads", {
            let h = GeometryHarness(); defer { h.follower.shutdown() }
            h.follower.update(h.countdown()); let old = h.initialWaits.last!.1
            h.follower.update(VoiceLimitReminderState()); old.action()
            try check(old.cancelled && !h.follower.state.canPresent, "Release allowed a late fallback flash")
            h.follower.update(h.countdown(epoch: 2)); let current = h.initialWaits.last!.1
            old.action(); h.source.finish(snapshot([window()]))
            try check(!h.follower.state.canPresent && h.follower.anchor == nil, "Old read or deadline exposed replacement segment")
            h.source.finish(snapshot([window(2)]))
            try check(current.cancelled && h.follower.state.canPresent && h.follower.anchor == window(2).bounds, "Replacement segment did not acquire its own anchor")
            h.follower.update(h.countdown(epoch: 3)); let pending = h.initialWaits.last!.1
            h.follower.shutdown(); pending.action(); h.source.finish(snapshot([window(3)]))
            try check(pending.cancelled && !h.follower.state.canPresent && h.follower.anchor == nil, "Shutdown revived a waiting segment")
        }),
        ("cancellation from fallback readiness cannot revive polling", {
            let h = GeometryHarness(); defer { h.follower.shutdown() }
            let observation = h.follower.states.sink { state in
                if state.canPresent && state.anchor == nil { h.follower.update(VoiceLimitReminderState()) }
            }
            h.follower.update(h.countdown()); h.source.finish(.unavailable)
            let poll = h.polls.last!.1
            h.initialWaits.last!.1.action(); poll.action()
            try check(!h.follower.state.canPresent && poll.cancelled && h.source.reads == 1, "Reentrant timeout cancellation left active work")
            observation.cancel()
        }),
        ("observed 3.0.1 voice windows match and preserve the calibrated lower control", {
            var matcher = WeTypeCapsuleMatcher()
            let compact = window(1, CGRect(x: 100, y: 200, width: 200, height: 130))
            try check(matcher.select(snapshot([compact], version: "3.0.1")) == compact.bounds, "Current patch version fell back to cursor screen")
            let capsule = WeTypeCapsuleMatcher.capsuleBounds(in: compact.bounds)
            try check(capsule == CGRect(x: 156, y: 230, width: 88, height: 36), "Green control offset drifted")
            let expanded = CGRect(x: 25, y: 150, width: 350, height: 180)
            try check(WeTypeCapsuleMatcher.capsuleBounds(in: expanded) == capsule, "Upper text growth shifted the control")
        }),
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
            try check(h.source.reads == 1 && h.polls.isEmpty && h.initialWaits.count == 1, "Duplicated in-flight read or initial wait")
            h.source.finish(snapshot([window()]))
            try check(h.follower.anchor == window().bounds && h.jobs.last!.0 == 0.2, "Follow/refresh missing")
            h.jobs.last!.1.action(); try check(h.source.reads == 2, "No periodic refresh")
            let moved = window(1, CGRect(x: 400, y: 300, width: 300, height: 130))
            h.source.finish(snapshot([moved])); try check(h.follower.anchor == moved.bounds, "Position stayed stale")
            h.jobs.last!.1.action(); h.source.finish(.unavailable)
            try check(h.follower.anchor == nil && h.follower.state.canPresent, "Lost target did not allow immediate fallback")
            let pending = h.jobs.last!.1
            h.follower.update(VoiceLimitReminderState()); pending.action()
            try check(pending.cancelled && h.source.reads == 3, "Hidden follower kept polling")
        }),
        ("old read and deadline cannot affect a replacement segment or shutdown", {
            let h = GeometryHarness()
            h.follower.update(h.countdown()); h.follower.update(h.countdown(epoch: 2))
            h.source.finish(snapshot([window()]))
            try check(h.follower.anchor == nil && h.polls.isEmpty, "Old segment result survived")
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
            try check(h.follower.anchor == nil && h.polls.isEmpty && !h.follower.state.canPresent && h.source.reads == 1, "Reentrant cancellation left stale state")
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
