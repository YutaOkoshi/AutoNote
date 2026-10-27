import AutoNoteCore
import SwiftUI

/// While the queue works on the meeting: the progress and the live transcript with the dictionary's replacements
/// applied (`live.json` is stored before replacement, §7.1). Read-only, no following.
struct ProcessingDetailView: View {
    let env: AppEnvironment
    let model: AppModel
    let row: MeetingRow
    @State private var lines: [LiveLine] = []
    @State private var loadError: String?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(row.title).font(.title3.bold())
                if let progress = queueItem?.progress {
                    ProgressView(value: progress)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                Text(row.progressLabel ?? row.state.displayText(progressLabel: nil))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            Divider()
            if let loadError {
                ContentUnavailableView("文字起こしを読めませんでした", systemImage: "doc.questionmark", description: Text(loadError))
                    .frame(maxHeight: .infinity)
            } else if lines.isEmpty {
                ContentUnavailableView("リアルタイムの文字起こしはありません", systemImage: "text.alignleft")
                    .frame(maxHeight: .infinity)
            } else {
                LiveTranscriptView(lines: lines, follows: false)
            }
        }
        .task(id: row.id) { await load() }
    }

    private var queueItem: QueueItemDTO? {
        model.queue.items.first { $0.meetingID == row.id && $0.state != JobState.done.rawValue }
    }

    private func load() async {
        let id = MeetingID(rawValue: row.id)
        do {
            let transcript = try await env.ports.meetings.transcript(id, kind: .live)
            let replacer = Replacer(await Self.dictionary(env).replacements)
            lines = LiveTranscriptView.lines(replacer.apply(transcript?.utterances ?? []))
            loadError = nil
        } catch {
            loadError = CommandRouter.ipcError(error).message
        }
    }

    /// The dictionary in the output folder (or its mirror); the default one when missing or unreadable (ruling X36).
    private static func dictionary(_ env: AppEnvironment) async -> DictionaryFile {
        guard let data = try? await env.output.portable().read(.dictionary) else { return .default }
        return DictionaryFile.parse(String(decoding: data, as: UTF8.self)).dictionary
    }
}
