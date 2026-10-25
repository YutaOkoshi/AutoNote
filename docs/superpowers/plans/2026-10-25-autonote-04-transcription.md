# AutoNote 計画 04: 文字起こし Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 計画 01 が宣言した `LiveTranscriber` / `BatchTranscriber` の実装（DictationTranscriber、SpeechTranscriber、whisper.cpp のバッチとチャンク方式）、エンジンの実行時判定と機種別の既定、ggml モデルの管理、リアルタイム表示への供給（`LiveFeed`）、確定版の結合（`raw.json` / `final.json`）を作り、`autonote dev transcribe` / `dev engines` で動かせるようにする。

**Architecture:** すべて `AutoNoteCore/Transcription/` に置く。whisper.cpp は公式 XCFramework を `.binaryTarget` で取り込み、C API を `WhisperCore` プロトコルの裏に隠す（テストはフェイクの core で回す）。Apple の 2 エンジンは `SpeechAnalyzer` を包む 1 つの汎用 actor を共有し、モジュールの作り方だけを差し替える。音声の時刻は `TimelineMapper` で「エンジンが見た音声秒」から会議タイムラインに直し、ハードウェアや認識結果の中身に依存しない部分（時刻、区切り、切り詰め、結合、統合）をすべて純粋な型にして Swift Testing で固める。

**Tech Stack:** Swift 6.3 / Speech（`SpeechAnalyzer`、`DictationTranscriber`、`SpeechTranscriber`、`AssetInventory`）/ AVFoundation（`AVAudioFile`、`AVAudioConverter`）/ whisper.cpp XCFramework `b5454`（C API、`whisper_full_with_state`）/ CryptoKit（SHA-256）/ URLSession / Synchronization（`Mutex`）/ Swift Testing

**Spec:** `docs/superpowers/specs/2026-10-24-autonote-design.md`（中心は §3.2、§3.3、§6.1〜6.4、§7.1、§13、§17、§18）と `docs/superpowers/plans/2026-10-25-autonote-plans-overview.md`（共通契約）。根拠の実測は `docs/superpowers/research/2026-10-24-spike-results.md` の項目 1・2・7・8・12

ブランチ: `plan-04`（起点は overview §1 のとおり直前の計画のブランチ）。push はしない。

## Global Constraints

- 最低 OS: macOS 26.0。`Package.swift` の platforms は `.macOS("26.0")`、`swiftLanguageModes: [.v6]`
- Intel（x86_64）と Apple Silicon（arm64）の両方でビルド・動作すること。機種依存の分岐は実行時判定（`isAvailable` など）で行い、`#if arch` で機能を落とさない
- 署名: 自己署名証明書 `AutoNote Dev`、Bundle ID `com.yutaokoshi.autonote`。`scripts/build-app.sh` を使う。App Sandbox なし、Hardened Runtime なし
- 音声・文字起こし・議事録・個人の機材識別子（MAC アドレス）をリポジトリにコミットしない。テストのフィクスチャは架空の内容にする
- 音声はローカルから出ない。外部へ渡すのは `claude -p` への文字起こしテキストだけ（要件書 G9）
- 共有する型とプロトコルは本書 §3・§4 の名前と形を使う。変えるなら本書を先に直す
- 利用者の手が要る手順は「👤 利用者」と明記し、実装者はそこで止めて依頼する
- 各タスクは TDD（失敗するテスト → 実装 → 通過 → コミット）。ハードウェアが要る部分だけ手動確認手順を書く
- コミットメッセージは英語の Conventional Commits。タスクごとにコミット。push はしない
- 実装者はタスク完了前に `scripts/e2e-check.sh` を回し、結果を報告に含める

（上の「本書」は overview を指す。）

## 前提にする計画 01・02 の API

計画 01・02 の文書（2026-10-25 版）から写した。**各タスクに入る前に実装済みのコードと照合し、違えば実物に合わせて本計画の該当行を直してから進む**（overview §3・§4 の名前と形は変えない）。

| 出所 | 本計画が使う形 |
|---|---|
| 01 Model | overview §3 の型。`TimelineTime(seconds:)`、`Utterance(start:end:speaker:text:isFinal:)`、`Transcript(utterances:engine:language:)`、`TrackFile(track:relativePath:startOffset:durationSeconds:)`。JSON は `AutoNoteJSON.encoder()` / `.decoder()` |
| 01 Transcription | `protocol LiveTranscriber` / `BatchTranscriber`（`Transcription/Protocols.swift`）。本計画はこのファイルを変えない |
| 01 Dictionary | `DictionaryFile { terms; replacements: [Replacement]; fillers }`、`Replacer(_ rules: [Replacement]).apply(_ text: String)`、`HintBudget.fit(_ terms: [String], limit: Int = HintBudget.whisperLimit) -> (included: [String], dropped: [String])`（224 トークン） |
| 01 Transcript | `TrackTranscription(file: TrackFile, utterances: [Utterance])`（ファイル内相対時刻）、`TranscriptFinalizer(dictionary:fillerRemoval:).finalize(_ parts: [TrackTranscription], source: MeetingSource, engine: String, language: Language) -> (raw: Transcript, final: Transcript)`（startOffset の加算、話者付け、重複除去、置換、フィラー除去までを行う） |
| 01 Storage | `AppPaths(root:)`、`.root`、`.meetingDirectory(_:)`、`.transcriptFile(_: MeetingID, _: TranscriptKind) -> URL`（`.live` `.raw` `.final`） |
| 01 Settings | `defaultLanguage`、`liveEngine` / `liveModel`、`finalEngine` / `finalModel`（`String?`。nil は機種別の既定）、`fillerRemoval` |
| 01 TestSupport | `TemporaryDirectory.make()`、`u(_ seconds:_ speaker:_ text:end:)`（`isFinal: true`）、`FakeLiveTranscriber(script: [Utterance])`（`start` で台本を流す、`fedChunks`、`startedWith`）、`FakeBatchTranscriber(results: [String: [Utterance]], failure: FakeError?)`（キーはファイル名、`calls`） |
| 01 CLI | `enum DevCommands { static func run(_ args: [String]) async -> Int32 }`（`Sources/autonote/DevCommands.swift`）と E2E の `autonote_bin()` |
| 02 Audio | `AudioChunk(track:samples:start:hostTime:)`（16 kHz mono Int16、`start` は会議タイムライン）、`WAVFile.header(sampleRate:channels:bitsPerSample:dataBytes:)`・`.info(_:)`・`.readSamples(_:)`、`SegmentMerger.merge(_ manifest: Manifest, track: Track, meetingDirectory: URL) throws -> [TrackFile]`（連続する分割を `merged/<track>-<n>.wav` につなぎ、一時停止で分ける） |
| 03 CLI | `autonote dev devices`（Task 13 で機材の見え方を見るのに使う） |

## Review Focus

1. 一時停止やシステム音のコールバック途絶で `AudioChunk.start` が飛ぶ入力 → リアルタイムの時刻が会議タイムラインに合ったままであること（Task 2 `mapperJumpsOverPause`、Task 6 `timelineGapAfterPause`）
2. 無音や小さな雑音だけの区間 → whisper が「ご視聴ありがとうございました」のような定型句や同じ文の繰り返しを出さないこと（Task 5 の `RepetitionFilter` 4 件、Task 6 `silenceOnlyNeverDecodes`）
3. 確定版の途中で録音が始まって一時停止し、終わって再開する → 発話が重複も欠落もしないこと（Task 5 `pauseAbortsAndResumesFromLastSegmentEnd`）
4. モデルのダウンロードが途中で切れる、中身が違う、手で置いたファイルの大きさが違う → 壊れたファイルが「取得済み」に見えないこと（Task 3 の 3 件）
5. 片方のトラックが空（システム音が一度も鳴らない会議）や片方の認識開始の失敗 → 残りのトラックで完走すること（Task 10 `oneTrackFailingKeepsOther`、Task 11 `emptyTrackStillCompletes`）

---

## ファイル構成

すべて `Sources/AutoNoteCore/Transcription/` の下に `Shared/`（Task 2）、`Models/`（Task 3）、`Engines/`（Task 4・8）、`Whisper/`（Task 1・5・6）、`Apple/`（Task 7・9）、`Live/`（Task 10）、`Batch/`（Task 11）で置く。フェイクは `Sources/AutoNoteTestSupport/`、開発用コマンドは `Sources/autonote/Dev/`、テストは `Tests/AutoNoteCoreTests/Transcription/`。各タスクの Files 欄が正。

---

### Task 1: whisper.cpp XCFramework の取り込みと機種判定

**Files:**
- Modify: `Package.swift`
- Modify: `scripts/build-app.sh`
- Create: `Sources/AutoNoteCore/Transcription/MachineKind.swift`
- Create: `Sources/AutoNoteCore/Transcription/Whisper/WhisperRuntime.swift`
- Test: `Tests/AutoNoteCoreTests/Transcription/WhisperLinkTests.swift`

**Interfaces:**
- Consumes: なし
- Produces: `public enum MachineKind: String, Codable, Sendable { case intel, appleSilicon; static func current() -> MachineKind; static func from(arm64Flag: Int32?) -> MachineKind }`（`sysctlbyname("hw.optional.arm64")` が 1 なら appleSilicon）。`enum WhisperRuntime { static func systemInfo() -> String; static func languageID(_ code: String) -> Int32 }`。`import whisper` は `AutoNoteCore` の中だけで行う

- [ ] **Step 1: 版を決める**
Run: `curl -s 'https://api.github.com/repos/ggml-org/whisper.cpp/releases?per_page=15' | jq -r '.[] | select(any(.assets[]?; .name | test("xcframework"))) | .tag_name' | head -3`
Expected: `b5454` が含まれる。新しい `bNNNN` があっても **b5454 を使う**（結果表項目 8。`v1.9.5` と同じコミット `d1be6fd` で、項目 1 のベンチと同じ版にそろえる）
- [ ] **Step 2: zip を取得して checksum を求める**
Run: `mkdir -p tools/xcframework-b5454 && curl -sSLf -o tools/xcframework-b5454/whisper-b5454-xcframework.zip https://github.com/ggml-org/whisper.cpp/releases/download/b5454/whisper-b5454-xcframework.zip && swift package compute-checksum tools/xcframework-b5454/whisper-b5454-xcframework.zip`
Expected: `e57f8c48933000acabc13bb913fbe82805d483a2deff692cc6738836bd92393b`（項目 8 の SHA-256 と同じ。SwiftPM の checksum は zip の SHA-256）。違えば止めて報告する
- [ ] **Step 3: 失敗するテストを書く**

```swift
@Test func whisperIsLinked() {
    #expect(!WhisperRuntime.systemInfo().isEmpty)
    #expect(WhisperRuntime.languageID("ja") >= 0)
    #expect(WhisperRuntime.languageID("en") >= 0)
}
@Test func machineKindFromSysctl() {
    #expect(MachineKind.from(arm64Flag: 1) == .appleSilicon)
    #expect(MachineKind.from(arm64Flag: 0) == .intel)
    #expect(MachineKind.from(arm64Flag: nil) == .intel)   // Intel では sysctl 自体が失敗する
}
```

