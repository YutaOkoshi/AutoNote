import Foundation

public enum RecorderState: String, Codable, Sendable { case idle, countdown, recording, paused, grace }

public enum RecordingTrigger: String, Sendable { case auto, manual }

public enum MicrophoneChoice: Equatable, Sendable { case device(DeviceIdentity), systemDefault }

public struct AutoRecordConfig: Equatable, Sendable {
    public private(set) var countdownSeconds: Int
    public private(set) var graceSeconds: Int
    public private(set) var language: Language
    public private(set) var startOnModelMatch: Bool

    /// Clamps countdown to 0...30 (§11.4) and grace to 5...300.
    public init(countdownSeconds: Int, graceSeconds: Int, language: Language, startOnModelMatch: Bool) {
        self.countdownSeconds = min(max(countdownSeconds, 0), 30)
        self.graceSeconds = min(max(graceSeconds, 5), 300)
        self.language = language
        self.startOnModelMatch = startOnModelMatch
    }
}

public enum RecorderEvent: Equatable, Sendable {
    case deviceConnected(DeviceIdentity, autoStartEntryID: String?)
    case deviceDisconnected(DeviceIdentity)
    case timerFired(token: Int)
    case cancelCountdown
    case manualStart
    case manualStop
    case pause
    case resume
    case startForConnectedDevice(DeviceIdentity, entryID: String)
    case sessionEnded
}

public enum RecorderEffect: Equatable, Sendable {
    case postCountdownNotice(DeviceIdentity, seconds: Int)
    case dismissCountdownNotice
    case scheduleTimer(seconds: Int, token: Int)
    case cancelTimer
    case startRecording(MicrophoneChoice, RecordingTrigger)
    case stopRecording
    case pauseRecording
    case resumeRecording
    case suspendMicrophone
    case reattachMicrophone(DeviceIdentity)
    case showGraceBanner(seconds: Int)
    case clearGraceBanner
}

/// Pure transition function for auto/manual recording (spec §5.9). Cells not handled leave everything unchanged.
public struct RecorderStateMachine: Sendable {
    public var config: AutoRecordConfig
    public private(set) var state: RecorderState = .idle
    public private(set) var trigger: RecordingTrigger?
    public private(set) var origin: DeviceIdentity?
    public private(set) var originEntryID: String?
    public private(set) var pendingTimerToken: Int?

    private var lastToken = 0
    private var graceFromPaused = false

    public init(config: AutoRecordConfig) { self.config = config }

    public var needsQuitConfirmation: Bool {
        switch state {
        case .recording, .paused, .grace: return true
        case .idle, .countdown: return false
        }
    }

    public mutating func apply(_ event: RecorderEvent) -> (RecorderState, [RecorderEffect]) {
        let effects = transition(event)
        return (state, effects)
    }

    private mutating func schedule(_ seconds: Int) -> RecorderEffect {
        lastToken += 1
        pendingTimerToken = lastToken
        return .scheduleTimer(seconds: seconds, token: lastToken)
    }

    private mutating func clearOrigin() { origin = nil; originEntryID = nil }

    private func isOrigin(_ device: DeviceIdentity) -> Bool { origin.map { $0.deviceUID == device.deviceUID } ?? false }

    private mutating func transition(_ event: RecorderEvent) -> [RecorderEffect] {
        switch (state, event) {
        case (.idle, .deviceConnected(let device, let entryID?)):
            origin = device; originEntryID = entryID
            if config.countdownSeconds == 0 {
                state = .recording; trigger = .auto
                return [.startRecording(.device(device), .auto)]
            }
            state = .countdown
            return [.postCountdownNotice(device, seconds: config.countdownSeconds), schedule(config.countdownSeconds)]
        case (.idle, .manualStart):
            state = .recording; trigger = .manual
            return [.startRecording(.systemDefault, .manual)]
        case (.idle, .startForConnectedDevice(let device, let entryID)):
            origin = device; originEntryID = entryID
            state = .recording; trigger = .auto
            return [.startRecording(.device(device), .auto)]

        case (.countdown, .deviceDisconnected(let device)) where isOrigin(device):
            state = .idle; pendingTimerToken = nil; clearOrigin()
            return [.cancelTimer, .dismissCountdownNotice]
        case (.countdown, .timerFired(let token)) where token == pendingTimerToken:
            pendingTimerToken = nil; state = .recording; trigger = .auto
            guard let origin else { return [.dismissCountdownNotice] }
            return [.dismissCountdownNotice, .startRecording(.device(origin), .auto)]
        case (.countdown, .cancelCountdown):
            state = .idle; pendingTimerToken = nil; clearOrigin()
            return [.cancelTimer, .dismissCountdownNotice]
        case (.countdown, .manualStart):
            state = .recording; trigger = .manual; pendingTimerToken = nil; clearOrigin()
            return [.cancelTimer, .dismissCountdownNotice, .startRecording(.systemDefault, .manual)]

        case (.recording, .deviceDisconnected(let device)) where trigger == .auto && isOrigin(device):
            return enterGrace(fromPaused: false)
        case (.paused, .deviceDisconnected(let device)) where trigger == .auto && isOrigin(device):
            return enterGrace(fromPaused: true)
        case (.recording, .manualStop), (.paused, .manualStop):
            endSession(); return [.stopRecording]
        case (.recording, .pause):
            state = .paused; return [.pauseRecording]
        case (.paused, .resume):
            state = .recording; return [.resumeRecording]
        case (.recording, .sessionEnded), (.paused, .sessionEnded):
            endSession(); return []

        case (.grace, .deviceConnected(let device, let entryID)) where isOrigin(device) || (entryID != nil && entryID == originEntryID):
            origin = device
            pendingTimerToken = nil; state = graceFromPaused ? .paused : .recording; graceFromPaused = false
            return [.cancelTimer, .clearGraceBanner, .reattachMicrophone(device)]
        case (.grace, .timerFired(let token)) where token == pendingTimerToken:
            endSession(); return [.clearGraceBanner, .stopRecording]
        case (.grace, .manualStop):
            endSession(); return [.cancelTimer, .clearGraceBanner, .stopRecording]
        case (.grace, .sessionEnded):
            endSession(); return [.cancelTimer, .clearGraceBanner]

        default:
            return []
        }
    }

    private mutating func enterGrace(fromPaused: Bool) -> [RecorderEffect] {
        graceFromPaused = fromPaused; state = .grace
        return [.suspendMicrophone, schedule(config.graceSeconds), .showGraceBanner(seconds: config.graceSeconds)]
    }

    private mutating func endSession() {
        state = .idle; trigger = nil; pendingTimerToken = nil; graceFromPaused = false; clearOrigin()
    }
}
