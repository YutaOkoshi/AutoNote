import Foundation

/// The meeting screen's translation controls and the translation under each transcript line.
public enum TranslationPresentation {
    /// The translation to show under each of `lines` of the final transcript (index-aligned): the entry made from
    /// that very line, nothing when hidden, stale, or for markers and partial lines.
    public static func finalTranslations(_ lines: [LiveLine], _ t: MeetingTranslation, shown: Bool) -> [String?] {
        guard shown else { return Array(repeating: nil, count: lines.count) }
        return lines.indices.map { i in
            guard case .utterance = lines[i] else { return nil }
            return t.byIndex[i]?.text
        }
    }

    /// The translation to show under each of `lines` of the live transcript: only confirmed lines, by
    /// `TranslationKey.live`.
    public static func liveTranslations(_ lines: [LiveLine], _ live: [String: LiveTranslatedLine],
                                        shown: Bool) -> [String?] {
        guard shown, !live.isEmpty else { return Array(repeating: nil, count: lines.count) }
        return lines.map { line in
            guard case .utterance(let u) = line, u.isFinal else { return nil }
            return live[TranslationKey.live(u)]?.text
        }
    }

    /// What the controls above a meeting's transcript offer.
    public struct Controls: Equatable, Sendable {
        /// 「翻訳する」 / 「訳し直す」 / 「再試行」; nil when no button (running, or translation is not usable).
        public var button: String?
        /// 「翻訳中… 12 / 340」, the failure, the stale note; nil when nothing to say.
        public var status: String?
        public var isFailure: Bool
        /// The progress bar's value while running.
        public var progress: Double?
        /// Whether the 「訳文」 switch shows (there is something to show or hide).
        public var showsToggle: Bool

        /// Nothing to show at all (no row is drawn).
        public var isEmpty: Bool { button == nil && status == nil && progress == nil && !showsToggle }

        public init(button: String? = nil, status: String? = nil, isFailure: Bool = false, progress: Double? = nil,
                    showsToggle: Bool = false) {
            self.button = button
            self.status = status
            self.isFailure = isFailure
            self.progress = progress
            self.showsToggle = showsToggle
        }
    }

    /// The controls of a meeting with a final transcript (spec 9): 「翻訳する」 with no translation, 「訳し直す」
    /// with one, 「再試行」 after a failure; only while translation is usable (the mode does not matter).
    public static func controls(job: TranslationJobState?, translation: MeetingTranslation, hasTranscript: Bool,
                                available: Bool) -> Controls {
        let hasLines = !translation.byIndex.isEmpty || !translation.live.isEmpty
        switch job {
        case .queued:
            return Controls(status: "翻訳の順番を待っています…", progress: nil, showsToggle: hasLines)
        case .running(let p):
            return Controls(status: "翻訳中… \(p.done) / \(p.total)", progress: fraction(p), showsToggle: hasLines)
        case .waitingForRecording(let p):
            return Controls(status: "録音中は翻訳を止めています（\(p.done) / \(p.total)）。停止すると続けます",
                            progress: fraction(p), showsToggle: hasLines)
        case .failed(let message):
            return Controls(button: available && hasTranscript ? "再試行" : nil, status: message, isFailure: true,
                            showsToggle: hasLines)
        case nil:
            break
        }
        guard hasTranscript else { return Controls(showsToggle: hasLines) }
        let button: String? = available ? (translation.status == .none || isPartial(translation.status) ? "翻訳する" : "訳し直す") : nil
        let status: String? = switch translation.status {
        case .stale: "文字起こしが変わったため、前の訳文は表示していません"
        case .partial(let done, let total): "翻訳は途中です（\(done) / \(total)）"
        case .none, .complete: nil
        }
        return Controls(button: button, status: status, showsToggle: hasLines)
    }

    private static func isPartial(_ s: TranslationStatus) -> Bool {
        if case .partial = s { true } else { false }
    }

    private static func fraction(_ p: TranslationProgress) -> Double? {
        p.total > 0 ? min(1, Double(p.done) / Double(p.total)) : nil
    }

    /// VoiceOver reads the original, then the translation announced as such.
    public static func accessibilityLabel(original: String, translation: String) -> String {
        "\(original)。訳文: \(translation)"
    }
}

/// The settings screen's 翻訳 tab: which choices this Mac offers and why some are off (spec 1).
public enum TranslationSettingsPresentation {
    public struct ModeOption: Equatable, Sendable {
        public var mode: TranslationMode
        public var title: String
        /// Why it cannot be picked here; nil when it can.
        public var disabledReason: String?
    }

    public struct ModelRow: Equatable, Sendable {
        public var model: TranslationModel
        /// 「2B（既定・1.8 GB）」
        public var title: String
        public var note: String
        public var isDefault: Bool
        public var disabledReason: String?
    }

    public static func modes(profile: MachineProfile) -> [ModeOption] {
        TranslationMode.allCases.map {
            ModeOption(mode: $0, title: $0.displayName,
                       disabledReason: TranslationModelPolicy.unavailableReason($0, profile: profile))
        }
    }

    public static func models(profile: MachineProfile) -> [ModelRow] {
        let fallback = TranslationModelPolicy.defaultModel(for: profile)
        return TranslationModelCatalog.all.map { m in
            let size = ByteCountFormatter.string(fromByteCount: m.sizeBytes, countStyle: .file)
            let isDefault = m == fallback
            return ModelRow(model: m, title: "\(m.displayName)（\(isDefault ? "この Mac の既定・" : "")\(size)）",
                            note: note(m.name), isDefault: isDefault,
                            disabledReason: TranslationModelPolicy.unavailableReason(m, profile: profile))
        }
    }

    private static func note(_ name: String) -> String {
        switch name {
        case "0.8b": "軽くて速い。Intel の Mac・メモリ 8 GB の Mac 向け。前後の文脈の効きは弱め"
        case "2b": "速さと訳の質のつり合いが最もよい（Apple Silicon・メモリ 16 GB 以上の既定）"
        case "8b": "訳がいちばん自然。メモリ 16 GB 以上の Apple Silicon 向け。2B の 3 倍ほど時間がかかります"
        default: ""
        }
    }

    /// The line under the mode when this build cannot translate at all.
    public static let runtimeUnavailableNote =
        "このビルドには端末内の翻訳エンジンがまだ入っていません。設定とモデルのダウンロードはできますが、翻訳は動きません。"

    /// 「Built with PLaMo」 and what the feature sends where.
    public static let privacyNote =
        "翻訳は Mac の中だけで行います。文字起こしも訳文も外へ送りません（通信するのはモデルのダウンロードだけです）。議事録は今までどおり原文から作ります。"
}
