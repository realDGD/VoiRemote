import Foundation
import VoiRemoteCore

func voiceReminderPlacementChecks() -> [(String, () throws -> Void)] {
    let size = CGSize(width: 192, height: 34)
    let primary = ReminderScreen(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                 visibleFrame: CGRect(x: 0, y: 24, width: 1440, height: 850))
    func place(_ window: CGRect, _ capsule: CGRect, screens: [ReminderScreen]? = nil) -> CGPoint? {
        VoiceReminderPlacement.following(topLeftWindow: window, topLeftCapsule: capsule,
            primaryMaxY: 900, screens: screens ?? [primary], size: size)
    }
    return [
        ("target screen follows the green control even when upper text lies on another display", {
            let above = ReminderScreen(frame: CGRect(x: 0, y: 900, width: 1440, height: 800), visibleFrame: CGRect(x: 0, y: 900, width: 1440, height: 780))
            let window = CGRect(x: 400, y: -300, width: 350, height: 400)
            let capsule = CGRect(x: 531, y: 40, width: 88, height: 36)
            try expect(VoiceReminderPlacement.screenIndex(containingTopLeftRect: capsule, primaryMaxY: 900, screens: [primary, above]) == 0, "Text bubble selected the wrong display")
            try expect(place(window, capsule, screens: [primary, above]) == CGPoint(x: 627, y: 825), "Control and reminder used different displays")
        }),
        ("reminder sits beside the green control and ignores upward text growth", {
            let capsule = CGRect(x: 456, y: 570, width: 88, height: 36)
            let a = place(CGRect(x: 400, y: 500, width: 200, height: 130), capsule)
            let b = place(CGRect(x: 325, y: 450, width: 350, height: 180), capsule)
            try expect(a == CGPoint(x: 552, y: 295) && a == b, "Control alignment drifted with transparent margin or text growth")
            let text = CGRect(x: 325, y: 360, width: 350, height: 202)
            try expect(a.map { !CGRect(origin: $0, size: size).intersects(text) } == true, "Expanded reminder covers upper text")
        }),
        ("capsule placement follows left and upper screens independently of cursor position", {
            let left = ReminderScreen(frame: CGRect(x: -1200, y: -500, width: 1200, height: 800),
                                      visibleFrame: CGRect(x: -1200, y: -480, width: 1200, height: 760))
            let above = ReminderScreen(frame: CGRect(x: 0, y: 900, width: 1440, height: 800),
                                       visibleFrame: CGRect(x: 0, y: 900, width: 1440, height: 780))
            let l = place(CGRect(x: -1000, y: 1100, width: 350, height: 130), CGRect(x: -869, y: 1170, width: 88, height: 36), screens: [primary, left])
            let u = place(CGRect(x: 400, y: -600, width: 350, height: 130), CGRect(x: 531, y: -530, width: 88, height: 36), screens: [primary, above])
            try expect(l == CGPoint(x: -773, y: -305), "Negative-origin screen conversion failed")
            try expect(u == CGPoint(x: 627, y: 1395), "Upper screen conversion failed")
        }),
        ("right edge selects the left side with enough room for the expanded hint", {
            let point = place(CGRect(x: 1190, y: 500, width: 200, height: 130), CGRect(x: 1246, y: 570, width: 88, height: 36))
            try expect(point == CGPoint(x: 1046, y: 295), "No room on the right should select left")
            let edge = place(CGRect(x: 400, y: 760, width: 350, height: 130), CGRect(x: 531, y: 830, width: 88, height: 36))
            try expect(edge == CGPoint(x: 627, y: 36), "Bottom-edge control should stay beside reminder")
        }),
        ("narrow screen uses lower fallback without overlapping control or text", {
            let narrow = ReminderScreen(frame: CGRect(x: 0, y: 0, width: 400, height: 900), visibleFrame: CGRect(x: 0, y: 0, width: 400, height: 900))
            let point = place(CGRect(x: 25, y: 100, width: 350, height: 130), CGRect(x: 156, y: 170, width: 88, height: 36), screens: [narrow])
            try expect(point == CGPoint(x: 104, y: 628), "Unsafe side layout did not fall below full window")
        }),
        ("invalid offscreen or impossible geometry requests fixed fallback", {
            let window = CGRect(x: 400, y: 500, width: 200, height: 130)
            let capsule = CGRect(x: 456, y: 570, width: 88, height: 36)
            let bad = CGRect(x: CGFloat.nan, y: 0, width: 300, height: 130)
            let tiny = ReminderScreen(frame: CGRect(x: 0, y: 0, width: 100, height: 100), visibleFrame: CGRect(x: 0, y: 0, width: 100, height: 100))
            try expect(place(bad, capsule) == nil, "Invalid numbers accepted")
            try expect(place(window, capsule.offsetBy(dx: 5000, dy: 0)) == nil, "Control outside its window accepted")
            try expect(place(window.offsetBy(dx: 5000, dy: 5000), capsule.offsetBy(dx: 5000, dy: 5000)) == nil, "Offscreen target guessed")
            try expect(place(window, capsule, screens: [tiny]) == nil, "Panel escaped a tiny screen")
        })
    ]
}
