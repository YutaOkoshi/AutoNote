# AutoNote 計画 01: 中核モデルと保存形式

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 会議の型（会議タイムライン、manifest、議事録出力）、アプリ領域の保存（設定・manifest・`_autonote/` の写し）、辞書・フィラー除去・置換、トラック結合と重複除去、Vault への書き出し（会議ファイル・`_index.md`・変更検知）をハードウェアなしの TDD で作り、フィクスチャから会議ファイルを再現できるようにする。

**Architecture:** すべて `AutoNoteCore` の中にフォルダで区切って置く（`Model/ Storage/ Dictionary/ Transcript/ Vault/`。録音・文字起こし・要約は protocol 宣言だけを `Audio/ Transcription/ Minutes/` に置く）。モデルは `Sendable` な値型、ファイルを持つサービスは `actor`。Markdown の生成は純粋関数（入力 → 文字列）にし、ファイル I/O は `VaultWriter` と各 Store に閉じ込める。新ターゲット `AutoNoteTestSupport` にフェイク・サンプル・フィクスチャ読み込みを置き、テストと `autonote dev render-fixture` の両方が使う。

**Tech Stack:** Swift 6.2（swift-tools-version 6.2、言語モード v6）/ Foundation / CryptoKit（SHA-256）/ Swift Testing / bash（E2E）

**Spec:** `docs/superpowers/specs/2026-10-24-autonote-design.md`（要件書。§5.2・§5.4〜5.6・§6.4・§6.5・§7・§8.2・§8.4・§9・§12・§21）と `docs/superpowers/plans/2026-10-25-autonote-plans-overview.md`（全計画の共通契約。型とプロトコルの名前と形は overview §3・§4 に従う）

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

（上の「本書」は overview を指す。）本計画の追加規約:

- `AutoNoteCore` の型・関数は TestSupport と CLI から使うので `public`。public な struct には public な `init` を明示する（メンバーワイズ init は internal にしかならない）
- JSON は必ず `AutoNoteJSON.encoder()` / `decoder()` を通す。`convertFromSnakeCase` は `meeting_id` を `meetingId` に戻し `meetingID` と一致しないので、頭字語を含むプロパティ名は使わないか `CodingKeys` を明示する
- 日付・時刻の文字列化は呼び手が渡す `TimeZone` で行う。テストとフィクスチャは `Asia/Tokyo` 固定
- 書き出す Markdown の改行は `\n`、ファイル末尾は改行 1 つ。差し込む文の中の改行は空白 1 つに置き換える
- テストは `@testable import AutoNoteCore` と `import AutoNoteTestSupport`。ファイル直下の補助（`doc` `part` など）は `private` にする（同じテストモジュールで名前がぶつかる）

## Review Focus

1. 同じ秒に二人が話す、または議事録の `t`・ブックマークの時刻がどの発話の開始とも一致しない → アンカーの重複やリンク切れ。アンカーは一意（2 つ目以降に `-2`）、リンクは「その時刻以前で最後の発話」へ向く（Task 9 `anchorsAreUniquePerSecond` `linkTargetFallsBackToPreviousUtterance`）
2. タイトルに `:` `"` `#` `|` `/` 改行などが入る → frontmatter が YAML として壊れず、ファイル名が作れ、`_index.md` の表が崩れない（Task 8 `escapesHostileTitle` `sanitizeReplacesForbiddenCharacters`、Task 10 `indexEscapesPipeInTitle`）
3. Obsidian で編集した後の再生成、別 Mac から持ってきたファイル（記録なし）、利用者が消したファイル → 前二者は黙って上書きせず `conflict` を返し、消えたものは書き直す（Task 11）
4. 外部ドライブ上の出力フォルダが未マウント → 書き出しはエラーで返し、そのパスにローカルのフォルダを作らない。`_autonote/` は写しで動く（Task 11 `unavailableOutputFolderThrowsAndCreatesNothing`、Task 12 `doesNotCreateMissingOutputFolder`）
5. 壊れた `settings.json`・壊れた manifest・形式の崩れた辞書の行 → 落ちずに既定値で動き、何が壊れていたかを返す（Task 3 `corruptSettingsAreSetAside` `allSkipsCorruptManifest`、Task 5 `reportsBrokenReplacementLines`）

### Task 1: 足場（TestSupport ターゲット、JSON 設定、版テストの修正）
**Files:**
- Modify: `Package.swift`、`Tests/AutoNoteCoreTests/AutoNoteVersionTests.swift`（計画 00 Task 1 の先送り minor: 名前 `versionIsSemver` と中身の不一致）
- Create: `Sources/AutoNoteCore/Model/AutoNoteJSON.swift`、`Sources/AutoNoteTestSupport/FixtureLibrary.swift`、`Sources/AutoNoteTestSupport/TemporaryDirectory.swift`、`Tests/Fixtures/README.md`（「すべて架空。人名・社名・機材識別子は実在しない」と各ファイルの役割。Task 13 で追記）
- Test: `Tests/AutoNoteCoreTests/Model/AutoNoteJSONTests.swift`、`Tests/AutoNoteCoreTests/FixtureLibraryTests.swift`

**Interfaces:**
- Produces: `public enum AutoNoteJSON { static func encoder() -> JSONEncoder; static func decoder() -> JSONDecoder }`、`public enum FixtureLibrary { static let defaultDirectory: URL; static let timeZone: TimeZone }`（`Asia/Tokyo`）、`public enum TemporaryDirectory { static func make() throws -> URL }`
- Package: `.target(name: "AutoNoteTestSupport", dependencies: ["AutoNoteCore"])` を足し、`autonote` と `AutoNoteCoreTests` の依存を `["AutoNoteCore", "AutoNoteTestSupport"]` にする。products には足さない

- [ ] **Step 1: Write the failing test**
```swift
@Test func versionIsSemver() { #expect(AutoNoteVersion.current.wholeMatch(of: /\d+\.\d+\.\d+/) != nil) }   // 既存の中身を置き換える
@Test func jsonUsesSnakeCaseAndISO8601() throws {
    struct Probe: Codable, Equatable { var startedAt: Date; var relativePath: String }
    let p = Probe(startedAt: Date(timeIntervalSince1970: 0), relativePath: "a/b")
    let s = String(decoding: try AutoNoteJSON.encoder().encode(p), as: UTF8.self)
    #expect(s.contains(#""started_at" : "1970-01-01T00:00:00Z""#)); #expect(s.contains(#""relative_path" : "a/b""#))
    #expect(try AutoNoteJSON.decoder().decode(Probe.self, from: Data(s.utf8)) == p)
}
@Test func fixtureDirectoryExists() { #expect(FileManager.default.fileExists(atPath: FixtureLibrary.defaultDirectory.appending(path: "README.md").path)) }
```
- [ ] **Step 2: 失敗を確認** `swift test` → FAIL（`AutoNoteJSON` `FixtureLibrary` が無い）
- [ ] **Step 3: Implement** encoder は `.convertToSnakeCase`・`.iso8601`・`[.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]`、decoder は `.convertFromSnakeCase`・`.iso8601`。`defaultDirectory` は `URL(filePath: #filePath)` から 3 階層上（リポジトリ直下）の `Tests/Fixtures`（Bundle のリソースは `.app` に写すと見つからないので使わない）。`make()` は `temporaryDirectory/autonote-tests-<UUID>` を作って返す
- [ ] **Step 4: 通過を確認** `swift test` → PASS（既存テストを含め全件）
- [ ] **Step 5: Commit** `git add Package.swift Sources Tests` → `git commit -m "chore: add AutoNoteTestSupport target and shared JSON coders"`

### Task 2: 共有する型（overview §3）
**Files:**
- Create: `Sources/AutoNoteCore/Model/` に `MeetingID.swift` `TimelineTime.swift` `Enums.swift`（Speaker, Language, Track, MeetingStatus, MeetingSource）`Utterance.swift`（Utterance, Transcript, Bookmark, PauseInterval, TrackFile）`Manifest.swift`（DeviceRef, Manifest）`MinutesOutput.swift`、`Sources/AutoNoteTestSupport/Samples.swift`
- Test: `Tests/AutoNoteCoreTests/Model/TimelineTimeTests.swift`、`ModelCodingTests.swift`

**Interfaces:**
- Consumes: `AutoNoteJSON`
- Produces（overview §3 の形。以下は本計画で決めた細部）:
  - `MeetingID`: `init(rawValue:)`、`static func make(start: Date, timeZone: TimeZone = .current, suffix: String = MeetingID.randomSuffix()) -> MeetingID`（`yyyyMMdd-HHmm-<suffix>`）、`static func randomSuffix() -> String`（小文字 hex 4 桁）。JSON は文字列 1 つ
  - `TimelineTime`（`Comparable` `Hashable`）: `init(seconds:)`、`init?(hhmmss:)`（`^\d{2,}:\d{2}:\d{2}$` かつ分・秒が 60 未満）、`static let zero`、`static func +`、`hhmmss` `anchor` `mmss`（秒は切り捨て、負は 0。`mmss` は 1 時間未満 `MM:SS`、以上 `H:MM:SS`）。JSON は数値 1 つ
  - `Speaker.displayName`（`自分` `相手` `不明`）。`MeetingStatus` の raw value は snake_case を明示（`minutesGenerated = "minutes_generated"`、`transcriptOnly = "transcript_only"`、`tooShort = "too_short"`、他は case 名）。frontmatter の `status` もこの値
  - `Transcript.fallbackEngineLabel(live: String) -> String` → `"<live>（確定版の失敗によりリアルタイム版で代用）"`（要件書 §6.4 の `transcript_engine`）。`Manifest.duration: Double?`（`endedAt - startedAt`）
  - `MinutesOutput { title; summary: [String]; decisions: [Decision]; agenda: [AgendaItem]; nextActions: [NextAction]; suggestedTerms: [String] }`、`Decision { text; t }`、`AgendaItem { title; body; t }`、`NextAction { text; owner: String?; due: String?; t }`。各 `t: String` に `var time: TimelineTime?`。`NextAction` は nil でも `owner` `due` に `null` を書く（スキーマで必須。`encode(to:)` を書く）
  - TestSupport: `public func u(_ seconds: Double, _ speaker: Speaker, _ text: String, end: Double? = nil) -> Utterance`（`isFinal: true`）、`Samples.tokyo`、`Samples.start`（`2026-10-24T05:00:00Z`＝東京 14:00）、`Samples.manifest`（id `20261024-1400-a1b2`、title nil、`endedAt = start + 62 分`、source live、device `DeviceRef(name: "Kestrel Headset 7", uid: "FAKE-KESTREL-0001:input", transport: "bluetooth")`、ja、tracks・pauses・bookmarks 空、status minutesGenerated、silenceWarning false、autonoteVersion `"0.1.0"`）、`Samples.minutes`（title `プロジェクト定例`、summary 1 行目 `リリースは来週に決定`、decision `t "00:12:34"`、agenda 1 件 `t "00:03:10"`、next action `ドキュメント更新` / `自分` / `10/31` / `t "00:40:02"`）