- [ ] **Step 4: 失敗を確認** — Run: `swift test --filter WhisperLinkTests` → Expected: FAIL（`WhisperRuntime` が無い）
- [ ] **Step 5: `Package.swift` に binaryTarget を足す**

```swift
.binaryTarget(
    name: "whisper",
    url: "https://github.com/ggml-org/whisper.cpp/releases/download/b5454/whisper-b5454-xcframework.zip",
    checksum: "e57f8c48933000acabc13bb913fbe82805d483a2deff692cc6738836bd92393b"),
.target(name: "AutoNoteCore", dependencies: ["whisper"]),
```

モジュール名は `find .build/artifacts -path '*macos-arm64_x86_64*' -name module.modulemap -exec cat {} \;` の `framework module <名前>` に合わせる（`whisper` のはず）。
- [ ] **Step 6: `MachineKind` と `WhisperRuntime` を実装**
`systemInfo()` は `whisper_print_system_info()`、`languageID` は `whisper_lang_id`。
- [ ] **Step 7: 通過を確認** — Run: `swift test --filter WhisperLinkTests` → Expected: PASS
- [ ] **Step 8: `.app` にフレームワークを入れる**
`scripts/build-app.sh` の署名の前に、`ditto "${BIN_DIR}/whisper.framework" "${APP}/Contents/Frameworks/whisper.framework"`、2 つの実行ファイルに `install_name_tool -add_rpath @executable_path/../Frameworks`（既にあれば無視）、`codesign --force --sign "${CERT_NAME}" --timestamp=none "${APP}/Contents/Frameworks/whisper.framework"` を CLI と本体より先に足す。`--deep` は使わない。

Run: `scripts/build-app.sh && otool -L build/AutoNote.app/Contents/MacOS/autonote | grep whisper && lipo -info build/AutoNote.app/Contents/Frameworks/whisper.framework/whisper && build/AutoNote.app/Contents/MacOS/autonote --version && codesign -d -r- build/AutoNote.app`
Expected: `@rpath/whisper.framework/…`、`x86_64 arm64`、`0.1.0`。designated requirement は計画 00 と同じ（識別子と証明書のハッシュだけ。TCC の許可が保たれる条件）
- [ ] **Step 9: E2E** — Run: `scripts/e2e-check.sh` → Expected: 項目 1〜5 を含め FAIL 0
- [ ] **Step 10: コミット**

```bash
git add Package.swift scripts/build-app.sh Sources/AutoNoteCore/Transcription Tests/AutoNoteCoreTests/Transcription
git commit -m "build: add whisper.cpp b5454 xcframework and machine detection"
```

---

### Task 2: 音声の受け渡し部品（PCM、チャンク、タイムライン写像、無音判定）

**Files:**
- Create: `Sources/AutoNoteCore/Transcription/Shared/{TranscriptionError,PCMAudio,TimelineMapper,SilenceDetector}.swift`
- Test: `Tests/AutoNoteCoreTests/Transcription/{PCMAudioTests,TimelineMapperTests,SilenceDetectorTests}.swift`
- Create: `Tests/AutoNoteCoreTests/Transcription/TestAudio.swift`（テスト用の補助: `tone(_:)` / `silence(_:)` / `chunk(_:at:track:)` / `partial(_:_:)`（`isFinal: false`・`.unknown` の発話）/ `wavFile(seconds:)` / `ProgressBox` / `collect(_:)` / `waitUntil(_:)`。一時フォルダは計画 01 の `TemporaryDirectory.make()`、確定の発話は計画 01 の `u(_:_:_:)`。Task 3 以降のテストも使う）

**Interfaces:**
- Consumes: `AudioChunk`・`WAVFile`（計画 02）、`TimelineTime`（計画 01）
- Produces:
  - `enum TranscriptionError: Error, Equatable, Sendable { case modelMissing(String), engineUnavailable(String), localeUnsupported(Language), invalidAudio(String), whisperFailed(Int32), noTracks, trackFailed(Track, String) }`
  - `enum PCMAudio { static let sampleRate = 16_000.0; static func readMono16k(_ url: URL) throws -> [Int16]; static func writeWAV(_ samples: [Int16], to url: URL) throws /* ヘッダは WAVFile.header */; static func floats(_ s: [Int16]) -> [Float]; static func chunks(_ s: [Int16], track: Track, chunkSeconds: Double, start: TimelineTime) -> [AudioChunk] }`。読み込みはどの形式（say の AIFF、m4a など）でも `AVAudioFile` ＋ `AVAudioConverter` で 16 kHz mono Int16 に直す（計画 02 の `WAVFile.readSamples` は 16 kHz の WAV 専用なので、開発用コマンドの任意ファイル入力のためにこちらを置く）
  - `struct TimelineMapper: Sendable { init(); mutating func append(_ chunk: AudioChunk); func timeline(atAudioSeconds: Double) -> TimelineTime; var audioSeconds: Double { get } }`。チャンクの `start` が直前の終わりより **0.05 秒以上**先なら、そこから新しい区間を始める（一時停止・コールバック途絶）。それ未満の差は連続とみなす
  - `struct SilenceDetector: Sendable { init(threshold: Double = 0.01, minSilence: Double = 0.8, minSpeech: Double = 0.3); mutating func process(_ samples: [Int16]) -> [Double] }`。20 ms フレームの RMS（Int16 を ±1 に正規化）が threshold 未満を無音とし、0.3 秒以上の発話のあとに 0.8 秒の無音が続いたら「発話の終わり」（無音の始まりの音声秒）を 1 回返す［私の判断: −40 dBFS、0.8 秒］

- [ ] **Step 1: 失敗するテストを書く**

```swift
func tone(_ sec: Double) -> [Int16] { (0..<Int(sec * 16_000)).map { Int16(8000 * sin(Double($0) * 0.1)) } }
func silence(_ sec: Double) -> [Int16] { Array(repeating: 0, count: Int(sec * 16_000)) }
func chunk(_ s: [Int16], at t: Double, track: Track = .mic) -> AudioChunk { AudioChunk(track: track, samples: s, start: TimelineTime(seconds: t), hostTime: 0) }

@Test func mapperJumpsOverPause() {
    var m = TimelineMapper()
    m.append(chunk(silence(1), at: 0))
    m.append(chunk(silence(1), at: 10))          // 9 秒の一時停止
    #expect(m.timeline(atAudioSeconds: 0.5).seconds == 0.5)
    #expect(m.timeline(atAudioSeconds: 1.5).seconds == 10.5)
    #expect(m.audioSeconds == 2.0)
}
@Test func mapperIgnoresTinyJitter() {
    var m = TimelineMapper()
    m.append(chunk(silence(1), at: 0)); m.append(chunk(silence(1), at: 1.01))
    #expect(m.timeline(atAudioSeconds: 1.5).seconds == 1.5)
}
@Test func chunksSplitAndKeepTimes() {
    let c = PCMAudio.chunks(Array(repeating: 1, count: 32_800), track: .system, chunkSeconds: 0.1, start: TimelineTime(seconds: 5))
    #expect(c.count == 21); #expect(abs(c[1].start.seconds - 5.1) < 1e-9); #expect(c.last!.samples.count == 800); #expect(c.allSatisfy { $0.track == .system })
}
@Test func wavRoundTripAndResample() throws   // writeWAV → readMono16k で同じ配列。44.1 kHz ステレオ Float の AVAudioFile を読むと 1 秒あたり 16,000±160 サンプル
@Test func silenceDetectorFindsBoundary() {
    var d = SilenceDetector()
    let b = d.process(tone(1) + silence(1) + tone(1))
    #expect(b.count == 1); #expect(abs(b[0] - 1.0) < 0.021)
}
@Test func silenceOnlyHasNoBoundary() { var d = SilenceDetector(); #expect(d.process(silence(5)).isEmpty) }
@Test func boundaryAcrossCalls() // tone(1) と silence(1) を 0.1 秒ずつ渡しても境界は 1 回
```

- [ ] **Step 2: 失敗を確認** — Run: `swift test --filter 'PCMAudioTests|TimelineMapperTests|SilenceDetectorTests'` → Expected: FAIL（型が無い）
- [ ] **Step 3: 4 ファイルを実装**
`TimelineMapper` は `(audioStart, timelineStart)` の区間の配列を持ち、二分探索で引く。
- [ ] **Step 4: 通過を確認** — 同じコマンドで PASS
- [ ] **Step 5: コミット**

```bash
git add Sources/AutoNoteCore/Transcription/Shared Tests/AutoNoteCoreTests/Transcription
git commit -m "feat(transcription): add PCM helpers, timeline mapper and silence detector"
```

---

### Task 3: ModelManager（ggml モデルの取得・検証・削除）

**Files:**
- Create: `Sources/AutoNoteCore/Transcription/Models/{WhisperModel,ModelManager,URLSessionModelDownloader}.swift`
- Create: `Sources/AutoNoteTestSupport/FakeModelDownloader.swift`
- Test: `Tests/AutoNoteCoreTests/Transcription/ModelManagerTests.swift`

**Interfaces:**
- Consumes: `AppPaths`（計画 01）
- Produces:
  - `struct WhisperModel: Codable, Equatable, Sendable { var name: String; var url: URL; var sizeBytes: Int64; var sha256: String; var fileName: String { "ggml-\(name).bin" } }`、`enum WhisperModelCatalog { static let all: [WhisperModel] }`（base、small、large-v3-turbo、large-v3-turbo-q5_0）
  - `protocol ModelDownloading: Sendable { func download(_ url: URL, to destination: URL, progress: @Sendable @escaping (Int64, Int64) -> Void) async throws }`、実装 `struct URLSessionModelDownloader: ModelDownloading`（`URLSession.download(from:delegate:)`、`didWriteData` で進捗）
  - `enum ModelError: Error, Equatable { case unknownModel(String), sizeMismatch(expected: Int64, actual: Int64), checksumMismatch }`
  - `actor ModelManager { init(directory: URL, catalog: [WhisperModel] = WhisperModelCatalog.all, downloader: any ModelDownloading = URLSessionModelDownloader()); static func defaultDirectory(_ paths: AppPaths) -> URL /* <root>/models */; func installed() -> [WhisperModel]; func fileURL(for name: String) -> URL?; func download(_ name: String, progress: @Sendable @escaping (Double) -> Void) async throws -> URL; func delete(_ name: String) throws; func verify(_ name: String) async throws -> Bool }`
  - 規律: 取得は `<fileName>.partial` に書き、サイズと SHA-256 が一致したら原子的に改名。失敗・不一致・キャンセルでは `.partial` を消す。`installed()` はサイズ一致だけで判定する（1.6 GB の SHA を起動のたびに計算しない［私の判断］）。同じモデルの同時取得は 1 本にまとめる

