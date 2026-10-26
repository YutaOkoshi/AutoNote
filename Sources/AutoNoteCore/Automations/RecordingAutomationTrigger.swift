import Foundation
import os

/// Fires `recording_started` / `recording_stopped` automations from recording events. Duplicate events are
/// no-ops through the runner's dedupe ledger (key `rec:<id>:<event>`).
public actor RecordingAutomationTrigger {
    private static let logger = Logger(subsystem: "com.yutaokoshi.autonote", category: "RecordingAutomationTrigger")

    private let dispatcher: AutomationDispatcher
    private let manifests: ManifestStore

    public init(dispatcher: AutomationDispatcher, manifests: ManifestStore) {
        self.dispatcher = dispatcher
        self.manifests = manifests
    }

    public func handle(_ event: RecordingEvent) async {
        switch event {
        case .started(let id):
            guard let manifest = try? await manifests.load(id) else {
                Self.logger.error("\(id.rawValue, privacy: .public): manifest unreadable, recording_started skipped")
                return
            }
            await fire(.recordingStarted, manifest)
        case .stopped(let manifest, _):
            await fire(.recordingStopped, manifest)
        default:
            break
        }
    }

    private func fire(_ trigger: AutomationTrigger, _ manifest: Manifest) async {
        let ctx = AutomationContextBuilder.make(event: trigger, manifest: manifest, file: nil, minutesJSON: nil)
        _ = await dispatcher.dispatch(trigger, context: ctx, dedupeKey: "rec:\(manifest.id.rawValue):\(trigger.rawValue)")
    }
}