- [ ] **Step 1: Write the failing test**
```swift
@Test func formatsAndParsesTimelineTime() {
    let t = TimelineTime(seconds: 754.9)
    #expect(t.hhmmss == "00:12:34"); #expect(t.anchor == "t00-12-34"); #expect(t.mmss == "12:34")
    #expect(TimelineTime(seconds: 3910).mmss == "1:05:10"); #expect(TimelineTime(seconds: -2).hhmmss == "00:00:00")
    #expect((TimelineTime(seconds: 2) + TimelineTime(seconds: 170)).seconds == 172)
    #expect(TimelineTime(hhmmss: "00:40:02")?.seconds == 2402)
    #expect(TimelineTime(hhmmss: "00:61:00") == nil); #expect(TimelineTime(hhmmss: "12:34") == nil)
}
@Test func idAndTimeEncodeAsSingleValues() throws {
    let id = MeetingID.make(start: Samples.start, timeZone: Samples.tokyo, suffix: "a1b2")
    #expect(id.rawValue == "20261024-1400-a1b2"); #expect(MeetingID.randomSuffix().wholeMatch(of: /[0-9a-f]{4}/) != nil)
    #expect(String(decoding: try JSONEncoder().encode(id), as: UTF8.self) == #""20261024-1400-a1b2""#)
    #expect(String(decoding: try JSONEncoder().encode(TimelineTime(seconds: 1.5)), as: UTF8.self) == "1.5")
    #expect([Speaker.me, .other, .unknown].map(\.displayName) == ["自分", "相手", "不明"])
    #expect(Transcript.fallbackEngineLabel(live: "Dictation") == "Dictation（確定版の失敗によりリアルタイム版で代用）")
}
@Test func manifestRoundTripsWithSnakeCaseKeys() throws {
    var m = Samples.manifest
    m.tracks = [TrackFile(track: .mic, relativePath: "tracks/mic-000.wav", startOffset: .zero, durationSeconds: 150)]
    m.pauses = [PauseInterval(start: .init(seconds: 150), end: nil)]; m.bookmarks = [Bookmark(at: .init(seconds: 41.5), note: "価格の話")]
    let s = String(decoding: try AutoNoteJSON.encoder().encode(m), as: UTF8.self)
    for key in ["started_at", "relative_path", "start_offset", "silence_warning", "autonote_version"] { #expect(s.contains("\"\(key)\"")) }
    #expect(s.contains(#""status" : "minutes_generated""#))
    #expect(try AutoNoteJSON.decoder().decode(Manifest.self, from: Data(s.utf8)) == m)
}
@Test func minutesOutputMatchesSchemaShape() throws {
    let json = #"{"title":"定例","summary":["a","b","c"],"decisions":[{"text":"来週出す","t":"00:12:34"}],"agenda":[{"title":"判定","body":"本文","t":"00:03:10"}],"next_actions":[{"text":"更新","owner":null,"due":"10/31","t":"00:40:02"}],"suggested_terms":["ルミナ茶"]}"#
    let m = try AutoNoteJSON.decoder().decode(MinutesOutput.self, from: Data(json.utf8))
    #expect(m.nextActions[0].owner == nil); #expect(m.nextActions[0].due == "10/31"); #expect(m.decisions[0].time == TimelineTime(seconds: 754))
    let back = String(decoding: try AutoNoteJSON.encoder().encode(m), as: UTF8.self)
    #expect(back.contains(#""owner" : null"#)); #expect(back.contains(#""next_actions""#))
}
```
- [ ] **Step 2: 失敗を確認** `swift test` → FAIL（ビルドエラー: まだ無い型・関数を参照している）
- [ ] **Step 3: Implement** Interfaces どおり
- [ ] **Step 4: 通過を確認** `swift test` → PASS
- [ ] **Step 5: Commit** `git add Sources Tests` → `git commit -m "feat: add shared meeting model types"`

### Task 3: アプリ領域の保存（AppPaths、SettingsStore、ManifestStore）
**Files:**
- Create: `Sources/AutoNoteCore/Storage/AppPaths.swift` `Settings.swift` `SettingsStore.swift` `ManifestStore.swift`
- Test: `Tests/AutoNoteCoreTests/Storage/SettingsStoreTests.swift`、`ManifestStoreTests.swift`

**Interfaces:**
- Consumes: `Manifest` `MeetingID` `Language`、`AutoNoteJSON`
- Produces:
  - `public struct AppPaths: Sendable, Equatable { let root: URL; init(root: URL); static var standard: AppPaths }`（root は `~/Library/Application Support/AutoNote`）。プロパティ `settingsFile` `automationsFile` `recordingsDirectory` `queueJobsDirectory`（`queue/jobs`）`logsDirectory` `logFile`（`logs/autonote.log`）`portableMirrorDirectory`（`portable-mirror`）`vaultStateDirectory`（`vault-state`）`socketFile`（`autonote.sock`）。関数 `meetingDirectory(_:)`（`recordings/<id>`）`manifestFile(_:)` `tracksDirectory(_:)` `transcriptsDirectory(_:)`（`transcripts/<id>`）`transcriptFile(_: MeetingID, _: TranscriptKind) -> URL` `minutesFile(_:)`（`transcripts/<id>/minutes.json`。要件書 §14.4 の `AUTONOTE_JSON` の実体）`vaultStateFile(_:)`（`vault-state/<id>.json`）`createBaseDirectories() throws`
  - `public enum TranscriptKind: String { case live, raw, final }`（ファイル名 `<kind>.json`）
  - `public struct Settings: Codable, Equatable, Sendable`（下表。`init()` が既定値、`init(from:)` は全キー `decodeIfPresent`、`countdownSeconds` は 0〜30 に丸める）、`public struct Shortcuts`（同じく欠けたキーは既定）、`public enum SummarizerKind: String, Codable { case claudeCode = "claude_code" }`
  - `public actor SettingsStore { init(paths: AppPaths); func load() throws -> Settings; func save(_: Settings) throws; func update(_ body: @Sendable (inout Settings) -> Void) throws -> Settings; private(set) var lastSetAside: URL? }`。ファイルが無ければ既定値。JSON として読めなければ `settings.json.corrupt-<yyyyMMdd-HHmmss>` に改名し、`lastSetAside` に入れて既定値を返す
  - `public actor ManifestStore { init(paths: AppPaths); func save(_: Manifest) throws; func load(_: MeetingID) throws -> Manifest; func update(_: MeetingID, _ body: @Sendable (inout Manifest) -> Void) throws -> Manifest; func all() -> [Manifest]; func unfinishedRecordings() -> [Manifest]; func delete(_: MeetingID) throws }`。書き込みは会議フォルダを作って原子的に（`Data.write(options: .atomic)`）。`all()` は `startedAt` の新しい順で、読めない manifest は飛ばす。`unfinishedRecordings()` は status `recording`（計画 02 のクラッシュ復旧用）。`delete` は `recordings/<id>`・`transcripts/<id>`・`vault-state/<id>.json` を消す（要件書 §12 の会議単位削除のアプリ領域分）

| `Settings` のフィールド | 型 | 既定 | 根拠 |
|---|---|---|---|
| `outputFolder` | `String?`（絶対パス） | nil | §9.5 |
| `claudePath` / `claudeModel` | `String?` | nil（パスは計画 05 が起動時に探して埋める。モデル nil は Claude Code の既定） | §8.1 |
| `summarizer` | `SummarizerKind` | `.claudeCode` | §8.5 |
| `launchAtLogin` | `Bool` | true | §4.1・§15.3 |
| `defaultLanguage` | `Language` | `.ja` | §6.4 |
| `liveEngine` `liveModel` `finalEngine` `finalModel` | `String?` | nil（機種ごとの既定。計画 04 の EngineCatalog） | §6.2 |
| `voiceProcessing` / `fillerRemoval` | `Bool` | false / true | §5.6 / §6.5 |
| `countdownSeconds` / `disconnectGraceSeconds` | `Int` | 5（0〜30）/ 30 | §11.4 / §11.5 |
| `startOnModelMatch` | `Bool` | false（機材ごとの上書きは計画 03 の devices.json） | §11.2 |
| `audioRetentionDays` | `Int` | 30（0 は「削除しない」。null と欠落を区別しないため数値） | §12 |
| `shortcuts` | `Shortcuts { bookmark; toggleRecording; togglePause: String? }` | `"ctrl+option+b"` / nil / nil | §5.5・§15.3 |
| `consentNoticeShown` | `Bool` | false | §11.6 |

- [ ] **Step 1: Write the failing test**
```swift
@Test func partialSettingsAreFilledAndClamped() async throws {
    let p = AppPaths(root: try TemporaryDirectory.make()); try p.createBaseDirectories()
    #expect(try await SettingsStore(paths: p).load() == Settings())
    try Data(#"{"output_folder":"/v/Meetings","countdown_seconds":99,"shortcuts":{}}"#.utf8).write(to: p.settingsFile)
    let s = try await SettingsStore(paths: p).load()
    #expect(s.outputFolder == "/v/Meetings"); #expect(s.countdownSeconds == 30); #expect(s.fillerRemoval); #expect(s.shortcuts.bookmark == "ctrl+option+b")
    let store = SettingsStore(paths: p); let updated = try await store.update { $0.audioRetentionDays = 0 }
    #expect(try await store.load() == updated)
}
@Test func corruptSettingsAreSetAside() async throws {
    let p = AppPaths(root: try TemporaryDirectory.make()); try p.createBaseDirectories()
    try Data("{not json".utf8).write(to: p.settingsFile)
    let store = SettingsStore(paths: p)
    #expect(try await store.load() == Settings())
    #expect(try #require(await store.lastSetAside).lastPathComponent.hasPrefix("settings.json.corrupt-"))
    #expect(!FileManager.default.fileExists(atPath: p.settingsFile.path))
}
@Test func manifestSaveLoadUpdateDelete() async throws {
    let p = AppPaths(root: try TemporaryDirectory.make()); let store = ManifestStore(paths: p); let id = Samples.manifest.id
    try await store.save(Samples.manifest)
    let m = try await store.update(id) { $0.status = .recording }
    #expect(try await store.load(id) == m); #expect(await store.unfinishedRecordings().map(\.id) == [id])
    try await store.delete(id); #expect(!FileManager.default.fileExists(atPath: p.meetingDirectory(id).path))
    let r = AppPaths(root: URL(filePath: "/r"))
    #expect(r.manifestFile(id).path == "/r/recordings/20261024-1400-a1b2/manifest.json"); #expect(r.transcriptFile(id, .raw).path == "/r/transcripts/20261024-1400-a1b2/raw.json")
    #expect(r.vaultStateFile(id).path == "/r/vault-state/20261024-1400-a1b2.json")
}
@Test func allSkipsCorruptManifest() async throws {
    let p = AppPaths(root: try TemporaryDirectory.make()); let store = ManifestStore(paths: p)
    try await store.save(Samples.manifest)
    let broken = p.meetingDirectory(MeetingID(rawValue: "20261024-0900-ffff"))
    try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
    try Data("{".utf8).write(to: broken.appending(path: "manifest.json"))
    #expect(await store.all().map(\.id) == [Samples.manifest.id])
}
```
- [ ] **Step 2: 失敗を確認** `swift test` → FAIL（ビルドエラー: まだ無い型・関数を参照している）
- [ ] **Step 3: Implement** Interfaces と表どおり
- [ ] **Step 4: 通過を確認** `swift test` → PASS
- [ ] **Step 5: Commit** `git add Sources Tests` → `git commit -m "feat: add app paths, settings store and manifest store"`

### Task 4: 差し替え層の protocol 宣言とフェイク（overview §4）
**Files:**
- Create: `Sources/AutoNoteCore/Audio/Protocols.swift`、`Sources/AutoNoteCore/Transcription/Protocols.swift`、`Sources/AutoNoteCore/Minutes/Protocols.swift`、`Sources/AutoNoteTestSupport/Fakes.swift`
- Test: `Tests/AutoNoteCoreTests/FakesTests.swift`