- [ ] **Step 1: カタログの値を集める**
Run: `grep -n 'huggingface' tools/whisper.cpp/models/download-ggml-model.sh` → 取得元の URL 形（`https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-<名前>.bin` のはず）を確かめる。
Run: `curl -s https://huggingface.co/api/models/ggerganov/whisper.cpp/tree/main | jq -r '.[] | select(.path | test("^ggml-(base|small|large-v3-turbo|large-v3-turbo-q5_0)\\.bin$")) | [.path, .lfs.size, .lfs.oid] | @tsv'` と `shasum -a 256 tools/whisper.cpp/models/ggml-{base,small,large-v3-turbo,large-v3-turbo-q5_0}.bin`
Expected: 手元にある分は SHA-256 が一致する。4 件の size と oid を `WhisperModelCatalog.all` に書く
- [ ] **Step 2: 失敗するテストを書く**

```swift
@Test func downloadVerifiesAndInstalls() async throws {
    let blob = Data("fake-model".utf8)
    let m = WhisperModel(name: "fake", url: URL(string: "https://example.invalid/ggml-fake.bin")!,
                         sizeBytes: Int64(blob.count), sha256: SHA256.hash(data: blob).map { String(format: "%02x", $0) }.joined())
    let mm = ModelManager(directory: try TemporaryDirectory.make(), catalog: [m], downloader: FakeModelDownloader(payload: blob))
    let p = ProgressBox()
    let url = try await mm.download("fake") { p.append($0) }
    #expect(url.lastPathComponent == "ggml-fake.bin")
    #expect(await mm.installed().map(\.name) == ["fake"])
    #expect(p.values.last == 1.0)
}
@Test func corruptDownloadIsRejectedAndLeavesNothing()   // payload を 1 バイト変える → throws ModelError.checksumMismatch、ディレクトリに ggml-*.bin も *.partial も無い
@Test func interruptedDownloadLeavesNothing()           // FakeModelDownloader(failAfterBytes: 3) → throws、ファイルなし、installed() は空
@Test func wrongSizeFileIsNotInstalled()                // ggml-fake.bin を違うサイズで直接置く → installed() は空、fileURL(for:) は nil
@Test func deleteRemovesFile()
@Test func concurrentDownloadsShareOne() async throws    // download を 2 本同時 → downloader.callCount == 1、両方同じ URL
@Test func catalogHasDefaults() {
    #expect(Set(WhisperModelCatalog.all.map(\.name)) == ["base", "small", "large-v3-turbo", "large-v3-turbo-q5_0"])
    #expect(WhisperModelCatalog.all.allSatisfy { $0.url.host() == "huggingface.co" && $0.sha256.count == 64 })
}
```

- [ ] **Step 3: 失敗を確認** — Run: `swift test --filter ModelManagerTests` → Expected: FAIL
- [ ] **Step 4: 実装**（SHA-256 は CryptoKit の `SHA256` に 1 MB ずつ流す）
- [ ] **Step 5: 通過を確認** — 同じコマンドで PASS
- [ ] **Step 6: コミット**

```bash
git add Sources/AutoNoteCore/Transcription/Models Sources/AutoNoteTestSupport/FakeModelDownloader.swift Tests/AutoNoteCoreTests/Transcription/ModelManagerTests.swift
git commit -m "feat(transcription): add whisper model manager with checksum verification"
```

---

### Task 4: EngineCatalog（実行時判定と機種別の既定）

**Files:**
- Create: `Sources/AutoNoteCore/Transcription/Engines/{EngineChoice,LocaleMapping,AppleSpeechCapabilities,EngineCatalog}.swift`
- Create: `Sources/AutoNoteTestSupport/FakeSpeechCapabilities.swift`（`init(speechAvailable: Bool, speechLocales: [String], dictationLocales: [String])`。BCP 47 の文字列で受ける）
- Test: `Tests/AutoNoteCoreTests/Transcription/EngineCatalogTests.swift`

**Interfaces:**
- Consumes: `MachineKind`（Task 1）、`ModelManager.installed()`（Task 3）、`Settings`、`Language`
- Produces:
  - `enum EngineKind: String, Codable, Sendable, CaseIterable { case dictation, speech, whisper }`、`enum EngineRole: String, Codable, Sendable { case live, batch }`
  - `struct EngineChoice: Codable, Hashable, Sendable { var kind: EngineKind; var model: String?; static func whisper(_ m: String) -> EngineChoice; static let dictation, speech: EngineChoice; var displayName: String; static func fromSettings(kind: String?, model: String?, role: EngineRole, machine: MachineKind) -> EngineChoice? }`。`displayName` は `"Apple DictationTranscriber"` / `"Apple SpeechTranscriber"` / `"whisper.cpp <model>"`（frontmatter `transcript_engine` の値。要件書 §9.2 の例と同じ形）
  - `struct EngineEntry: Codable, Equatable, Sendable { var choice: EngineChoice; var available: Bool; var reason: String? }`
  - `protocol SpeechCapabilityProbing: Sendable { func dictationLocales() async -> [Locale]; func speechTranscriberIsAvailable() async -> Bool; func speechTranscriberLocales() async -> [Locale] }`、実装 `struct AppleSpeechCapabilities`（`DictationTranscriber.supportedLocales`、`SpeechTranscriber.isAvailable`、`SpeechTranscriber.supportedLocales`。`supportedLocale(equivalentTo:)` は使わない。要件書 §6.2）
  - `enum LocaleMapping { static func locale(for: Language) -> Locale /* ja→ja-JP, en→en-US, auto→ja-JP */; static func contains(_ list: [Locale], _ target: Locale) -> Bool /* 言語コードと地域で比較 */ }`。Apple のエンジンは言語固定なので `auto` は日本語にする［私の判断。要件書 §3.1 の日本語メイン］
  - `struct EngineCatalog: Sendable { init(machine: MachineKind, speech: any SpeechCapabilityProbing, installedModels: @Sendable @escaping () async -> [String]); static func defaults(for: MachineKind) -> (live: EngineChoice, batch: EngineChoice, whisperLiveModel: String); func entries(role: EngineRole, language: Language) async -> [EngineEntry]; func resolve(role: EngineRole, language: Language, override: EngineChoice?) async -> EngineChoice? }`

既定（要件書 §6.2）: Intel はリアルタイム `dictation`、確定版 `whisper("large-v3-turbo")`、whisper をリアルタイムに選んだときのモデル `small`。Apple Silicon は**仮**でリアルタイム `speech`、確定版 `whisper("large-v3-turbo")`、whisper リアルタイム `small`（Task 13 で見直す）。

判定: dictation は `dictationLocales` に言語の Locale がある。speech は `isAvailable && !locales.isEmpty` かつ Locale がある。whisper は `installedModels()` にモデル名がある。entries の live は dictation、speech、カタログの各モデルの whisper。batch は whisper だけ（Apple の確定版は持たない。確定版失敗時のリアルタイム版での代替は計画 05）。
`resolve` の順: 使える override → 使える既定 → live なら dictation、speech、whisper(既定の whisperLiveModel)、取得済み whisper の順 / batch なら取得済みの large-v3-turbo、large-v3-turbo-q5_0、small、base の順 → どれも無ければ nil。

- [ ] **Step 1: 失敗するテストを書く**

```swift
@Test func intelDefaults() {
    let d = EngineCatalog.defaults(for: .intel)
    #expect(d.live == .dictation); #expect(d.batch == .whisper("large-v3-turbo")); #expect(d.whisperLiveModel == "small")
}
@Test func appleSiliconProvisionalDefaults() { #expect(EngineCatalog.defaults(for: .appleSilicon).live == .speech) }
@Test(arguments: [(true, [String]()), (false, ["ja-JP"])])
func speechTranscriberNeedsBothFlags(isAvailable: Bool, locales: [String]) async {
    let c = EngineCatalog(machine: .appleSilicon, speech: FakeSpeechCapabilities(speechAvailable: isAvailable, speechLocales: locales, dictationLocales: ["ja-JP"]), installedModels: { [] })
    #expect(await c.entries(role: .live, language: .ja).first { $0.choice == .speech }?.available == false)
    #expect(await c.resolve(role: .live, language: .ja, override: nil) == .dictation)
}
@Test func dictationJudgedByLocales() async       // dictationLocales ["en-US"]、language .ja → dictation は available false、reason に "ja-JP"
@Test func autoLanguageUsesJapaneseLocale()       // LocaleMapping.locale(for: .auto).identifier(.bcp47) == "ja-JP"
@Test func whisperNeedsModel() async              // installed [] → resolve(.batch) == nil。["small"] → .whisper("small")
@Test func overrideWinsWhenAvailable() async      // Intel、override .whisper("small")、installed ["small"] → .whisper("small")
@Test func overrideFallsBackWhenUnavailable() async // Intel（speech 不可）、override .speech → .dictation
@Test func settingsParsing() {
    #expect(EngineChoice.fromSettings(kind: "whisper", model: nil, role: .batch, machine: .intel) == .whisper("large-v3-turbo"))
    #expect(EngineChoice.fromSettings(kind: "whisper", model: nil, role: .live, machine: .intel) == .whisper("small"))
    #expect(EngineChoice.fromSettings(kind: "sf", model: nil, role: .live, machine: .intel) == nil)
    #expect(EngineChoice.fromSettings(kind: nil, model: nil, role: .live, machine: .intel) == nil)
}
@Test func displayNames() { #expect(EngineChoice.whisper("large-v3-turbo").displayName == "whisper.cpp large-v3-turbo") }
```

- [ ] **Step 2: 失敗を確認** — Run: `swift test --filter EngineCatalogTests` → Expected: FAIL
- [ ] **Step 3: 実装**（`Settings.liveEngine` / `liveModel` は live、`finalEngine` / `finalModel` は batch の上書きとして `fromSettings` に渡す）
- [ ] **Step 4: 通過を確認** — `swift test --filter EngineCatalogTests` で PASS
- [ ] **Step 5: コミット**

```bash
git add Sources/AutoNoteCore/Transcription/Engines Sources/AutoNoteTestSupport/FakeSpeechCapabilities.swift Tests/AutoNoteCoreTests/Transcription
git commit -m "feat(transcription): add engine catalog with runtime availability and machine defaults"
```

---

### Task 5: WhisperBatchTranscriber（確定版。キャンセルと一時停止）

**Files:**
- Create: `Sources/AutoNoteCore/Transcription/Whisper/{WhisperCore,WhisperContext,WhisperPrompt,RepetitionFilter,BatchGate,WhisperBatchTranscriber}.swift`
- Create: `Sources/AutoNoteTestSupport/FakeWhisperCore.swift`
- Test: `Tests/AutoNoteCoreTests/Transcription/{WhisperBatchTranscriberTests,RepetitionFilterTests,WhisperPromptTests,WhisperContextTests}.swift`

