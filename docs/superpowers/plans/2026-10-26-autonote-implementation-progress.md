# AutoNote 実装進捗（計画 01〜06）

## 目的
2026-10-26 に利用者が「最後まで進めてよい。実際に実装して動作確認するところまで承認します」と承認。計画 01〜06 を順に subagent-driven-development で実装し、各計画の最後で E2E（`scripts/e2e-check.sh`）を全 PASS にする。

## 運用ルール
- Lead（メインセッション）はブリーフ・レビュー・裁定だけ。実装・レビューはサブエージェント。
- ブランチは計画ごとに積む: `plan-01`（`plan-00` から）→ `plan-02`（`plan-01` から）→ … → `plan-06`。main への統合と push は利用者の判断。**push しない。**
- タスクごとにコミット。各タスクは実装者 → レビュー担当 → 修正ループ（最大 5 回）。計画ごとに最終の全ブランチレビュー。
- 各計画の SDD 台帳は `.superpowers/sdd/<計画ファイル名>/progress.md`（git 管理外）。計画完了時に削除し、裁定はこのファイルに写す。
- 👤 利用者の手が要る手順は止めずに「後回し」として記録し、利用者に最後にまとめて依頼する（初回の許可ダイアログのみ利用者。GUI 確認は osascript + TCC.db で自動化）。

## 計画ごとの状態
| 計画 | ブランチ | 状態 | 備考 |
|---|---|---|---|
| 01 中核モデルと保存形式 | plan-01 | **完了**（2026-10-26、HEAD 652df47） | 基点 5fd0a64。14 タスク、最終レビュー（opus）で Critical 1・Important 4・Minor 5 を修正し再レビュー clean。swift test 80 件、E2E 20 項目 PASS |
| 02 音声取り込み | plan-02 | 未着手 | |
| 03 機材と自動録音 | plan-03 | 未着手 | |
| 04 文字起こし | plan-04 | 未着手 | |
| 05 議事録と待ち行列 | plan-05 | 未着手 | |
| 06 UI・CLI・Automations | plan-06 | 未着手 | |

## 裁定の写し（計画完了時に台帳から転記）