**Interfaces:**
- Consumes: Task 2 の型、`AppPaths` `Settings` `ManifestStore`
- Produces（protocol は overview §4 の宣言そのまま。実装は計画 02・04・05）:
  - `public struct AudioChunk: Sendable, Equatable { static let sampleRate = 16_000.0; var track: Track; var samples: [Int16]; var start: TimelineTime; var hostTime: UInt64; var duration: Double { get } }`（16kHz・モノラル。`start` は会議タイムライン）
  - `public struct SummaryInput: Codable, Equatable, Sendable { var instructions: String; var terms: [String]; var bookmarks: [Bookmark]; var transcript: Transcript; var language: Language }`
  - `public enum StageName { static let transcribe = "transcribe", summarize = "summarize", writeVault = "write_vault", updateIndex = "update_index", automations = "automations"; static let all: [String] }`（この順）
  - `public enum JobState: String, Codable, Sendable { case pending, running, waiting, failed, done }`
  - `public struct Job: Codable, Equatable, Sendable { var id: String; var meeting: MeetingID; var stages: [String]; var completedStages: [String]; var state: JobState; var attempts: Int; var lastError: String?; var notBefore: Date?; var createdAt: Date; var nextStage: String? { get } }`（`nextStage` は未完了の最初の段階。再試行の規則は計画 05）
  - `public struct StageContext: Sendable { var paths: AppPaths; var settings: Settings; var manifests: ManifestStore; var now: @Sendable () -> Date; var reportProgress: @Sendable (Double) -> Void }`（計画 05 が足してよい）
  - TestSupport: `struct FakeError: Error, Equatable { var message: String }`、`actor CallLog { var entries: [String]; func append(_: String) }`、`actor FakeAudioSource(track:chunks:)`（`nonisolated let track`。`start` は台本の chunk を順に渡して返る。`stopCount`）、`actor FakeLiveTranscriber(script: [Utterance])`（`start` のストリームに台本を流す。`feed` は `fedChunks` に貯め、`finish` でストリームを閉じる。`startedWith: (Language, [String])?`）、`actor FakeBatchTranscriber(results: [String: [Utterance]], failure: FakeError? = nil)`（キーは `lastPathComponent`。progress に 0 と 1。`calls: [URL]`）、`actor FakeSummarizer(result: Result<MinutesOutput, FakeError>)`（`inputs`）、`struct FakeQueueStage(name:log:failure:)`（`run` で `log.append(name)`、failure があれば投げる）

- [ ] **Step 1: Write the failing test**
```swift
@Test func fakesFollowProtocols() async throws {
    let live: any LiveTranscriber = FakeLiveTranscriber(script: [u(1, .me, "a")])
    let stream = try await live.start(language: .ja, hints: ["ルミナ茶"])
    await live.feed(AudioChunk(track: .mic, samples: [0, 0], start: .zero, hostTime: 0)); await live.finish()
    var got: [String] = []; for await x in stream { got.append(x.text) }
    #expect(got == ["a"])
    let batch: any BatchTranscriber = FakeBatchTranscriber(results: ["mic-000.wav": [u(2, .me, "b")]])
    #expect(try await batch.transcribe(file: URL(filePath: "/x/mic-000.wav"), language: .ja, hints: []) { _ in }.map(\.text) == ["b"])
    let s = FakeSummarizer(result: .success(Samples.minutes))
    let input = SummaryInput(instructions: "x", terms: [], bookmarks: [], transcript: Transcript(utterances: [], engine: "e", language: .ja), language: .ja)
    #expect(try await s.summarize(input) == Samples.minutes); #expect(await s.inputs == [input])
}
@Test func fakeStageRunsAndJobRoundTrips() async throws {
    let log = CallLog(); let stage: any QueueStage = FakeQueueStage(name: StageName.summarize, log: log, failure: nil)
    var job = Job(id: "j1", meeting: Samples.manifest.id, stages: StageName.all, completedStages: ["transcribe"], state: .pending, attempts: 0, lastError: nil, notBefore: nil, createdAt: Samples.start)
    #expect(job.nextStage == "summarize")
    let paths = AppPaths(root: try TemporaryDirectory.make())
    try await stage.run(&job, context: StageContext(paths: paths, settings: Settings(), manifests: ManifestStore(paths: paths), now: { Samples.start }, reportProgress: { _ in }))
    #expect(await log.entries == ["summarize"])
    #expect(try AutoNoteJSON.decoder().decode(Job.self, from: AutoNoteJSON.encoder().encode(job)) == job)
}
```
- [ ] **Step 2: 失敗を確認** `swift test` → FAIL（ビルドエラー: まだ無い型・関数を参照している）
- [ ] **Step 3: Implement** Interfaces どおり（本物の実装は書かない）
- [ ] **Step 4: 通過を確認** `swift test` → PASS
- [ ] **Step 5: Commit** `git add Sources Tests` → `git commit -m "feat: declare engine protocols and add fakes"`

### Task 5: 辞書ファイル、置換、ヒントの上限（要件書 §7）
**Files:**
- Create: `Sources/AutoNoteCore/Dictionary/DictionaryFile.swift` `Replacer.swift` `HintBudget.swift`
- Test: `Tests/AutoNoteCoreTests/Dictionary/DictionaryFileTests.swift`、`ReplacerTests.swift`

**Interfaces:**
- Consumes: `Utterance`
- Produces:
  - `public struct Replacement: Codable, Equatable, Sendable { var from: String; var to: String }`、`public struct DictionaryIssue: Equatable, Sendable { var line: Int; var text: String; var reason: String }`（line は 1 始まり）
  - `public struct DictionaryFile: Equatable, Sendable { var terms: [String]; var replacements: [Replacement]; var fillers: [String]; static let defaultFillers = ["えー", "えーと", "あのー", "um", "uh"]; static let default: DictionaryFile; static var defaultMarkdown: String; static func parse(_ markdown: String) -> (dictionary: DictionaryFile, issues: [DictionaryIssue]); func render() -> String }`
  - `public struct Replacer: Sendable { init(_ rules: [Replacement]); func apply(_ text: String) -> String; func apply(_ utterances: [Utterance]) -> [Utterance] }`
  - `public enum HintBudget { static let whisperLimit = 224; static func estimateTokens(_ text: String) -> Int; static func fit(_ terms: [String], limit: Int = whisperLimit) -> (included: [String], dropped: [String]) }`

読み取り規則（§7.2）:
- 見出し `## 用語` `## 置換` `## フィラー`（`##` の後を trim して比較）。他の見出しの下と最初の見出しより前は読まない
- 項目は先頭の空白を除いて `- ` か `* ` で始まる行。本文を trim し空なら飛ばす。項目でない行は黙って飛ばす。用語・フィラーの重複は最初だけ残す
- 置換は最初の `=>` で分けて両辺を trim。`=>` が無い・どちらかが空なら `DictionaryIssue(reason: "置換は「誤 => 正」の形で書く")` でその行を捨てる。同じ `from` の二つ目も issue（最初を使う）
- `## フィラー` 節が無ければ `defaultFillers`、節があって空なら空
- `render()` は §7.2 の例の形（三節この順、節の間に空行 1 つ、空の節は見出しだけ）。`parse(render(d)).dictionary == d`

置換: `from` の長い順に、左から一度だけ走査し、各位置で一致する最長の `from` を置き換えてその直後から続ける（置き換えた結果を再び置換しない）。大文字小文字は区別する。

トークン数の近似（whisper の BPE を安全側に）: ASCII 英数字の連続は `ceil(長さ / 4)`、空白は 0、他の ASCII 文字は 1、非 ASCII の Unicode scalar は 1 つにつき 2。`fit` は用語を `", "` でつなぐ前提で区切り 1 つに 1 を足し、先頭から入れて最初に溢れた語で打ち切る（以降は小さくても入れない。§7.2「先頭から収まる分だけ」）。

- [ ] **Step 1: Write the failing test**
```swift
private let specExample = "## 用語\n- AutoNote\n- 所沢\n- Kubernetes\n\n## 置換\n- オートノート => AutoNote\n- クーバネティス => Kubernetes\n\n## フィラー\n- えー\n- えーと\n"
@Test func parsesAndRendersSpecExample() {
    let (d, issues) = DictionaryFile.parse(specExample)
    #expect(d.terms == ["AutoNote", "所沢", "Kubernetes"]); #expect(d.fillers == ["えー", "えーと"]); #expect(issues.isEmpty)
    #expect(d.replacements == [.init(from: "オートノート", to: "AutoNote"), .init(from: "クーバネティス", to: "Kubernetes")])
    #expect(d.render() == specExample)
}
@Test func reportsBrokenReplacementLines() {
    let (d, issues) = DictionaryFile.parse("## 置換\n- 矢印なし\n- => 右だけ\n- 左だけ =>\n- a => b => c\n- a => z\n")
    #expect(d.replacements == [.init(from: "a", to: "b => c")]); #expect(issues.map(\.line) == [2, 3, 4, 6])
}
@Test func sectionsAndProse() {
    #expect(DictionaryFile.parse("## 用語\n- X\n").dictionary.fillers == DictionaryFile.defaultFillers)
    #expect(DictionaryFile.parse("## フィラー\n").dictionary.fillers == [])
    #expect(DictionaryFile.parse("メモ\n- 前\n## その他\n- x\n## 用語\n説明文\n  * Y\n- Y\n").dictionary.terms == ["Y"])
}
@Test func replacerAndHintBudget() {
    let r = Replacer([.init(from: "ノート", to: "Note"), .init(from: "オートノート", to: "AutoNote"), .init(from: "A", to: "B"), .init(from: "B", to: "C")])
    #expect(r.apply("オートノートのノート") == "AutoNoteのNote"); #expect(r.apply("A") == "B")
    #expect(HintBudget.estimateTokens("Kubernetes") == 3); #expect(HintBudget.estimateTokens("所沢") == 4); #expect(HintBudget.estimateTokens("AutoNote v2") == 3)
    #expect(HintBudget.fit(Array(repeating: "所沢市役所", count: 30)).included.count == 20)
    let long = String(repeating: "長", count: 200); let h = HintBudget.fit(["短い", long, "次"])
    #expect(h.included == ["短い"]); #expect(h.dropped == [long, "次"])
}
```
- [ ] **Step 2: 失敗を確認** `swift test` → FAIL（ビルドエラー: まだ無い型・関数を参照している）
- [ ] **Step 3: Implement** 上の規則どおり
- [ ] **Step 4: 通過を確認** `swift test` → PASS
- [ ] **Step 5: Commit** `git add Sources Tests` → `git commit -m "feat: add dictionary file, replacer and hint budget"`

### Task 6: フィラー除去（要件書 §6.5）
**Files:**
- Create: `Sources/AutoNoteCore/Dictionary/FillerRemover.swift`
- Test: `Tests/AutoNoteCoreTests/Dictionary/FillerRemoverTests.swift`

**Interfaces:**
- Consumes: `Utterance`、`DictionaryFile.fillers`
- Produces: `public struct FillerRemover: Sendable { init(fillers: [String]); func clean(_ text: String) -> String; func clean(_ utterances: [Utterance]) -> [Utterance] }`（空になった発話は捨てる。他のフィールドはそのまま）

