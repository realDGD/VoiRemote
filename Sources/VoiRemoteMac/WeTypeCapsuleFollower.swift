import AppKit
import Combine
import CoreGraphics
import Foundation
import VoiRemoteCore

public struct WeTypeWindowGeometry: Sendable {
    public let id: UInt32
    public let bounds: CGRect
    public let layer: Int
    public let alpha: Double
    public let onScreen: Bool
    public init(id: UInt32, bounds: CGRect, layer: Int, alpha: Double = 1, onScreen: Bool = true) {
        self.id = id; self.bounds = bounds; self.layer = layer; self.alpha = alpha; self.onScreen = onScreen
    }
}

public struct WeTypeGeometrySnapshot: Sendable {
    public let version: String?
    public let windows: [WeTypeWindowGeometry]
    public init(version: String?, windows: [WeTypeWindowGeometry]) { self.version = version; self.windows = windows }
    public static let unavailable = WeTypeGeometrySnapshot(version: nil, windows: [])
}

/// A conservative local-version profile, not a claim about WeType's private window classes.
public struct WeTypeCapsuleMatcher: Sendable {
    public static let supportedVersions: Set<String> = ["3.0.0", "3.0.1"]
    public static let windowLayer = Int(CGWindowLevelForKey(.maximumWindow)) - 2
    private var selectedID: UInt32?
    public init() {}
    public mutating func clear() { selectedID = nil }
    public mutating func select(_ snapshot: WeTypeGeometrySnapshot) -> CGRect? {
        guard let version = snapshot.version, Self.supportedVersions.contains(version) else { clear(); return nil }
        let visible = snapshot.windows.filter {
            $0.onScreen && $0.alpha.isFinite && $0.alpha > 0
                && $0.layer == Self.windowLayer
                && VoiceReminderPlacement.isUsable($0.bounds)
        }
        if let selectedID, let existing = visible.first(where: { $0.id == selectedID }),
           (199...351).contains(existing.bounds.width), (129...600).contains(existing.bounds.height) {
            guard !visible.contains(where: { $0.id != selectedID && Self.isCompact($0.bounds) }) else { clear(); return nil }
            // A known capsule may grow upward to hold uncommitted text, without changing ownership.
            return existing.bounds
        }
        clear()
        let matches = visible.filter { Self.isCompact($0.bounds) }
        guard matches.count == 1, let match = matches.first else { return nil }
        selectedID = match.id
        return match.bounds
    }
    private static func isCompact(_ bounds: CGRect) -> Bool {
        (199...351).contains(bounds.width)
            && (abs(bounds.height - 130) <= 1 || abs(bounds.height - 180) <= 1)
    }
    /// The green control has a 64pt transparent lower margin in the observed 3.0.x window.
    /// This visual calibration is not a public WeType API.
    public static func capsuleBounds(in window: CGRect) -> CGRect {
        CGRect(x: window.midX - 44, y: window.maxY - 100, width: 88, height: 36)
    }
}

@MainActor public protocol WeTypeWindowSource: AnyObject {
    func read(_ completion: @escaping @MainActor @Sendable (WeTypeGeometrySnapshot) -> Void)
}

/// Reads only public numeric geometry. No titles, AX values, screenshots, clipboard or audio.
@MainActor public final class SystemWeTypeWindowSource: WeTypeWindowSource {
    private let queue = DispatchQueue(label: "dev.voiremote.capsule-geometry", qos: .utility)
    private var querying = false
    private var cachedApplication: (pid: pid_t, version: String)?
    public init() {}

    public func read(_ completion: @escaping @MainActor @Sendable (WeTypeGeometrySnapshot) -> Void) {
        guard !querying else { completion(.unavailable); return }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.tencent.inputmethod.wetype")
        guard apps.count == 1, let app = apps.first else { cachedApplication = nil; completion(.unavailable); return }
        let pid = app.processIdentifier
        if cachedApplication?.pid != pid {
            guard let url = app.bundleURL,
                  let version = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
                cachedApplication = nil; completion(.unavailable); return
            }
            cachedApplication = (pid, version)
        }
        guard let version = cachedApplication?.version, WeTypeCapsuleMatcher.supportedVersions.contains(version) else {
            completion(.unavailable); return
        }
        querying = true
        queue.async { [weak self] in
            let snapshot: WeTypeGeometrySnapshot = autoreleasepool {
                guard let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
                    return .unavailable
                }
                let windows = rows.compactMap { row -> WeTypeWindowGeometry? in
                    guard row[kCGWindowOwnerPID as String] as? pid_t == pid,
                          let id = row[kCGWindowNumber as String] as? UInt32,
                          let bounds = row[kCGWindowBounds as String] as? [String: Double],
                          let x = bounds["X"], let y = bounds["Y"], let w = bounds["Width"], let h = bounds["Height"] else { return nil }
                    return WeTypeWindowGeometry(id: id, bounds: CGRect(x: x, y: y, width: w, height: h),
                                                layer: row[kCGWindowLayer as String] as? Int ?? -1,
                                                alpha: row[kCGWindowAlpha as String] as? Double ?? 0,
                                                onScreen: row[kCGWindowIsOnscreen as String] as? Bool ?? true)
                }
                return WeTypeGeometrySnapshot(version: version, windows: windows)
            }
            Task { @MainActor [weak self] in
                self?.querying = false
                completion(snapshot)
            }
        }
    }
}

