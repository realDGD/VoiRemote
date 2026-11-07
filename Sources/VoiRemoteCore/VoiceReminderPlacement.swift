import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public struct ReminderScreen: Equatable, Sendable {
    public let frame: CGRect
    public let visibleFrame: CGRect
    public init(frame: CGRect, visibleFrame: CGRect) { self.frame = frame; self.visibleFrame = visibleFrame }
}

/// Geometry only. CG window bounds use a top-left origin; AppKit screens use bottom-left.
public enum VoiceReminderPlacement {
    public static func isUsable(_ rect: CGRect) -> Bool {
        [rect.origin.x, rect.origin.y, rect.width, rect.height].allSatisfy(\.isFinite)
            && rect.width > 0 && rect.height > 0
    }

    public static func screenIndex(containingTopLeftRect rect: CGRect, primaryMaxY: CGFloat,
                                   screens: [ReminderScreen]) -> Int? {
        guard isUsable(rect), primaryMaxY.isFinite else { return nil }
        let converted = CGRect(x: rect.minX, y: primaryMaxY - rect.maxY, width: rect.width, height: rect.height)
        let candidates = screens.indices.filter { isUsable(screens[$0].frame) && isUsable(screens[$0].visibleFrame) }
        guard let index = candidates.max(by: { area(screens[$0].frame.intersection(converted)) < area(screens[$1].frame.intersection(converted)) }),
              area(screens[index].frame.intersection(converted)) > 0 else { return nil }
        return index
    }

    public static func following(topLeftWindow: CGRect, topLeftCapsule: CGRect, primaryMaxY: CGFloat,
                                 screens: [ReminderScreen], size: CGSize) -> CGPoint? {
        guard isUsable(topLeftWindow), isUsable(topLeftCapsule), topLeftWindow.contains(topLeftCapsule), primaryMaxY.isFinite,
              size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
        let anchor = CGRect(x: topLeftWindow.minX, y: primaryMaxY - topLeftWindow.maxY,
                            width: topLeftWindow.width, height: topLeftWindow.height)
        let capsule = CGRect(x: topLeftCapsule.minX, y: primaryMaxY - topLeftCapsule.maxY,
                             width: topLeftCapsule.width, height: topLeftCapsule.height)
        guard let index = screenIndex(containingTopLeftRect: topLeftCapsule, primaryMaxY: primaryMaxY, screens: screens) else { return nil }
        let screen = screens[index]
        let safe = screen.visibleFrame.intersection(screen.frame).insetBy(dx: 12, dy: 12)
        guard isUsable(safe), size.width <= safe.width, size.height <= safe.height else { return nil }
        let gap: CGFloat = 8
        // Transparent window margins are not the control. Keep the lower control
        // centered beside the HUD while reserving the entire upper text-bubble area.
        let text = CGRect(x: anchor.minX, y: capsule.maxY + gap,
                          width: anchor.width, height: max(0, anchor.maxY - capsule.maxY - gap))
        let proposals = [
            CGPoint(x: capsule.maxX + gap, y: capsule.midY - size.height / 2),
            CGPoint(x: capsule.minX - size.width - gap, y: capsule.midY - size.height / 2),
            CGPoint(x: anchor.midX - size.width / 2, y: anchor.minY - size.height - gap),
            CGPoint(x: anchor.midX - size.width / 2, y: anchor.maxY + gap)
        ]
        for point in proposals {
            let bounded = CGPoint(x: min(max(point.x, safe.minX), safe.maxX - size.width),
                                  y: min(max(point.y, safe.minY), safe.maxY - size.height))
            let rect = CGRect(origin: bounded, size: size)
            if !rect.intersects(capsule.insetBy(dx: -4, dy: -4)) && (text.isEmpty || !rect.intersects(text)) { return bounded }
        }
        return nil
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.isNull || rect.isEmpty ? 0 : rect.width * rect.height
    }
}
