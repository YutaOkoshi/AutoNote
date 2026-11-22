// 確定版の「自動」: whisper の判定は呼び出し 1 回（10 分の窓）につき先頭 30 秒の 1 回だけなので、日英が交互に出る会議では
// 窓の後半の言語を外す（日米 2017 の会見で、英語の冒頭に引きずられて日本語の冒頭発言が en の指定で起きていた）。
// 窓を無音で区切った塊（発話が一定量たまるまで次の無音で切らない）ごとに ja/en を判定し、同じ言語が続く塊をまとめた
// 「言語の区間」ごとに、その言語を固定して起こす。区間の切れ目は必ず無音の中なので、語の途中で切れない。
// 判定の揺れを抑えるため、言語を切り替えるのは反対の言語が ja と en の 2 つの中の割合で `switchShare` 以上、かつ whisper の
// 99 言語の中の確率でも `switchProbability` 以上のときだけで、発話の少ない塊は判定せずに直前の言語を引き継ぐ。
// 確率の条件は、相づち（「うん」）の多い塊が en に寄る（en 0.14〜0.76、割合は 0.9 以上。IngCrowd の話者別トラック）のを
// 切り替えに数えないため。本物の切り替えの塊は日米 2017 で 0.78〜1.0、合成の混在で 0.53〜1.0 と重なっていて、0.8 未満の
// 切り替え（合成の混在で 13 か所中 3 か所）は直前の言語のまま起こす。単一言語の会議のトラックで誤って切り替える方が崩れ方が
// 大きいので、この取りこぼしを受け入れた。測定と理由: docs/eval/results/2026-11-22-auto-language-probabilities.md
// 窓の先頭は直前の窓の言語から始め、窓の途中と同じ規則で切り替える（窓の切れ目の位置で結果が変わらないように）。
// 直前の窓が無いとき（最初の窓、まだ判定が返っていないとき）だけ、窓の中の最初の確かな判定を先読みする。単一言語の会議では窓全体が 1 区間になり、固定の言語と同じ呼び出しになる。

/// How finely the final transcription judges the language with `.auto`.
public enum AutoLanguageSplitting: Equatable, Sendable {
    /// Each block of a window (`LanguageRunPlanner`): one extra encoder pass per block, about 3–4 times the encoder work
    /// of decoding alone. Measured on Apple Silicon (Metal): batch RTF 0.012–0.018 → 0.019–0.030 (about 1.3–1.8×).
    case perBlock
    /// Once per window, on its first 30 s (whisper's own place to judge): no extra work.
    case perWindow

    /// Per block only with Metal. On Intel the encoder runs on the CPU and the large models' final transcription already
    /// takes about as long as the recording (`WhisperModelFit`), so the extra passes could make it several times longer.
    public static func `for`(_ machine: MachineKind) -> AutoLanguageSplitting {
        machine == .appleSilicon ? .perBlock : .perWindow
    }
}

/// Splits one batch window into runs of one language each (Japanese or English) for `.auto` final transcription.
/// Sample ranges are relative to the window's samples (16 kHz).
public struct LanguageRunPlanner: Sendable {
    /// Lengths in seconds.
    public struct Config: Equatable, Sendable {
        /// A quiet stretch at least this long may end a block (`SilenceDetector`'s 20 ms frames, RMS < 0.01).
        public var minSilence: Double
        /// A block is cut only after it holds at least this much speech, so whisper has enough to judge the language.
        public var blockSpeech: Double
        /// A block with less speech than this is not judged and keeps the language before it.
        public var judgeSpeech: Double
        /// The share (of Japanese, or of English) between the two the other language needs to take over.
        public var switchShare: Float
        /// The probability among all of whisper's languages the other language also needs.
        public var switchProbability: Float

        public init(minSilence: Double = 0.5, blockSpeech: Double = 6, judgeSpeech: Double = 2, switchShare: Float = 0.8,
                    switchProbability: Float = 0.8) {
            self.minSilence = minSilence
            self.blockSpeech = blockSpeech
            self.judgeSpeech = judgeSpeech
            self.switchShare = switchShare
            self.switchProbability = switchProbability
        }
    }

    /// A stretch of the window decoded in one language.
    public struct Run: Equatable, Sendable {
        public var samples: Range<Int>
        public var language: Language

        public init(samples: Range<Int>, language: Language) {
            self.samples = samples; self.language = language
        }
    }

    private static let sampleRate = 16_000.0

    public let config: Config