規則（部分一致では消さない）:
- 区切り: 読点類 `、` `，` `,`、句点類 `。` `．` `.` `!` `?` `！` `？`、空白（U+3000 を含む）。本文を「語」と「区切りの連続」に分ける。比較は ASCII の大文字小文字を無視する
- 発話全体: 区切りを除いた残りがフィラーの連結だけで書ける（例 `えーえーと`）なら空にする
- 独立した語: フィラーに完全一致する語を消す。直後の区切りに句点類が無ければ直後の区切りも消す。句点類があれば直前の区切り（あれば）を消して句点は残す
- 最後に前後の空白を trim。区切りしか残らなければ空

- [ ] **Step 1: Write the failing test**
```swift
@Test(arguments: [
    ("えー、来週リリースします。", "来週リリースします。"), ("それで えーと 来週です", "それで 来週です"), ("そうです、えー。", "そうです。"),
    ("えーとですね、はい", "えーとですね、はい"), ("あのー人に聞きます", "あのー人に聞きます"), ("um, I think so.", "I think so."),
    ("Uh", ""), ("えー。えーと。", ""), ("えーえーと", ""), ("umbrella を持参", "umbrella を持参"),
])
func cleans(_ c: (String, String)) { #expect(FillerRemover(fillers: DictionaryFile.defaultFillers).clean(c.0) == c.1) }
@Test func dropsEmptiedUtterances() {
    let out = FillerRemover(fillers: ["えー"]).clean([u(1, .me, "えー。"), u(2, .me, "えー、はい")])
    #expect(out.map(\.text) == ["はい"]); #expect(out[0].start.seconds == 2)
}
```
- [ ] **Step 2: 失敗を確認** `swift test` → FAIL（ビルドエラー: まだ無い型・関数を参照している）
- [ ] **Step 3: Implement** 上の規則どおり
- [ ] **Step 4: 通過を確認** `swift test` → PASS
- [ ] **Step 5: Commit** `git add Sources Tests` → `git commit -m "feat: add filler remover"`

### Task 7: トラック結合、重複除去、確定版の組み立て（要件書 §5.4・§5.6・§6.4）
**Files:**
- Create: `Sources/AutoNoteCore/Transcript/TranscriptMerger.swift` `EchoDeduplicator.swift` `TranscriptFinalizer.swift`
- Test: `Tests/AutoNoteCoreTests/Transcript/TranscriptMergerTests.swift`、`EchoDeduplicatorTests.swift`

**Interfaces:**
- Consumes: `TrackFile` `Utterance` `Transcript` `MeetingSource`、`DictionaryFile` `Replacer` `FillerRemover`
- Produces:
  - `public struct TrackTranscription: Codable, Equatable, Sendable { var file: TrackFile; var utterances: [Utterance] }`（utterances はファイル内の相対時刻。分割ファイルごとでも結合ファイル 1 つでもよい）
  - `public enum TranscriptMerger { static func merge(_ parts: [TrackTranscription], source: MeetingSource) -> [Utterance] }`: `start`・`end` に `file.startOffset` を足し、話者を `mic → .me`・`system → .other`（`source == .imported` なら全部 `.unknown`）にして `start` 昇順（同時刻は mic が先、同じトラック内は元の順）
  - `public struct EchoDeduplicator: Sendable { struct Configuration: Sendable { var window = 3.0; var similarityThreshold = 0.8; var minimumLength = 4; var containmentMinimumLength = 6; static let standard }; init(configuration: Configuration = .standard); func deduplicate(_ utterances: [Utterance]) -> [Utterance]; static func normalize(_ text: String) -> String; static func similarity(_ a: String, _ b: String) -> Double }`
  - `public struct TranscriptFinalizer: Sendable { init(dictionary: DictionaryFile, fillerRemoval: Bool, deduplicator: EchoDeduplicator = .init()); func finalize(_ parts: [TrackTranscription], source: MeetingSource, engine: String, language: Language) -> (raw: Transcript, final: Transcript) }`: raw ＝ 結合 → 重複除去（アプリ領域の `raw.json`。§6.5「除去前の生テキスト」）。final ＝ raw → 置換 → フィラー除去（`fillerRemoval` のときだけ）（`final.json` と Vault）

重複除去の規則（§5.6 の閾値を本計画で決める）:
- `normalize`: NFKC → 小文字 → 空白と句読点・記号（Unicode の P・S 類）を除く。`similarity` は `1 - 編集距離 / max(長さ)`（Character 単位、両方空なら 0。2 行の動的計画法）
- 「自分」の発話 m について、区間 `[m.start - 3, (m.end ?? m.start) + 3]` と `[o.start, o.end ?? o.start]` が重なる「相手」の発話 o を候補にする
- 正規化後の m が 4 文字未満なら捨てない（相づちの「はい」を守る）
- いずれかの候補と `similarity ≥ 0.8`、または m が 6 文字以上で候補の本文を時刻順に連結した正規化文字列に含まれるなら m を捨てる。「相手」と「不明」は捨てない

- [ ] **Step 1: Write the failing test**
```swift
private func part(_ track: Track, _ path: String, _ offset: Double, _ us: [Utterance]) -> TrackTranscription {
    TrackTranscription(file: TrackFile(track: track, relativePath: path, startOffset: .init(seconds: offset), durationSeconds: nil), utterances: us)
}
@Test func mergeShiftsByStartOffsetAndSorts() {
    let merged = TranscriptMerger.merge([part(.mic, "tracks/mic-001.wav", 170, [u(2, .unknown, "c", end: 4)]),
                                         part(.mic, "tracks/mic-000.wav", 0, [u(5, .unknown, "a")]),
                                         part(.system, "tracks/system-000.wav", 0, [u(5, .unknown, "b")])], source: .live)
    #expect(merged.map(\.text) == ["a", "b", "c"]); #expect(merged.map(\.speaker) == [.me, .other, .me])
    #expect(merged[2].start.seconds == 172); #expect(merged[2].end?.seconds == 174)
    #expect(TranscriptMerger.merge([part(.mic, "tracks/import-000.wav", 0, [u(1, .me, "x")])], source: .imported)[0].speaker == .unknown)
}
@Test func dropsEchoesButKeepsBackchannelAndOutsideWindow() {
    let d = EchoDeduplicator(); #expect(d.deduplicate([u(10, .other, "来週の金曜にルミナ茶を発売します", end: 14), u(10.8, .me, "来週の金曜にルミナちゃを発売します", end: 14.5)]).map(\.speaker) == [.other])
    #expect(d.deduplicate([u(30, .other, "それでは価格について説明します", end: 33), u(31, .me, "価格について説明")]).map(\.speaker) == [.other])
    let out = d.deduplicate([u(10, .other, "了解しました", end: 11), u(10.1, .other, "はい"), u(10.2, .me, "はい"), u(20, .me, "了解しました")])
    #expect(out.filter { $0.speaker == .me }.map(\.text) == ["はい", "了解しました"])
    #expect(EchoDeduplicator.normalize("Hello、 World！") == "helloworld"); #expect(EchoDeduplicator.similarity("abcd", "abce") == 0.75)
}
@Test func finalizerKeepsRawAndCleansFinal() {
    let dict = DictionaryFile(terms: [], replacements: [.init(from: "ルミナちゃ", to: "ルミナ茶")], fillers: ["えーと"])
    let parts = [part(.mic, "tracks/mic-000.wav", 0, [u(20, .unknown, "えーと、ルミナちゃの在庫は十分ですか。")])]
    let (raw, final) = TranscriptFinalizer(dictionary: dict, fillerRemoval: true).finalize(parts, source: .live, engine: "whisper.cpp large-v3-turbo", language: .ja)
    #expect(raw.utterances[0].text == "えーと、ルミナちゃの在庫は十分ですか。"); #expect(final.utterances[0].text == "ルミナ茶の在庫は十分ですか。")
    #expect(final.engine == "whisper.cpp large-v3-turbo")
    #expect(TranscriptFinalizer(dictionary: dict, fillerRemoval: false).finalize(parts, source: .live, engine: "e", language: .ja).final.utterances[0].text == "えーと、ルミナ茶の在庫は十分ですか。")
}
```
- [ ] **Step 2: 失敗を確認** `swift test` → FAIL（ビルドエラー: まだ無い型・関数を参照している）
- [ ] **Step 3: Implement** 上の規則どおり
- [ ] **Step 4: 通過を確認** `swift test` → PASS
- [ ] **Step 5: Commit** `git add Sources Tests` → `git commit -m "feat: merge tracks on meeting timeline and drop echoed utterances"`

### Task 8: ファイル名と frontmatter テンプレート（要件書 §8.4・§9.1・§9.2）
**Files:**
- Create: `Sources/AutoNoteCore/Vault/MeetingFileName.swift` `FrontmatterTemplate.swift`
- Test: `Tests/AutoNoteCoreTests/Vault/MeetingFileNameTests.swift`、`FrontmatterTemplateTests.swift`

**Interfaces:**
- Consumes: `Manifest` `MeetingStatus`
- Produces:
  - `public enum MeetingFileName { static let maxTitleLength = 60; static func titled(start: Date, title: String, timeZone: TimeZone) -> String; static func untitled(start: Date, timeZone: TimeZone) -> String; static func yearFolder(start: Date, timeZone: TimeZone) -> String; static func sanitize(_ title: String) -> String; static func isUntitled(_ fileName: String) -> Bool; static func unique(_ fileName: String, exists: (String) -> Bool) -> String }`
  - `public struct FrontmatterTemplate: Sendable { static let requiredKeys = ["title", "date", "status", "autonote_id"]; static let defaultText: String; init(text: String); func render(_ values: [String: String]) -> String; static func values(manifest: Manifest, title: String, transcriptEngine: String, appVersion: String, timeZone: TimeZone) -> [String: String]; static func yamlScalar(_ value: String) -> String }`

ファイル名:
- `titled` → `YYYY-MM-DD_HHMM_<sanitize(title)>.md`、`untitled` → `YYYY-MM-DD_HHMMSS.md`（§8.4）、`yearFolder` → `YYYY`。日付は `DateFormatter`（`en_US_POSIX`、渡された timeZone）
- `sanitize` の置換表（ファイル名と Obsidian のリンクで使えない文字を全角に）: `/`→`／` `\`→`＼` `:`→`：` `*`→`＊` `?`→`？` `"`→`”` `<`→`＜` `>`→`＞` `|`→`｜` `#`→`＃` `^`→`＾` `[`→`［` `]`→`］`。改行・タブ・制御文字は空白、連続する空白は 1 つ、前後の空白と `.` を除く（先頭の `.` は隠しファイルになる）。60 文字を超えたら先頭 60 文字。空なら `無題`
- `isUntitled`: `^\d{4}-\d{2}-\d{2}_\d{6}(-\d+)?\.md$`。`unique`: `exists` が true の間、拡張子の前に `-2` `-3` … を付ける

frontmatter:
- `defaultText`（この 11 行そのまま。`---` は含めない。要件書 §9.2 の例と同じ並び）:
```
title: {{title}}
date: {{date}}
start: "{{start}}"
end: "{{end}}"
duration_min: {{duration_min}}
tags: [meeting]
device: "{{device}}"
transcript_engine: "{{transcript_engine}}"
status: {{status}}
autonote_id: {{autonote_id}}
autonote: "{{autonote}}"
```
- 変数: `title` `date`（YYYY-MM-DD）`start` `end`（HH:MM。endedAt nil なら空）`duration_min`（分を四捨五入。nil なら空）`device`（`manifest.device?.name ?? ""`。取り込みは `import`）`transcript_engine` `status`（raw value）`autonote_id` `autonote`（appVersion）`language`。未知の `{{x}}` は空文字
- 差し込み: `"{{x}}"` のように引用符の中にある変数は、改行を空白にして `\` `"` を `\\` `\"` に逃がす。引用符の外の変数は `yamlScalar` を通す
- `yamlScalar`: 改行を空白にしたうえで、空・前後に空白・先頭が `- ? : , [ ] { } # & * ! | > ' " % @` か backtick・`: ` か ` #` を含む・小文字にして `true false yes no on off null ~` のどれか、なら `"` で囲んで `\` `"` を逃がす。他はそのまま
- テンプレートの先頭・末尾の `---` 行は除く。差し込み後、行頭 `^([A-Za-z0-9_]+):` で拾ったキーに `requiredKeys` が欠けていれば `key: yamlScalar(値)` をこの順で末尾に足す（§9.2「消しても必ず付ける」）。`render` は `"---\n" + 本体 + "\n---\n"`