public struct WeTypeCapsuleState: Equatable, Sendable {
    public let anchor: CGRect?
    public let canPresent: Bool
    public init(anchor: CGRect? = nil, canPresent: Bool = false) {
        self.anchor = anchor; self.canPresent = canPresent
    }
}

/// One in-flight read, one poll and one initial search deadline; inactive states own no work.
@MainActor public final class WeTypeCapsuleFollower {
    public static let initialSearchTimeout: TimeInterval = 2
    private let stateSubject = CurrentValueSubject<WeTypeCapsuleState, Never>(WeTypeCapsuleState())
    public var state: WeTypeCapsuleState { stateSubject.value }
    public var anchor: CGRect? { state.anchor }
    public var states: AnyPublisher<WeTypeCapsuleState, Never> { stateSubject.eraseToAnyPublisher() }
    public var anchors: AnyPublisher<CGRect?, Never> { states.map(\.anchor).removeDuplicates().eraseToAnyPublisher() }
    private let source: any WeTypeWindowSource
    private let schedule: VoiceLimitReminderRuntime.Schedule
    private var deadline: (any VoiceLimitDeadline)?
    private var initialDeadline: (any VoiceLimitDeadline)?
    private var matcher = WeTypeCapsuleMatcher()
    private var active = false
    private var epoch: UInt64 = 0
    private var generation: UInt64 = 0
    private var stopped = false

    public init(source: any WeTypeWindowSource = SystemWeTypeWindowSource(),
                schedule: VoiceLimitReminderRuntime.Schedule? = nil) {
        self.source = source
        self.schedule = schedule ?? { delay, action in SleepingDeadline(delay: delay, action: action) }
    }

    public func update(_ state: VoiceLimitReminderState, allowed: Bool = true) {
        guard !stopped else { return }
        let wanted = allowed && state.mayFollowCapsule
        guard wanted != active || (wanted && state.displayEpoch != epoch) else { return }
        generation &+= 1; deadline?.cancel(); deadline = nil
        initialDeadline?.cancel(); initialDeadline = nil
        matcher.clear(); active = wanted; epoch = state.displayEpoch
        let token = generation
        publish(WeTypeCapsuleState())
        if active, !stopped, generation == token {
            initialDeadline = schedule(Self.initialSearchTimeout) { [weak self] in
                guard let self, self.active, !self.stopped, self.generation == token else { return }
                self.initialDeadline = nil
                self.publish(WeTypeCapsuleState(anchor: self.anchor, canPresent: true))
            }
            read()
        }
    }
    public func shutdown() {
        guard !stopped else { return }
        // Mark terminal before publishing nil: a subscriber cannot restart us during delivery.
        stopped = true; active = false; generation &+= 1
        deadline?.cancel(); deadline = nil; matcher.clear()
        initialDeadline?.cancel(); initialDeadline = nil
        publish(WeTypeCapsuleState())
    }
    private func publish(_ value: WeTypeCapsuleState) {
        if state != value { stateSubject.send(value) }
    }
    private func read() {
        guard active, !stopped else { return }
        let token = generation
        source.read { [weak self] snapshot in
            guard let self, self.active, !self.stopped, self.generation == token else { return }
            let next = self.matcher.select(snapshot)
            if next != nil { self.initialDeadline?.cancel(); self.initialDeadline = nil }
            self.publish(WeTypeCapsuleState(anchor: next, canPresent: next != nil || self.state.canPresent))
            guard self.active, !self.stopped, self.generation == token else { return }
            self.deadline = self.schedule(0.2) { [weak self] in
                guard let self, self.active, !self.stopped, self.generation == token else { return }
                self.deadline = nil; self.read()
            }
        }
    }
}
