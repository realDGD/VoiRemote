import AppKit
import CoreGraphics
import VoiRemoteCore
import VoiRemoteMac

@MainActor private final class CapsuleSmokeSource: WeTypeWindowSource {
    var snapshot = WeTypeGeometrySnapshot.unavailable
    var reads = 0
    func read(_ completion: @escaping @MainActor @Sendable (WeTypeGeometrySnapshot) -> Void) {
        reads += 1; completion(snapshot)
    }
    func move(to bounds: CGRect) {
        snapshot = WeTypeGeometrySnapshot(version: "3.0.1", windows: [
            WeTypeWindowGeometry(id: 1, bounds: bounds, layer: Int(CGWindowLevelForKey(.maximumWindow)) - 2)
        ])
    }
}

/// Exercises the actual panel using synthetic numeric geometry, never another app or hardware.
@MainActor func smokeCapsuleFollowing() async throws {
    struct Failure: Error { let message: String }
    func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(message: message) }
    }
    func saveHUD(_ name: String) throws {
        guard let flag = CommandLine.arguments.firstIndex(of: "--preview-directory"), CommandLine.arguments.indices.contains(flag + 1),
              let view = NSApp.windows.first(where: { $0.title == "语音时限提醒" && $0.isVisible })?.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let directory = URL(fileURLWithPath: CommandLine.arguments[flag + 1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name + ".png"))
    }
    guard let primary = NSScreen.screens.first else { throw Failure(message: "No screen") }
    let screen = NSScreen.screens.first { !NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? primary
    let source = CapsuleSmokeSource()
    var now = 7.0
    let runtime = VoiceLimitReminderRuntime(clock: { now })
    let hud = VoiceLimitHUDController(runtime: runtime, inspectionSource: source)
    defer { hud.shutdown() }
    let key = NSApp.keyWindow; let main = NSApp.mainWindow; let active = NSApp.isActive
    var config = AppConfiguration()
    config.voiceEnabled = true; config.remoteAudioEnabled = true; config.voiceLimitReminderEnabled = true
    hud.configure(config)
    var policy = VoiceLimitIndicator(); policy.begin(segment: 1, at: 0, hasRC003Limit: true)
    hud.update(policy)
    try await Task.sleep(for: .milliseconds(250))
    let fixed = hud.inspectionFrame
    try require(fixed?.size == VoiceLimitHUDLayout.size && source.reads > 0, "Missing panel/fallback or inconsistent compact size")
    try require(hud.inspectionLevel == WeTypeCapsuleMatcher.windowLayer, "Reminder is below the voice window level")

    let appKitBounds = CGRect(x: screen.visibleFrame.midX - 175, y: screen.visibleFrame.midY, width: 350, height: 130)
    let first = CGRect(x: appKitBounds.minX, y: primary.frame.maxY - appKitBounds.maxY, width: 350, height: 130)
    source.move(to: first)
    try await Task.sleep(for: .milliseconds(250))
    let expected = VoiceReminderPlacement.following(topLeftWindow: first, topLeftCapsule: WeTypeCapsuleMatcher.capsuleBounds(in: first), primaryMaxY: primary.frame.maxY,
        screens: NSScreen.screens.map { ReminderScreen(frame: $0.frame, visibleFrame: $0.visibleFrame) }, size: VoiceLimitHUDLayout.size)
        .map { CGPoint(x: $0.x.rounded(), y: $0.y.rounded()) }
    try require(expected != nil && hud.inspectionFrame?.origin == expected && hud.inspectionFrame != fixed, "Panel did not follow geometry")
    try require(!runtime.state.showsReleaseHint, "Early countdown should remain compact")
    try saveHUD("follow-compact")
    now = 50; hud.configure(config)
    try await Task.sleep(for: .milliseconds(350))
    try require(runtime.state.showsReleaseHint && hud.inspectionFrame?.origin == expected, "Hint expansion moved the anchor")
    try saveHUD("follow-expanded")
    now = 55; hud.configure(config)
    try require(runtime.state.presentation == .countdown(seconds: 5, urgent: true), "Urgent state missing")

    let moved = first.offsetBy(dx: 60, dy: -20)
    source.move(to: moved)
    try await Task.sleep(for: .milliseconds(250))
    let followed = hud.inspectionFrame
    try require(followed?.origin != expected, "Moving capsule did not move panel")
    source.move(to: CGRect(x: moved.minX, y: moved.minY - 90, width: moved.width, height: moved.height + 90))
    try await Task.sleep(for: .milliseconds(250))
    try require(hud.inspectionFrame == followed, "Text growth moved stable lower anchor")

    source.snapshot = .unavailable
    try await Task.sleep(for: .milliseconds(250))
    try require(hud.inspectionFrame.map { screen.visibleFrame.contains($0) } == true, "Missing capsule returned to cursor screen instead of the target display")
    hud.configure(AppConfiguration())
    let count = source.reads
    try await Task.sleep(for: .milliseconds(300))
    try require(hud.previewIsHidden && source.reads == count, "Hidden panel retained queries")
    let previewScreen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? primary
    hud.preview()
    try await Task.sleep(for: .milliseconds(250))
    try require(hud.previewIsNonactivating && source.reads == count && hud.inspectionFrame.map { previewScreen.visibleFrame.contains($0) } == true, "Preview queried windows or lost fallback")
    try require(NSApp.keyWindow === key && NSApp.mainWindow === main && NSApp.isActive == active, "Geometry updates changed focus")
    hud.shutdown()
    try await Task.sleep(for: .milliseconds(250))
    try require(hud.previewIsHidden && source.reads == count, "Shutdown revived panel/queries")
    print("Synthetic capsule HUD smoke passed: compact/expanded/urgent states, stable expansion anchor, follows/moves, avoids text growth, restores fallback, stops queries; preview/shutdown and own focus unchanged; no foreign windows or hardware")
}
