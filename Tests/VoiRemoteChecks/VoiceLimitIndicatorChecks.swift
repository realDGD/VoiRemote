import Foundation
import VoiRemoteCore

func voiceLimitIndicatorChecks() -> [(String, () throws -> Void)] {
    [
        ("reported stop codes retain uncertainty and do not classify other control events", {
            try expect(RemoteVoiceProtocol.stopReason(packet: Data([0, 0])) == .ordinaryReported, "Ordinary report lost")
            try expect(RemoteVoiceProtocol.stopReason(packet: Data([0, 2])) == .ordinaryReported, "Alternate ordinary report lost")
            try expect(RemoteVoiceProtocol.stopReason(packet: Data([0, 8])) == .timeLimitReported, "Reported limit reason lost")
            try expect(RemoteVoiceProtocol.stopReason(packet: Data([0])) == .unspecified && RemoteVoiceProtocol.stopReason(packet: Data([0, 99])) == .unspecified, "Unknown reason guessed")
            try expect(RemoteVoiceProtocol.stopReason(packet: Data()) == nil && RemoteVoiceProtocol.stopReason(packet: Data([4, 8])) == nil, "Another control event became STOP")
        }),
        ("voice warning follows monotonic segment time and never invents a stop", {
            var indicator = VoiceLimitIndicator()
            indicator.begin(segment: 1, at: 100, hasRC003Limit: true)
            try expect(indicator.presentation(at: 100) == .countdown(seconds: 60, urgent: false), "Countdown missing at real START")
            try expect(indicator.presentation(at: 149.99) == .countdown(seconds: 11, urgent: false), "Countdown hidden before the hint")
            try expect(indicator.nextUpdate(at: 100) == 101, "Countdown first tick drifted")
            try expect(indicator.presentation(at: 150) == .countdown(seconds: 10, urgent: false), "50 second warning missing")
            try expect(indicator.presentation(at: 154.99) == .countdown(seconds: 6, urgent: false), "Warning rounded down too early")
            try expect(indicator.presentation(at: 155) == .countdown(seconds: 5, urgent: true), "Final five second state missing")
            try expect(indicator.presentation(at: 159.99) == .countdown(seconds: 1, urgent: true), "Last second missing")
            try expect(indicator.presentation(at: 160) == .approachingLimit && indicator.presentation(at: 170) == .approachingLimit, "A timer expiry invented device termination")
            try expect(indicator.nextUpdate(at: 151.2) == 152 && indicator.nextUpdate(at: 160) == nil, "Update deadlines drift or poll forever")
        }),
        ("confirmed and unverified limit reports retain distinct three second end indications", {
            var indicator = VoiceLimitIndicator(); indicator.begin(segment: 1, at: 0, hasRC003Limit: true)
            indicator.end(segment: 1, reason: .deviceLimit, at: 60)
            try expect(indicator.presentation(at: 60) == .ended && indicator.presentation(at: 62.99) == .ended, "Confirmed limit was hidden too soon")
            try expect(indicator.presentation(at: 63) == .hidden && indicator.nextUpdate(at: 63) == nil, "End indication remained indefinitely")
            var reported = VoiceLimitIndicator(); reported.begin(segment: 1, at: 0, hasRC003Limit: true)
            reported.end(segment: 1, reason: .reportedDeviceLimit, at: 60)
            try expect(reported.presentation(at: 60) == .endedUnconfirmed && reported.presentation(at: 63) == .hidden, "Unverified report asserted timeout or stayed visible")
            for reason in [VoiceLimitEndReason.released, .interrupted, .unknown] {
                var other = VoiceLimitIndicator(); other.begin(segment: 1, at: 0, hasRC003Limit: true)
                other.end(segment: 1, reason: reason, at: 60)
                try expect(other.presentation(at: 60) == .hidden, "An ordinary stop was mislabeled as a device limit")
            }
        }),
        ("custom thresholds reveal only the action hint without moving the voice limit", {
            var indicator = VoiceLimitIndicator(); indicator.begin(segment: 1, at: 100, hasRC003Limit: true)
            for start in [0, 5, 50, 55] {
                let time = 100 + Double(start)
                if start > 0 {
                    try expect(!indicator.presentation(at: time - 0.01).showsReleaseHint(after: start), "Hint appeared before selected threshold")
                }
                try expect(indicator.presentation(at: time).showsReleaseHint(after: start), "Action hint did not appear")
                try expect(indicator.presentation(at: time) == .countdown(seconds: 60 - start, urgent: start >= 55), "Countdown was rebased to the hint time")
                try expect(indicator.presentation(at: 155) == .countdown(seconds: 5, urgent: true), "Urgency shifted with hint")
                try expect(indicator.presentation(at: 160) == .approachingLimit && indicator.nextUpdate(at: 160) == nil, "Hint setting extended the voice limit")
            }
            for invalid in [-1, 56, Int.max] {
                try expect(!indicator.presentation(at: 155).showsReleaseHint(after: invalid), "Invalid threshold exposed hint")
            }
        }),
        ("duplicate starts and late ends cannot rebase or hide a new voice warning", {
            var indicator = VoiceLimitIndicator(); indicator.begin(segment: 1, at: 0, hasRC003Limit: true)
            try expect(!indicator.begin(segment: 1, at: 30, hasRC003Limit: true), "Duplicate START extended the duration")
            try expect(indicator.presentation(at: 50) == .countdown(seconds: 10, urgent: false), "Original origin was lost")
            indicator.end(segment: 1, reason: .deviceLimit, at: 60)
            indicator.begin(segment: 2, at: 61, hasRC003Limit: true)
            try expect(!indicator.cancel(segment: 1) && !indicator.end(segment: 1, reason: .deviceLimit, at: 62), "Old callback modified a replacement segment")
            try expect(indicator.presentation(at: 111) == .countdown(seconds: 10, urgent: false), "Old hiding callback lost the new warning")
        }),
        ("cancelled voice warnings cannot restart from delayed old events", {
            var indicator = VoiceLimitIndicator(); indicator.begin(segment: 9, at: 0, hasRC003Limit: true)
            indicator.cancel()
            try expect(!indicator.begin(segment: 9, at: 1, hasRC003Limit: true), "Old START revived a cancelled indicator")
            try expect(!indicator.end(segment: 9, reason: .deviceLimit, at: 60) && indicator.presentation(at: 60) == .hidden, "Old STOP revived an indicator")
            indicator.begin(segment: 10, at: 100, hasRC003Limit: true)
            try expect(indicator.presentation(at: 150) == .countdown(seconds: 10, urgent: false), "Next actual segment was blocked")
        }),
        ("unsupported devices and invalid clocks never show RC003 warnings", {
            var indicator = VoiceLimitIndicator(); indicator.begin(segment: 1, at: 0, hasRC003Limit: false)
            try expect(indicator.presentation(at: 55) == .hidden && indicator.nextUpdate(at: 55) == nil, "Unsupported source received RC003 UI")
            var invalid = VoiceLimitIndicator()
            try expect(!invalid.begin(segment: 1, at: .nan, hasRC003Limit: true), "NaN origin was accepted")
            invalid.begin(segment: 1, at: 10, hasRC003Limit: true)
            try expect(invalid.presentation(at: .infinity) == .hidden && invalid.presentation(at: 9) == .hidden, "Invalid time exposed UI")
            try expect(!invalid.end(segment: 1, reason: .deviceLimit, at: 9), "Stop before the start was accepted")
        })
    ]
}
