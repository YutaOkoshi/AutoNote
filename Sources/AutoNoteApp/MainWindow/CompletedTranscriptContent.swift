import AutoNoteCore
import SwiftUI

/// The 文字起こし tab's content (inside the tab's scroll view): the bookmarks, then the final transcript under its
/// heading with the translation controls, each line with its translation when there is one and 「訳文」 is on.
struct CompletedTranscriptContent: View {
    let model: AppModel
    let id: MeetingID
    let bookmarks: [Bookmark]
    let transcript: [LiveLine]
    let translation: MeetingTranslation
    var highlighted: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("ブックマーク").font(.headline)
                if bookmarks.isEmpty { Text("（なし）").foregroundStyle(.secondary) }
                ForEach(bookmarks.indices, id: \.self) { i in
                    Label {
                        Text("\(bookmarks[i].at.hhmmss)\(bookmarks[i].note.map { "  \($0)" } ?? "")")
                            .monospacedDigit()
                    } icon: {
                        Image(systemName: "bookmark.fill").foregroundStyle(.orange)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Text("文字起こし（確定版）").font(.headline)
                    TranslationControls(model: model, id: id, translation: translation)
                }
                TranscriptList(lines: transcript, highlighted: highlighted,
                               translations: TranslationPresentation.finalTranslations(
                                   transcript, translation, shown: model.translationShown))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The transcript inside an outer scroll view: plain rows, no own scrolling. Each row has an id for `scrollTo`;
/// the highlighted row (a jump from 要約) gets a tinted background.
struct TranscriptList: View {
    let lines: [LiveLine]
    var highlighted: Int?
    var translations: [String?] = []

    static func rowID(_ index: Int) -> String { "transcript.\(index)" }

    var body: some View {
        if lines.isEmpty {
            Text("（なし）").foregroundStyle(.secondary)
        } else {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    TranscriptLineView(line: line, translation: translations.indices.contains(index) ? translations[index] : nil)
                        .padding(.horizontal, 4)
                        .background(RoundedRectangle(cornerRadius: 4)
                            .fill(index == highlighted ? Color.accentColor.opacity(0.18) : Color.clear))
                        .id(Self.rowID(index))
                }
            }
            .textSelection(.enabled)
        }
    }
}