**Interfaces:**
- Consumes: `BatchTranscriber`（計画 01）、`HintBudget.fit`（計画 01）、`PCMAudio`（Task 2）、`MachineKind`（Task 1）
- Produces:
  - `struct WhisperSegment: Equatable, Sendable { var start: Double; var end: Double; var text: String }`（ファイル先頭からの秒）、`struct TimedToken: Equatable, Sendable { var start: Double; var end: Double; var text: String }`
  - `enum WhisperDecodeMode: Sendable { case batch /* beam 5, best_of 5 */; case live /* greedy, best_of 1, token timestamps */ }`
  - `struct WhisperRunRequest: Sendable { var samples: [Float]; var offsetSeconds: Double; var language: Language; var prompt: String?; var mode: WhisperDecodeMode }`、`enum WhisperRunOutcome: Equatable, Sendable { case completed, aborted }`
  - `protocol WhisperCore: Sendable { func run(_ r: WhisperRunRequest, onSegment: @Sendable @escaping (WhisperSegment, [TimedToken]) -> Void, onProgress: @Sendable @escaping (Double) -> Void, shouldAbort: @Sendable @escaping () -> Bool) async throws -> WhisperRunOutcome }`
  - `final class WhisperContext: WhisperCore, @unchecked Sendable { init(modelURL: URL, machine: MachineKind, threads: Int) throws }`。モデル（`whisper_context`）は URL ごとに 1 つを共有し、インスタンスごとに `whisper_init_state` で state を持って `whisper_full_with_state` を呼ぶ（2 トラックで同じモデルを 2 回読まない）。`whisper_full` は専用の `DispatchQueue`（qos `.utility`）で回し、協調スレッドを塞がない。`use_gpu` は `machine == .appleSilicon` のときだけ true（Intel の Metal は出力が壊れる。要件書 §3.3）
  - `final class BatchGate: Sendable { init(); func pause(); func resume(); var isPaused: Bool { get }; func waitWhilePaused() async }`（`Mutex` で状態と待ち手を持つ）。計画 05 の待ち行列が録音開始で `pause()`、終了で `resume()` を呼ぶ（要件書 §13）
  - `enum RepetitionFilter { static let hallucinations: [String]; static func clean(_ s: [WhisperSegment]) -> [WhisperSegment] }`
  - `enum WhisperPrompt { static func make(hints: [String]) -> String? }`（`HintBudget.fit(hints).included.joined(separator: "、")`、空なら nil）
  - `actor WhisperBatchTranscriber: BatchTranscriber { init(core: any WhisperCore, gate: BatchGate? = nil) }`
  - `final class FakeWhisperCore: WhisperCore`（TestSupport）: `init(segments: [WhisperSegment], afterFirstSegment: (@Sendable () -> Void)? = nil, delay: Duration = .zero)` と `init(fixedText: String)`（live 用。どの窓にも本文 1 つと窓の先頭からのトークン 1 つを返す）。各 run で `offsetSeconds` 以降に始まるセグメントを順に出し、1 つ出すごとに `shouldAbort` を見て true なら `.aborted` を返す。`requests: [WhisperRunRequest]`、`runCount: Int` を記録する。返す `Utterance` は `speaker: .unknown`、`isFinal: true`、ファイル内相対時刻（話者と startOffset は Task 11 が付ける）

パラメータ（`WhisperContext` が `WhisperRunRequest` から組む）: batch は `WHISPER_SAMPLING_BEAM_SEARCH`・beam 5・best_of 5（項目 1 のベンチと同じ）、スレッド `min(4, max(1, activeProcessorCount / 2))`、`language` は `"ja"` / `"en"` / `"auto"`、`no_context = true`、`suppress_blank`・`suppress_nst = true`、`print_*` はすべて false、`offset_ms` は `offsetSeconds`、`abort_callback`・`progress_callback`・`new_segment_callback` を結ぶ。

`max-context 0` とヒントの両立（Step 1 で確かめて決める）: whisper.cpp は `n_max_text_ctx = 0`（CLI の `--max-context 0`）にすると initial prompt も使わなくなる作りの可能性がある。

一時停止と再開の手順（テストでは決まりきらないので書く）:

```
offset = 0; kept = []
loop {
  try Task.checkCancellation(); await gate?.waitWhilePaused()
  outcome = core.run(request(offset), onSegment: kept に追加,
                     onProgress: p → progress((offset + p * (total - offset)) / total),
                     shouldAbort: Task.isCancelled || gate?.isPaused == true)
  if outcome == .completed { break }
  if Task.isCancelled { throw CancellationError() }
  offset = kept.last?.end ?? offset        // 一時停止: 最後に完了したセグメントの終わりから再開
}
progress(1.0); return RepetitionFilter.clean(kept) → Utterance
```

`RepetitionFilter.clean` の規則［私の判断。要件書 §6.4 の繰り返し除去］: (1) 空白・句読点を除くと空のセグメントを捨てる (2) 本文全体が `hallucinations`（`ご視聴ありがとうございました`、`ご清聴ありがとうございました`、`チャンネル登録よろしくお願いします`、`Thank you for watching.`）と一致するセグメントを捨てる (3) 直前に残したセグメントと正規化後の本文が同じなら捨てる (4) セグメント内で 1〜15 文字の同じ並びが 4 回以上続いたら 1 回に縮める。

- [ ] **Step 1: ヒントの渡し方を決める**
Run: `grep -n 'carry_initial_prompt\|n_max_text_ctx\|no_context' tools/whisper.cpp/include/whisper.h && grep -n 'n_max_text_ctx' tools/whisper.cpp/src/whisper.cpp`
決め方: (a) `carry_initial_prompt` があれば `no_context = true`・`carry_initial_prompt = true`・`n_max_text_ctx` は既定（過去の文字起こしは渡さず、ヒントだけ毎回の窓に渡す） (b) 無く、`n_max_text_ctx = 0` で initial prompt も消える作りなら `n_max_text_ctx = 0` を優先してヒントは渡さない（造語の表記は置換ルールと議事録生成の用語指定で直す。要件書 §7.1 と同じ逃げ方）。決めた内容を `WhisperContext.swift` の冒頭コメントと結果表の項目 1 の末尾に 1 行で残す
- [ ] **Step 2: 失敗するテストを書く**

```swift
@Test func segmentsBecomeFinalUtterances() async throws {
    let core = FakeWhisperCore(segments: [.init(start: 0, end: 2, text: "こんにちは"), .init(start: 2, end: 4, text: "よろしく")])
    let u = try await WhisperBatchTranscriber(core: core).transcribe(file: try wavFile(seconds: 4), language: .ja, hints: [], progress: { _ in })
    #expect(u.map(\.start.seconds) == [0, 2]); #expect(u.allSatisfy { $0.isFinal && $0.speaker == .unknown })
}
@Test func progressIsMonotonicAndEndsAtOne() async throws
@Test func cancellationStopsAndThrows() async throws       // 遅い fake を Task で走らせ cancel → CancellationError、core.runCount == 1
@Test func pauseAbortsAndResumesFromLastSegmentEnd() async throws {
    // 1 本目は seg(0–3) を出した直後に一時停止され .aborted。再開後の 2 本目は offset 3 から seg(3–6) だけを出す
    let gate = BatchGate()
    let core = FakeWhisperCore(segments: [.init(start: 0, end: 3, text: "前半"), .init(start: 3, end: 6, text: "後半")], afterFirstSegment: { gate.pause() })
    let t = Task { try await WhisperBatchTranscriber(core: core, gate: gate).transcribe(file: try wavFile(seconds: 6), language: .ja, hints: [], progress: { _ in }) }
    try await waitUntil { gate.isPaused }; try await Task.sleep(for: .milliseconds(50)); gate.resume()
    let u = try await t.value
    #expect(core.requests.map(\.offsetSeconds) == [0, 3]); #expect(u.map(\.text) == ["前半", "後半"])
}
@Test func hintsBecomePrompt() async throws        // hints ["所沢", "Kubernetes"] → core.requests[0].prompt == "所沢、Kubernetes"
@Test func noHintsNoPrompt() async throws          // prompt == nil
@Test func languageIsForwarded() async throws      // .en → requests[0].language == .en、mode == .batch
// RepetitionFilterTests
@Test func dropsHallucinationPhrase()   // [seg("ご視聴ありがとうございました")] → []
@Test func dropsConsecutiveDuplicate()  // ["了解です", "了解です。", "次へ"] → ["了解です", "次へ"]
@Test func collapsesInnerRepetition()   // "そうですねそうですねそうですねそうですね" → "そうですね"
@Test func keepsShortRepeats()          // "はいはい" はそのまま（4 回未満）
// WhisperPromptTests
@Test func longDictionaryIsTrimmed() {   // 500 語 → make(hints:) == HintBudget.fit(terms).included.joined(separator: "、") で、500 語全部は含まない
}
// WhisperContextTests（実モデル。環境変数 AUTONOTE_TEST_WHISPER_MODEL が ggml の実在パスのときだけ）
@Test(.enabled(if: ProcessInfo.processInfo.environment["AUTONOTE_TEST_WHISPER_MODEL"] != nil))
func realCoreHandlesSilence() async throws      // 3 秒の無音で例外なく .completed
```

- [ ] **Step 3: 失敗を確認** — Run: `swift test --filter 'WhisperBatchTranscriberTests|RepetitionFilterTests|WhisperPromptTests'` → Expected: FAIL
- [ ] **Step 4: 6 ファイルと `FakeWhisperCore` を実装**
- [ ] **Step 5: 通過を確認** — 同じコマンドで PASS。続けて `AUTONOTE_TEST_WHISPER_MODEL=$PWD/tools/whisper.cpp/models/ggml-base.bin swift test --filter WhisperContextTests` も PASS
- [ ] **Step 6: コミット**

```bash
git add Sources/AutoNoteCore/Transcription/Whisper Sources/AutoNoteTestSupport/FakeWhisperCore.swift Tests/AutoNoteCoreTests/Transcription docs/superpowers/research/2026-10-24-spike-results.md
git commit -m "feat(transcription): add whisper batch transcriber with pause, cancel and repetition filter"
```

---

### Task 6: WhisperLiveTranscriber（チャンク方式）

**Files:**
- Create: `Sources/AutoNoteCore/Transcription/Whisper/{ChunkPlanner,OverlapTrimmer,WhisperLiveTranscriber}.swift`
- Test: `Tests/AutoNoteCoreTests/Transcription/{ChunkPlannerTests,WhisperLiveTranscriberTests}.swift`

**Interfaces:**
- Consumes: `LiveTranscriber`（計画 01）、`WhisperCore`・`WhisperPrompt`（Task 5）、`TimelineMapper`・`SilenceDetector`（Task 2）
- Produces:
  - `struct ChunkPlanner: Sendable { struct Config: Sendable { var windowMax = 8.0; var overlap = 1.0; var partialEvery = 2.0; var minSpeech = 0.3 }; enum Action: Equatable, Sendable { case partial(from: Double, to: Double), commit(from: Double, to: Double, nextFrom: Double), skip(from: Double, to: Double) }; init(config: Config = .init()); mutating func ingest(_ samples: [Int16]) -> [Action]; mutating func flush() -> [Action] }`（値は音声秒）
  - `enum OverlapTrimmer { static func text(_ tokens: [TimedToken], droppingBefore: Double) -> String }`（窓先頭からの秒が `droppingBefore` 未満のトークンを落として連結）
  - `actor WhisperLiveTranscriber: LiveTranscriber { init(core: any WhisperCore, config: ChunkPlanner.Config = .init()) }`。core は `mode: .live`（greedy・best_of 1・token timestamps・スレッド 2［私の判断］）

