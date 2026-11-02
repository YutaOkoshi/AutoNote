import Foundation

/// One item of the meeting list's context menu.
public enum MeetingContextAction: Equatable, Hashable, Sendable {
    case merge
    case rerunAutomation(String)
    case regenerate
    case revealInFinder
    case delete

    public var title: String {
        switch self {
        case .merge: "1 つの会議に統合"
        case .rerunAutomation(let name): "再実行: \(name)"
        case .regenerate: "再生成"
        case .revealInFinder: "Finder で表示"
        case .delete: "この会議を削除"
        }
    }

    public var systemImage: String {
        switch self {
        case .merge: "rectangle.stack.badge.plus"
        case .rerunAutomation, .regenerate: "arrow.clockwise"
        case .revealInFinder: "folder"
        case .delete: "trash"
        }
    }

    public var isDestructive: Bool { self == .delete }
}

/// What the meeting list's context menu offers for the meetings it was opened on.
public enum MeetingContextMenu {
    /// Two or more meetings: only 統合 (the merge itself refuses what it cannot combine). One meeting: its failed
    /// automations to run again (§14.5), then 再生成 for a meeting with minutes or a transcript, Finder always, and
    /// 削除 unless it is recording or still being processed. A meeting no longer listed keeps only its reruns.
    public static func actions(selected: Set<String>, rows: [MeetingRow],
                               automationFailures: [AutomationRunRecord]) -> [MeetingContextAction] {
        if selected.count >= 2 { return [.merge] }
        guard let id = selected.first else { return [] }
        var actions = automationFailures.filter { $0.meetingID == id }.map { MeetingContextAction.rerunAutomation($0.name) }
        guard let row = rows.first(where: { $0.id == id }) else { return actions }
        if [.minutesGenerated, .transcriptOnly].contains(row.state) { actions.append(.regenerate) }
        actions.append(.revealInFinder)
        if ![.recording, .recorded, .processing].contains(row.state) { actions.append(.delete) }
        return actions
    }

    /// 「Finder で表示」 selects the meeting's note, or the recording folder while there is none (as the failure
    /// band's 「録音を Finder で表示」 does).
    public static func revealURL(for row: MeetingRow?, tracksDirectory: URL) -> URL {
        row?.filePath.map { URL(filePath: $0) } ?? tracksDirectory
    }
}
