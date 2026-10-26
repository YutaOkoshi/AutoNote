import Foundation

public enum AutomationTrigger: String, Codable, Sendable, CaseIterable {
    case minutesGenerated = "minutes_generated"
    case transcriptOnly = "transcript_only"
    case recordingStarted = "recording_started"
    case recordingStopped = "recording_stopped"
}

/// One entry of `automations.json`. JSON keys: `name` `enabled` `on` `command` `timeout_sec`.
public struct AutomationDefinition: Codable, Equatable, Sendable, Identifiable {
    public static let defaultTimeoutSec = 300

    public var name: String
    public var enabled: Bool
    public var on: AutomationTrigger
    public var command: String
    public var timeoutSec: Int
    public var id: String { name }

    public init(name: String, enabled: Bool = true, on: AutomationTrigger, command: String,
                timeoutSec: Int = AutomationDefinition.defaultTimeoutSec) {
        self.name = name
        self.enabled = enabled
        self.on = on
        self.command = command
        self.timeoutSec = timeoutSec
    }

    private enum CodingKeys: String, CodingKey {
        case name, enabled, on, command
        case timeoutSec = "timeout_sec"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        on = try c.decode(AutomationTrigger.self, forKey: .on)
        command = try c.decode(String.self, forKey: .command)
        timeoutSec = try c.decodeIfPresent(Int.self, forKey: .timeoutSec) ?? Self.defaultTimeoutSec
    }
}

public struct LoadedAutomation: Equatable, Sendable {
    public var definition: AutomationDefinition
    public var isRunnable: Bool
    public var problem: String?

    public init(definition: AutomationDefinition, isRunnable: Bool, problem: String? = nil) {
        self.definition = definition
        self.isRunnable = isRunnable
        self.problem = problem
    }
}

public struct AutomationsLoadResult: Equatable, Sendable {
    public var items: [LoadedAutomation]
    public var warnings: [String]
    public var disabledByPermission: Bool

    public init(items: [LoadedAutomation] = [], warnings: [String] = [], disabledByPermission: Bool = false) {
        self.items = items
        self.warnings = warnings
        self.disabledByPermission = disabledByPermission
    }
}