### 計画 01（台帳から転記、2026-10-26）
- ## Pre-flight scan (table in preflight-scan.md, by sidekick-runner/sonnet). Rulings:
- - Ruling: Task 2 declares `Equatable` on every shared model type incl. `Transcript` (plan L72-83; overview L66 lacks it; Task 4 `SummaryInput: Equatable` needs it) — values are plain Codable structs, synthesis is free — cost if wrong: none (overview to be amended with a note at plan end).
- - Ruling: Task 13 L706 `MeetingDocument(frontmatter: defaultText…)` is a typo; use `FrontmatterTemplate(text: defaultText)` as the tests at L491/558/596 do — carry into Task 13 dispatch.
- - Ruling: Task 14 L809 — E2E item 6 PASS is expected on this machine (cert `AutoNote Dev` exists); SKIP acceptable only where cert absent. Carry into Task 14 dispatch.
- - Ruling: Task 9 regenerate notice text = test's expected string (half-width space before 「で作り直せます。」); test is authoritative — cost if wrong: cosmetic.
- - Ruling: Task 2 tests L98-99 use `AutoNoteJSON.encoder()` instead of bare `JSONEncoder()` (constraint L30) — cost: none.
- - Ruling: Task 3 corrupt-file timestamp: `SettingsStore.init(paths:timeZone: TimeZone = .current)`; the `yyyyMMdd-HHmmss` is formatted in that zone — cost if wrong: filename cosmetic.
- - Ruling: `TimeZone = .current` default args are allowed (caller can still pass); no change.
- - Ruling: Task 4 protocol placement: `Audio/Protocols.swift` = AudioSource; `Transcription/Protocols.swift` = LiveTranscriber, BatchTranscriber; `Minutes/Protocols.swift` = Summarizer, QueueStage, StageContext. All public. Carry into Task 4 dispatch.
- - Ruling: all TestSupport types/members are `public` (general rule L29 applies). Carry into Task 4.
- - Ruling: Task 9 「改行→空白 1 つ」applies to every inserted single-line field (title, summary bullets, decisions, agenda, next actions, bookmark notes), not only utterance paragraphs. Carry into Task 9.
- - Ruling: Task 11 vault-state JSON goes through `AutoNoteJSON` (constraint L30). Carry into Task 11.
- - Ruling: `AppPaths` in Task 3 stays as planned; `claude-cwd/` (plan 05) and `merged/` (plan 02) are added by their owning plans.
- Task 1: review clean (spec ✅, quality approved). Ruling: `autonote` → `AutoNoteTestSupport` dependency (flagged Important/plan-mandated) stands — Task 14 `autonote dev render-fixture` needs FixtureLibrary; dev-only CLI subcommand, acceptable — cost if wrong: test helpers in the CLI binary.
- Task 4: Ruling: three `Protocols.swift` files renamed to Audio/AudioProtocols.swift, Transcription/TranscriptionProtocols.swift, Minutes/MinutesProtocols.swift — SwiftPM rejects duplicate basenames in one target — cost if wrong: later plans referencing Protocols.swift need the new names (carry forward to plans 02/04/05).
- Task 8: review clean (spec ✅, approved). Ruling: second trim after the 60-char cut stands (avoids trailing dot; spec intent is a safe filename) — cost if wrong: filenames up to a few chars shorter than 60. minor (deferred): quote-tracking edge with value ending in `\`; untested nil end/duration, import device, unknown var, language key; `\d` matches non-ASCII digits; CRLF template `---\r`.
- Task 9: review clean (spec ✅, approved). Ruling: whitespace-only title counts as no title (stands; a blank title would otherwise produce 「# 」 and an empty filename) — cost if wrong: none observable. minor (deferred): flatten misses U+2028/2029/0085; open-ended pause / trailing pause untested; bookmark note trimming is extra.
- Rulings for the fix wave:
- - Ruling C1: PortableConfigStore keeps `portable-mirror/.sync-state.json` (AutoNoteJSON) = { output_folder: String?, files: { <PortableFile.rawValue>: { last_synced_sha256 } } }. Decide per file: Vault wins when mirror SHA == last synced (mirror unchanged) or when state's output_folder ≠ current folder and Vault has the file; mirror wins when Vault SHA == last synced (Vault unchanged) or Vault lacks the file; both changed → newer mtime, tie → Vault. Defaults written while unavailable are recorded as synced (so they never overwrite a real Vault). State updated after every sync and after `write` when available. — cost if wrong: an offline edit could be lost to a Vault edit made in the same window (newer mtime decides).
- - Ruling I1: linkTarget: candidates = utterances with floor(start) ≤ t; prefer the LAST candidate whose (end ?? start) ≥ t (contains t); else the last candidate; else first utterance. Golden regenerated and re-checked by eye.
- - Ruling I2: yamlScalar quotes unless the value consists only of letters/digits/space/`_`/`-`/`.`, does not begin with a digit, `-` or `.`, and is not a bool/null word; existing rules kept.
- - Ruling I3: remove(): if the record's file is missing → delete every locateAll hit, then the record.
- - Ruling I4: AutoNoteJSON encodes dates as ISO-8601 with fractional seconds (`.withFractionalSeconds`, e.g. `1970-01-01T00:00:00.000Z`) and decodes both forms; Task 1 test updated accordingly; fixture JSON stays (decodes).
- - Ruling M1: after filler removal drop all leading separators, drop a trailing comma-class run, and collapse a comma-class run directly followed by a period-class run into the period.
- - Ruling M3: `HintBudget.fit(_:limit:separator: String = ", ")`, separators counted as (n−1) × estimateTokens(separator).
- - Ruling M5: `init?(hhmmss:)` returns nil when hours > 99_999.
- Fix wave: 8/9 done (5da5438..a0759af), I2 blocked → Ruling I2 refined: strict quoting only for free-text variables (title, device, transcript_engine, unknown); structured values (date, start, end, duration_min, status, autonote_id, autonote, language) keep the old rule — cost if wrong: a custom template that unquotes a structured value with odd content. Ruling I1 amended: containment candidate also requires start ≤ t (implementer's tightening accepted). Ruling I4: dates persist at millisecond precision; later plans compare dates after round-trip or round to ms — cost if wrong: equality tests on raw Date() fail.
- Ruling: untitled default title quoted in frontmatter (golden line changed) accepted — safe YAML, Obsidian reads it as text either way. Fix wave complete 40d9a2a..652df47; scoped re-review dispatched (opus).

後回しにした minor（最終レビューで「後回しでよい」と判定）:
- Task 1: minor (deferred): FixtureLibrary.timeZone force-unwrap untested; Tests/Fixtures/README.md written in English (repo docs are Japanese) → Task 13 rewrites README in Japanese when appending.
- Task 2: review clean (spec ✅, approved). minor (deferred): TimelineTime hhmmss hours overflow unguarded; parts() traps for > Int.max; %d vs %ld; thin parser rejection tests.
- Task 3: review clean (spec ✅, approved). ⚠️ resolved by controller: AutoNoteJSON snake_case (Task 1 test), Samples shapes (Task 2), Samples.manifest status is minutesGenerated so unfinishedRecordings assertion is meaningful. minor (deferred): corrupt-file rename collides within the same second; unfinishedRecordings exclusion untested; timezone effect on aside filename untested; per-field defaults not asserted individually.
- Task 4: review clean (spec ✅, approved). minor (deferred): FakeAudioSource untested; FakeSummarizer failure & FakeBatchTranscriber missing-key branch untested; FakeLiveTranscriber start-twice leaves first stream open.
- Task 5: review clean (spec ✅, approved). minor (deferred, fix before merge recommended): CRLF dictionary file parses as one line (DictionaryFile.swift:62); separator count n vs n-1 in HintBudget.fit (conservative, untested boundary); issue text/reason untested; unreachable `.other` case.
- Task 6: review clean (spec ✅, approved). minor (deferred): trailing filler after comma leaves dangling 「、」; leading filler before period leaves leading 「。」 (both literal to brief; decide at final review); DP rebuilds arrays per index.
- Task 7: review clean (spec ✅, approved). minor (deferred): mic-first tie rule not pinned by test; no boundary tests for 0.8 / len 4 / len 6 / ±3.0 window; unstable sort for same-start others; imported test lacks system track.
- Task 8: review clean (spec ✅, approved). Ruling: second trim after the 60-char cut stands (avoids trailing dot; spec intent is a safe filename) — cost if wrong: filenames up to a few chars shorter than 60. minor (deferred): quote-tracking edge with value ending in `\`; untested nil end/duration, import device, unknown var, language key; `\d` matches non-ASCII digits; CRLF template `---\r`.
- Task 9: review clean (spec ✅, approved). Ruling: whitespace-only title counts as no title (stands; a blank title would otherwise produce 「# 」 and an empty filename) — cost if wrong: none observable. minor (deferred): flatten misses U+2028/2029/0085; open-ended pause / trailing pause untested; bookmark note trimming is extra.
- Task 10: review clean (spec ✅, approved). ⚠️ resolved: MeetingDocument emits `## 3行要約` + `- ` lines (Task 9 test documentHasSectionsInOrder). minor (deferred): Found stores base per file; symlink outside vault yields absolute linkPath; unreadable .md silently skipped; newline in index cell; missing date/start/title → empty untested.
- Task 11: review → Needs fixes. Important: swallowed delete after rename (VaultWriter.swift:82). minor (deferred): record(for:) hides corrupt vs missing; no tests for remove-without-record, .force+rename, rebuildIndex unavailable folder. Fix round 1 dispatched (resumed implementer; FIX_BASE 961e969).
- Task 11: fix round 1/5 (2 addressed, 0 open — swallowed delete; out-of-vault locate hits; commits 961e969..088a4e6). minor (deferred): outputFolder not symlink-normalized in init (literal path compare); no test forcing delete failure.
- Task 12: review clean (spec ✅, approved). minor (deferred): put() mtime set after atomic write (narrow race); directory named like a file; tests packed with `;`.
- Task 13: review clean (spec ✅, approved; golden traced against spec §9.2/§9.3/§5.4/§5.6/§6.5/§8.4, no gaps found in Tasks 2-12). minor (deferred, recommend fixing in final wave): import-000.json speakers should be "me" so the source→unknown rule is actually exercised; FixtureRenderer drops non-.written outcomes silently; FixtureLibrary.dictionary discards parse issues; test uses `import` not `@testable import`; note: decision link at 00:00:42 lands on 「はい。」 (rule-correct; consider prompt guidance in plan 05).
- Task 14: review clean (spec ✅, approved). ⚠️ resolved: compare returns relative paths (01.2 PASS in Lead's own run), Package.swift dependency exists (Task 1), `run` merges stderr (01.2 PASS). minor (deferred): --help range omits last header line (pre-existing); AUTONOTE_CLI line splits E2E_MENUBAR_*; arg parser accepts flag names as values.
- Final re-review (opus): all 10 findings ADDRESSED, no new breakage. PLAN 01 COMPLETE at 652df47. deferred observations: I1 overlapping-channel case (earlier other-speaker utterance can win when t is rounded down); cloud-synced Vault not yet downloaded counts as absent; ISO8601DateFormatter per call; .sync-state.json must be skipped by anything enumerating portable-mirror/.

## 利用者への依頼（後回しにした 👤 手順）

## 再開手順
1. この表で進行中の計画を見る。そのブランチに checkout。
2. `.superpowers/sdd/<計画ファイル名>/progress.md` の台帳で `Task N: complete` を数え、次のタスクから再開。台帳が無ければ `git log` で判断。
3. superpowers:subagent-driven-development の手順に従う。