チャンクの数値［私の判断。要件書 §17 の体感 5 秒以内］: 窓の最大 **8.0 秒**、強制で切るときの重なり **1.0 秒**、部分結果の更新 **2.0 秒**ごと、発話の終わりは `SilenceDetector`（0.8 秒）。規則:
1. 窓 = `[windowStart, 今]`。窓の中で発話の終わり b が出て `b − windowStart ≥ 1.0` → `commit(from: windowStart, to: b, nextFrom: b)`（無音で切るので重ねない）
2. `今 − windowStart ≥ 8.0` → `commit(from: windowStart, to: windowStart + 8.0, nextFrom: windowStart + 7.0)`（1.0 秒重ねる。次の窓の確定文は `OverlapTrimmer` で先頭 1.0 秒のトークンを落とす）
3. どちらでもなく、前回の partial から 2.0 秒分の音声が増えた → `partial(from: windowStart, to: 今)`
4. 窓の中の発話フレームが 0.3 秒未満の commit は `skip` にする（無音を whisper に渡さない。幻覚対策）
5. 処理待ちが溜まったら古い partial を捨てて最新だけ回す。commit は捨てない

`WhisperLiveTranscriber` は partial を `Utterance(start: mapper.timeline(windowStart), end: nil, isFinal: false)`、commit を同じ start・`end: mapper.timeline(to)`・`isFinal: true` で流す（同じ start で上書きする約束。overview §4）。

- [ ] **Step 1: 失敗するテストを書く**（`tone` / `silence` は Task 2 のテストの補助関数を `TestAudio` として共有）

```swift
@Test func speechThenSilenceCommitsAtBoundary() {
    var p = ChunkPlanner(); let a = p.ingest(tone(3.0) + silence(1.0))
    #expect(a.contains(.commit(from: 0, to: 3.0, nextFrom: 3.0)))
}
@Test func longSpeechHardCutsWithOverlap() { var p = ChunkPlanner(); #expect(p.ingest(tone(10)).contains(.commit(from: 0, to: 8, nextFrom: 7))) }
@Test func partialEveryTwoSeconds() {   // tone(5) を 0.1 秒ずつ ingest → partial の to が [2, 4]
}
@Test func silenceOnlyNeverDecodes() { var p = ChunkPlanner(); #expect(p.ingest(silence(20)).allSatisfy { if case .skip = $0 { true } else { false } }) }
@Test func flushCommitsRemainder() { var p = ChunkPlanner(); _ = p.ingest(tone(1.5)); #expect(p.flush() == [.commit(from: 0, to: 1.5, nextFrom: 1.5)]) }
@Test func overlapTokensDropped() {
    #expect(OverlapTrimmer.text([.init(start: 0.2, end: 0.8, text: "重なり"), .init(start: 1.3, end: 2.0, text: "続き")], droppingBefore: 1.0) == "続き")
}
@Test func emitsPartialThenFinalWithSameStart() async throws {
    let core = FakeWhisperCore(fixedText: "テスト"); let t = WhisperLiveTranscriber(core: core)
    let s = try await t.start(language: .ja, hints: [])
    for c in PCMAudio.chunks(tone(3) + silence(1), track: .mic, chunkSeconds: 0.1, start: TimelineTime(seconds: 100)) { await t.feed(c) }
    await t.finish(); let all = await collect(s)
    #expect(all.first { !$0.isFinal }?.start.seconds == 100); #expect(all.last?.isFinal == true); #expect(all.last?.start.seconds == 100)
}
@Test func timelineGapAfterPause() async throws   // tone(3)+silence(1) を t=0 から、tone(3)+silence(1) を t=60 から → 2 件目の final の start が 60±0.05
```

- [ ] **Step 2: 失敗を確認** — `swift test --filter 'ChunkPlannerTests|WhisperLiveTranscriberTests'` で FAIL
- [ ] **Step 3: 実装**
- [ ] **Step 4: 通過を確認** — 同じコマンドで PASS
- [ ] **Step 5: コミット**

```bash
git add Sources/AutoNoteCore/Transcription/Whisper Tests/AutoNoteCoreTests/Transcription
git commit -m "feat(transcription): add chunked whisper live transcriber"
```

---

### Task 7: Apple の LiveTranscriber（DictationTranscriber / SpeechTranscriber）

**Files:**
- Create: `Sources/AutoNoteCore/Transcription/Apple/{SegmentationStrategy,UtteranceAssembler,AppleAudioBuffers,AppleSpeechModuleAdapter,AppleLiveTranscriber}.swift`
- Test: `Tests/AutoNoteCoreTests/Transcription/{UtteranceAssemblerTests,AppleAudioBuffersTests,SegmentationStrategyTests}.swift`

**Interfaces:**
- Consumes: `LiveTranscriber`、`LocaleMapping`（Task 4）、`TimelineMapper`・`SilenceDetector`（Task 2）、`TranscriptionError`
- Produces:
  - `enum SegmentationStrategy: String, Codable, Sendable, CaseIterable { case engineDefault = "default", frequentFinalization = "frequent", silenceFinalize = "silence"; static var current: SegmentationStrategy { get } }`（このタスクでは `.engineDefault`。Task 9 で確定）
  - `struct RecognizedSegment: Equatable, Sendable { var audioStart: Double; var audioEnd: Double; var text: String; var isFinal: Bool }`
  - `struct UtteranceAssembler: Sendable { mutating func consume(_ r: RecognizedSegment, mapper: TimelineMapper) -> Utterance }`。確定のあと最初の結果の `audioStart` を発話の start に固定し、確定までの部分結果はすべてその start で返す（Apple の volatile は範囲の先頭が動くことがあるため）。確定で `end` を付け、固定を外す。`speaker` は `.unknown`（`LiveFeed` が付ける）
  - `enum AppleAudioBuffers { static func pcmBuffer(_ chunk: AudioChunk) -> AVAudioPCMBuffer }`（16 kHz / mono / Int16）
  - `protocol AppleSpeechModuleAdapter: Sendable { static var engineKind: EngineKind { get }; static func supportedLocales() async -> [Locale]; static func supports(_ s: SegmentationStrategy) -> Bool; static func makeModule(locale: Locale, strategy: SegmentationStrategy) -> (module: any SpeechModule, results: AsyncThrowingStream<RecognizedSegment, Error>) }`、`enum DictationAdapter`（`default` は `.progressiveLongDictation`。`frequent` は同じ設定の reportingOptions に `.frequentFinalization` を足す）、`enum SpeechAdapter`（`SpeechTranscriber` の progressive 系 preset。`.frequentFinalization` 相当が無ければ `supports(.frequentFinalization) == false`）
  - `actor AppleLiveTranscriber<Adapter: AppleSpeechModuleAdapter>: LiveTranscriber { init(strategy: SegmentationStrategy = .current) }`、`typealias DictationLiveTranscriber = AppleLiveTranscriber<DictationAdapter>`、`typealias SpeechLiveTranscriber = AppleLiveTranscriber<SpeechAdapter>`

`start(language:hints:)` の順（スパイク `AppleSpeechProbe.dictationLive` と同じ流れ）: Locale を決め `supportedLocales` に無ければ `TranscriptionError.localeUnsupported` → `makeModule`（Adapter が strategy に未対応なら `.silenceFinalize` に落とす）→ `AssetInventory.assetInstallationRequest(supporting:)` があれば `downloadAndInstall()` → `SpeechAnalyzer(modules:)` → hints が空でなければ `AnalysisContext().contextualStrings[.general] = Array(hints.prefix(100))`［私の判断: 上限 100 語］を `setContext(_:)`（要件書 §7.1）→ `bestAvailableAudioFormat(compatibleWith:)` → `prepareToAnalyze(in:)` → `AsyncStream<AnalyzerInput>` で `start(inputSequence:)` → 結果を読むタスクが `UtteranceAssembler` を通して流す。
`feed`: `mapper.append` → `pcmBuffer` → 解析形式へ `AVAudioConverter`（使い回す）→ `AnalyzerInput` を yield。`.silenceFinalize` なら `SilenceDetector.process` の境界ごとに `finalize(through: CMTime(seconds: b, preferredTimescale: 16_000))`。
`finish`: 入力を閉じ `finalizeAndFinishThroughEndOfInput()`、結果タスクを待って stream を閉じる。

- [ ] **Step 1: 失敗するテストを書く**

```swift
@Test func partialsShareStartUntilFinal() {
    var m = TimelineMapper(); m.append(chunk(silence(5), at: 30))
    var a = UtteranceAssembler()
    let u = [RecognizedSegment(audioStart: 0, audioEnd: 1, text: "こん", isFinal: false),
             .init(audioStart: 0.3, audioEnd: 1.5, text: "こんにちは", isFinal: false),
             .init(audioStart: 0, audioEnd: 2, text: "こんにちは", isFinal: true),
             .init(audioStart: 2.5, audioEnd: 3, text: "次", isFinal: false)].map { a.consume($0, mapper: m) }
    #expect(u.map(\.start.seconds) == [30, 30, 30, 32.5]); #expect(u.map(\.isFinal) == [false, false, true, false])
    #expect(u[2].end?.seconds == 32); #expect(u[0].end == nil)
}
@Test func pcmBufferKeepsSamples() {
    let s = (0..<1600).map { Int16($0) }; let b = AppleAudioBuffers.pcmBuffer(chunk(s, at: 0))
    #expect(b.frameLength == 1600); #expect(b.format.sampleRate == 16_000); #expect(b.format.channelCount == 1); #expect(b.int16ChannelData![0][5] == 5)
}
@Test func strategyRawValuesMatchCLI() { #expect(SegmentationStrategy.allCases.map(\.rawValue) == ["default", "frequent", "silence"]) }
@Test func dictationSupportsAllStrategies() { #expect(SegmentationStrategy.allCases.allSatisfy(DictationAdapter.supports)) }
@Test func speechSupportsSilenceAndDefault() { #expect(SpeechAdapter.supports(.silenceFinalize) && SpeechAdapter.supports(.engineDefault)) }
```

- [ ] **Step 2: 失敗を確認** — `swift test --filter 'UtteranceAssemblerTests|AppleAudioBuffersTests|SegmentationStrategyTests'` で FAIL
- [ ] **Step 3: 実装**。`DictationTranscriber.ReportingOption.frequentFinalization` と `SpeechTranscriber` の preset 名は SDK でコンパイルして確かめ、名前が違えば SDK の名前を使って Adapter の冒頭コメントに残す
- [ ] **Step 4: 通過を確認** — 同じコマンドで PASS。実際の認識は Task 8 の E2E `check_dev_transcribe_dictation` で確かめる（認識結果の中身はテストで固定しない）
- [ ] **Step 5: コミット**

