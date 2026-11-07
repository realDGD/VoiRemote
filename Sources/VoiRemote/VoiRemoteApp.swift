import AppKit
import Combine
import VoiRemoteCore
import VoiRemoteMac
import SwiftUI
import Carbon
import ServiceManagement

/// Inspection windows use their own preferences and never start device adapters.
@MainActor
enum InterfaceInspection {
    static let bundleID = "dev.voiremote.ui-preview"
    static let preferencesDomain = "dev.voiremote.ui-preview.settings"
    static let interactive = Bundle.main.bundleIdentifier == bundleID || CommandLine.arguments.contains("--ui-preview")
    static let enabled = interactive || CommandLine.arguments.contains("--smoke-test") || CommandLine.arguments.contains("--smoke-test-guide") || CommandLine.arguments.contains("--smoke-test-reminder") || CommandLine.arguments.contains("--smoke-test-background") || CommandLine.arguments.contains("--smoke-test-desktop")
    static let defaults: UserDefaults = {
        guard enabled else { return .standard }
        let defaults = UserDefaults(suiteName: preferencesDomain)!
        defaults.removePersistentDomain(forName: preferencesDomain)
        return defaults
    }()
}

@main
enum Launcher {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--version") {
            print("VoiRemote \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development")")
            return
        }
        if CommandLine.arguments.contains("--self-check") {
            do {
                let configuration = AppConfiguration()
                guard try AppConfiguration.decode(configuration.encoded()) == configuration else { exit(1) }
                try checkInitialSetupLifecycle()
                try checkDesktopSettings()
                try checkLoginItemMaintenance()
                print("VoiRemote self-check passed (configuration and first-launch lifecycle; no hardware access)")
            } catch {
                fputs("VoiRemote self-check failed: \(error)\n", stderr)
                exit(1)
            }
            return
        }
        if CommandLine.arguments.contains("--list-remotes") {
            print("Xiaomi RC001/RC003 keyboard interfaces: \(HIDRemoteMonitor.discoverCount())")
            print("Input monitoring: \(IOHIDPermission.inputMonitoringGranted)")
            return
        }
        if CommandLine.arguments.contains("--unregister-login-item") {
            do {
                try LoginItemMaintenance.prepareForRemoval()
                print("Login item after removal: \(LoginItemMaintenance.describe(SMAppService.mainApp.status))")
            } catch { fputs("Could not unregister login item: \(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        if CommandLine.arguments.contains("--restore-login-item") {
            do { try LoginItemMaintenance.restoreAfterInstall() }
            catch { fputs("Could not restore login item: \(error.localizedDescription)\n", stderr); exit(1) }
            print("Login item after installation: \(LoginItemMaintenance.describe(SMAppService.mainApp.status))")
            return
        }
        if CommandLine.arguments.contains("--login-item-status") {
            print(LoginItemMaintenance.describe(SMAppService.mainApp.status))
            return
        }
        if CommandLine.arguments.contains("--list-loopback-devices") {
            let devices = LoopbackDevices.available()
            print("Compatible loopback devices: \(devices.count)")
            for device in devices { print(device.name) }
            return
        }
        if CommandLine.arguments.contains("--check-input-catalog") {
            let system = CoreAudioInputSystem()
            do {
                let before = LoopbackDevices.defaultSnapshot()
                try system.start(onChange: {})
                let snapshot = try system.snapshot()
                let listeners = system.listenerCount
                system.stop()
                guard system.listenerCount == 0, before == LoopbackDevices.defaultSnapshot() else { throw InputSystemFailure.unavailable }
                print("Input catalog check passed: \(snapshot.inputs.count) inputs, \(snapshot.inputs.filter { $0.policy.isPhysical }.count) physical, \(snapshot.inputs.filter { $0.policy.supportsPriority }.count) eligible loopbacks; \(listeners) listeners removed; defaults unchanged; no input capture")
            } catch { system.stop(); fputs("Input catalog check failed: \(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        VoiRemoteApp.main()
    }
}

struct VoiRemoteApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var delegate
    private var store: ConfigurationStore { delegate.store }
    private var runtime: RemoteMappingRuntime { delegate.runtime }

    var body: some Scene {
        MenuBarExtra("VoiRemote", systemImage: "appletvremote.gen4.fill") {
            MenuContents()
                .environmentObject(store)
                .environmentObject(runtime)
                .environmentObject(delegate.presentation)
        }
    }
}

private struct MenuContents: View {
    @EnvironmentObject private var presentation: AppPresentation
    @EnvironmentObject private var store: ConfigurationStore
    @EnvironmentObject private var runtime: RemoteMappingRuntime

    var body: some View {
        Text("VoiRemote")
        MenuAudioInputs(priority: runtime.inputPriority, audio: runtime.audio, setupActive: runtime.setupActive)
        Divider()
        Button("打开设置…") {
            presentation.showSettings()
        }
        .keyboardShortcut(",")
        Button("运行设置向导…") {
            presentation.showSettings()
            store.isSetupPresented = true
            NSApp.activate(ignoringOtherApps: true)
        }
        .disabled(store.persistenceError != nil)
        Divider()
        Button("退出 VoiRemote") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    let store = ConfigurationStore(defaults: InterfaceInspection.defaults)
    let runtime = RemoteMappingRuntime(hardwareEnabled: !InterfaceInspection.enabled)
    let reminder = VoiceLimitHUDController()
    let presentation = AppPresentation(defaults: InterfaceInspection.defaults)
    let login = LoginItemSettings(inspection: InterfaceInspection.enabled)
    private var subscriptions = Set<AnyCancellable>()
    private var backgroundProbePassed = false
    private var settingsWindow: NSWindow?
    override init() {
        super.init()
        presentation.installOpener { [weak self] in self?.showSettingsWindow() }
        // Own configuration before any window appears, including menu-only cold launches.
        store.$configuration.sink { [weak self] configuration in
            self?.runtime.configure(configuration)
            self?.reminder.configure(configuration)
        }.store(in: &subscriptions)
        runtime.audio.$voiceLimit.sink { [weak self] policy in self?.reminder.update(policy) }.store(in: &subscriptions)
        if CommandLine.arguments.contains("--smoke-test-background") {
            guard NSApp?.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) != true else {
                fputs("Background smoke inconclusive: settings already visible at owner initialization\n", stderr); exit(1)
            }
            store.update { $0.voiceLimitReminderPosition = .bottomTrailing }
            backgroundProbePassed = reminder.runtime.state.position == .bottomTrailing
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        reminder.shutdown()
        var completed = false
        var waiting = false
        runtime.prepareToTerminate {
            if waiting {
                // A quit initiated on GCD may keep that queue occupied inside AppKit's modal loop.
                RunLoop.main.perform(inModes: [.default, .modalPanel, .eventTracking]) {
                    MainActor.assumeIsolated { sender.reply(toApplicationShouldTerminate: true) }
                }
            } else { completed = true }
        }
        if completed { return .terminateNow }
        waiting = true
        return .terminateLater
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        let loginLaunch = event?.eventID == kAEOpenApplication && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        let quiet = loginLaunch || CommandLine.arguments.contains("--background") || CommandLine.arguments.contains("--smoke-test-reminder") || CommandLine.arguments.contains("--smoke-test-background")
        presentation.finishLaunch(silent: quiet)
        if CommandLine.arguments.contains("--smoke-test-desktop") {
            Task { @MainActor in
                do {
                    try await Task.sleep(for: .seconds(2))
                    try await self.smokeDesktop(silent: quiet)
                    print("Desktop smoke passed: silent launch, settings open/close/reopen, Dock preference; no login registration or hardware")
                    NSApp.terminate(nil)
                } catch { fputs("Desktop smoke failed: \(error)\n", stderr); exit(1) }
            }
        }
        if CommandLine.arguments.contains("--smoke-test") || CommandLine.arguments.contains("--smoke-test-guide") || CommandLine.arguments.contains("--smoke-test-reminder") || CommandLine.arguments.contains("--smoke-test-background") {
            if CommandLine.arguments.contains("--smoke-test-guide") { PermissionDragGuide.shared.show() }
            let reminderKeyBefore = NSApp.keyWindow
            let reminderActiveBefore = NSApp.isActive
            if CommandLine.arguments.contains("--smoke-test-reminder") { reminder.preview() }
            DispatchQueue.main.asyncAfter(deadline: .now() + (CommandLine.arguments.contains("--smoke-test-reminder") ? 1 : 2)) {
                if CommandLine.arguments.contains("--smoke-test-background") {
                    guard self.backgroundProbePassed else {
                        fputs("Background smoke failed: configuration did not reach owner before window creation\n", stderr); exit(1)
                    }
                    print("Background smoke passed: configuration subscriptions active before settings creation; no hardware")
                    NSApp.terminate(nil); return
                }
                guard CommandLine.arguments.contains("--smoke-test-reminder") || NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) else {
                    let diagnostic = NSApp.windows.map { "\($0.title):visible=\($0.isVisible),main=\($0.canBecomeMain),key=\($0.isKeyWindow)" }.joined(separator: "; ")
                    fputs("UI smoke failed: settings window is not visible [\(diagnostic)]\n", stderr)
                    exit(1)
                }
                if CommandLine.arguments.contains("--smoke-test-guide"),
                   !NSApp.windows.contains(where: { $0.isVisible && $0.title.contains("拖入授权引导") }) {
                    fputs("UI smoke failed: permission guide is not visible\n", stderr)
                    exit(1)
                }
                if CommandLine.arguments.contains("--smoke-test-reminder"),
                   !self.reminder.previewIsNonactivating || self.reminder.runtime.state.showsReleaseHint || NSApp.keyWindow !== reminderKeyBefore || NSApp.isActive != reminderActiveBefore {
                    fputs("UI smoke failed: voice reminder is missing, interactive or key/main\n", stderr)
                    exit(1)
                }
                if let flag = CommandLine.arguments.firstIndex(of: "--preview-directory"), CommandLine.arguments.indices.contains(flag + 1) {
                    self.savePreviews(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1], isDirectory: true))
                }
                if CommandLine.arguments.contains("--smoke-test-reminder") {
                    let keyWindow = NSApp.keyWindow
                    let active = NSApp.isActive
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        guard self.reminder.runtime.state.showsReleaseHint,
                              self.reminder.previewIsNonactivating, NSApp.keyWindow === keyWindow, NSApp.isActive == active else {
                            fputs("Reminder smoke failed: hint expansion or focus changed\n", stderr); exit(1)
                        }
                        if let flag = CommandLine.arguments.firstIndex(of: "--preview-directory"), CommandLine.arguments.indices.contains(flag + 1) {
                            self.savePreviews(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1], isDirectory: true).appendingPathComponent("expanded"))
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            guard self.reminder.previewIsHidden, NSApp.keyWindow === keyWindow, NSApp.isActive == active else {
                                fputs("Reminder smoke failed: preview did not hide or focus changed\n", stderr); exit(1)
                            }
                            print("Reminder lifecycle smoke passed: compact panel, expanded hint, hidden after five seconds; key/main and activation unchanged; click-through property true")
                            Task { @MainActor in
                                do {
                                    try await smokeCapsuleFollowing()
                                    NSApp.terminate(nil)
                                } catch {
                                    fputs("Synthetic capsule HUD smoke failed: \(error)\n", stderr); exit(1)
                                }
                            }
                        }
                    }
                } else {
                    print("UI smoke passed: settings window is visible")
                    NSApp.terminate(nil)
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func showSettingsWindow() {
        if settingsWindow == nil {
            let content = SettingsView()
                .environmentObject(store).environmentObject(runtime).environmentObject(reminder)
                .environmentObject(presentation).environmentObject(login)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 850),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = InterfaceInspection.interactive ? "VoiRemote · 界面预览" : "VoiRemote"
            window.contentViewController = NSHostingController(rootView: content)
            window.minSize = NSSize(width: 1040, height: 640)
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.toolbar = NSToolbar(identifier: "VoiRemote.Settings")
            window.toolbarStyle = .unified
            if !InterfaceInspection.enabled { window.setFrameAutosaveName("VoiRemote.Settings") }
            window.center()
            presentation.attach(window)
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func smokeDesktop(silent: Bool) async throws {
        enum Failure: Error { case windowOrDock(String) }
        func settings() -> NSWindow? { NSApp.windows.first { $0.isVisible && $0.canBecomeMain } }
        if silent {
            guard settings() == nil, NSApp.activationPolicy() == .accessory else { throw Failure.windowOrDock("silent startup: visible=\(settings() != nil), policy=\(NSApp.activationPolicy().rawValue), tracked=\(presentation.settingsVisible)") }
        }
        presentation.showSettings()
        try await Task.sleep(for: .milliseconds(450))
        guard let window = settings(), NSApp.activationPolicy() == .regular else { throw Failure.windowOrDock("open settings") }
        window.performClose(nil)
        try await Task.sleep(for: .milliseconds(200))
        guard settings() == nil, NSApp.activationPolicy() == .accessory else { throw Failure.windowOrDock("close settings") }
        presentation.keepDockVisible = true
        presentation.showSettings()
        try await Task.sleep(for: .milliseconds(250))
        settings()?.performClose(nil)
        try await Task.sleep(for: .milliseconds(200))
        guard settings() == nil, NSApp.activationPolicy() == .regular else { throw Failure.windowOrDock("persistent Dock") }
        presentation.keepDockVisible = false
        guard NSApp.activationPolicy() == .accessory else { throw Failure.windowOrDock("disable persistent Dock") }
        presentation.showSettings()
        try await Task.sleep(for: .milliseconds(250))
        guard settings() != nil, NSApp.activationPolicy() == .regular else { throw Failure.windowOrDock("reopen settings") }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        presentation.showSettings()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        reminder.shutdown(); subscriptions.removeAll()
        presentation.shutdown()
        if InterfaceInspection.enabled {
            InterfaceInspection.defaults.removePersistentDomain(forName: InterfaceInspection.preferencesDomain)
        }
    }

    private func statusButton(in view: NSView) -> NSStatusBarButton? {
        if let button = view as? NSStatusBarButton { return button }
        return view.subviews.lazy.compactMap { self.statusButton(in: $0) }.first
    }

    private func savePreviews(to directory: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (index, window) in NSApp.windows.filter({ $0.isVisible && ($0.canBecomeMain || $0.title.contains("拖入授权引导") || $0.title == "语音时限提醒") }).enumerated() {
                guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) {
                    try data.write(to: directory.appendingPathComponent("window-\(index).png"))
                }
            }
            for window in NSApp.windows {
                guard let view = window.contentView, let button = statusButton(in: view),
                      let bitmap = button.bitmapImageRepForCachingDisplay(in: button.bounds) else { continue }
                button.cacheDisplay(in: button.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) {
                    try data.write(to: directory.appendingPathComponent("menu-icon.png"))
                }
                break
            }
            let remote = ImageRenderer(content: RemoteDiagram(selection: .constant(.select), active: [], voiceHeld: false))
            remote.scale = 2
            if let image = remote.nsImage, let tiff = image.tiffRepresentation,
               let data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try data.write(to: directory.appendingPathComponent("remote.png"))
            }
            print("UI previews saved (own views only)")
        } catch { fputs("UI preview failed: \(error.localizedDescription)\n", stderr) }
    }
}