- [ ] **Step 1: Write the failing test**
```swift
@Test func fileNames() {
    #expect(MeetingFileName.titled(start: Samples.start, title: "プロジェクト定例", timeZone: Samples.tokyo) == "2026-10-24_1400_プロジェクト定例.md")
    #expect(MeetingFileName.untitled(start: Samples.start, timeZone: Samples.tokyo) == "2026-10-24_140000.md")
    #expect(MeetingFileName.isUntitled("2026-10-24_140000-2.md")); #expect(!MeetingFileName.isUntitled("2026-10-24_1400_x.md"))
    #expect(MeetingFileName.unique("x.md") { ["x.md", "x-2.md"].contains($0) } == "x-3.md")
}
@Test func sanitizeReplacesForbiddenCharacters() {
    #expect(MeetingFileName.sanitize(#"A/B:C|D#E^F[G]H?*"<>\"#) == "A／B：C｜D＃E＾F［G］H？＊”＜＞＼")
    #expect(MeetingFileName.sanitize("  ..改行\nあり.. ") == "改行 あり"); #expect(MeetingFileName.sanitize("") == "無題")
    #expect(MeetingFileName.sanitize(String(repeating: "あ", count: 61)).count == 60)
}
@Test func defaultTemplateMatchesSpecExample() {
    let v = FrontmatterTemplate.values(manifest: Samples.manifest, title: "プロジェクト定例", transcriptEngine: "whisper.cpp large-v3-turbo", appVersion: "0.1.0", timeZone: Samples.tokyo)
    let expected = ["---", "title: プロジェクト定例", "date: 2026-10-24", #"start: "14:00""#, #"end: "15:02""#, "duration_min: 62", "tags: [meeting]", #"device: "Kestrel Headset 7""#,
                    #"transcript_engine: "whisper.cpp large-v3-turbo""#, "status: minutes_generated", "autonote_id: 20261024-1400-a1b2", #"autonote: "0.1.0""#, "---", ""]
    #expect(FrontmatterTemplate(text: FrontmatterTemplate.defaultText).render(v) == expected.joined(separator: "\n"))
}
@Test func requiredKeysAreRestored() {
    let out = FrontmatterTemplate(text: "---\ntags: [meeting]\n---\n").render(["title": "定例", "date": "2026-10-24", "status": "transcript_only", "autonote_id": "20261024-1400-a1b2"])
    #expect(out == "---\ntags: [meeting]\ntitle: 定例\ndate: 2026-10-24\nstatus: transcript_only\nautonote_id: 20261024-1400-a1b2\n---\n")
}
@Test func escapesHostileTitle() {
    let out = FrontmatterTemplate(text: "title: {{title}}\ndevice: \"{{device}}\"").render(["title": #"Q3: "予算" #1"#, "device": #"A"B"#])
    #expect(out.contains(#"title: "Q3: \"予算\" #1""#)); #expect(out.contains(#"device: "A\"B""#))
    #expect(FrontmatterTemplate.yamlScalar("yes") == #""yes""#); #expect(FrontmatterTemplate.yamlScalar("プロジェクト定例") == "プロジェクト定例")
    #expect(FrontmatterTemplate.yamlScalar("一行目\n二行目") == "一行目 二行目")
}
```
- [ ] **Step 2: 失敗を確認** `swift test` → FAIL（ビルドエラー: まだ無い型・関数を参照している）
- [ ] **Step 3: Implement** 上の規則どおり
- [ ] **Step 4: 通過を確認** `swift test` → PASS
- [ ] **Step 5: Commit** `git add Sources Tests` → `git commit -m "feat: add meeting file names and frontmatter template"`

### Task 9: 文字起こし節と会議ファイル（要件書 §9.2）
**Files:**
- Create: `Sources/AutoNoteCore/Transcript/TranscriptMarkdown.swift`、`Sources/AutoNoteCore/Vault/MeetingDocument.swift`
- Test: `Tests/AutoNoteCoreTests/Transcript/TranscriptMarkdownTests.swift`、`Tests/AutoNoteCoreTests/Vault/MeetingDocumentTests.swift`

**Interfaces:**
- Consumes: Task 2 の型、`FrontmatterTemplate` `MeetingFileName`
- Produces:
  - `public enum TranscriptMarkdown { static func anchors(for: [Utterance]) -> [String]; static func linkTarget(for time: TimelineTime, utterances: [Utterance], anchors: [String]) -> String?; static func render(_ utterances: [Utterance], pauses: [PauseInterval]) -> String }`
  - `public struct MeetingDocument: Sendable { let manifest: Manifest; let transcript: Transcript; let minutes: MinutesOutput?; let timeZone: TimeZone; init(manifest:transcript:minutes:frontmatter: FrontmatterTemplate, appVersion: String, timeZone: TimeZone); var title: String; var hasTitle: Bool; var preferredFileName: String; var yearFolder: String; func render() -> String; static func link(_ time: TimelineTime, anchor: String?) -> String }`

規則:
- `anchors`: 各発話の `start.anchor`。同じ値が前にあれば `-2` `-3` … を付ける。`linkTarget`: `start ≤ time` の最後の発話のアンカー、無ければ最初の発話、発話が無ければ nil
- `link` → `[[#^<anchor>|<time.mmss>]]`（表示はもらった時刻、飛び先は解決したアンカー。anchor nil なら `time.mmss` だけ）。`t` が `TimelineTime(hhmmss:)` で読めなければリンクを付けない
- 発話の段落 `**[<hhmmss>] <displayName>**: <本文> ^<anchor>`、段落の間は空行 1 つ。一時停止は `pause.start` 以降に始まる最初の発話の前に段落 `── 一時停止 <start.hhmmss>〜<end.hhmmss> ──`（end nil なら `〜 ──`）（§5.4）
- `title` ＝ `manifest.title ?? minutes?.title ?? "<YYYY-MM-DD HH:MM> の会議"`。`hasTitle` は前二つのどちらかがあるとき。`preferredFileName` は status が `transcriptOnly` か `!hasTitle` なら `untitled`、他は `titled(title)`
- 本文（節の間は空行 1 つ）: frontmatter（`transcript_engine` は `transcript.engine`）、`# <title>`。minutes があれば `## 3行要約`（`- ` 3 行）`## 決定事項`（`- <text> <link>`）`## 議題`（`### <n>. <title>` の次の行に `<body> <link>`、議題の間は空行）`## Next Action`（`| 内容 | 担当 | 期限 | 出典 |` `|---|---|---|---|`、nil は `—`、セル内の `|` は `\|`、出典は `[[#^a\|mm:ss]]`）。0 件の節は `- なし`。minutes が無ければ代わりに `> 議事録は未生成です。` + `` `autonote regenerate <id>` `` + `で作り直せます。` の 1 行。続けて `## ブックマーク`（`- <link>`、メモがあれば空白＋メモ。0 件は `- なし`）、`## 文字起こし`、空行、`TranscriptMarkdown.render`

- [ ] **Step 1: Write the failing test**
```swift
@Test func anchorsAreUniquePerSecond() { #expect(TranscriptMarkdown.anchors(for: [u(40.0, .other, "a"), u(40.6, .me, "b"), u(60, .me, "c")]) == ["t00-00-40", "t00-00-40-2", "t00-01-00"]) }
@Test func linkTargetFallsBackToPreviousUtterance() {
    let us = [u(5, .me, "a"), u(12, .other, "b"), u(30, .me, "c")]; let a = TranscriptMarkdown.anchors(for: us)
    #expect(TranscriptMarkdown.linkTarget(for: .init(seconds: 20), utterances: us, anchors: a) == "t00-00-12")
    #expect(TranscriptMarkdown.linkTarget(for: .init(seconds: 2), utterances: us, anchors: a) == "t00-00-05")
    #expect(TranscriptMarkdown.linkTarget(for: .zero, utterances: [], anchors: []) == nil)
    #expect(MeetingDocument.link(.init(seconds: 21), anchor: "t00-00-12") == "[[#^t00-00-12|00:21]]")
}
@Test func rendersParagraphsAndPause() {
    #expect(TranscriptMarkdown.render([u(5, .me, "a"), u(200, .other, "b\nc")], pauses: [PauseInterval(start: .init(seconds: 150), end: .init(seconds: 170))]) ==
        "**[00:00:05] 自分**: a ^t00-00-05\n\n── 一時停止 00:02:30〜00:02:50 ──\n\n**[00:03:20] 相手**: b c ^t00-03-20\n")
}
private func doc(_ minutes: MinutesOutput?, status: MeetingStatus = .minutesGenerated, title: String? = nil) -> MeetingDocument {
    var m = Samples.manifest; m.status = status; m.title = title; m.bookmarks = [Bookmark(at: .init(seconds: 1215), note: "大事")]
    return MeetingDocument(manifest: m, transcript: Transcript(utterances: [u(5, .me, "はじめます"), u(754, .other, "来週出します")], engine: "whisper.cpp large-v3-turbo", language: .ja),
                           minutes: minutes, frontmatter: .init(text: FrontmatterTemplate.defaultText), appVersion: "0.1.0", timeZone: Samples.tokyo)
}
@Test func documentHasSectionsInOrder() throws {
    let s = doc(Samples.minutes).render()
    let pos = try ["# プロジェクト定例", "## 3行要約", "## 決定事項", "## 議題", "## Next Action", "## ブックマーク", "## 文字起こし"].map { try #require(s.range(of: "\n\($0)\n")).lowerBound }
    #expect(pos == pos.sorted()); #expect(s.contains("- [[#^t00-12-34|20:15]] 大事"))
    #expect(s.contains("| ドキュメント更新 | 自分 | 10/31 | [[#^t00-12-34\\|40:02]] |")); #expect(s.hasSuffix("^t00-12-34\n"))
    var mins = Samples.minutes; mins.nextActions = [.init(text: "A|B 比較", owner: nil, due: nil, t: "00:00:06")]
    #expect(doc(mins).render().contains("| A\\|B 比較 | — | — | [[#^t00-00-05\\|00:06]] |"))
}
@Test func transcriptOnlyOmitsMinutesSections() {
    let d = doc(nil, status: .transcriptOnly); let s = d.render()
    #expect(!s.contains("## 3行要約")); #expect(s.contains("> 議事録は未生成です。`autonote regenerate 20261024-1400-a1b2` で作り直せます。\n"))
    #expect(s.contains("status: transcript_only")); #expect(s.contains("\n# 2026-10-24 14:00 の会議\n"))
    #expect(d.preferredFileName == "2026-10-24_140000.md")
    #expect(doc(Samples.minutes, title: "改名後").title == "改名後"); #expect(doc(Samples.minutes).preferredFileName == "2026-10-24_1400_プロジェクト定例.md")
}
```
- [ ] **Step 2: 失敗を確認** `swift test` → FAIL（ビルドエラー: まだ無い型・関数を参照している）
- [ ] **Step 3: Implement** 上の規則どおり
- [ ] **Step 4: 通過を確認** `swift test` → PASS
- [ ] **Step 5: Commit** `git add Sources Tests` → `git commit -m "feat: render meeting markdown with block anchors"`

