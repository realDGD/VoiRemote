import Foundation

/// Versioned persisted preferences. Device identifiers must be macOS UIDs, never transient numeric IDs.
public struct AppConfiguration: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 6
    public var schemaVersion: Int = currentSchemaVersion
    public var mappingsEnabled = false
    public var voiceEnabled = false
    public var remoteAudioEnabled = false
    public var preferVirtualInput = false
    public var voiceLimitReminderEnabled = false
    /// Legacy storage name: seconds before revealing the action hint, not the countdown.
    public var voiceLimitReminderStartSeconds = VoiceLimitIndicator.defaultStartSeconds
    public var voiceLimitReminderPosition: VoiceLimitReminderPosition = .bottomCenter
    public var voiceTrigger: VoiceTrigger = .function
    public var selectedVirtualInputUID: String?
    public var bindings: [KeyBinding] = []
    public var gestureTiming = GestureTiming()
    public var buttonBehaviors: [ButtonBehaviorOverride] = []

    public init() {}

    public func action(for button: RemoteButton, gesture: ButtonGesture) -> MappedAction {
        bindings.first { $0.button == button && $0.gesture == gesture }?.action ?? .none
    }

    public mutating func setAction(_ action: MappedAction, for button: RemoteButton, gesture: ButtonGesture) {
        bindings.removeAll { $0.button == button && $0.gesture == gesture }
        if action != .none {
            bindings.append(KeyBinding(button: button, gesture: gesture, action: action))
        }
    }

    public mutating func setShortcut(_ shortcut: KeyboardShortcut, for button: RemoteButton, gesture: ButtonGesture) {
        bindings.removeAll { $0.button == button && $0.gesture == gesture }
        bindings.append(KeyBinding(button: button, gesture: gesture, action: .customShortcut, shortcut: shortcut))
    }

    public func invocation(for button: RemoteButton, gesture: ButtonGesture) -> MappedInvocation {
        guard let binding = bindings.first(where: { $0.button == button && $0.gesture == gesture }) else {
            return MappedInvocation(action: .none)
        }
        return MappedInvocation(action: binding.action, shortcut: binding.shortcut)
    }

    /// Fill every empty preset gesture, preserving all existing overrides and feature switches.
    public mutating func fillBasicNavigationBindings() {
        for binding in CommonMappings.bindings where action(for: binding.button, gesture: binding.gesture) == .none {
            if let shortcut = binding.shortcut { setShortcut(shortcut, for: binding.button, gesture: binding.gesture) }
            else { setAction(binding.action, for: binding.button, gesture: binding.gesture) }
        }
    }

    public func behavior(for button: RemoteButton) -> ButtonBehavior {
        buttonBehaviors.first { $0.button == button }?.behavior ?? ButtonBehavior()
    }
    public mutating func setBehavior(_ behavior: ButtonBehavior, for button: RemoteButton) {
        buttonBehaviors.removeAll { $0.button == button }
        if behavior != ButtonBehavior() { buttonBehaviors.append(ButtonBehaviorOverride(button: button, behavior: behavior)) }
    }

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    /// Missing fields inherit defaults, but unknown future schemas must never be overwritten silently.
    public static func decode(_ data: Data) throws -> Self {
        var configuration = try JSONDecoder().decode(Self.self, from: data)
        guard (1...currentSchemaVersion).contains(configuration.schemaVersion) else {
            throw ConfigurationError.unsupportedVersion(configuration.schemaVersion)
        }
        let keys = configuration.bindings.map { "\($0.button.rawValue):\($0.gesture.rawValue)" }
        guard Set(keys).count == keys.count else { throw ConfigurationError.duplicateBinding }
        guard VoiceLimitIndicator.startSecondsRange.contains(configuration.voiceLimitReminderStartSeconds) else {
            throw ConfigurationError.invalidVoiceReminderSettings
        }
        for binding in configuration.bindings {
            if binding.action == .customShortcut && binding.shortcut == nil { throw ConfigurationError.invalidShortcut }
            if let shortcut = binding.shortcut, !shortcut.isValid { throw ConfigurationError.invalidShortcut }
        }
        guard configuration.gestureTiming.isValid,
              Set(configuration.buttonBehaviors.map(\.button)).count == configuration.buttonBehaviors.count else {
            throw ConfigurationError.invalidGestureSettings
        }
        configuration.schemaVersion = currentSchemaVersion
        return configuration
    }

    private enum CodingKeys: String, CodingKey {
        case gestureTiming, buttonBehaviors
        case voiceLimitReminderEnabled, voiceLimitReminderPosition, voiceLimitReminderStartSeconds
        case schemaVersion, mappingsEnabled, voiceEnabled, remoteAudioEnabled, preferVirtualInput, voiceTrigger, selectedVirtualInputUID, bindings
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        mappingsEnabled = try values.decodeIfPresent(Bool.self, forKey: .mappingsEnabled) ?? false
        voiceEnabled = try values.decodeIfPresent(Bool.self, forKey: .voiceEnabled) ?? (schemaVersion < 3 && mappingsEnabled)
        remoteAudioEnabled = try values.decodeIfPresent(Bool.self, forKey: .remoteAudioEnabled) ?? false
        preferVirtualInput = try values.decodeIfPresent(Bool.self, forKey: .preferVirtualInput) ?? false
        voiceLimitReminderEnabled = try values.decodeIfPresent(Bool.self, forKey: .voiceLimitReminderEnabled) ?? false
        voiceLimitReminderStartSeconds = try values.decodeIfPresent(Int.self, forKey: .voiceLimitReminderStartSeconds) ?? VoiceLimitIndicator.defaultStartSeconds
        voiceLimitReminderPosition = try values.decodeIfPresent(VoiceLimitReminderPosition.self, forKey: .voiceLimitReminderPosition) ?? .bottomCenter
        voiceTrigger = try values.decodeIfPresent(VoiceTrigger.self, forKey: .voiceTrigger) ?? .function
        selectedVirtualInputUID = try values.decodeIfPresent(String.self, forKey: .selectedVirtualInputUID)
        bindings = try values.decodeIfPresent([KeyBinding].self, forKey: .bindings) ?? []
        gestureTiming = try values.decodeIfPresent(GestureTiming.self, forKey: .gestureTiming) ?? GestureTiming()
        buttonBehaviors = try values.decodeIfPresent([ButtonBehaviorOverride].self, forKey: .buttonBehaviors) ?? []
    }
}

public enum ConfigurationError: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
    case duplicateBinding
    case invalidShortcut
    case invalidGestureSettings
    case invalidVoiceReminderSettings
}

public enum VoiceLimitReminderPosition: String, Codable, CaseIterable, Sendable {
    case bottomCenter, bottomTrailing
}
