import Foundation
import VoiRemoteCore
import VoiRemoteMac

@MainActor private final class ReminderDeadline: VoiceLimitDeadline {
    var cancelled = false
    let action: @MainActor () -> Void
    init(_ action: @escaping @MainActor () -> Void) { self.action = action }
    func cancel() { cancelled = true }
}
@MainActor private final class ReminderHarness {
    var now = 0.0
    var jobs: [(Double, ReminderDeadline)] = []
    lazy var runtime = VoiceLimitReminderRuntime(clock: { [weak self] in self?.now ?? 0 }, schedule: { [weak self] delay, action in
        let job = ReminderDeadline(action); self?.jobs.append(((self?.now ?? 0) + delay, job)); return job
    })
    func enable(startAfter: Int = VoiceLimitIndicator.defaultStartSeconds) {
        var c = AppConfiguration(); c.voiceEnabled = true; c.remoteAudioEnabled = true; c.voiceLimitReminderEnabled = true
        c.voiceLimitReminderStartSeconds = startAfter
        runtime.configure(c)
    }
    func segment(_ id: UInt64, at time: Double) -> VoiceLimitIndicator {
        var p = VoiceLimitIndicator(); p.begin(segment: id, at: time, hasRC003Limit: true); return p
    }
    func fire() { let job = jobs.last!; now = job.0; job.1.action() }
}
@MainActor func voiceLimitReminderChecks() -> [(String, @MainActor () throws -> Void)] {
    [
        ("all reminder capability combinations gate real presentation independently", {
            for voice in [false, true] { for audio in [false, true] { for enabled in [false, true] {
                let h = ReminderHarness(); defer { h.runtime.shutdown() }; h.now = 55
                var c = AppConfiguration(); c.voiceEnabled = voice; c.remoteAudioEnabled = audio; c.voiceLimitReminderEnabled = enabled
                h.runtime.configure(c); h.runtime.update(h.segment(1, at: 0))
                let active = voice && audio && enabled
                try check((h.runtime.state.presentation != .hidden) == active && (!h.jobs.isEmpty) == active, "A disabled capability scheduled or showed a warning")
            } } }
        }),
        ("reminder defaults allocate no deadlines and enabled countdown persists with a delayed hint", {
            let h = ReminderHarness(); defer { h.runtime.shutdown() }
            h.runtime.update(h.segment(1, at: 0))
            try check(h.jobs.isEmpty && h.runtime.state.presentation == .hidden, "Defaults scheduled work")
            h.enable()
            try check(h.jobs.count == 1 && h.jobs.last!.0 == 1 && h.runtime.state.presentation == .countdown(seconds: 60, urgent: false), "Countdown missing at START")
            for _ in 0..<49 { h.fire() }
            try check(!h.runtime.state.showsReleaseHint, "Action hint appeared early")
            h.fire(); try check(h.runtime.state.presentation == .countdown(seconds: 10, urgent: false) && h.runtime.state.showsReleaseHint, "50 second hint missing")
            let epoch = h.runtime.state.displayEpoch
            for _ in 0..<5 { h.fire() }
            try check(h.runtime.state.presentation == .countdown(seconds: 5, urgent: true) && h.runtime.state.displayEpoch == epoch, "Urgency or fixed-screen epoch wrong")
            for _ in 0..<5 { h.fire() }
            try check(h.runtime.state.presentation == .approachingLimit && h.jobs.last!.1.cancelled, "Timer invented stop or kept polling")
        }),
        ("old deadline and end-hide callbacks cannot change a replacement segment", {
            let h = ReminderHarness(); defer { h.runtime.shutdown() }; h.enable()
            var first = h.segment(1, at: 0); h.runtime.update(first); let oldWake = h.jobs.last!.1
            h.now = 60; first.end(segment: 1, reason: .reportedDeviceLimit, at: 60); h.runtime.update(first)
            try check(h.runtime.state.presentation == .endedUnconfirmed, "Unverified stop was asserted")
            let oldHide = h.jobs.last!.1
            h.now = 61; h.runtime.update(h.segment(2, at: 61)); let count = h.jobs.count
            oldWake.action(); oldHide.action()
            try check(h.runtime.state.presentation == .countdown(seconds: 60, urgent: false) && !h.runtime.state.showsReleaseHint && h.jobs.count == count && h.jobs.last!.0 == 62, "Stale work modified new segment")
            h.fire(); try check(h.runtime.state.presentation == .countdown(seconds: 59, urgent: false), "New countdown lost")
        }),
        ("changing hint time preserves the persistent segment and preview demonstrates expansion", {
            let h = ReminderHarness(); defer { h.runtime.shutdown() }
            h.enable(startAfter: 5); h.runtime.update(h.segment(1, at: 0))
            try check(h.jobs.last!.0 == 1 && !h.runtime.state.showsReleaseHint, "Custom hint hid the countdown")
            for _ in 0..<5 { h.fire() }; let epoch = h.runtime.state.displayEpoch
            try check(h.runtime.state.presentation == .countdown(seconds: 55, urgent: false) && h.runtime.state.showsReleaseHint, "Quick hint test changed the estimated limit")
            h.now = 10; h.enable()
            try check(h.runtime.state.presentation == .countdown(seconds: 50, urgent: false) && !h.runtime.state.showsReleaseHint && h.jobs.last!.0 == 11, "Restoring hint default hid the countdown or retained early text")
            h.enable(startAfter: 0)
            try check(h.runtime.state.presentation == .countdown(seconds: 50, urgent: false) && h.runtime.state.showsReleaseHint && h.runtime.state.displayEpoch == epoch, "Hint change restarted the voice segment")
            h.now = 60; h.jobs.last!.1.action()
            try check(h.runtime.state.presentation == .approachingLimit, "Start setting extended sixty seconds")
            h.enable(startAfter: 55); h.runtime.preview()
            try check(h.runtime.state.presentation == .countdown(seconds: 12, urgent: false) && h.runtime.state.isPreview && !h.runtime.state.showsReleaseHint, "Preview should begin compact")
            h.fire(); h.fire()
            try check(h.runtime.state.showsReleaseHint && !h.runtime.state.mayFollowCapsule, "Preview did not expand independently of saved threshold")
            for _ in 0..<3 { h.fire() }
            try check(!h.runtime.state.isPreview && h.runtime.state.presentation == .approachingLimit, "Preview did not expire back to the real segment")
        }),
        ("preview expires without hardware and is cancelled by configuration and live events", {
            let h = ReminderHarness(); defer { h.runtime.shutdown() }
            h.runtime.preview(); try check(h.runtime.state.presentation == .countdown(seconds: 12, urgent: false), "Preview needs hardware")
            for _ in 0..<5 { h.fire() }
            try check(h.runtime.state.presentation == .hidden && h.jobs.last!.1.cancelled, "Preview outlived five seconds")
            h.runtime.preview(); let stale = h.jobs.last!.1
            h.runtime.configure(AppConfiguration()); stale.action()
            try check(h.runtime.state.presentation == .hidden, "Disabled configuration retained preview")
            h.runtime.preview(); h.runtime.update(h.segment(1, at: h.now))
            try check(h.runtime.state.presentation == .hidden, "Preview masked real session")
        }),
        ("sleep and shutdown cancel timers without reviving the old segment", {
            let h = ReminderHarness(); h.enable(); let p = h.segment(1, at: 0); h.runtime.update(p)
            let old = h.jobs.last!.1; h.runtime.suspend(); h.now = 55; old.action(); h.runtime.resume(); h.runtime.update(p)
            try check(h.runtime.state.presentation == .hidden, "Wake replayed old segment")
            h.runtime.update(h.segment(2, at: 55)); let wake = h.jobs.last!.1
            h.runtime.shutdown(); h.now = 105; wake.action(); h.runtime.resume(); h.runtime.preview(); h.enable()
            try check(h.runtime.state.presentation == .hidden && wake.cancelled, "Shutdown retained work")
        })
    ]
}