```bash
git add Sources/AutoNoteCore/Transcription/Apple Tests/AutoNoteCoreTests/Transcription
git commit -m "feat(transcription): add SpeechAnalyzer-based dictation and speech live transcribers"
```

---

### Task 8: 生成口と開発用サブコマンド（`dev engines` / `dev transcribe` / `dev models`）

**Files:**
- Create: `Sources/AutoNoteCore/Transcription/Engines/TranscriberFactory.swift`
- Create: `Sources/autonote/{DevEngines,DevTranscribe,DevModels,DevMicCapture}.swift`
- Modify: `Sources/autonote/DevCommands.swift`（`engines` `transcribe` `models` を足す）、`scripts/e2e-check.sh`
- Test: `Tests/AutoNoteCoreTests/Transcription/TranscriberFactoryTests.swift`

**Interfaces:**
- Consumes: Task 3〜7 のすべて
- Produces:
  - `struct TranscriberFactory: Sendable { init(models: ModelManager, machine: MachineKind); func makeLive(_ c: EngineChoice) async throws -> any LiveTranscriber; func makeBatch(_ c: EngineChoice, gate: BatchGate?) async throws -> any BatchTranscriber }`。モデル未取得は `TranscriptionError.modelMissing`、Apple を batch に求めたら `.engineUnavailable`
  - CLI（利用者向けの使い方には出さない。overview §7）:
    - `autonote dev engines` → 標準出力に JSON 1 つ: `machine`、`speech_transcriber: {is_available, supported_locales}`、`dictation: {supported_locales}`（件数）、`live` / `batch`（`EngineEntry` の配列）、`defaults`、`resolved`（`Settings` の上書きを反映した結果）
    - `autonote dev transcribe <音声> --engine dictation|speech|whisper|whisper-live [--model <名前> | --model-path <ggml.bin>] [--lang ja|en|auto] [--hints "語1,語2"] [--realtime] [--segmentation default|frequent|silence] [--max-seconds N] [--gpu on|off] [--text-out <path>]`、`autonote dev transcribe --mic --engine … --seconds N`。発話ごとに JSON 1 行 `{"wall":秒,"start":秒,"end":秒|null,"final":bool,"text":"…"}`（`wall` は入力開始からの壁時計秒）、最後に `{"summary":{"engine":…,"audio_seconds":…,"elapsed":…,"rtf":…,"finals":n}}`。`--text-out` は確定文を改行なしで連結して書く（`scripts/cer.py` 用）。live のエンジンはファイルを 0.1 秒の `AudioChunk` にして渡し、`--realtime` なら 0.1 秒ずつ待つ。終了コード: 成功 0、エラー 1、エンジンが使えない 3（stderr に `unavailable: <理由>`）
    - `autonote dev models list|download <名前>|delete <名前>`（`list` は JSON、`download` は進捗を stderr に）
  - `--mic` は `DevMicCapture`（スパイクの `MicCapture` と同じく既定入力を `AVAudioEngine` で取り 16 kHz mono Int16 に変換。開発用なので計画 02 に依存しない）。これが Task 13 の「SpeechTranscriber の live/file 経路」になる（AppleSpeechProbe に足す代わりに本体の `SpeechLiveTranscriber` を使う）

- [ ] **Step 1: 失敗するテストを書く**

```swift
@Test func batchRejectsAppleEngines() async {
    let f = TranscriberFactory(models: ModelManager(directory: try TemporaryDirectory.make(), catalog: []), machine: .intel)
    await #expect(throws: TranscriptionError.self) { _ = try await f.makeBatch(.dictation, gate: nil) }
}
@Test func missingModelIsReported() async   // makeBatch(.whisper("small")) → TranscriptionError.modelMissing("small")
@Test func liveDictationIsConstructible() async throws   // makeLive(.dictation) が DictationLiveTranscriber を返す（start は呼ばない）
```

- [ ] **Step 2: 失敗を確認** — `swift test --filter TranscriberFactoryTests` で FAIL
- [ ] **Step 3: `TranscriberFactory` と 4 つの CLI ファイルを実装**し、`DevCommands.run` に `engines` `transcribe` `models` を足す
- [ ] **Step 4: 通過を確認** — `swift test --filter TranscriberFactoryTests` で PASS
- [ ] **Step 5: 手で動かす**
Run: `swift build && .build/debug/autonote dev engines | jq .`
Expected: Intel 機では `machine: "intel"`、`speech_transcriber.is_available: false`、`resolved.live.kind: "dictation"`

Run: `.build/debug/autonote dev transcribe tools/samples/ja-5min.wav --engine whisper --model-path tools/whisper.cpp/models/ggml-small.bin --text-out /tmp/autonote-small.txt | tail -1 && python3 -I scripts/cer.py /tmp/autonote-small.txt scripts/samples/ja-5min.txt`
Expected: CER ≤ 0.30（項目 1 のソースビルドは 0.2782）。`--hints "AutoNote,所沢,Kubernetes"` を付けても ≤ 0.30。`--lang auto` でも回し、`ja` との CER の差を記録する（要件書 §6.4「`language=ja` と `auto` の差はベンチで確かめる」）。RTF と CER を結果表の項目 8 の末尾に「XCFramework（x86_64 スライス）の small: RTF x、CER y」と 1 行で足す（項目 8 で未測定だった点）

Run（ネットワークがあれば）: `.build/debug/autonote dev models download base && .build/debug/autonote dev models list | jq '.[] | select(.name=="base")'`
Expected: `installed: true`
- [ ] **Step 6: E2E に 4 項目を足す**（計画 01〜03 が番号 16 以降を使うので番号は付けず、計画 03 と同じく名前で書く。実行ファイルは計画 01 の `autonote_bin()`。CHECKS の末尾に追加）
  - `check_dev_engines`（`CURRENT="dev engines: 機種・エンジン一覧の JSON"`）: `jq -e '(.machine == "intel" or .machine == "appleSilicon") and (.live | length > 0) and .defaults.batch.model == "large-v3-turbo"'`
  - `check_dev_transcribe_dictation`（`"dev transcribe dictation: say の短い WAV"`）: `say -v Kyoko --file-format=WAVE --data-format=LEI16@16000 -o "${WORK}/short.wav" "本日の定例を始めます。議題は三つです。"`。Kyoko が無い・終了コード 3 なら SKIP。確定が 1 件以上で本文が空でなければ PASS（内容は見ない）。60 秒で打ち切り
  - `check_dev_transcribe_whisper`（`"dev transcribe whisper: base で先頭 10 秒"`）: `--model-path tools/whisper.cpp/models/ggml-base.bin --max-seconds 10`、入力 `tools/samples/ja-5min.wav`（無ければ「scripts/make-sample-audio.sh」と出して SKIP）。確定 1 件以上・全 `start < 10.5` で PASS
  - `check_dev_transcribe_whisper_live`（`"dev transcribe whisper-live: base で先頭 10 秒"`）: 同じ条件で final が 1 件以上

Run: `scripts/e2e-check.sh`
Expected: FAIL 0（新しい 4 件は PASS か条件付き SKIP）
- [ ] **Step 7: コミット**

```bash
git add Sources Tests scripts/e2e-check.sh docs/superpowers/research/2026-10-24-spike-results.md
git commit -m "feat(cli): add dev engines, dev transcribe and dev models"
```

---

### Task 9: 発話の区切りを決める（`finalize(through:)` / `.frequentFinalization` / 沈黙）

**Files:**
- Create: `scripts/samples/ja-segments.txt`
- Modify: `scripts/make-sample-audio.sh`
- Modify: `Sources/AutoNoteCore/Transcription/Apple/SegmentationStrategy.swift`（`current`）
- Modify: `docs/superpowers/research/2026-10-24-spike-results.md`（項目 2 に追記）
- Test: `Tests/AutoNoteCoreTests/Transcription/SegmentationStrategyTests.swift`

**Interfaces:**
- Consumes: `autonote dev transcribe --realtime --segmentation`（Task 8）
- Produces: `SegmentationStrategy.current` の確定値。3 案の対応: `silence` ＝自前の沈黙検出 → `finalize(through:)`、`frequent` ＝`.frequentFinalization`、`default` ＝エンジンの沈黙判定に任せる（スパイクの挙動）

- [ ] **Step 1: 比較用の音声を用意する**
`scripts/samples/ja-segments.txt` に架空の会議の発言を 10 文（各 3〜8 秒）、文の間に `[[slnc 1500]]` を挟んで書く。`make-sample-audio.sh` に `say -v "$JA_VOICE" -r "$RATE" -o "$TMP/seg.aiff" -f "$SRC/ja-segments.txt"` と `afconvert -f WAVE -d LEI16@16000 -c 1 "$TMP/seg.aiff" "$OUT/ja-segments.wav"` を足す。
Run: `scripts/make-sample-audio.sh && afinfo tools/samples/ja-segments.wav | grep duration`
Expected: 50〜90 秒
- [ ] **Step 2: 3 案を同じ音声で回す**（実時間で流すので 1 案 1〜1.5 分）
Run: `for s in default frequent silence; do .build/debug/autonote dev transcribe tools/samples/ja-segments.wav --engine dictation --realtime --segmentation $s > tools/seg-$s.jsonl; done`
- [ ] **Step 3: 集計する**
Run: `for s in default frequent silence; do jq -s --arg s $s '[.[] | select(.final == true)] | {s: $s, finals: length, max_len: (map(.end - .start) | max), median_latency: (map(.wall - .end) | sort | .[length/2|floor])}' tools/seg-$s.jsonl; done`

判定基準: (1) 確定件数 8〜13（理想 10。文の区切りにおおむね合う） (2) 最長の発話 ≤ 15 秒（スパイクでは 70 秒が 1 件にまとまった） (3) 確定遅延の中央値 ≤ 3.0 秒（`wall − end`。要件書 §17 の体感 5 秒以内に余裕を残す）。3 つとも満たす案のうち `default` → `frequent` → `silence` の順に採る（自前の処理が少ない順）。どれも満たさなければ最長の発話が最も短い案を採り、満たさなかった基準を記録する。
- [ ] **Step 4: 👤 利用者（任意）: マイクで自然な話し方を 1 回**
Run: `.build/debug/autonote dev transcribe --mic --engine dictation --segmentation <採った案> --seconds 60`
Expected: 60 秒話して、15 秒を超える発話が無い。利用者がいなければ飛ばし、結果表に「マイク確認は未」と書く
- [ ] **Step 5: 失敗するテストを書く**

```swift
@Test func chosenSegmentation() { #expect(SegmentationStrategy.current == .silenceFinalize) }   // Step 3 で採った案に置き換える
```

