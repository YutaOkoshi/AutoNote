import AutoNoteCore
import SwiftUI

/// Above a meeting's transcript: the translation's progress or failure, 「翻訳する」 / 「訳し直す」 / 「再試行」, and the
/// app-wide 「訳文」 switch (spec 9 and the screen section).
struct TranslationControls: View {
    let model: AppModel
    let id: MeetingID
    let translation: MeetingTranslation

    var body: some View {
        let c = TranslationPresentation.controls(job: model.translationJobs[id], translation: translation,
                                                 hasTranscript: translation.hasTranscript,
                                                 available: model.translationAvailability.isReady)
        if !c.isEmpty {
            HStack(spacing: 8) {
                if let status = c.status {
                    if c.isFailure {
                        Label(status, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    } else {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let progress = c.progress {
                    ProgressView(value: progress)
                        .frame(width: 100)
                        .accessibilityLabel("翻訳の進み具合")
                }
                Spacer(minLength: 0)
                if let title = c.button {
                    Button(title, systemImage: "character.bubble") {
                        Task { await model.perform(.translate(id)) }
                    }
                    .controlSize(.small)
                }
                if c.showsToggle { TranslationToggle(model: model) }
            }
        }
    }
}

/// 「訳文」: show translations under the lines or not. Kept app-wide in the settings, not per meeting.
struct TranslationToggle: View {
    let model: AppModel

    var body: some View {
        Toggle("訳文", isOn: Binding(get: { model.translationShown },
                                    set: { v in Task { await model.perform(.setTranslationShown(v)) } }))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(.caption)
            .help("文字起こしの各行と要約の各項目に訳文を併記します（原文は小さく表示）")
    }
}

/// A summary text (a live summary item, a minutes row) with its translation underneath, the transcript line's look:
/// the original shrinks to caption size in the secondary colour and the translation takes the given style; without
/// one, the text exactly as before. Fonts set outside apply to the translation (or to the text alone).
struct TranslatedText: View {
    let original: String
    let translation: String?

    var body: some View {
        if let translation {
            VStack(alignment: .leading, spacing: 1) {
                Text(original)
                    .font(.caption)
                    .fontWeight(.regular)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(translation).fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(TranslationPresentation.accessibilityLabel(original: original, translation: translation))
        } else {
            Text(original).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Loads a meeting's stored translation again whenever a run of it finishes.
struct TranslationLoadKey: Hashable {
    let id: String
    let revision: Int
}