### Task 10: 一覧ファイル `_index.md` と Vault の走査（要件書 §9.3・§9.5）
**Files:**
- Create: `Sources/AutoNoteCore/Vault/Frontmatter.swift` `IndexFile.swift` `VaultScanner.swift`
- Test: `Tests/AutoNoteCoreTests/Vault/IndexFileTests.swift`、`VaultScannerTests.swift`

**Interfaces:**
- Consumes: `MeetingDocument`、`MeetingID`
- Produces:
  - `public enum Frontmatter { static func parse(_ document: String) -> [String: String]? }`（先頭が `---\n` のときだけ、次の `---` 行までのトップレベル `key: value`。ダブルクォートの値は外して `\"` `\\` を戻す。無ければ nil）
  - `public struct IndexEntry: Equatable, Sendable { var meetingID: MeetingID; var date: String; var start: String; var title: String; var durationMinutes: Int?; var firstLine: String; var status: String; var linkPath: String }`（`linkPath` は出力フォルダからの相対パスで拡張子なし）
  - `public enum IndexFile { static let guide: String; static func render(_ entries: [IndexEntry]) -> String }`、`public enum VaultScanner { static func scan(outputFolder: URL) throws -> [IndexEntry]; static func locate(_ id: MeetingID, in outputFolder: URL) throws -> [URL] }`