- [ ] **Step 6: 失敗を確認** — `swift test --filter SegmentationStrategyTests` で FAIL（まだ `.engineDefault`）
- [ ] **Step 7: `current` を採った案にする**
- [ ] **Step 8: 通過を確認** — 同じコマンドで PASS
- [ ] **Step 9: 結果表の項目 2 に追記する**
項目 2 の末尾に「- 発話の区切り（計画 04 Task 9、<日付>、Intel、DictationTranscriber、`tools/samples/ja-segments.wav`）」として 3 案の表（確定件数・最長・遅延中央値）、採った案と理由、マイク確認の有無を書く。SpeechTranscriber 側は Task 13。
- [ ] **Step 10: コミット**

```bash
git add scripts/samples/ja-segments.txt scripts/make-sample-audio.sh Sources/AutoNoteCore/Transcription/Apple/SegmentationStrategy.swift Tests docs/superpowers/research/2026-10-24-spike-results.md
git commit -m "feat(transcription): choose utterance segmentation from measured comparison"
```

---

### Task 10: LiveFeed（2 本のリアルタイム結果を 1 本に）

**Files:**
- Create: `Sources/AutoNoteCore/Transcription/Live/LiveFeed.swift`
- Modify: `Sources/AutoNoteTestSupport/Fakes.swift`（`FakeLiveTranscriber` に `startError: FakeError? = nil` を足す。既定 nil なので計画 01 のテストは変わらない）
- Test: `Tests/AutoNoteCoreTests/Transcription/LiveFeedTests.swift`

**Interfaces:**
- Consumes: `LiveTranscriber`、`FakeLiveTranscriber`、`Replacer`、`Transcript`・`Bookmark`・`AudioChunk`、`AutoNoteJSON.encoder()`（計画 01・02）
- Produces: `actor LiveFeed`
  - `static let pauseMarkerText = "── 一時停止 ──"`（要件書 §5.4）、`static func bookmarkMarkerText(_ note: String?) -> String`（`"── ブックマーク ──"` / `"── ブックマーク: <note> ──"`［私の判断］）、`static func isMarker(_ u: Utterance) -> Bool`
  - `init(transcribers: [Track: any LiveTranscriber], replacer: Replacer, liveJSON: URL, engineName: String, saveInterval: Duration = .seconds(5))`（`liveJSON` は呼び手が `paths.transcriptFile(id, .live)` を渡す）
  - `func start(language: Language, hints: [String]) async throws -> AsyncStream<[Utterance]>`（片方の start が失敗しても続け、両方失敗したときだけ throw）
  - `var failures: [Track: String] { get }`、`func feed(_ chunk: AudioChunk) async`（`chunk.track` で振り分ける）、`func pause(at: TimelineTime)`、`func resume(at: TimelineTime)`、`func bookmark(_ b: Bookmark)`、`func snapshot() -> [Utterance]`、`func finish() async throws -> Transcript`

規律: 話者は mic → `.me`、system → `.other`。同じ (speaker, start) の発話は後から来たもので置き換える（部分 → 確定）。本文が空の確定は、その部分結果ごと消す。表示（stream と `snapshot`）は確定＋部分＋印を start 順（同時刻は mic が先）に並べ、本文に置換ルールを適用する（要件書 §7.1「リアルタイム版は表示時に適用」）。印は `speaker: .unknown`・`isFinal: true` の `Utterance`（一時停止は `pause(at:)` の時刻、ブックマークは `b.at`）。`live.json`（要件書 §12）は**確定した発話だけ**を置換前の本文で `Transcript(utterances:engine:language:)` として書く（印は manifest の pauses / bookmarks から作れるので入れない）。確定のたびに、前回の保存から `saveInterval` 以上たっていれば原子的に書き、`finish()` で必ず書く。

- [ ] **Step 1: 失敗するテストを書く**

```swift
// 補助（テストファイル内）: makeFeed(mic:sys:rules:sysError:) throws -> (LiveFeed, FakeLiveTranscriber, FakeLiveTranscriber, URL)
//   台本つきの Fake を 2 つ作り、liveJSON は TemporaryDirectory.make() の下、engineName は "Apple DictationTranscriber"
@Test func mergesTwoTracksSortedAndLabelsSpeakers() async throws {
    let (feed, _, _, _) = try makeFeed(mic: [u(5, .unknown, "おはよう")], sys: [u(3, .unknown, "どうも")])
    _ = try await feed.start(language: .ja, hints: [])
    try await waitUntil { await feed.snapshot().count == 2 }
    #expect(await feed.snapshot().map(\.text) == ["どうも", "おはよう"]); #expect(await feed.snapshot().map(\.speaker) == [.other, .me])
}
@Test func partialIsReplacedByFinalWithSameStart() async throws   // mic 台本 [partial(5,"おは"), u(5,.unknown,"おはよう")] → 1 件、isFinal
@Test func emptyFinalRemovesPartial() async throws                // [partial(5,"えっと"), u(5,.unknown,"")] → 0 件
@Test func replacementOnDisplayOnly() async throws                // rules [オートノート => AutoNote]: snapshot は "AutoNoteです"、finish() 後の live.json は "オートノートです"
@Test func pauseMarkerAndBookmarkInOrder() async throws           // mic [u(5),u(22)]、pause(at:10)、resume(at:20)、bookmark(at:25,"重要") → 本文順 [_, "── 一時停止 ──", _, "── ブックマーク: 重要 ──"]、印は isMarker、live.json に印なし
@Test func liveJSONWrittenOnFinish() async throws                 // AutoNoteJSON.decoder() で読んだ Transcript: 確定のみ、engine "Apple DictationTranscriber"、language .ja
@Test func oneTrackFailingKeepsOther() async throws               // sysError あり → start は成功、failures[.system] != nil、mic の発話は流れる
@Test func bothTracksFailingThrows() async
@Test func feedRoutesByTrack() async throws                       // feed(chunk(silence(0.1), at: 0, track: .mic)) → mic.fedChunks.count == 1、sys.fedChunks.isEmpty
```

- [ ] **Step 2: 失敗を確認** — `swift test --filter LiveFeedTests` で FAIL
- [ ] **Step 3: 実装**（`FakeLiveTranscriber` の `startError` もここで足す）
- [ ] **Step 4: 通過を確認** — `swift test` 全体で PASS（計画 01 の Fakes のテストも通る）
- [ ] **Step 5: コミット**

```bash
git add Sources/AutoNoteCore/Transcription/Live Sources/AutoNoteTestSupport/Fakes.swift Tests/AutoNoteCoreTests/Transcription/LiveFeedTests.swift
git commit -m "feat(transcription): add LiveFeed merging both tracks with markers and live.json"
```

---

### Task 11: 確定版（結合済みファイルごとの文字起こし → raw / final）

**Files:**
- Create: `Sources/AutoNoteCore/Transcription/Batch/FinalTranscription.swift`
- Test: `Tests/AutoNoteCoreTests/Transcription/FinalTranscriptionTests.swift`

**Interfaces:**
- Consumes: `BatchTranscriber`・`FakeBatchTranscriber`、`TrackTranscription`・`TranscriptFinalizer`、`DictionaryFile`、`Manifest`、`AppPaths.meetingDirectory(_:)`・`.transcriptFile(_:_:)`（計画 01）、`SegmentMerger.merge(_:track:meetingDirectory:)`・`WAVFile.info`（計画 02）
- Produces:
  - `struct FinalTranscriptResult: Sendable { var raw: Transcript; var final: Transcript; var rawURL: URL; var finalURL: URL }`
  - `struct FinalTranscription: Sendable { init(transcriber: any BatchTranscriber, engineName: String, paths: AppPaths); func run(manifest: Manifest, dictionary: DictionaryFile, fillerRemoval: Bool, progress: @Sendable @escaping (Double) -> Void) async throws -> FinalTranscriptResult }`

手順: `SegmentMerger.merge(manifest, track: .mic, …)` と `.system` で結合済みの `TrackFile` を得る（どちらも空なら `TranscriptionError.noTracks`）→ mic の分を先、system を後に**直列で**（CPU を取り合わない。要件書 §13）`transcribe(file: meetingDirectory/relativePath, language: manifest.language, hints: dictionary.terms, progress:)` → `TrackTranscription(file:utterances:)` を集める → `TranscriptFinalizer(dictionary:fillerRemoval:).finalize(parts, source: manifest.source, engine: engineName, language: manifest.language)`（startOffset の加算・話者・重複除去・置換・フィラー除去は計画 01 の担当）→ raw を `transcriptFile(id, .raw)`、final を `.final` に `AutoNoteJSON.encoder()` で原子的に書く。進捗はファイルの長さ（`durationSeconds`）で重み付けして 0〜1。失敗はそのトラックを `TranscriptionError.trackFailed(track, String(describing: error))` で返し、ファイルは書かない。キャンセルはそのまま投げる。リアルタイム版での代替と `transcript_engine` の記録は計画 05 の段階が行う。

- [ ] **Step 1: 失敗するテストを書く**（音声は `PCMAudio.writeWAV` で `tracks/mic-000.wav` などに数秒の無音を書き、manifest の `tracks` に並べる。結合後の名前は `merged/mic-0.wav` / `merged/system-0.wav` で、`FakeBatchTranscriber` のキーにする）

```swift
@Test func offsetsAddedAndSpeakersAssigned() async throws {
    // mic: tracks/mic-000.wav（0–2 秒）、system: tracks/system-000.wav（startOffset 420）
    let fake = FakeBatchTranscriber(results: ["mic-0.wav": [u(1.0, .unknown, "おはようございます")], "system-0.wav": [u(1.0, .unknown, "よろしくお願いします")]])
    let r = try await FinalTranscription(transcriber: fake, engineName: "whisper.cpp large-v3-turbo", paths: paths)
        .run(manifest: m, dictionary: DictionaryFile.default, fillerRemoval: false, progress: { _ in })
    #expect(r.raw.utterances.map(\.start.seconds) == [1.0, 421.0]); #expect(r.raw.utterances.map(\.speaker) == [.me, .other])
    #expect(r.raw.engine == "whisper.cpp large-v3-turbo")
}
@Test func pauseSplitFilesKeepTheirOffsets() async throws   // mic 0–2 と 60–62 の 2 分割 → fake に mic-0.wav と mic-1.wav、start [1, 61]
@Test func importedMeetingIsUnknownSpeaker() async throws   // source .imported、tracks/import.wav（.system）→ speaker .unknown
@Test func rawKeepsFillersFinalRemovesThem() async throws   // fake が "えー" と "本題です" → raw 2 件、final 1 件。rawURL / finalURL を AutoNoteJSON.decoder() で読める
@Test func emptyTrackStillCompletes() async throws          // system の結果が [] → final は mic の発話だけで成功
@Test func failureNamesTrackAndWritesNothing() async throws // FakeBatchTranscriber(failure:) → TranscriptionError.trackFailed(.mic, _)、raw.json は無い
@Test func noTracksIsReported() async                       // tracks [] → .noTracks
@Test func progressWeightedByDuration() async throws        // mic 1 秒、system 3 秒 → 進捗に 0.25±0.01 が現れ、最後は 1.0
```