    public init(config: Config = .init()) {
        precondition(config.minSilence > 0 && config.blockSpeech > 0 && config.judgeSpeech >= 0, "lengths must be positive")
        precondition((0.5...1).contains(config.switchShare), "switchShare must be in 0.5...1")
        precondition((0...1).contains(config.switchProbability), "switchProbability must be in 0...1")
        self.config = config
    }

    /// Blocks of `pcm` cut in the middle of a silence once each holds `blockSpeech` of speech. A tail with less than
    /// `blockSpeech` joins the block before it. Together they cover `pcm` exactly, in order.
    public func blocks(_ pcm: [Int16]) -> [Range<Int>] {
        guard !pcm.isEmpty else { return [] }
        var detector = SilenceDetector(minSilence: config.minSilence)
        let half = Int((config.minSilence / 2 * Self.sampleRate).rounded())
        let cuts = detector.process(pcm).map { min(pcm.count, Int(($0 * Self.sampleRate).rounded()) + half) }
        let enough = SilenceDetector(minSpeech: config.blockSpeech)
        var blocks: [Range<Int>] = []
        var start = 0
        for cut in cuts where cut > start && cut < pcm.count
            && enough.hasSpeech(in: pcm, from: Double(start) / Self.sampleRate, to: Double(cut) / Self.sampleRate) {
            blocks.append(start..<cut)
            start = cut
        }
        if let last = blocks.last, !enough.hasSpeech(in: pcm, from: Double(start) / Self.sampleRate, to: Double(pcm.count) / Self.sampleRate) {
            blocks[blocks.count - 1] = last.lowerBound..<pcm.count
        } else {
            blocks.append(start..<pcm.count)
        }
        return blocks
    }

    /// Whether whisper should judge the language of `block` (it holds at least `judgeSpeech` of speech).
    public func shouldJudge(_ pcm: [Int16], _ block: Range<Int>) -> Bool {
        SilenceDetector(minSpeech: config.judgeSpeech)
            .hasSpeech(in: pcm, from: Double(block.lowerBound) / Self.sampleRate, to: Double(block.upperBound) / Self.sampleRate)
    }

    /// Where speech starts in `pcm` (a little before the first 20 ms frame at or above `SilenceDetector`'s threshold),
    /// or nil when `pcm` has less than `SilenceDetector`'s minimum speech. Used to judge a window none of whose blocks has
    /// enough speech: whisper looks at the 30 s from here.
    public func speechStart(_ pcm: [Int16]) -> Int? {
        guard SilenceDetector().hasSpeech(in: pcm, from: 0, to: Double(pcm.count) / Self.sampleRate) else { return nil }
        let frame = 320
        var i = 0
        while i < pcm.count {
            if Self.isSpeech(pcm[i..<min(i + frame, pcm.count)]) { return max(0, i - Int(0.2 * Self.sampleRate)) }
            i += frame
        }
        return nil
    }

    /// `SilenceDetector`'s speech frame: RMS (Int16 normalised to ±1) at or above 0.01.
    private static func isSpeech(_ frame: ArraySlice<Int16>) -> Bool {
        guard !frame.isEmpty else { return false }
        var sum = 0.0
        for sample in frame {
            let v = Double(sample) / 32_768
            sum += v * v
        }
        return (sum / Double(frame.count)).squareRoot() >= 0.01
    }

    /// The runs for `blocks` (in order, covering the window) given whisper's guess for each (nil = not judged).
    /// The window starts in `previous` (the language the window before ended in); with none, in the first decisive guess
    /// of this window, else its first guess, else Japanese. A block switches only on a decisive guess for the other
    /// language, at the start of the window as anywhere else. Decisive: the language reaches `switchShare` between the
    /// two and `switchProbability` on its own.
    public func runs(_ blocks: [Range<Int>], guesses: [LanguageGuess?], previous: Language? = nil) -> [Run] {
        precondition(blocks.count == guesses.count, "one guess per block")
        let decisive = guesses.compactMap { $0 }.first { isDecisive($0) }
        var current = previous ?? decisive?.language ?? guesses.compactMap { $0 }.first?.language ?? .ja
        var runs: [Run] = []
        for (block, guess) in zip(blocks, guesses) {
            if let guess, guess.language != current, isDecisive(guess) { current = guess.language }
            if let last = runs.last, last.language == current {
                runs[runs.count - 1].samples = last.samples.lowerBound..<block.upperBound
            } else {
                runs.append(Run(samples: block, language: current))
            }
        }
        return runs
    }

    private func isDecisive(_ guess: LanguageGuess) -> Bool {
        let share = guess.language == .ja ? guess.japaneseShare : 1 - guess.japaneseShare
        return share >= config.switchShare && max(guess.ja, guess.en) >= config.switchProbability
    }
}