規則:
- `render`: `# 会議一覧`、空行、`guide`、空行、表。見出し `| 日付 | 時刻 | タイトル | 長さ | 一行目 | ファイル |` と `|---|---|---|---|---|---|`、行 `| <date> | <start> | <title> | <n> 分 | <firstLine> | [[<linkPath>]] |`（長さ nil は `—`、title と firstLine の `|` は `\|`）。`date + start` の新しい順、同じなら `linkPath` の降順
- `guide`（この 5 行そのまま。§9.3「Claude Code への案内」）:
```
> **Claude Code への案内**（AutoNote が自動で書き直す。手で編集しても次の更新で消える）
> - このフォルダは会議の記録で、一会議一ファイル。`YYYY/YYYY-MM-DD_HHMM_<タイトル>.md`（議事録未生成は `YYYY/YYYY-MM-DD_HHMMSS.md`）に置いてある。`_autonote/` はアプリの設定なので読まなくてよい
> - 各ファイルは frontmatter（title, date, start, end, duration_min, status, autonote_id など）の後に「3行要約」「決定事項」「議題」「Next Action」「ブックマーク」「文字起こし」の節が続く。status が transcript_only のファイルは議事録の節が無い
> - 文字起こしは一発話一段落の `**[HH:MM:SS] 話者**: 本文 ^tHH-MM-SS`。話者は 自分 / 相手 / 不明。議事録中の `[[#^tHH-MM-SS|MM:SS]]` はその発言へのリンクで、時刻の文字列で検索すれば該当行に行ける
> - 下の表は新しい順の一覧。まずここで日付とタイトルから対象を絞り、該当ファイルの必要な節だけを読む
```
- `scan`: 再帰的に歩き、`_autonote/`・`.` で始まるフォルダ・`_index.md`・`.md` 以外を飛ばす。frontmatter に `autonote_id` があるファイルだけ拾う（利用者のメモは無視）。`title` `date` `start` `duration_min` `status` は frontmatter から、`firstLine` は `## 3行要約` の後の最初の `- ` 行から。無ければ status が `transcript_only` のとき `（議事録未生成）`、他は空。`locate` は同じ走査で `autonote_id` が一致するファイル（複製されていれば複数）

- [ ] **Step 1: Write the failing test**
```swift
private let e1 = IndexEntry(meetingID: .init(rawValue: "20261024-1400-a1b2"), date: "2026-10-24", start: "14:00", title: "プロジェクト定例", durationMinutes: 62,
                            firstLine: "リリースは来週に決定", status: "minutes_generated", linkPath: "2026/2026-10-24_1400_プロジェクト定例")
@Test func indexHeadingGuideAndRowsNewestFirst() {
    #expect(IndexFile.render([]).hasPrefix("# 会議一覧\n\n> **Claude Code への案内**")); #expect(IndexFile.guide.split(separator: "\n").count == 5)
    var e2 = e1; e2.date = "2026-10-25"; e2.start = "09:30"; e2.durationMinutes = nil; e2.linkPath = "2026/2026-10-25_093015"
    #expect(IndexFile.render([e1, e2]).split(separator: "\n").filter { $0.hasPrefix("| 2026") } == [
        "| 2026-10-25 | 09:30 | プロジェクト定例 | — | リリースは来週に決定 | [[2026/2026-10-25_093015]] |",
        "| 2026-10-24 | 14:00 | プロジェクト定例 | 62 分 | リリースは来週に決定 | [[2026/2026-10-24_1400_プロジェクト定例]] |"])
}
@Test func indexEscapesPipeInTitle() { var e = e1; e.title = "A|B"; #expect(IndexFile.render([e]).contains("| A\\|B |")) }
@Test func frontmatterParseUnquotes() {
    #expect(Frontmatter.parse("---\ntitle: \"Q3: \\\"予算\\\"\"\nautonote_id: x\n---\n# h\n") == ["title": "Q3: \"予算\"", "autonote_id": "x"])
    #expect(Frontmatter.parse("# no frontmatter\n") == nil)
}
@Test func scannerReadsMeetingFilesOnly() throws {
    let v = try TemporaryDirectory.make(); let fm = FileManager.default
    let d = MeetingDocument(manifest: Samples.manifest, transcript: Transcript(utterances: [], engine: "e", language: .ja), minutes: Samples.minutes,
                            frontmatter: .init(text: FrontmatterTemplate.defaultText), appVersion: "0.1.0", timeZone: Samples.tokyo)
    for dir in ["2026", "notes", "_autonote"] { try fm.createDirectory(at: v.appending(path: dir), withIntermediateDirectories: true) }
    for (path, text) in [("2026/\(d.preferredFileName)", d.render()), ("notes/own.md", "# 自分のメモ\n"), ("_autonote/copy.md", d.render()), ("_index.md", "# 会議一覧\n")] { try text.write(to: v.appending(path: path), atomically: true, encoding: .utf8) }
    #expect(try VaultScanner.scan(outputFolder: v) == [e1])
    #expect(try VaultScanner.locate(Samples.manifest.id, in: v).map(\.lastPathComponent) == ["2026-10-24_1400_プロジェクト定例.md"])
}
```
- [ ] **Step 2: 失敗を確認** `swift test` → FAIL（ビルドエラー: まだ無い型・関数を参照している）
- [ ] **Step 3: Implement** 上の規則どおり
- [ ] **Step 4: 通過を確認** `swift test` → PASS
- [ ] **Step 5: Commit** `git add Sources Tests` → `git commit -m "feat: add index file and vault scanner"`

### Task 11: Vault への書き出しと変更検知（要件書 §8.4・§9.1・§9.4）
**Files:**
- Create: `Sources/AutoNoteCore/Vault/VaultWriter.swift`
- Test: `Tests/AutoNoteCoreTests/Vault/VaultWriterTests.swift`

**Interfaces:**
- Consumes: `MeetingDocument`（`preferredFileName` `yearFolder` `hasTitle` `render()` `manifest`）、`MeetingFileName`、`IndexFile` `VaultScanner`、`AppPaths.vaultStateFile(_:)`
- Produces:
  - `public enum VaultError: Error, Equatable { case outputFolderUnavailable(URL) }`、`public enum VaultWriteOutcome: Equatable, Sendable { case written(URL); case conflict(URL) }`、`public enum OverwritePolicy: Sendable { case ifUnchanged, force }`
  - `public struct VaultWriteRecord: Codable, Equatable, Sendable { var meeting: MeetingID; var relativePath: String; var sha256: String; var writtenAt: Date }`（`vault-state/<id>.json`。sha256 は書いたバイト列の小文字 hex、CryptoKit）
  - `public actor VaultWriter { init(outputFolder: URL, paths: AppPaths, now: @escaping @Sendable () -> Date = Date.init); func write(_: MeetingDocument, policy: OverwritePolicy = .ifUnchanged, renameToMatchTitle: Bool = false) throws -> VaultWriteOutcome; func rebuildIndex() throws -> URL; func remove(_: MeetingID) throws; func record(for: MeetingID) -> VaultWriteRecord? }`

`write` の手順（この順に判定）:
1. 出力フォルダが存在するディレクトリでなければ `outputFolderUnavailable` を投げる。出力フォルダ自体は作らない（未マウントのボリュームのパスにローカルのフォルダができるのを防ぐ）。年フォルダは作ってよい
2. 既存ファイル ＝ 記録の `relativePath` にファイルがあればそれ、無ければ `VaultScanner.locate` の最初の一件（記録の無いファイル＝別の Mac や手で置いたもの）
3. 既存ファイルがあるとき: `.ifUnchanged` で、記録が無いか現在の SHA-256 が記録と違えば、何も書かずに `.conflict(既存の URL)`。書き先は既存のパス。ただし既存のファイル名が `isUntitled` で `document.hasTitle` かつ status が `transcriptOnly` でない（§8.4 の例外）か、`renameToMatchTitle` なら、年フォルダ内の `unique(preferredFileName)` に書いて既存を消す
4. 既存ファイルが無いとき（初回、または利用者が消した）: 年フォルダ内の `unique(preferredFileName)`
5. 原子的に書き、記録を保存して `.written(URL)`

`rebuildIndex`: 1 と同じ確認 → `scan` → `IndexFile.render` → `_index.md` を原子的に書く（常にアプリが書き直すファイルなので変更検知しない）。`remove`: 記録のファイル（無ければ `locate` の全件）と記録を消す。どちらも呼び手が続けて `rebuildIndex` を呼ぶ。

- [ ] **Step 1: Write the failing test**
```swift
private func doc(status: MeetingStatus = .minutesGenerated, minutes: MinutesOutput? = Samples.minutes, title: String? = nil, id: String = "20261024-1400-a1b2") -> MeetingDocument {
    var m = Samples.manifest; m.status = status; m.title = title; m.id = .init(rawValue: id)
    return MeetingDocument(manifest: m, transcript: Transcript(utterances: [u(5, .me, "a")], engine: "e", language: .ja), minutes: minutes,
                           frontmatter: .init(text: FrontmatterTemplate.defaultText), appVersion: "0.1.0", timeZone: Samples.tokyo)
}
private func writer() throws -> VaultWriter { VaultWriter(outputFolder: try TemporaryDirectory.make(), paths: AppPaths(root: try TemporaryDirectory.make())) }
private func url(_ o: VaultWriteOutcome) throws -> URL { guard case .written(let x) = o else { throw FakeError(message: "\(o)") }; return x }
@Test func writesOverwritesRewritesAndSuffixes() async throws {
    let w = try writer(); let first = try url(await w.write(doc()))
    #expect(first.path.hasSuffix("/2026/2026-10-24_1400_プロジェクト定例.md")); #expect(await w.record(for: Samples.manifest.id)?.relativePath == "2026/2026-10-24_1400_プロジェクト定例.md")
    #expect(try await w.write(doc()) == .written(first))
    try FileManager.default.removeItem(at: first); #expect(try await w.write(doc()) == .written(first))   // 利用者が消したら書き直す
    #expect(try url(await w.write(doc(id: "20261024-1400-ffff"))).lastPathComponent == "2026-10-24_1400_プロジェクト定例-2.md")
}
@Test func detectsExternalEditAndUnknownOrigin() async throws {
    let v = try TemporaryDirectory.make(); let w = VaultWriter(outputFolder: v, paths: AppPaths(root: try TemporaryDirectory.make()))
    let f = try url(await w.write(doc()))
    try (try String(contentsOf: f, encoding: .utf8) + "利用者のメモ\n").write(to: f, atomically: true, encoding: .utf8)
    #expect(try await w.write(doc()) == .conflict(f)); #expect(try String(contentsOf: f, encoding: .utf8).hasSuffix("利用者のメモ\n"))
    #expect(try await w.write(doc(), policy: .force) == .written(f))
    let otherMac = VaultWriter(outputFolder: v, paths: AppPaths(root: try TemporaryDirectory.make()))
    #expect(try await otherMac.write(doc()) == .conflict(f))
}
@Test func untitledIsRenamedWhenTitleArrives() async throws {
    let w = try writer(); let first = try url(await w.write(doc(status: .transcriptOnly, minutes: nil)))
    #expect(first.lastPathComponent == "2026-10-24_140000.md"); #expect(try url(await w.write(doc())).lastPathComponent == "2026-10-24_1400_プロジェクト定例.md")
    #expect(!FileManager.default.fileExists(atPath: first.path))
}
@Test func titledFileIsNotRenamedUnlessAsked() async throws {
    let w = try writer(); let f = try url(await w.write(doc()))
    #expect(try await w.write(doc(title: "改名後")) == .written(f)); #expect(try String(contentsOf: f, encoding: .utf8).contains("\n# 改名後\n"))
    #expect(try url(await w.write(doc(title: "改名後"), renameToMatchTitle: true)).lastPathComponent == "2026-10-24_1400_改名後.md")
    #expect(!FileManager.default.fileExists(atPath: f.path))
}
@Test func unavailableOutputFolderThrowsAndCreatesNothing() async throws {
    let missing = try TemporaryDirectory.make().appending(path: "Volumes/Ext/Meetings")
    let w = VaultWriter(outputFolder: missing, paths: AppPaths(root: try TemporaryDirectory.make()))
    await #expect(throws: VaultError.outputFolderUnavailable(missing)) { try await w.write(doc()) }
    #expect(!FileManager.default.fileExists(atPath: missing.path))
}
@Test func rebuildIndexAndRemove() async throws {
    let w = try writer(); _ = try await w.write(doc())
    let index = try await w.rebuildIndex()
    #expect(try String(contentsOf: index, encoding: .utf8).contains("[[2026/2026-10-24_1400_プロジェクト定例]]"))
    try await w.remove(Samples.manifest.id); _ = try await w.rebuildIndex()
    #expect(!(try String(contentsOf: index, encoding: .utf8)).contains("プロジェクト定例]]")); #expect(await w.record(for: Samples.manifest.id) == nil)
}
```
- [ ] **Step 2: 失敗を確認** `swift test` → FAIL（ビルドエラー: まだ無い型・関数を参照している）
- [ ] **Step 3: Implement** 上の手順どおり
- [ ] **Step 4: 通過を確認** `swift test` → PASS
- [ ] **Step 5: Commit** `git add Sources Tests` → `git commit -m "feat: write meeting files to vault with change detection"`

### Task 12: 持ち運ぶ設定 `_autonote/` と写し（要件書 §9.5）
**Files:**
- Create: `Sources/AutoNoteCore/Storage/PortableConfigStore.swift`
- Test: `Tests/AutoNoteCoreTests/Storage/PortableConfigStoreTests.swift`

**Interfaces:**
- Consumes: `AppPaths.portableMirrorDirectory`、`DictionaryFile.defaultMarkdown`（Task 5）、`FrontmatterTemplate.defaultText`（Task 8）
- Produces:
  - `public enum PortableFile: String, CaseIterable, Sendable { case dictionary = "dictionary.md", prompt = "prompt.md", frontmatter = "frontmatter.md", devices = "devices.json" }`
  - `public enum PortableDefaults { static let standard: [PortableFile: Data] }`（dictionary・frontmatter・devices（`"[]\n"`）。prompt の既定文は計画 05 が足す。devices の中身の形は計画 03）
  - `public struct PortableSyncReport: Equatable, Sendable { var outputAvailable: Bool; var toMirror: [PortableFile]; var toVault: [PortableFile]; var createdDefaults: [PortableFile] }`
  - `public actor PortableConfigStore { init(paths: AppPaths, outputFolder: URL?, defaults: [PortableFile: Data] = PortableDefaults.standard); var isOutputAvailable: Bool { get }; func sync() throws -> PortableSyncReport; func read(_: PortableFile) throws -> Data?; func write(_: PortableFile, _ data: Data) throws }`

規則（ファイルごと、`allCases` の順）:
- 出力フォルダが nil か存在しなければ「使えない」。出力フォルダは作らない。使えるときは `<出力フォルダ>/_autonote/` を必要なら作る
- 使える: 両方にあり同じ中身 → 何もしない。違う → 更新日時の新しい方で古い方を上書き（同じ日時なら Vault を正とする）。片方だけ → もう片方へ写す。どちらにも無い → 既定があれば両方に書いて `createdDefaults`。写した先の更新日時は写し元と同じにする（`setAttributes(.modificationDate)`。往復させない）
- 使えない: 写しだけを見る。写しに無く既定があれば写しに書く
- `read`: 使えるなら Vault 側（無ければ写し）、使えないなら写し、どちらにも無ければ nil。`write`: 使えるなら両方（同じ更新日時）、使えないなら写しだけ（フォルダが戻った次の `sync` で写しが新しいので Vault へ戻る）

- [ ] **Step 1: Write the failing test**
```swift
@Test func syncCreatesDefaultsThenCopiesNewerVaultFile() async throws {
    let v = try TemporaryDirectory.make(); let p = AppPaths(root: try TemporaryDirectory.make()); let store = PortableConfigStore(paths: p, outputFolder: v)
    #expect(try await store.sync().createdDefaults == [.dictionary, .frontmatter, .devices])
    let f = v.appending(path: "_autonote/dictionary.md"); #expect(try String(contentsOf: f, encoding: .utf8).contains("## 用語"))
    try Data("## 用語\n- 新語\n".utf8).write(to: f)
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: f.path)
    #expect(try await store.sync().toMirror == [.dictionary]); #expect(try Data(contentsOf: p.portableMirrorDirectory.appending(path: "dictionary.md")) == Data("## 用語\n- 新語\n".utf8))
    #expect(try await store.sync().toMirror == [])
}
@Test func editsWhileUnavailableArePushedBack() async throws {
    let v = try TemporaryDirectory.make().appending(path: "Meetings"); let p = AppPaths(root: try TemporaryDirectory.make()); let data = Data("[{\"name\":\"x\"}]\n".utf8)
    let offline = PortableConfigStore(paths: p, outputFolder: v)
    try await offline.write(.devices, data); #expect(try await offline.read(.devices) == data)
    try FileManager.default.createDirectory(at: v, withIntermediateDirectories: true)
    #expect(try await PortableConfigStore(paths: p, outputFolder: v).sync().toVault.contains(.devices))
    #expect(try Data(contentsOf: v.appending(path: "_autonote/devices.json")) == data)
}
@Test func doesNotCreateMissingOutputFolder() async throws {
    let v = try TemporaryDirectory.make().appending(path: "Volumes/Ext/Meetings")
    let r = try await PortableConfigStore(paths: AppPaths(root: try TemporaryDirectory.make()), outputFolder: v).sync()
    #expect(r.outputAvailable == false); #expect(!FileManager.default.fileExists(atPath: v.path))
}
```
- [ ] **Step 2: 失敗を確認** `swift test` → FAIL（ビルドエラー: まだ無い型・関数を参照している）
- [ ] **Step 3: Implement** 上の規則どおり
- [ ] **Step 4: 通過を確認** `swift test` → PASS
- [ ] **Step 5: Commit** `git add Sources Tests` → `git commit -m "feat: sync portable config folder with app-side mirror"`

### Task 13: フィクスチャと golden（架空の 5 分の会議）
**Files:**
- Create: `Tests/Fixtures/dictionary.md`、`Tests/Fixtures/meetings/20261024-1400-a1b2/{manifest.json, minutes.json, utterances/mic-000.json, mic-001.json, system-000.json, system-001.json}`、`Tests/Fixtures/meetings/20261025-0930-c3d4/{manifest.json, utterances/import-000.json}`、`Tests/Fixtures/expected/{_index.md, 2026/2026-10-24_1400_ルミナ茶発売準備会議.md, 2026/2026-10-25_093015.md}`（Step 4 で生成して確かめてから置く）、`Sources/AutoNoteTestSupport/FixtureRenderer.swift`
- Modify: `Sources/AutoNoteTestSupport/FixtureLibrary.swift`、`Tests/Fixtures/README.md`
- Test: `Tests/AutoNoteCoreTests/FixtureGoldenTests.swift`

**Interfaces:**
- Consumes: Task 2〜11 のすべて
- Produces:
  - `public struct FixtureMeeting: Sendable { var manifest: Manifest; var parts: [TrackTranscription]; var minutes: MinutesOutput? }`
  - `FixtureLibrary`: `static let engine = "whisper.cpp large-v3-turbo"`、`static func meetings(in: URL = defaultDirectory) throws -> [FixtureMeeting]`（`meetings/*/` を名前順。`utterances/<トラックファイル名の拡張子なし>.json` を `[Utterance]` として `TrackFile` と組にする。`minutes.json` は任意）、`static func dictionary(in: URL = defaultDirectory) throws -> DictionaryFile`
  - `public enum FixtureRenderer { static func render(fixtures: URL = FixtureLibrary.defaultDirectory, into vault: URL) async throws -> [String]; static func compare(_ vault: URL, expected: URL) throws -> [String] }`。`render` は会議ごとに `TranscriptFinalizer(dictionary:, fillerRemoval: true)` → `MeetingDocument(frontmatter: defaultText, appVersion: "0.1.0", timeZone: FixtureLibrary.timeZone)` → 一時 `AppPaths` の `VaultWriter.write(policy: .force)`、最後に `rebuildIndex()`。書いた相対パス（`_index.md` を含む）を返す。`compare` は両方の `.md` を相対パスで突き合わせ、中身が違うか片方にしか無いパスを返す（空なら一致）

フィクスチャ（すべて架空。相手は「ほしぞら食品」、新商品「ルミナ茶」。JSON は `AutoNoteJSON` の形）:

会議 1 `20261024-1400-a1b2`: startedAt `2026-10-24T05:00:00Z`、endedAt `2026-10-24T05:05:12Z`、title null、live、device `{"name": "Kestrel Headset 7", "uid": "FAKE-KESTREL-0001:input", "transport": "bluetooth"}`、ja、pauses `[{150, 170}]`、bookmarks `[{41.5, "価格の話"}, {231.0, null}]`、status `minutes_generated`。tracks は `tracks/mic-000.wav`（offset 0、150 秒）`tracks/mic-001.wav`（offset 170、142 秒）と system の同じ二つ。発話（ファイル内の秒。括弧は会議タイムライン）:

| ファイル | start–end | 本文 | 確かめること |
|---|---|---|---|
| system-000 | 3–7.5 | 本日はルミナ茶の発売準備についてご相談させてください。 | |
| mic-000 | 8–11 | よろしくお願いします。 | |
| system-000 | 12–16 | えー、まず発売日ですが、来週の金曜を考えています。 | 先頭のフィラー |
| mic-000 | 12.4–16 | えー、まず発売日ですが、来週の金曜を考えています。 | 回り込み（捨てる） |
| mic-000 | 20–26 | えーと、ルミナちゃの在庫は十分にありますか。 | フィラーと置換 |
| system-000 | 40–46 | 価格は一本百八十円で進めたいと思います。 | |
| mic-000 | 40.6–41 | はい。 | 短い相づち（残す）、同じ秒のアンカー `-2` |
| mic-000 | 60–66 | 価格は了解しました。社内で承認を取ります。 | |
| system-000 | 120–121 | えー。 | フィラーだけ（捨てる） |
| system-001 | 5–9（175） | 店頭の販促物はこちらで用意します。 | 一時停止の後、offset |
| mic-001 | 10–14（180） | 販促物の納期は来週水曜でお願いできますか。 | |
| system-001 | 60–64（230） | それでは発売日は来週の金曜で確定にしましょう。 | |
| mic-001 | 61–63（231） | 発売日は来週の金曜で確定 | 部分的な回り込み（捨てる） |
| system-001 | 100–103（270） | ありがとうございました。 | |
| mic-001 | 105–107（275） | 失礼します。 | |

`minutes.json`: title `ルミナ茶発売準備会議`、summary `["ルミナ茶の発売日を来週金曜に確定した。", "価格は一本百八十円で、自分が社内承認を取る。", "販促物は相手側が用意し、納期は来週水曜を依頼した。"]`、decisions `[("発売日は来週の金曜", "00:03:50"), ("価格は一本百八十円", "00:00:42")]`、agenda `[("発売日", "来週金曜を提案し、最後に確定した。", "00:00:12"), ("価格", "一本百八十円で進め、自分が社内承認を取る。", "00:00:40"), ("販促物", "相手側が用意する。納期の回答を依頼した。", "00:02:55")]`、next_actions `[("価格の社内承認を取る", "自分", null, "00:01:00"), ("販促物A|B 案の納期を回答する", null, "来週水曜", "00:03:00")]`、suggested_terms `["ほしぞら食品"]`。

会議 2 `20261025-0930-c3d4`（取り込み・議事録失敗）: startedAt `2026-10-25T00:30:15Z`、endedAt `2026-10-25T00:32:15Z`、title null、imported、device `{"name": "import", "uid": "import", "transport": "import"}`、tracks `[{mic, "tracks/import-000.wav", 0, 120}]`（取り込みは 1 トラックで track は mic とする。話者は source で不明になる）、pauses・bookmarks 空、status `transcript_only`、minutes なし。発話 `3 えーと、取り込んだ録音の確認です。` `30 um, this part is in English.` `62 以上です。`。`dictionary.md`: 用語 `ルミナ茶` `ほしぞら食品`、置換 `ルミナちゃ => ルミナ茶`、フィラーは既定の 5 語。

- [ ] **Step 1: Write the failing test**
```swift
@Test func fixtureRendersToGolden() async throws {
    let out = try TemporaryDirectory.make()
    #expect(try await FixtureRenderer.render(into: out).count == 3)
    #expect(try FixtureRenderer.compare(out, expected: FixtureLibrary.defaultDirectory.appending(path: "expected")) == [])
}
@Test func goldenHasKeyLines() throws {   // golden が誤りごと作り直されるのを防ぐ
    let dir = FixtureLibrary.defaultDirectory.appending(path: "expected")
    let m1 = try String(contentsOf: dir.appending(path: "2026/2026-10-24_1400_ルミナ茶発売準備会議.md"), encoding: .utf8)
    for line in ["title: ルミナ茶発売準備会議", "end: \"14:05\"", "duration_min: 5", "- 発売日は来週の金曜 [[#^t00-03-50|03:50]]",
                 "- 価格は一本百八十円 [[#^t00-00-40-2|00:42]]", "| 販促物A\\|B 案の納期を回答する | — | 来週水曜 | [[#^t00-03-00\\|03:00]] |",
                 "- [[#^t00-00-40-2|00:41]] 価格の話", "- [[#^t00-03-50|03:51]]", "── 一時停止 00:02:30〜00:02:50 ──",
                 "**[00:00:12] 相手**: まず発売日ですが、来週の金曜を考えています。 ^t00-00-12", "**[00:00:20] 自分**: ルミナ茶の在庫は十分にありますか。 ^t00-00-20",
                 "**[00:00:40] 自分**: はい。 ^t00-00-40-2", "**[00:02:55] 相手**: 店頭の販促物はこちらで用意します。 ^t00-02-55"] { #expect(m1.contains(line + "\n"), "\(line)") }
    #expect(m1.components(separatedBy: "**: ").count - 1 == 12)   // 15 発話から回り込み 2 とフィラーだけ 1 を除く
    let m2 = try String(contentsOf: dir.appending(path: "2026/2026-10-25_093015.md"), encoding: .utf8)
    for line in ["title: 2026-10-25 09:30 の会議", "status: transcript_only", "device: \"import\"", "**[00:00:03] 不明**: 取り込んだ録音の確認です。 ^t00-00-03",
                 "**[00:00:30] 不明**: this part is in English. ^t00-00-30"] { #expect(m2.contains(line + "\n"), "\(line)") }
    #expect(try String(contentsOf: dir.appending(path: "_index.md"), encoding: .utf8).contains(
        "| 2026-10-25 | 09:30 | 2026-10-25 09:30 の会議 | 2 分 | （議事録未生成） | [[2026/2026-10-25_093015]] |\n| 2026-10-24 | 14:00 | ルミナ茶発売準備会議 | 5 分 | ルミナ茶の発売日を来週金曜に確定した。 | [[2026/2026-10-24_1400_ルミナ茶発売準備会議]] |\n"))
}
```
- [ ] **Step 2: 失敗を確認** `swift test` → FAIL（ビルドエラー: まだ無い型・関数を参照している）
- [ ] **Step 3: Implement** `FixtureLibrary.meetings` `dictionary`、`FixtureRenderer`、上の表どおりのフィクスチャ入力ファイル
- [ ] **Step 4: golden を生成して確かめる** `expected/` を作り、一時的なテスト関数で `FixtureRenderer.render(into: <defaultDirectory>/expected)` を一度走らせ、関数は消す。生成した 3 ファイルを読み、`goldenHasKeyLines` の各行と Task 9・10 の規則（節の順、空行、末尾改行 1 つ、`guide` 5 行）に合うことを目で確かめる。合わなければ golden ではなく実装を直す
- [ ] **Step 5: 通過を確認** `swift test` → PASS
- [ ] **Step 6: Commit** `git add Tests Sources` → `git commit -m "test: add fictional 5-minute meeting fixtures and golden vault output"`

### Task 14: 開発用サブコマンド `autonote dev render-fixture`、E2E 更新、全 PASS 確認
**Files:**
- Create: `Sources/autonote/DevCommands.swift`
- Modify: `Sources/autonote/main.swift`、`scripts/e2e-check.sh`（項目 16・16b を足し、`CHECKS` の末尾に `check_render_fixture` `check_render_fixture_detects_diff`）

**Interfaces:**
- Consumes: `FixtureRenderer.render(fixtures:into:)` `compare(_:expected:)`、`FixtureLibrary.defaultDirectory`
- Produces: `enum DevCommands { static func run(_ args: [String]) async -> Int32 }`。`autonote dev render-fixture --out <dir> [--fixtures <dir>] [--no-compare]`
  - `--out` に会議ファイルと `_index.md` を書く（無ければ作る）。`--fixtures` の既定は `FixtureLibrary.defaultDirectory`
  - 比較（既定）: `<fixtures>/expected` と比べ、一致なら標準出力に `一致: <n> ファイル` で 0。不一致なら標準エラーに `差分: <相対パス>` を 1 行ずつ出して 1
  - `--no-compare`: 書いた相対パスを標準出力に並べて 0（golden の作り直し用。作り直したら Task 13 Step 4 と同じく目で確かめる）
  - 引数の誤りは標準エラーに `usage: autonote dev render-fixture --out <dir> [--fixtures <dir>] [--no-compare]` で 2
- `main.swift`: 先頭の引数が `dev` なら `exit(await DevCommands.run(残り))`。他の挙動（`--version`、引数なしで `usage: autonote --version` と終了コード 1）は変えない。`dev` は使い方に出さない（overview §7）

- [ ] **Step 1: E2E に項目を足す（失敗する確認を先に書く）**
```bash
AUTONOTE_CLI=""
check_render_fixture() {
    CURRENT="16. autonote dev render-fixture がフィクスチャを期待ファイルどおりに書く"
    if [[ "${QUICK}" -eq 0 ]]; then run swift build --product autonote || { fail "swift build --product autonote が失敗"; return; }; fi
    local c; for c in "${ROOT}/.build/debug/autonote" "${APP}/Contents/MacOS/autonote"; do [[ -x "${c}" ]] && { AUTONOTE_CLI="${c}"; break; }; done
    [[ -n "${AUTONOTE_CLI}" ]] || { skip "autonote の実行ファイルが無い（swift build で作る）"; return; }
    local out="${WORK}/render-fixture"
    run "${AUTONOTE_CLI}" dev render-fixture --out "${out}" --fixtures "${ROOT}/Tests/Fixtures" || { fail "render-fixture が 0 以外で終了"; return; }
    [[ -f "${out}/_index.md" ]] || { LAST_LOG=""; fail "_index.md が書かれていない"; return; }
    pass "$(tail -n 1 "${LAST_LOG}")"
}
check_render_fixture_detects_diff() {
    CURRENT="16b. render-fixture が期待ファイルとの差を検出して exit 1"
    [[ -n "${AUTONOTE_CLI}" ]] || { skip "項目 16 で autonote が見つからなかった"; return; }
    local fx="${WORK}/fixtures-tampered"; cp -R "${ROOT}/Tests/Fixtures" "${fx}"; printf '改ざん\n' >>"${fx}/expected/_index.md"
    run "${AUTONOTE_CLI}" dev render-fixture --out "${WORK}/render-tampered" --fixtures "${fx}"; local code=$?
    [[ ${code} -eq 1 ]] || { fail "exit ${code}（期待 1）"; return; }
    grep -q '差分: _index.md' "${LAST_LOG}" || { fail "「差分: _index.md」が出ていない"; return; }
    pass
}
```
- [ ] **Step 2: 失敗を確認** `scripts/e2e-check.sh` → 項目 16・16b が FAIL（`dev` が未実装で usage と exit 1）、他の項目はこれまでどおり
- [ ] **Step 3: Implement** `DevCommands.run(_:)` と `main.swift` の分岐（Interfaces どおり）
- [ ] **Step 4: 全 PASS を確認** `swift test` → PASS。`scripts/e2e-check.sh` → 終了コード 0、項目 1・6・16・16b が PASS、FAIL 0（機材・GUI・証明書に依存する項目は条件しだいで SKIP 可）。`--quick` では `.build/debug/autonote` が古いと 16 が FAIL しうるので、そのときは `swift build` してから回す
- [ ] **Step 5: Commit** `git add Sources/autonote scripts/e2e-check.sh` → `git commit -m "feat: add autonote dev render-fixture and e2e checks"`