- [ ] **Step 2: 失敗を確認** — `swift test --filter FinalTranscriptionTests` で FAIL
- [ ] **Step 3: 実装**
- [ ] **Step 4: 通過を確認** — 同じコマンドで PASS。続けて `swift test` 全体も PASS
- [ ] **Step 5: コミット**

```bash
git add Sources/AutoNoteCore/Transcription/Batch Tests/AutoNoteCoreTests/Transcription/FinalTranscriptionTests.swift
git commit -m "feat(transcription): add final transcription pipeline writing raw and final json"
```

---

### Task 12: Spikes の削除、E2E と README の更新

**Files:**
- Delete: `Spikes/`
- Modify: `scripts/e2e-check.sh`、`README.md`、`docs/superpowers/research/2026-10-24-spike-results.md`（項目 7・12 の「手順」）

**Interfaces:**
- Consumes: Task 8 の E2E 4 件（`check_dev_engines` ほか）
- Produces: Spikes に依存しない E2E。Task 13 の手順は本体の `autonote dev …` だけで完結する

- [ ] **Step 1: 参照を洗い出す**
Run: `grep -rn 'Spikes\|AppleSpeechProbe\|DeviceProbe\|TapCapture\|MicHotSwap' --exclude-dir=.build --exclude-dir=tools . | grep -v '^./docs/superpowers/plans/2026-10-24' `
Expected: `scripts/e2e-check.sh`、`README.md`、結果表の手順欄だけ（計画 00 の文書と生データは歴史の記録として残す）
- [ ] **Step 2: 削除前のコミットを控える**
Run: `git rev-parse HEAD`
この値を結果表の項目 4 の手順欄に「DeviceProbe はこのコミットにある」として書く（Task 13 Step 7 が使う）
- [ ] **Step 3: 削除と E2E の更新**
`git rm -r Spikes`。`scripts/e2e-check.sh` から `check_spikes_build`（項目 8）、`check_device_probe`（14）、`check_apple_speech_probe`（15）、`check_apple_speech_probe_guard`（15b）の関数と CHECKS の行を消し、冒頭の `--quick` の説明から「Spikes build」を消す。項目 10（whisper-cli）は残す（`tools/whisper.cpp` のソースビルドはベンチ `bench-whisper.sh` と Task 13 で今後も使う）。
- [ ] **Step 4: README と結果表を直す**
README の `Spikes/` の行を「whisper.cpp のベンチ用スクリプト（`scripts/setup-whisper.sh` ほか。取得物は `tools/`）と、文字起こしの開発用コマンド `autonote dev engines` / `autonote dev transcribe`」に書き換える。結果表の項目 7・12 の「手順」を「計画 04 Task 13: `autonote dev engines` と `autonote dev transcribe --engine speech --file/--mic`（Spikes は計画 04 で削除。AppleSpeechProbe の transcriber 経路の代わり）」に直す。
- [ ] **Step 5: 全体の確認**
Run: `swift build && swift test && scripts/e2e-check.sh`
Expected: FAIL 0。項目 8・14・15・15b が出力に無く、Task 8 の 4 件が PASS か条件付き SKIP
- [ ] **Step 6: コミット**

```bash
git add -A Spikes scripts/e2e-check.sh README.md docs/superpowers/research/2026-10-24-spike-results.md
git commit -m "chore: remove plan 00 spikes and switch e2e to dev transcribe"
```

---

### Task 13: 👤 利用者: Apple Silicon 確認（計画 00 Task 8 の引き継ぎ）

Apple Silicon 機が手元にあるときに行う。無い間は後回しにしてよく、他のタスクはこれを待たない（Apple Silicon の既定は「仮」のまま。要件書 §6.2）。前提は Task 8（本体の `SpeechLiveTranscriber` を `dev transcribe` から動かせること）。

**Files:**
- Modify: `docs/superpowers/research/2026-10-24-spike-results.md`（項目 1 の Apple Silicon 側、4、7、12 の Apple Silicon 側、2 の区切りの SpeechTranscriber 側）
- Modify（結果次第）: `Sources/AutoNoteCore/Transcription/Engines/EngineCatalog.swift`（Apple Silicon の既定）、`Tests/AutoNoteCoreTests/Transcription/EngineCatalogTests.swift`、要件書 §6.2 の表と §19 の状態

**Interfaces:**
- Consumes: `autonote dev engines` / `dev transcribe` / `dev models`（Task 8）
- Produces: `EngineCatalog.defaults(for: .appleSilicon)` の確定値（「仮」を外すか、変える）

- [ ] **Step 1: 👤 clone してビルド**
Run: `scripts/make-dev-cert.sh && scripts/build-app.sh && swift test && scripts/make-sample-audio.sh`
Expected: 署名成功、テスト PASS（Intel と同じ手順で動く）
- [ ] **Step 2: SpeechTranscriber が使えるか（項目 7）**
Run: `.build/debug/autonote dev engines | jq '{machine, speech_transcriber, resolved}'`
Expected を記録: `machine: "appleSilicon"`、`is_available`、`supported_locales` の件数と ja-JP の有無（`entries` の speech の `available`）
- [ ] **Step 3: ファイル入力の速さと精度**
Run: `for e in speech dictation; do .build/debug/autonote dev transcribe tools/samples/ja-5min.wav --engine $e --text-out /tmp/as-$e.txt | tail -1; python3 -I scripts/cer.py /tmp/as-$e.txt scripts/samples/ja-5min.txt; done`
Expected を記録: 各 RTF と CER（Intel の DictationTranscriber は RTF 0.307、CER 0.3494）
- [ ] **Step 4: 👤 contextual strings の効き（項目 12）**
利用者が同じ原稿（「AutoNote で所沢の Kubernetes 勉強会の議事録を作る」を含む 30 秒ほど）を 2 回読む。
Run: `.build/debug/autonote dev transcribe --mic --engine speech --seconds 40` と `… --hints "AutoNote,所沢,Kubernetes"`
Expected を記録: 3 語それぞれの正誤をヒントなし／ありで比べる（Intel では比較していなかった点）
- [ ] **Step 5: 発話の区切り（SpeechTranscriber 側）**
Task 9 の Step 2〜3 を `--engine speech` で回し、同じ基準で判定。Dictation と違う案が良ければ `SegmentationStrategy.current` をエンジン別にする（`static func current(for: EngineKind)`）。その場合は Task 9 のテストを両エンジン分に直す（TDD の順で）
- [ ] **Step 6: whisper（項目 1 の Apple Silicon 側、Metal）**
Run: `scripts/setup-whisper.sh && scripts/bench-whisper.sh`（`build` と `build-metal` の両方の表が出る）と、XCFramework 経由で `for g in on off; do .build/debug/autonote dev transcribe tools/samples/ja-5min.wav --engine whisper --model large-v3-turbo --gpu $g --text-out /tmp/as-turbo-$g.txt | tail -1; done`（モデルは `dev models download large-v3-turbo`）
Expected を記録: 各 RTF・CER。Metal（`--gpu on`）の CER が CPU と同程度なら Apple Silicon の `use_gpu = true` を確定、壊れていれば `MachineKind` に関係なく false にする（Task 5 の `WhisperContext` を TDD で直す）
- [ ] **Step 7: 👤 機材の見え方（項目 4）**
`autonote dev devices --watch`（計画 03。plan-04 は plan-03 から切るのであるはず）を使う。無ければ結果表の項目 4 に控えた削除前のコミットから `git worktree add ../autonote-spikes <その値> && swift run --package-path ../autonote-spikes/Spikes DeviceProbe` を使う。3.5mm のイヤホンマイクと Shokz を抜き差しする。
Expected を記録: 3.5mm が `BuiltInHeadphoneInputDevice` の追加・削除で見えるか、Shokz の入力 `DeviceUID` が Intel 機と同じか（MAC アドレスの下 3 バイトは伏せて書く。Global Constraints）。終わったら `git worktree remove ../autonote-spikes`
- [ ] **Step 8: 既定を見直す**
結果から Apple Silicon の既定（リアルタイム speech / 確定版 large-v3-turbo / whisper リアルタイム small）を確定または変更する。変えるときは先に `EngineCatalogTests.appleSiliconProvisionalDefaults` を新しい値に直して失敗を確認してから `EngineCatalog.defaults` を直す。要件書 §6.2 の表の「仮」と §19 の項目 1・7・12 の状態を更新する。
- [ ] **Step 9: E2E とコミット**
Run: `scripts/e2e-check.sh`
Expected: FAIL 0（Apple Silicon 機で Task 8 の 4 件が PASS）

```bash
git add docs Sources Tests
git commit -m "docs: record Apple Silicon speech and whisper results"
```

---

## 自己点検の記録（Self-Review）

- 要件書との対応: §3.2 XCFramework → Task 1／§3.3 Metal は Intel で使わない → Task 5（`use_gpu`）・Task 13 Step 6／§6.1 二段構え → Task 6・7（リアルタイム）、Task 5・11（確定版）／§6.2 差し替え層・既定・実行時判定・設定で上書き → Task 4・8／§6.3 2 本を別セッション・部分結果・区切り → Task 7・9・10／§6.4 トラックごと・タイムラインで結合・言語・`max-context 0`・繰り返し除去・話者 → Task 5・11（失敗時の代替は計画 05）／§6.5 フィラー除去の適用位置 → Task 11（除去と raw / final の組み立ては計画 01 の `TranscriptFinalizer`）／§7.1 initial prompt と contextual strings・置換は表示時 → Task 5・7・10／§7.2 224 トークン → Task 5（`HintBudget`）／§12 `live.json`・raw → Task 10・11／§13 録音中は確定版を止める → Task 5 `BatchGate`（待ち行列は計画 05）／§17 遅延 5 秒・CPU → Task 6 の数値・Task 9 の基準／§18 WhisperKit は作らない（差し替え層で後から足せる）
- overview との対応: §2 の `Transcription/` の 8 つの名前はすべてある（`DictationLiveTranscriber` / `SpeechLiveTranscriber` は typealias）。`Package.swift` の変更は Task 1 だけ。§7 の `dev transcribe` / `dev engines` → Task 8。§2 の Spikes 削除と E2E 8・14・15・15b → Task 12。§8 の 04 の申し送り（区切り、判定、Apple Silicon、`max-context 0`、Intel の既定）→ Task 9・4・13・5・4
- 型の一貫性: `EngineChoice` / `EngineKind` / `EngineRole`（Task 4）を Task 8・13 で同じ名前で使う。`WhisperCore.run` の引数（Task 5）を Task 6 も使う。`SegmentationStrategy` の rawValue（Task 7）と CLI の `--segmentation` の値（Task 8・9）が同じ。`TranscriptionError` の case（Task 2）を Task 7・8・11 が使う。計画 01・02 の名前（`HintBudget.fit`、`TranscriptFinalizer`、`SegmentMerger`、`AudioChunk(track:…)`、`finalEngine`）は冒頭の表と各タスクで一致させた
