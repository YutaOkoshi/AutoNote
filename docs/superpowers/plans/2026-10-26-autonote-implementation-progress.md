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
| 02 音声取り込み | plan-02 | **完了**（2026-10-26、HEAD 9a0fd64） | 基点 4441130。16 タスク（Task 15 👤 は利用者待ち）、最終レビュー（opus）で Important 1・Minor 7 → 修正波 1 回 + 再レビュー clean。swift test 206 件、E2E 21 PASS / 0 FAIL / 1 SKIP（02.1 は許可未応答）。Task 1 と 14/16 の 👤 手順は「利用者への依頼」参照 |
| 03 機材と自動録音 | plan-03 | **完了**（2026-10-26、HEAD 974aeee） | 基点 9a0fd64。11 タスク（Task 10 Step 4〜7 👤 は利用者待ち）、実行前スキャンで 22 件を裁定（Y1〜Y21）、最終レビュー（opus）で Important 2・Minor 9 → 修正波 1 回 + 再レビュー clean。swift test 348 件、E2E 24 PASS / 0 FAIL / 1 SKIP（02.1 は許可未応答） |
| 04 文字起こし | plan-04 | 完了（2026-10-27、HEAD 0a76f1f、487 テスト、E2E 25/0/0） | 裁定 Z1〜Z29（下の写し）。ローカル AVX2 xcframework（Z20）、`.silenceFinalize` 採用（Task 9 計測）。Task 12 👤（Apple Silicon）は利用者待ち |
| 05 議事録と待ち行列 | plan-05 | 完了（2026-10-27、HEAD e121609、630 テスト、E2E 27/0/0） | 裁定 P1・Y1〜Y35（下の写し）。Task 1 👤 と Task 14 Step 6 👤（claude -p の実測）は利用者待ち。計画 06 は Step 6 を配線前の関門にする |
| 06 UI・CLI・Automations | plan-06 | 完了（2026-10-27、HEAD d948918、808 テスト、E2E 33/0/0） | 基点 68bd1e3。16 タスク（Task 13 は 13a/13b/13c に分割）。実行前スキャン（R1〜R36、C1〜C29、S1〜S16、N1〜N17、U1〜U20）と裁定 X-T3a・X-T5a・X-T6a・X-T8a・X1〜X58（下の写し）。計画 04 の `AudioImporter`（X44）と計画 05 の `resolveOverwrite`（X55）を本計画で修正。最終レビュー（opus）で Important 5・Minor 13 → 修正波 1 回（12 コミット）+ 再レビュー clean。計画 05 Step 6 の関門は 2026-10-27 に実行して合格（X41）。実機の画面確認は「利用者への依頼」参照 |

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

### 計画 02（台帳から転記、2026-10-26）
ブランチ `plan-02`、基点 4441130、最終 9a0fd64。レビュー: 各タスク + 最終（opus）+ 修正波 1 回 + 範囲再レビュー。Lead 検証: 単体 206 件、E2E 21 PASS / 0 FAIL / 1 SKIP（02.1 はシステム音声の録音許可が未応答のため）。

#### 裁定
- ## Pre-flight scan (preflight-scan.md, sidekick-runner/sonnet): 17 mismatches. Rulings (provisional until dispatch, carried into the relevant task's dispatch):
- - Ruling X1: `DiskSpace` protocol, `SystemDiskSpace`, `FakeDiskSpace` are created in Task 10 (`Audio/DiskSpace.swift` + TestSupport); Task 11 consumes them — cost if wrong: Task 10 slightly larger.
- - Ruling X2/X3 (Task 7 silence detector): the rule text (plan L368-370) is authoritative; the implementer derives the expected tick values from the rule and corrects the test numbers, documenting the derivation in the report — cost if wrong: a test pinned to a wrong tick.
- - Ruling X4: add `AutoNoteJSON.compactEncoder()` (no prettyPrinted, sortedKeys, iso8601 fractional, snake_case) for one-line outputs; `RecordingReport` writes `encode(to:)` so nil fields emit explicit `null`. Match `"meeting_id":` without a space.
- - Ruling X5: reset condition = |actualHostTime − (previousHostTime + previousDuration)| > tolerance (expected-vs-actual, not consecutive start difference).
- - Ruling X6: implement `.tapOnly` only; the `withOutputClock` branch is not built unless Task 1's measurement demands it (then Task 8 adds a `write` variant). Keep the default in one place (`TapClockMode.tapOnly`).
- - Ruling X7: TestSupport gets `FakeMicrophonePermission(status:)` and `FakeDeviceLookup(devices:)` with public inits; `prepared` asserted as two separate `#expect`s.
- - Ruling X8: every type with a default-argument init and every TestSupport type is `public` with explicit `public init` (contract rule).
- - Ruling X9: `zeroCrossings` is a `private` test helper. X10: `@testable import` may read internal members in tests. X11: Task 1 `git add` list includes Info.plist and e2e-check.sh. X12: contract already requires `e2e-check.sh --quick` per task. X13: tests pass `timeZone: Samples.tokyo` explicitly to `MeetingID.make`. X14: `dev import --lang` default `ja`; `usageError`/`printError` become internal in DevCommands. X15: branch created at start. X16: protocol file is `Audio/AudioProtocols.swift`. X17: `TemporaryDirectory.make()` throws (tests already use try).
- - Ruling T1 (👤 handling, per memory feedback-automate-gui-checks): Task 1 implements DevChecks + menu (Steps 1-3), then writes `scripts/tcc-check.sh` with phases `audio-persist` (Step 4), `dictation` (Step 6), `bt-silence` (Step 7) that run every automatable step (tccutil reset, afplay loop, open, osascript menu click, dialog detection, sqlite3 TCC.db, PlistBuddy version bump, rebuild, log extraction) and print exactly what the user must do by hand. The implementer runs `audio-persist` and `dictation` up to the first dialog; it never clicks a permission dialog. Steps needing the user (clicking 許可, System Settings toggle, reboot, Shokz connect) are recorded in the master progress file's 「利用者への依頼」 and the plan continues with `AggregateLayout.tapOnly` as default (ruling X6). Spec/results-table updates are made for whatever was measured; the rest marked 未測定（利用者待ち）. — cost if wrong: Task 8 default may need flipping to withOutputClock later.
- Task 1: implemented 85ed3f4..b5d873f (DevChecks, scripts/tcc-check.sh with phases audio-persist/dictation/audio-denied/bt-silence, docs). Measured: Dictation needs no permission (no dialog, no TCC row, recognised OK). audio-persist stopped at the AudioCapture permission dialog (screen was locked; dialog still pending). Ruling: `AudioDeviceStart` also blocks ~90 s while the dialog is pending → Task 8 runs start AND teardown on the dedicated queue with timeout (carry into Task 8 dispatch) — cost if wrong: none. Task 8 default stays .tapOnly (not yet measured). Review dispatched (sonnet).
- Task 6: review → Approved (Spec ✅ / Quality ✅). minor (deferred): stale merged/<track>-N.wav from a prior run not removed (Ruling: callers use the returned [TrackFile], never a directory scan — carry to Tasks 10/12/13); partial file left if a write throws mid-run; tolerance-boundary and overlap-within-tolerance untested; zero-length segments untested.
- Task 8: review → Approved with minors (opus). Fix round 1 dispatched (resumed implementer; FIX_BASE 5fab378): flush-before-reset at gap (+test), deinit teardown, stronger failure/timeout tests, count callbacks before guards, Ruling: defaultOutputDeviceUID uses kAudioHardwarePropertyDefaultOutputDevice (not System/alert device) — cost if wrong: only affects .withOutputClock. Accepted as-is: selector in call names; stop-while-start-pending returns immediately (deferred to final review); tail chunk hostTime approximate; re-start after timed-out stop queues behind teardown. SDK check: CATapDescription.bundleIDs exists (macOS 26); exclusion semantics unverified on device (👤 Task 15).
- Task 9: implemented e2f0ba0 (refactor SourceDrain) + 2abfd0c. Ruling: MicrophoneSource.init gains trailing stopTimeout: Duration = .seconds(5) (parity with ProcessTapSource). Review dispatched (opus).
- Task 10: review → Needs fixes (opus). Important: (1) ticker→tick()→stop self-await deadlock (Task 11 would trigger) — Ruling: performStop cancels ticker without awaiting; tick() never calls stop inline, spawns a Task (carry to Task 11); (2) writer write/open errors swallowed — emit .sourceFailed once per track + silenceWarning, resume rethrows; (3) Ruling: events() streams are app-lifetime — .stopped does NOT finish them (plans 03/06 subscribe once); audio(for:) stays per-meeting and finishes at stop — cost if wrong: plan 03/06 listeners would need re-subscribe. Minor fixes: saver doc, yield .stopped even if final save throws then rethrow, monitor! unwrap, vacuous waitUntilIdle test, audio(for:) onTermination, OperationGate split. Fix round 1 dispatched (resumed implementer; FIX_BASE afb4691).
- Task 12: implemented 4b81d9c. Ruling: corrupt (non-WAV) header → drop the file from tracks with a log, never throw from recover (I/O errors on write/save may propagate) — cost if wrong: a corrupt-but-salvageable file silently dropped. Pre-review fix commit requested (resumed implementer).
- Task 14: Ruling — E2E items follow Task 16's definitions (02.1 dev record 5 s / 02.2 dev import m4a+wav), superseding the task-14-lead-notes item list; Task 16 Step 1 is thereby folded into Task 14 (own commit), Task 16 becomes build-app + full e2e run + ledger. Task 15 (👤) deferred to the user per the brief.
- On-device conclusion: dev record --tap-layout withOutputClock also blocks ~90 s with system chunks 0 (rec2.log) → layout is NOT the cause; both layouts behave like Task 1's "AudioCapture prompt unanswered" signature. Responsible process here is Orca Helper (com.stablyai.orca.helper) which has no TCC AudioCapture row. Ruling: keep `.tapOnly` default (X6 unchanged, still unmeasured with permission); E2E 02.1 SKIPs (not FAILs) when `dev record` hits the 40 s timeout (exit 124), reason 「システム音声の録音許可が未応答（責任プロセス: ターミナル）」; the real measurement is a 👤 item (run `scripts/e2e-check.sh` from Terminal.app, which had AudioCapture in the spike, or answer the dialog). — cost if wrong: a genuine 40 s hang would be hidden as SKIP; mitigated by the SKIP reason naming the condition.
- Final review (opus): Critical 0 / Important 1 (I1 ProcessTapSource.start has no timeout → 90 s freeze while permission pending; Ruling: add startTimeout = 10 s, new AudioSourceError.timedOut(call:), late objects torn down) / Minor 7 (M2 audio subs on start failure, M3 endedAt ms truncation, M4 observe skipped while paused, M5 ring keypath — in this wave; M1 withOutputClock drops tap audio when the output device has inputs — DEFERRED, must be fixed before flipping the default; M6 self-stop exit 1 — deferred; M7 already committed 91a39cc). Fix wave dispatched (fresh opus implementer, BASE 71a2d4c).

#### 最終レビューへ繰り越した Minor（未対応。次の計画の該当箇所を触るときに拾う）
- Task 1: review clean (spec ✅, approved). minor (deferred): startHost captured before AudioDeviceStart (per_second index skew); dictation collector not cancelled on throw; withOutputClock with empty output UID; pkill afplay broad; first-run garbage in raw log. IOProc path untested until the user grants permission.
- Task 2: review clean (spec ✅, approved). minor (deferred): writtenEnd after trim untested; Int(rounded) traps on NaN/inf; AudioFixturesTests + generic `Box` helper live in MeetingClockTests.swift.
- Task 3: review clean (spec ✅, approved). minor (deferred): concurrent test never straddles ring end; planar wrap, invalid-layout drops, frameCount>capacity untested; planar inner loop re-unwraps per sample.
- Task 4: review → Needs fixes. Important (plan-mandated): PCM buffers allocated per convert (SampleConverter.swift:94,:117). minor (deferred): .error status silently dropped; partial trailing frame dropped; struct copies share the AVAudioConverter. Fix round 1 dispatched (resumed implementer; FIX_BASE 1d54ac6).
- Task 5: review → Approved (Spec ✅ / Quality ✅). minor (deferred to final review): aligner advanced before I/O in write (drift if caller continues after a write error — treat write error as terminal in Task 10); open-after-failed-finishSegment loses .closed; startSegment handle not closed explicitly if seekToEnd throws; Segment.url unused; test depth for boundary slicing/silence straddling/close exactly at 300 s; repairHeader data size may be odd after crash (round down to frame multiple — consider in Task 12); no invalidHeader test.
- Task 6: review → Approved (Spec ✅ / Quality ✅). minor (deferred): stale merged/<track>-N.wav from a prior run not removed (Ruling: callers use the returned [TrackFile], never a directory scan — carry to Tasks 10/12/13); partial file left if a write throws mid-run; tolerance-boundary and overlap-within-tolerance untested; zero-length segments untested.
- Task 7: review → Approved (Spec ✅ / Quality ✅). Implementer rewrote two test sketches per ruling X2/X3 (derivation in task-7-report.md). minor (deferred): no tests for now<lastTick clamp, empty chunk, loud mic chunk after judgement.
- Task 8: review → Approved with minors (opus). Fix round 1 dispatched (resumed implementer; FIX_BASE 5fab378): flush-before-reset at gap (+test), deinit teardown, stronger failure/timeout tests, count callbacks before guards, Ruling: defaultOutputDeviceUID uses kAudioHardwarePropertyDefaultOutputDevice (not System/alert device) — cost if wrong: only affects .withOutputClock. Accepted as-is: selector in call names; stop-while-start-pending returns immediately (deferred to final review); tail chunk hostTime approximate; re-start after timed-out stop queues behind teardown. SDK check: CATapDescription.bundleIDs exists (macOS 26); exclusion semantics unverified on device (👤 Task 15).
- Task 8: fix round 1/5 (6 addressed, 0 open; commits 5fab378..4a63b74). minor (deferred): no test that an empty-buffer callback is counted.
- Task 9: fix round 1/5 (4 addressed + doc comment, 0 open; commits 2abfd0c..d06b897). minor (deferred): SourceDrainTests timeout margins (~200 ms headroom); no fire-before-install gate test; dropped invalid-hostTime buffers uncounted.
- Task 10: fix round 1/5 (9 addressed, 0 open; commits afb4691..e0db319). Residual minors carried INTO Task 11 (same code paths): tick can land during stop's final save (set monitor=nil after ticker cancel); reportWriterFailures before persist in pause/resume; doc comment that resume() may throw yet leave state .recording. Deferred: final-save-failure path, mid-stream write failure and stale-ticker guard untested; test-only task leak in withTimeout; internal members comment.
- Task 11: fix round 1/5 (4 addressed, 0 open; commits 739a105..c29cedf). minor (deferred): providerErrorDuringTickIsSkipped uses a 50 ms negative wait.
- Task 12: review → Approved (Spec ✅ / Quality ✅). minor (deferred): no <44-byte file test; no idempotence / stale-duration-overwrite test; convoluted fixture build; unreachable `?? 0`.
- Task 13: fix round 1/5 (5 addressed, 0 open; commits efb88a2..4fe2fc2). minor (deferred): .noAudioTrack untested; id-collision path untested; 2 ms tolerance loose.
- Task 14: Ruling — E2E items follow Task 16's definitions (02.1 dev record 5 s / 02.2 dev import m4a+wav), superseding the task-14-lead-notes item list; Task 16 Step 1 is thereby folded into Task 14 (own commit), Task 16 becomes build-app + full e2e run + ledger. Task 15 (👤) deferred to the user per the brief.
- Task 14: fix round 1/5 (5 addressed, 0 open; commits def453f..13a0516). minor (deferred): self-stop before timer → exit 1 without report.
- Task 15: 👤 deferred (per brief) — recorded in master progress 「利用者への依頼」.
- Final review (opus): Critical 0 / Important 1 (I1 ProcessTapSource.start has no timeout → 90 s freeze while permission pending; Ruling: add startTimeout = 10 s, new AudioSourceError.timedOut(call:), late objects torn down) / Minor 7 (M2 audio subs on start failure, M3 endedAt ms truncation, M4 observe skipped while paused, M5 ring keypath — in this wave; M1 withOutputClock drops tap audio when the output device has inputs — DEFERRED, must be fixed before flipping the default; M6 self-stop exit 1 — deferred; M7 already committed 91a39cc). Fix wave dispatched (fresh opus implementer, BASE 71a2d4c).

### 計画 03（台帳から転記、2026-10-26）
- Ruling Y1 (#1 devices.json default): (a)+(b) — `DeviceRegistry` reads a top-level `[]` as empty and migrates to `{"version":1,"devices":[]}` on next save; Task 4 ALSO changes `PortableDefaults.standard[.devices]` (Storage/PortableConfigStore.swift) to `{"version":1,"devices":[]}` and adjusts any test. Cost if wrong: one extra migration path.
- Ruling Y2 (#2 snake_case round trip): explicit `CodingKeys` (`device_uid`, `model_uid`) on `RegisteredDevice` and `DeviceIdentity`; every JSON read/write in plan 03 (Tasks 4, 10, 11) uses `AutoNoteJSON` (`encoder()`/`decoder()`/`compactEncoder()`), never a bare JSONEncoder (#16 folded in).
- Ruling Y3 (#3 selfStops): `func selfStops() async -> AsyncStream<Void>` — the subscription to `session.events()` is established before returning. Own-stop detection: `RecordingSessionControl` sets `expectingOwnStop = true` before awaiting `session.stop`, and the first `.stopped` consumed while it is set clears it and is NOT forwarded; any other `.stopped` is a self-stop. Cost: a race only if two stops overlap, which the gate prevents.
- Ruling Y4 (#4 reentrancy): (b) — the coordinator holds the in-flight start / reattach as a `Task`; stop, disconnect, and a new grace cancel it (Reattacher checks `Task.isCancelled` between retries and before `attachMicrophone`); effects run serially on the coordinator actor. `handle(.added)` returns after scheduling the reattach, not after it completes; `reattachFallbackShowsBanner` is written against that (advance the manual timer between steps).
- Ruling Y5 (#5 monitor subscribers): (a) — `DeviceMonitor.events()` supports multiple subscribers; each new subscriber first receives `.present(_, .launch)` for every currently-connected candidate, once. Coordinator subscribes once in `run()`.
- Ruling Y6 (#6 initial reload): (c) — `Coordinator.run()` calls `registry.reload()` first; `DeviceRegistry.match`/`entries` lazily load if nothing was loaded yet.
- Ruling Y6b (#6b adapter test): `adapterPassesMicrophoneUID` asserts `factory.microphoneUIDs == [uid]` and the manifest `device`; for nil the expected device is `FakeAudioSourceFactory`'s default input. Adapter tests may use `SessionHarness` via `@testable`.
- Ruling Y7 (#7 duplication with plan 02): (a) — Task 2's Files add Modify `Audio/AudioDeviceLookup.swift`: `CoreAudioDeviceLookup.transport(_:)` delegates to `CoreAudioHardware.transport(coreAudio:).rawValue`; property-read helpers shared internal; Task 1 references `ProcessTapSource.aggregateUIDPrefix` instead of a literal.
- Ruling Y7b (#7b GP c1): (b) — disconnect while paused then reattach → stays PA (`X, g, M+(A)` only); resuming is the user's action (spec §5.9 「再開時は機材復帰を待つ」 read as: the user's resume waits for the device, not that reattach resumes). Cost if wrong: one table cell + its test.
- Ruling Y8 (#8 public inits/fixtures): Task 1 Files add `Sources/AutoNoteTestSupport/Devices/DeviceFixtures.swift` (public fixtures `A` `B` `U` `bt` `jack` `aggregate`, `RawAudioDevice.fixture*`, `btRef`); contract rule X8 applies (every Produces/TestSupport type: `public` + explicit `public init`); `InMemoryRegistryStorage`/`FakeMacIdentity` live in TestSupport with public members.
- Ruling Y9 (#9 retry policy): non-retryable errors (`AudioSourceError.microphonePermission`, `RecordingError.notRecording`) → immediate `.failed`; retry only `deviceNotFound`, `coreAudio`, `timedOut`; add a test per class.
- Ruling Y10 (#10 corrupt file loop): quarantine once per content (remember the SHA-256 of the last quarantined content; identical content is not re-quarantined); `PortableDevicesStorage.init` gains `timeZone: TimeZone = .current`.
- Ruling Y11 (#11 effects table/snapshots): the implementer extends the effect execution to all 13 effect kinds; snapshots are emitted after state application (a `recording` snapshot without meetingID is the legitimate "starting" display); `snapshotsStreamEachTransition` expectation is derived from the state machine by the implementer (document the derivation, as ruling X2/X3 did).
- Ruling Y12 (#12 Codable): Task 6 makes `RecorderSnapshot` and `RecorderState` `Codable` (dates via AutoNoteJSON); Task 10 encodes them with `compactEncoder()`.
- Ruling Y13 (#13 run termination): `run()` returns when `monitor.events()` ends or the task is cancelled; `selfStops()` is consumed in a child task cancelled with `run`. Task 10 `quit`: stop the recording (if any) then cancel `run`, then exit 0.
- Ruling Y14 (#14 harness): Task 8 Files add `Tests/AutoNoteCoreTests/Devices/CoordinatorHarness.swift` (FakeRecordingControl, FakeUserNotifier, ManualTimerScheduler, InMemoryRegistryStorage, FakeMacIdentity, DeviceMonitor over FakeAudioHardware, registered A, config closure; helper to "connect" a device = put it on the fake hardware and pump the monitor); Task 9 reuses it.
- Ruling Y15 (#15 device JSON): Task 10 creates `Sources/autonote/DeviceJSON.swift` (DeviceIdentity → one-line JSON incl. `candidate`); Task 11 uses it; each task updates the `dev` usage text for its subcommand.
- Ruling Y16 (#16): folded into Y2 (`AutoNoteJSON.compactEncoder()`).
- Ruling Y17 (#17 copy duplication): `DeviceNoticeCopy.body` calls `Banner.grace(seconds:)`.
- Ruling Y18 (#18 sleep window): plan as written (recordings spanning sleep are out of scope); note in Task 3's report.
- Ruling Y19 (#19 e2e): Task 11 adds E2E item `03.3 dev auto-record が quit で終わる`（`printf 'quit\n' | dev auto-record` exit 0, first line `{"kind":"status","state":"idle"`）.
- Ruling Y20 (#20): `AutoRecordCoordinator.stop(reason: StopReason = .manual)`.
- Ruling Y21 (#21 UID split): `split(separator: ":", omittingEmptySubsequences: false)` stated in Task 1 Step 3; add tests for built-in mic, nil name, nil UID.
- Ruling Y2 (amended): with `.convertFromSnakeCase` the decoder camel-cases the JSON key before matching CodingKeys, so raw values `"device_uid"`/`"model_uid"` never match. CodingKeys use `"deviceUid"`/`"modelUid"`; the on-disk keys remain `device_uid`/`model_uid` (round-trip test asserts this). Applies to `RegisteredDevice` in Task 4 too. — Why: AutoNoteJSON key strategy. — Cost if wrong: devices.json keys drift from snake_case.
- Ruling Y22 (sleep cancellation): `extension TimerScheduling { func sleep(seconds:) async throws }` throws `CancellationError` promptly when the calling task is cancelled (cancels the underlying timer) — Why: Y4 relies on cancelling the reattach task; silent return would fire all retries back to back — Cost if wrong: plan text for Tasks 3/7 says non-throwing; Task 7's Reattacher must `try await` and return `.failed` on cancellation (the coordinator ignores results of a cancelled reattach).
- Ruling (Minor 1): removals arriving between willSleep and didWake are emitted as `.removed` (window opens at didWake, per spec §11.1 "復帰から 10 秒以内") — harmless while idle; Y18 puts sleeping-while-recording out of scope; Task 10 👤 step 8 observes real behaviour. Minor 3: document only.
- Ruling Y23 (load failure): `reload()` stays non-throwing (coordinator calls it on every `.added`); the registry records `loadFailed` with the error; while set, `register/ignore/remove/setDisposition/setStartOnModelMatch` throw `DeviceRegistryError.storageUnavailable(String)` and `match` returns `.unknown`; a later successful `reload()` clears it. A failed `backupCorrupt` is treated the same way (no overwrite of the only copy). — Why: never destroy devices.json on a transient read error — Cost if wrong: a read-only vault makes registration impossible until fixed (acceptable).
- Ruling Y3 (amended): the adapter remembers the requested `StopReason?` and drops only a `.stopped` carrying that same reason; any other `.stopped` is a self-stop — Why: a disk-full stop racing our own stop must not be swallowed — Cost if wrong: none observed (session stops are serialized).
- Ruling Y4 (amended): `stop` awaits an in-flight `start` and then stops (RecordingSession.start is serialized and cannot be aborted by Task cancellation); only the reattach task is cancelled. A start returning after its session ended is ignored. — Cost if wrong: a stop pressed during a slow start waits up to the 10 s start timeout.
- Ruling Y24: `AutoRecordCoordinator.snapshots()` is `async` (goes through the gate so the initial value is consistent); `bookmark` and `handle(_ action:)` are gated too. Plan 06's RecorderPort awaits it. A registration answer given after the device was unplugged still registers/ignores it (the pending prompt remembers the identity).
- Ruling Y25 (I1): fix — DeviceRegistry.reload builds the new list locally and assigns once after the last await; mutations are serialized (own gate); regression test for an overlapping reload/register.
- Ruling Y26 (I2): fix — during grace, a `.usb` device whose transport, modelUID (non-nil, non "0 0") and name equal the origin's counts as the origin's return (same as UID/entryID match); `uidKind` heuristic unchanged; 👤 USB step already covers the port change. — Cost if wrong: two identical USB mics swapped during grace are treated as the same (acceptable).
- Ruling (M1): fix — CLI `quit` always routes `stop(reason: .appTerminating)` through the gate (no-op when idle), then cancels run.
- Ruling (M5): fix — `dev auto-record` handles SIGINT like `quit`.
- Ruling (M9): document on `AutoRecordCoordinator` that the gate is not re-entrant (notifier/recorder must not call back into the coordinator synchronously) — plan 06 note.
- Ruling (M2): parked — a queued attach after cancel hits a session that is detached or stopped; `attachMicrophone` on a stopped session throws and is ignored. Revisit if 👤 shows audio glitches.
- Ruling (M3): Y6 lazy load dropped — run() reloads first and every `.added` reloads; plan 06 settings UI must call reload() before entries(). Ledger + overview note.
- Ruling (M4, M6, M7, M8): parked — M4/M6 are 👤 observations; M7 (Continuity/unknown transport prompts) → plan 06 may filter by transport; M8 2 s bounded waits acceptable.
- Ruling Y27: CLI quit path cancels the countdown (gated) before stop(.appTerminating) — stop is a no-op during countdown, so without it the timer could start a session just before exit (the reviewer's M1 case) — cost if wrong: one extra gated no-op call on quit.

#### 最終レビュー（opus、HEAD f5fdd57）と修正波
- Critical 0 / Important 2（I1 レジストリの reload 再入、I2 USB 別ポート復帰）/ Minor 9。修正波 1 回: 38bd152（I1）・08d8a7c（I2）・ba0199e（M1+M5）・974aeee（M9）。限定再レビュー（opus）: 5 件すべて ADDRESSED、新規の Critical/Important なし。残った Minor「quit ループ後も SIGINT が無視されたまま（遅い stop 中の 2 回目の Ctrl-C が効かない）」は保留（stop は有界、dev 専用 CLI。計画 06 のアプリ終了経路はこのハンドラを使わない）。
- 繰り越した Minor（未対応・次の計画で該当箇所を触るときに拾う）: ManualTimerScheduler の doc summary の順序（Task 3）、Task 7 のゲート付きテストでの `defer { mic.release() }`、willSleep〜didWake 間の切断が `.removed` として出る件（裁定どおり現状維持）。

### 計画 04（台帳から転記、2026-10-27）
- 実行前スキャン（基点 3de330f）: API の読み替え 5 件 — ① 共有プロトコルのファイル名は `Transcription/TranscriptionProtocols.swift`（計画の `Protocols.swift` を読み替え、Z1）、② TestSupport のヘルパ配置（`u()` は Samples.swift、`TemporaryDirectory` は別ファイル、Fakes.swift の fake は actor なので `await` が要る、`FakeError(message:)`、Z2）、③ `DevCommands` は internal enum で `Dev*.swift` は `Sources/autonote/` 直下（Z3）、④ `OperationGate` は `tryEnter/wait/leave` の struct で `withGate` ではない（BatchGate は計画どおり Mutex、再利用しない）、⑤ `HintBudget.fit` は `separator` 引数を持つ（Z4）。そのほか `TranscriptFinalizer` の既定付き `deduplicator:` は無害。
- 実行前スキャン（タスク間）: Task 2 の `waitUntil` が Devices テストのファイル private 版と衝突（Z5）、Task 6 の `timelineGapAfterPause` / `silenceOnlyNeverDecodes` が先頭無音の扱いと矛盾（Z6）、Task 8 の `batchRejectsAppleEngines` が非 throws で `try`（Z11）、Task 11 の `progressWeightedByDuration` は fake が進捗を呼ばない場合がある（Z7）、Task 12 は Apple Silicon が要る（Z9）。それ以外のタスク対（MachineKind、PCMAudio 系、EngineCatalog、WhisperCore、BatchGate、LiveFeed.make、FinalTranscriptionRunner の署名）は整合。
- Ruling Z1: プロトコルのファイルは `Transcription/TranscriptionProtocols.swift`（概要 §8c）。計画の `Protocols.swift` はそう読み替える。
- Ruling Z2: TestSupport の配置はそのまま（`u()` は Samples.swift、TemporaryDirectory.swift、Fakes.swift）。fake は actor なのでテストは `await fedChunks/startedWith/calls`。Task 10 が編集するのは Fakes.swift だけ。
- Ruling Z3: 新しい CLI ファイルは `Sources/autonote/` 直下（DevEngines / DevTranscribe / DevModels / DevMicCapture.swift）。`Dev/` サブディレクトリは作らない — 既存の配置に合わせる。コスト: ファイルの移動。
- Ruling Z4: `WhisperPrompt.make(hints:)` は `HintBudget.fit(hints, separator: "、").included.joined(separator: "、")`。`longDictionaryIsTrimmed` も同じ呼び出しと比べる。
- Ruling Z5: Task 2 の TestAudio.swift がモジュール直下の `waitUntil(_ condition: () async -> Bool) async throws`（10 ms ポーリング、約 5 秒でタイムアウトして throw）を 1 つだけ持ち、Devices/MicrophoneReattacherTests.swift と Devices/DeviceMonitorTests.swift のファイル private 版 2 つを消す（スイート内のメソッドは残す）。理由: 同じ署名の private と internal の自由関数は呼び出し側で曖昧になる。
- Ruling Z6（Task 6 ChunkPlanner）: 先頭の無音は削る — 窓に発話フレームが無い間は `windowStart` を最初の発話フレームまで進める。窓内の発話が minSpeech 未満なら `partial` を出さず、境界・強制切りでの確定も発話が minSpeech 未満なら `.skip`。理由: `timelineGapAfterPause` は 2 つ目の final を 60±0.05 に期待し（削らないと窓の開始が音声 3.0 になる）、`silenceOnlyNeverDecodes` も要る。コスト: 発話の開始が最大 1 フレーム（20 ms）遅れる。
- Ruling Z7（Task 11）: ランナー自身がファイル境界ごとに時間重み付きの累積進捗を報告し（最後に 1.0）、ファイル内のコールバックはそのファイルの重みの中に縮めて渡す。理由: `progressWeightedByDuration` は fake が `progress` を呼ばなくても 0.25 を見る。
- Ruling Z8（Task 8 E2E 04.2）: 声は `scripts/make-sample-audio.sh` と同じ選び方（`JA_VOICE`、既定 Kyoko、無ければ最初の ja_JP、無ければ SKIP）。Kyoko を直書きしない。
- Ruling Z9: Task 12（👤 Apple Silicon）は利用者に回す — この Mac は Intel。「利用者への依頼」に記録済み。Task 13 は計画どおり先へ進む。
- Ruling Z10: Task 9 Step 4（👤 マイク、任意）は飛ばし、結果表に「マイク確認は未」と書く。
- Ruling Z11: Task 8 の `batchRejectsAppleEngines` は `async throws`。
- Ruling Z12（Task 1 Step 8）: `whisper.framework` は `.build` 配下（bin パスか artifacts の `macos-arm64_x86_64` スライス）から探し、スライスのフレームワークをコピーして計画どおり otool / lipo で検証する。
- Ruling Z16（Task 5 Step 1）: プロンプトの持ち込みは実装者が計画の規則で (a)/(b) を決め、WhisperContext.swift と結果表の項目 1 に書く。結果は (a) `carry_initial_prompt`。
- Ruling Z17（Z20 で置換）: SwiftPM のバイナリターゲット取得が keychain で止まる件（`swift package --disable-keychain resolve`）。URL ターゲットをやめたので不要になった。
- Ruling Z18: ggml / whisper のログ — `WhisperRuntime` が `whisper_log_set` / `ggml_log_set` で静かなコールバック（エラーだけ stderr）を入れ、テストと CLI の出力を汚さない。Task 5 で実施。
- Ruling Z19: `WhisperContext` は UTF-8 の文字を途中で割るバイト単位の BPE トークンを 1 つの `TimedToken` にまとめる（有効な UTF-8 になるまでバイトを貯め、スパンは最初の t0〜最後の t1）。理由: ライブの `OverlapTrimmer` がトークン文字列を連結するので、U+FFFD が日本語の途中結果を壊す。コスト: トークン境界が数 ms 粗くなる。
- Ruling Z20: 公式の URL バイナリターゲット（b5454）をやめ、ローカルでビルドした `tools/whisper.xcframework` に置き換える（同じ commit d1be6fd、x86_64 スライスは AVX/AVX2/FMA/F16C を明示、arm64 は上流の Metal / Core ML フラグ）。`scripts/build-whisper-xcframework.sh` が作り、build-app.sh / e2e-check.sh が無ければ呼ぶ。`Package.swift` は `.binaryTarget(path:)`。理由: 公式の x86_64 スライスは AVX なしで small が RTF 1.5 以上、spec §6.2/§17 の Intel 既定（large-v3-turbo の一括）が成り立たない。Intel の macOS 26 機はすべて AVX2 を持つ。コスト: 新しいクローンで最初に数分のビルドが要る。Task 1b として追加。
- Ruling Z21（Task 6 規則 1）: 無音境界では窓内の発話合計が minSpeech（0.3 秒）以上なら確定する。ブリーフの「b − windowStart ≥ 1.0」の下限は外す（発話の少ない窓は Z6 で skip）。理由: spec §17（体感 5 秒以内）— 短い返事のあとに無音が続いても 8 秒の強制切りまで待たされる。コスト: 途切れがちな発話で短い whisper 窓が増える。
- Ruling Z22: 強制切りから始まる窓の 1.0 秒の重なり部分にある発話は minSpeech に数えない（どのみちトークンは捨てられる）。理由: レビュアの Important #2（確定が 7 秒遅れ、whisper に無音を食わせる）。コスト: 強制切りの直後の skip が少し増える。
- Ruling Z23: E2E 02.1 の失敗は計画 02 の挙動（システムタップを畳む間もマイクが書き続け、停止の遅れが約 0.65 秒）。Lead 追加の Task 8b で扱う。原因は `DevRecord` が `session.start` の戻り（マイクエンジン起動で約 0.7 秒）のあとに `--seconds` まるごと待っていたこと。`seconds − session.elapsed()` だけ待つように直した（4 行）。02.1 の長さは 5.003〜5.006 秒。計画 02 の 👤 項目（上の追記）もこれで片付く。
- Ruling Z24: 計画 02 の 2 つのタイミングテスト（`SourceDrainTests.runAwaitingReturnsFalseWhenWorkOutlastsTimeout`、`ProcessTapSourceTests.startTimesOutWhenHardwareStartBlocks`）は負荷がかかると不安定になり、E2E の項目 1 を赤くしうる（単独実行では通る）。計画の最後に Lead が静かな状態で再実行し、まだ不安定なら最終の修正波でタイミングの余裕を広げる（テストのみの変更）。
- Ruling Z25: Task 9 の遅延の増加は `dev transcribe --realtime` のペース配分の漂い（処理のあとに sleep していた）。修正ラウンドで締め切り（開始 + 0.1 秒 × チャンク番号）方式に直し、3 案を測り直して再判定。
- Ruling Z26: Task 9 レビューの指摘（SegmentationStrategyTests.swift:8-10 の doc コメントと `@Test` が struct 内でカラム 0）は修正ラウンドにせず最終の修正波へ回す — 3 行の空白だけで、走っている Task 10 の実装者と衝突させない（実装者は同時に 1 人）。
- 追加の裁定（番号なし）: Task 1b は RTF 0.345（目標 ≤ 0.33 に対し実質達成と判定。0.218 の参照値は `-nt`＝タイムスタンプなしだった）、DispatchQueue の QoS は `.utility` のまま、`xcodebuild -create-xcframework` が失敗する環境（Xcode プラグインの問題。`xcodebuild -runFirstLaunch` で直る）向けに手組み xcframework のフォールバックを持つ、`WhisperRuntime.systemInfo()` は静的バッファなので Mutex で守る。Task 5 の `waitIfPaused` は非 throws のまま（概要 §8b）でキャンセルされたら返り、transcriber 側が throw する。
- タスクごとの結果（最終コミット、レビュー判定、修正ラウンド）:
  - Task 1 af16591 — 仕様 ✅ / 品質 承認（sonnet）、修正 0。350 テスト
  - Task 1b c346d09 — 仕様 ✅ / 品質 承認（opus）、修正 1（コミット固定の検証と結果表の記述）。419 テスト
  - Task 2 586918d — 仕様 ✅ / 品質 承認（sonnet）、修正 1（未使用の `EventWaitTimedOut` を削除）
  - Task 3 d1773d5 — 初回は品質 不承認（再ダウンロードで正常なファイルを先に消す）→ 修正 1（`replaceItemAt`）で承認。374 テスト
  - Task 4 099a630 — 仕様 ✅ / 品質 承認（sonnet）、修正 0。388 テスト
  - Task 5 377fa62 — 仕様 ✅ / 品質 承認（opus）、修正 1（キャンセルのテスト強化、`waitIfPaused` のキャンセル対応、Z19）。418 テスト
  - Task 6 d89363b — 初回は品質 不承認（デコード失敗の握りつぶし、窓末尾 0.8 秒の発話の取りこぼし）→ 修正 1（ログ、Z21、Z22、`finish` の冪等性）で承認。437 テスト
  - Task 7 6615f68 — 初回は品質 不承認（変換エラーでストリームが終わらず無言で止まる、変換前に mapper へ追記）→ 修正 1 で承認。457 テスト
  - Task 8 ac6b980 — 仕様 ✅ / 品質 承認（opus）、修正 1（エラー経路の `live.finish()`、到達しない分岐の削除、04.1 を stdout だけ読む、`--model-path` の不在は `modelMissing`）。Lead が diff stat と `bash -n` で確認
  - Task 8b 538a26d — Lead が 4 行の diff を確認（Z23）。フル E2E 29/0/0
  - Task 9 be8189c — 仕様 ✅、品質は空白 1 件のみ（Z26 で最終波へ）。修正 1（Z25 のペース配分と再測定）
  - Task 10 0776470 — 仕様 ✅ / 品質 承認（opus）、修正 0。472 テスト
  - Task 11 cfce6f6 — 仕様 ✅ / 品質 承認（opus）、修正 0。481 テスト
  - Task 12 — 👤 保留（下記）
  - Task 13 54efaf5 — 仕様 ✅ / 品質 承認（sonnet）、修正 0。Spikes モジュールと E2E 8/14/15/15b を削除
- 計測:
  - small（ja、実音声 60 秒、beam 5）: ソースビルドの whisper-cli は RTF 0.218（`-nt`、4 スレッド）/ 0.311（2 スレッド）。公式 xcframework（AVX なし）を `WhisperContext` 経由は 1.576 / 3.119 で 7〜10 倍遅い。Task 1b 後の自前 xcframework は 0.345（タイムスタンプ付きの同条件 whisper-cli の 1.05 倍）。
  - Task 8（ja-5min、small、`dev transcribe`、一括）: RTF 0.335、CER 0.2712（`--no-punct` 0.2218）。`--hints "AutoNote,所沢,Kubernetes"` で CER 0.2671、`--lang auto` は ja と同じ出力（差 0）。
  - Task 9（Intel、DictationTranscriber、`tools/samples/ja-segments.wav` 77.5 秒＝10 文、`--realtime`、締め切り方式で再測定）:

    | 案 | 確定件数 | 最長の発話 | 確定遅延の中央値（wall − end） |
    |---|---|---|---|
    | default | 2 | 60.01 秒 | 1.24 秒 |
    | frequent | 2 | 60.01 秒 | 1.21 秒 |
    | silence | 10 | 8.98 秒 | 0.01 秒 |

    判定基準（件数 8〜13、最長 ≤ 15 秒、遅延中央値 ≤ 3.0 秒）を満たしたのは silence だけ → `SegmentationStrategy.current == .silenceFinalize`。silence の `end` は `finalize(through:)` に渡した時刻なので、体感の遅れは沈黙判定の待ち約 0.8 秒に処理時間を足したもの。直す前は 60 秒で 2 件・遅延が 1 文ごとに約 0.7 秒増えていた（Z25）。
- 保留した Minor（次に該当箇所を触るときに拾う）:
  - Task 1: build-app の `find` が artifacts ディレクトリ無しで pipefail に当たる、`MachineKind.current()` がテストされていない
  - Task 1b: スクリプトの libtool 警告を捨てている、`DTSDKName`、`.tmp` の残骸
  - Task 2: リサンプルのアサーションが弱い、`chunks()` に 0 以下の `chunkSeconds`
  - Task 3: 共有ダウンロードタスクは非構造化（呼び出し側のキャンセルでは止まらない。他の呼び出し側が使うので許容）、インストール済みの近道なし（ブリーフどおり）
  - Task 4: ライブのフォールバックが一括の順序を使う、カタログ外のモデル、地域の完全一致、`displayName` の nil モデル
  - Task 5: モデル読み込み中のキャッシュのロック、actor 上のファイル読み、`@unchecked Sendable` のコメント、最後のセグメントの終端クランプ、`WhisperTokenAssembler` が不正なバイトで flush まで貯める（4 バイトで打ち切れば直る）、実 `WhisperContext` のキャンセルが未テスト
  - Task 6: 他の Minor 8 件、強制切りの先の 0.3 秒未満の発話の末尾は skip（規則 4）
  - Task 7: コンバータの flush が 64 フレームの 1 回呼び（`endOfStream` まで繰り返すのが正確）、他に #5〜#9
  - Task 8: ダウンロード進捗の粒度、`--realtime` のずれ
  - Task 9: `--realtime` の `try? clock.sleep(until:)`（キャンセル時）、silence の遅延指標の意味（`wall − end` は構造上ほぼ 0）
  - Task 10: 定期保存のエラーは `finish()` まで握りつぶされる、`finish()` 以外に中断経路がない、`start` の二重呼びが無防備、`saveInterval` 内の 2 回目の保存スキップのテストが無い
  - Task 11: 2 つ目の書き込みが失敗したとき raw.json が残る、`WAVFile.info` のフォールバックが到達しない、進捗コールバックがロックの外、system トラック失敗のテストが無い、キャンセルのテストが transcriber 内の再 throw 経路を通らない
  - Task 12: 下記
  - Task 13: 歴史的な「Spikes」のコメントが 2 か所（DevChecks.swift:7-8、CoreAudioHardware.swift:84）、フル E2E は計画の最後に Lead が実行
- Task 12 👤 保留: Apple Silicon 機が要る（この Mac は Intel）。`EngineCatalog.defaults(for: .appleSilicon)` の「仮」（`.speech` / large-v3-turbo / small）は未確定。手順は「利用者への依頼」の計画 04 Task 12。
- 台帳に番号のない欠番: Z13〜Z15 は台帳に記載が無い（Z12 の次は Z16）。

**最終レビュー（ブランチ全体、opus、BASE 3de330f..54efaf5）**: 判定「修正後マージ可」。Critical 0、Important 4、Minor 7（保留。M3/M4/M5 と Task 5 のプール負荷の注意は計画 05 の実行前スキャンへ持ち越す）。「判断しなかった事項」は台帳アーカイブの final-review.md §Declined を参照。
- Z27（I1）: RepetitionFilter 規則 (4) が数字列を壊す（10000円→10円）。数字（半角/全角）と区切り（, . 、）だけの繰り返し単位は縮約の対象外にし、計画 04 の規則 (4) の文面も修正。外れた場合の損失は数字の吃音がそのまま残る程度。
- Z28（I2）: バッチ経路に無音ゲートが無く、無音区間の幻覚が final.json に入りうる。復号後、区間内の発話が 0.3 秒未満（SilenceDetector と同じ RMS 規則・20 ms フレーム）のセグメントを捨てる。既存のバッチテストはトーン音声に差し替え（無音 WAV だと全セグメントが落ちるため）。
- Z29（I3）: ライブのトラックが finish() 前に終わっても failures に残らなかった。ストリームが早期終了したトラックを failures に記録し、finish() は失敗トラックの transcriber.finish() を飛ばす。
- I4（Z24 の恒久化）: SourceDrainTests / ProcessTapSourceTests の時間余裕を広げた（timeout 1.0 秒、ブロック 3 秒、上限 2.5 秒未満）。Z26 の字下げも同コミット。
- 修正波: 5c15ee7（I1）、bb03cb5（I2）、2da35f2（I3）、0a76f1f（I4+Z26）。再レビュー（sonnet）: 5 件すべて Addressed、新規の Critical/Important なし。再レビューの範囲外メモ 2 件は保留: 計画 04 本文 726 行付近の `wavFile(seconds:)` 例が実装の `wavFile(samples:)` と不一致（文書のみ）、`ProcessTapSourceTests.stopAfterTimedOutStartReturnsPromptly` は 200 ms のまま（負荷時に揺れる可能性）。

**Lead 検証（HEAD 0a76f1f、2026-10-27）**: `swift test` 487 テスト / 45 スイート 緑（アイドル実行、警告なし、Z24 の 2 件も緑）。`scripts/build-app.sh && scripts/e2e-check.sh` 25 PASS / 0 FAIL / 0 SKIP（04.3 base RTF 0.136、04.4 whisper-live RTF 0.349、02.1 を含む）。ログは scratchpad の plan04-final-swift-test.log / plan04-final-e2e.log。

### 計画 05（台帳から転記、2026-10-27）
- 実行前スキャン（基点 018c339）: API 74 行のうち差異 11・無し 4（うち #21 #30 は計画が作る）。読み替え 11 件は次のとおり。
  - #12 `Job.nextStage` は計算プロパティ（保存しない。JSON に出ない）
  - #18 共有プロトコルのファイルは `Minutes/MinutesProtocols.swift`（計画の `Protocols.swift` を読み替え）
  - #21 `AppPaths.claudeWorkingDirectory` は無い（Task 2 が `AppPaths+Minutes.swift` で追加）
  - #25 `ManifestStore.load(_:)` は `throws -> Manifest`（optional ではない。「読めない→何もしない」は `try?`）
  - #27 `ManifestStore.all()` は throws なし（`try` 不要）
  - #30 `PortableDefaults.standard` に `.prompt` は無い（Task 3 が追加）
  - #31 `PortableConfigStoreTests.createdDefaults` の期待値は 2 か所（Task 3 が両方直す）
  - #32 `DictionaryFile.parse(_:)` は `(dictionary:, issues:)` のタプル
  - #41 `VaultError.outputFolderUnavailable(URL)` はペイロードあり
  - #46 `Samples.manifest` は `.minutesGenerated`・`tracks: []`（テストで上書きする）
  - #70 `DevCommands.run` の default usage 一覧に `DevSummarize.usage` を足す指示が計画に無い
- そのほかのスキャン結果: タスク間の衝突表で 39 行のうち食い違い 10 件、未決 14 件を Y1〜Y32 で裁定。overview 8b の `PostProcessingQueue` init の記述が内部で矛盾（Y28）、8c の「`VaultWriter` / `PortableConfigStore` は出力フォルダごとに 1 インスタンス」と計画 05 の毎回 new が衝突（Y14）。
- Ruling P1: Task 1（👤 `claude -p` の 60 分・120 分を `--setting-sources project` で測る）は利用者に回す。各回で利用者の claude の使用量を消費するため計画自身が 👤 としており、Task 2〜14 は Task 1 に依存しない（Task 3 は計画の推定式 文字数 ÷ 1.0 + 16,000 のまま。Task 1 はその妥当性を確かめるだけ）。「利用者への依頼」に記録済み。コスト: 外れていれば `charsPerToken` と分割閾値の定数 1 つを後で下げる。
- Y1: 共有プロトコルのファイルは `Minutes/MinutesProtocols.swift`。01 / 04 の型は再定義しない。`StageName` は String 定数の名前空間で `StageName.all: [String]`。
- Y2: 計画 01 Storage はコードに合わせる — `ManifestStore.load(_:) throws -> Manifest`（「読めない→何もしない」は `try?`）、`ManifestStore.all() -> [Manifest]`（throws なし）。
- Y3: Task 3 は `PortableConfigStoreTests.createdDefaults` の期待値 2 か所を `[.dictionary, .prompt, .frontmatter, .devices]` に直す。
- Y4: `DictionaryFile.parse(_:)` は `(dictionary:, issues:)`。ステージは `.dictionary` を取り `issues` は無視する。
- Y5: `VaultError.outputFolderUnavailable(URL)` はペイロードあり。`catch VaultError.outputFolderUnavailable` のパターンで受ける。
- Y6: `Samples.manifest` は `.minutesGenerated` / `tracks: []`。テストが `status`・`tracks`・`endedAt` を必要に応じて上書きする。
- Y7: Task 14 は `DevSummarize.usage` を `DevCommands.run` の default usage 一覧に足し、既存の `rest` を使う。
- Y8: `ClaudeLocator.locate(home:loginShellLookup:isExecutable:)` に既定引数（`homeDirectoryForCurrentUser`、`ClaudeLocator.loginShellLookup`、`isExecutableFile(atPath:)`）。`SummarizerFactory` は既定で `locate()` を呼ぶ。
- Y9: `PostProcessingQueue` の `jobStore`・実行中タスク・enqueue / rerun のヘルパは `internal`（`private` にしない）。`+Commands.swift` の拡張がコンパイルできるように。
- Y10: TestSupport の `ScriptedStage` のストリーム引数は `release:`（`gate:` にしない。`BatchGate` と紛らわしいため）。
- Y11: `job.transcriptEngine` は TranscribeStage が引き続き書く（計画 06 が表示する）。欠陥ではない。
- Y12: `resolveOverwrite(false)` は manifest の status も `.minutesGenerated` にする（議事録はアプリ領域にあり、Vault は意図して更新しない）。コスト: status 書き込み 1 回。
- Y13: `standardStages(runner:summarizer:timeZone: TimeZone = .current)` は `timeZone` を `WriteVaultStage` へ渡す。Task 12 のテストは `TimeZone(identifier: "Asia/Tokyo")!` を渡し、CI のタイムゾーンによらず固定ファイル名で通す。
- Y14: 新規 `Minutes/SharedVaultServices.swift`。`public final class SharedVaultServices: Sendable`（出力フォルダのパス + paths.root をキーに Mutex で守るキャッシュ）、`public static let standard`、`vaultWriter(outputFolder:paths:now:)`、`configStore(outputFolder:paths:)`。Task 9〜13 のステージと `Retention` は init の `services: SharedVaultServices = .standard` を受け取り、`VaultWriter` / `PortableConfigStore` を直接作らない。テストは隔離のため `SharedVaultServices()` を渡し、計画 06 は `.standard` を使う（overview 8c の「1 インスタンス共有」を満たす）。Task 9（最初の利用者）が作る。コスト: 間接層 1 つ。
- Y15: Task 6 の `classifiesFailures` は `@Test(arguments:)` でパラメータ化し（stdout と期待する `SummarizerError` の case）、実際の `#expect` を持たせる。全タスク共通: 計画中のコメントだけのテスト本体は実行できるアサーションにする。コメントだけのテストはレビューで ❌。
- Y16: 分割規則の端: パートは空にしない。1 発話だけで予算の半分を超えても単独で 1 パートにする。発話数が `minimumParts` 未満ならパート数 = 発話数（最小 1）。
- Y17: ジョブの順序は `(createdAt, id)` の昇順。テストは id の同順位判定に頼ってよい。
- Y18: `.retry(after:)` は 1 ステージにつき最大 `maxAttempts = 24` 回まで受け付ける（毎時の rate limit 再試行で約 24 時間）。超えたら最後の理由でジョブを failed にする。`generation` は summarize の再実行が実際に始まるときだけ増える。
- Y19: 失敗した regenerate は done のジョブに `summaryFailure` を残す（UI が表示する）。通知を `meeting:generation` で重複排除するのは計画 06 の担当（06 への申し送り）。
- Y20: `Retention.purgeExpiredAudio` が音声を消すのは、`final.json` があり、status が `.recording` / `.tooShort` でなく、`transcribe` が未完了のジョブが無い会議だけ。4 つ目のテストにジョブ無しの `.recorded` を入れる。
- Y21: 出力フォルダが無いときの「書き出し済み」は `paths.vaultStateFile(id)` の存在で判定する。
- Y22: Task 9 のフォールバック（ライブ → 確定版）は `TranscriptFinalizer` と同じ順で Replacer → FillerRemover を通し、エコーの重複排除はしない（live.json にトラック情報が無い）。コードのコメントに記載。計画 06 への申し送り。
- Y23: `TranscribeStage` のランナーは init で固定。確定版エンジンの設定が変わったら計画 06 がステージ一式を組み直す（06 への申し送り）。
- Y24: `ProcessRunning.run(environment:)` は環境を置き換える（呼び出し側は親の環境を含む `childEnvironment` を渡す）。cwd のテストは `realpath` で比べる。
- Y25: `start()` は保存済みの `Job.stages` を使う。未知のステージ名は明確な理由つきでジョブを failed にする。
- Y26: `JobProgress.stage` は実行中のステージ（待機中は `nextStage`）。進捗は保存せず、再起動後はジョブが走るまで nil。
- Y27: `runUntilIdle()` は実行できるジョブが無くなったら戻る（キューが空のときだけではない。録音による停止・`notBefore`・`awaitingConfirmation` も含む）。
- Y28: `PostProcessingQueue.init` は計画 05 どおり `gate:` 必須。overview 8b の「配線」の箇条は計画完了時に直し、計画 06 のブリーフは必須の形で書く。
- Y29: Task 3 の `build(_:)` は `build(_:utterances:part:)` に委譲する（描画経路を 1 本にし、区切り文字の防御を 1 か所に置く）。
- Y30: `TemporaryDirectory`・`Samples`・`u()`・`FakeError`・`CallLog`・`FakeBatchTranscriber`・`FakeSummarizer`・`FakeQueueStage` は計画の名前で TestSupport にある（スキャンで一致）。新しい fake は `Sources/AutoNoteTestSupport/Minutes/` に置く。
- Y31（最終修正波。Y35 に統合して実装）: stdout の JSON が `is_error == true` でどのパターンにも合わないときは `.invalidOutput` ではなく `.failed(exitCode:, message: result テキスト + stderr の先頭 500 字)` に分類し、エラー文を失わない。ブリーフの `.invalidOutput` の行は `is_error == false` で構造化出力がデコードできない場合だけに当てはまる。
- Y32（最終修正波で実装、b2567d2）: `PostProcessingQueue.init` に `services: SharedVaultServices = .standard`（`clock` の後）を足し、`delete()` がそれを使う。隔離した services を渡すテストでステージと同じ `VaultWriter` になる。
- タスクごとの結果（最終コミット、レビュー判定、修正ラウンド）:
  - Task 1 — 👤 保留（P1）。コミットなし
  - Task 2 6d23722 — 仕様 ✅ / 品質 承認（sonnet）、修正 0。492 テスト
  - Task 3 822bdef — 仕様 ✅ / 品質 承認（sonnet）、修正 0。505 テスト。実装者の懸念: `partNote` / `mergeInstructions` の文面は創作だった → Task 4 が一字一句のブリーフ文面に置換、`PortableConfigStoreTests` の 2 か所の編集は `.prompt` 既定を足した帰結と確認
  - Task 4 9c97e2c — 仕様 ✅ / 品質 承認（sonnet）、修正 0。520 テスト（フル実行で一度だけ「1 issue」、再現せず。タイミングのテストと推定）
  - Task 5 135db9a — 仕様 ✅ / 品質 承認（opus）、修正 0。539 テスト
  - Task 6 fed4737 — 仕様 ✅ / 品質 承認（opus）、修正 0。552 テスト。作業ディレクトリの作成を認証確認より前に置く順序変更を許容
  - Task 7 53e0064 — 初回 807debb は品質 不承認（I1 `resolveOverwrite` が承認待ちでないジョブに作用する、I2 rerun が `.running` を再確認しない）→ 修正 1（承認待ち（`.waiting` かつ `notBefore == nil`）の場合だけ作用、`rerunsInProgress` フラグを `isRunnable` で見る、M1/M2/M3/M5）で承認（sonnet の限定再レビュー）。584 テスト
  - Task 8 da7b691 — 仕様 ✅ / 品質 承認（sonnet）、修正 0。575 テスト
  - Task 9 90eb80d — 仕様 ✅ / 品質 承認（opus）、修正 0。582 テスト
  - Task 10 8b106da — 仕様 ✅ / 品質 承認（sonnet）、修正 0。596 テスト
  - Task 11 83f20f7 — 初回 f2d083b は品質 不承認（frontmatter の読み取りがエラー対応づけの外にあり、Vault の権限エラーで `.retry(after: 300)` ではなく failed になる）→ 修正 1（対応づけの中へ移動、`minutes_unreadable` のログ、テスト追加）で承認（sonnet の限定再レビュー）。613 テスト
  - Task 12 617d2a6 — 仕様 ✅ / 品質 承認（opus）、修正 0。612 テスト
  - Task 13 ccfb50d — 仕様 ✅ / 品質 承認（sonnet）、修正 0。621 テスト
  - Task 14 ac8b7e3 — 仕様 ✅ / 品質 承認（sonnet）、修正 0。624 テスト / 60 スイート、フル E2E 27/0/0（05.1 / 05.2 を含む）。Step 6 👤 保留
- 実装中に Lead が許容した点（Task 7）: 毎時の rate limit の再実行回数はメモリ上（クラッシュでリセット。計画 06 への申し送り）、`retry` は attempts を戻して rate limit 待ちのジョブも即時に走らせる、実行中のジョブへの `rerun` は先にステージをキャンセルする、ログは `os.Logger` のみ（ファイルロガーは計画 06 の `logs/autonote.log`）。
- 保留した Minor（最終修正波に入れるか保留のままかは最終レビューで裁定）:
  - Task 2: 順序のテストに id 同順位のケースが無い、`load()` は壊れたファイルで throw（`all()` だけが脇へ退避）
  - Task 3: `utteranceCannotForgeDelimiter` の `lines.last` 判定がゆるい、テストの force unwrap
  - Task 4: 計画の描画が二重（eager）、`mergePrompt` はエンコード失敗時に `{}` を使う、推定が文字列を確保する、`sortedKeys` と閾値境界のテストが無い、1 秒の実時間の性能テスト
  - Task 5: タイムアウト発火後のキャンセルが `CancellationError` ではなくタイムアウト結果を返す（`ProcessRunner.swift:79` / `:150`、完了後に `Task.checkCancellation()` を足す）、ログインシェル探索の最悪が約 11 秒（注記の 5 秒・テストの 10 秒を超える）、小さな整理 3 件（task-5-review.md）
  - Task 6: （Y31 は修正波へ）作業ディレクトリがシンボリックリンクだとリンク越しに空にする、テストの `className` 使い回し、`FakeClaude` の空レスポンスの前提、タイムアウトのテスト後に sleep プロセスが約 4 秒残る、`public let` の余り
  - Task 7: 限定再レビューの M4 / M6、rerun のテストが rerun 直後に状態を読む（ループが先に `.running` を永続化すると揺れうる）、同じ会議への 2 つの同時 rerun がフラグを共有、`notBefore != nil` と manifest が throw する経路が未テスト、再起動のテストが attempts − 1 を固定していない
  - Task 8: `stop()` が `recordingTask` を待たない、`initial()` の前後で `.started` / `.stopped` がバッファされると brief が true → false になりうる、`init(session:)` が実 `RecordingSession` で未テスト（計画 06 が配線）
  - Task 9: `TranscribeStage.swift:30` の汎用 catch の先頭に `Task.checkCancellation()`（キャンセルされたジョブがフォールバックしない）、辞書の読み取り / フォールバックの書き込みが throw すると manifest が `.transcribing` のまま、ほかは見た目のみ
  - Task 10: アトミック書き込みのヘルパが JobStore と重複（共有ヘルパ化の候補）、prompt / 辞書の読み取りエラーが `summaryFailure` ではなくステージ失敗になる、成功時に既存の `minutes.json` を置き換えるテストが無い
  - Task 11: 4 件（task-11-review.md）
  - Task 12: 古いジョブがあると `acceptShortRecording` が黙って何もしない、failed のジョブへの `regenerate` は summarize から再実行（計画 06 が failed → retry に振る）、automations が最後であることのテストが順序ではなく存在を見る、計画 Step 4 のフィルタ文言、テストの `/tmp/unused` リテラル
  - Task 13: `delete` が `.standard` を使う（Y32 で修正波）、`purge` の `throws` が未使用、`delete` の `try?` の設定読み込み、`eventually` ヘルパが実時間でポーリング
  - Task 14: パースエラーのメッセージが捨てられ汎用 usage だけが出る（`\(error)` を出す）、到達しない `else` 分岐、`meetingFile` が最初の `.md` を取る（会議 1 件のときだけ正しい）、パーサのテストが `--out` のディレクトリ性と `--claude` と `--fail-summary` の優先を見ない、05.1 の `_index.md` 確認がファイル名の部分一致で行ではない
- 👤 保留: Task 1 と Task 14 Step 6（実際の `claude -p` を使う。手順は「利用者への依頼」の計画 05）。
- 台帳に番号のない欠番: なし（P1、Y1〜Y32 が連番）。

**最終レビュー（ブランチ全体、opus、BASE 018c339..ac8b7e3）**: 判定「修正後マージ可」。Critical 0、Important 3、Minor 7（保留）。「判断しなかった事項」は台帳アーカイブの final-review.md §Declined を参照。
- Y33（I1）: 再生成が失敗すると SummarizeStage が付けた `.generating` が戻らず「生成中」が表示され続ける。WriteVaultStage の手順 2（summaryFailure あり＋minutes.json あり）で manifest を `.minutesGenerated` に戻す。
- Y34（I2）: Y18 の上限 24 回が §13 の「5 分おきに再試行」を約 2 時間で失敗に変えていた。`.retry(after:)` は無制限にし、上限 24 は rate limit の回数（`Job.rateLimitRounds: Int?`、optional で追加、summarize 成功と rerun/regenerate で nil に戻す）にだけ適用。25 回目は `rate_limited_rounds_exhausted` で失敗。手動 `retry` は回数を保持する（もう 1 回だけ試して再び失敗）。`maxAttempts` は `maxRateLimitRounds` に改名。
- Y35（I3、Y31 を統合）: 分類器が `is_error:false` で structured_output が無いときにモデル本文へ失敗パターンを当てていた（会議で「rate limit」と話すと誤分類し、本文が summaryFailure/lastError に漏れる）。パターン照合は `is_error:true` の `result` と stderr だけ。`is_error:false` で構造化出力が無い/壊れている → `.invalidOutput("subtype=<s>: structured_output invalid at <スキーマのパス>")`（本文は入れない）。`is_error:true` で不一致 → `.failed(exitCode:, message: result+stderr の先頭 500 字)`。
- Y32: `PostProcessingQueue.init(paths:stages:activity:gate:clock:services:)`（`services` 既定 `.standard`）、`delete` がそれを使う。
- 保留から昇格: Task 5 のタイムアウト後キャンセル（`completion()` の後に `Task.checkCancellation()`）、Task 9 の汎用 catch 先頭でのキャンセル確認（キャンセル時は代用に行かない）。
- 修正波: 44799bb（Y34）、761f116（Y33）、34960d9（Y35）、b2567d2（Y32）、47d76cc（T5）、e121609（T9）。再レビュー（sonnet）: 6 件すべて Addressed、新規の Critical/Important なし。残った Minor: rate limit 以外の失敗で `rateLimitRounds` が古いまま残る（上限 24 で無害）、旧形式 job JSON の decode テストなし、`cancelledJobNeverTakesLiveFallback` が事前キャンセル依存。
- 最終レビューの指摘（計画 06 への申し送り）: Task 14 Step 6 👤（本物の `claude` を Swift から 1 回呼ぶ）は、計画 06 で待ち行列を配線する前の関門にする。`claude auth status --json` と失敗文言の分類はこれでしか確かめられない。

**Lead 検証（HEAD e121609、2026-10-27）**: `swift test` 630 テスト / 60 スイート 緑（アイドル実行、警告なし）。`scripts/build-app.sh && scripts/e2e-check.sh` 27 PASS / 0 FAIL / 0 SKIP（05.1 は `2026/2026-10-24_1400_架空の定例.md`、05.2 は `2026/2026-10-24_140000.md`）。ログは scratchpad の plan05-final-swift-test.log / plan05-final-e2e.log。

### 計画 06（台帳から転記、2026-10-27）
- 台帳 `progress.md`・`rulings.md`・`preflight-scan.md`・各タスクのブリーフ/報告/レビューの全文は scratchpad の `sdd-archive-plan-06/` に退避（セッション限り）。以下は裁定だけの写し。
- # Plan 06 rulings (X-series) — from preflight-scan.md (R/C/S/N/U refs) and task reviews
- Spec is binding; plan is its argument. Format: Ruling — why — cost if wrong.
- X-T3a: undecodable automations entries are never in `items`; `save` preserves them; `importReplacing` writes source bytes. (Task 3 done @ 34b0f52.)
- X-T5a: Task 5 does not reference `AppCommandError`; `runOne` is added in Task 8.
- X-T6a: wire encoder = `AutoNoteJSON.compactEncoder()` / `decoder()` (R15); no second date format.
- X-T8a: `OutputFolderServices` delegates to `SharedVaultServices.standard` (R3/N1); `init(paths:services: = .standard)`.
- X1 (R16/N2): every type carrying `meetingID` that goes through `AutoNoteJSON` (`AutomationRunRecord`, `IPCArgs`, `IPCResult`, `QueueItemDTO`, `RecorderStatusDTO`, `MeetingRow` if applicable) declares `CodingKeys` with `meetingID = "meetingId"` so snake_case round-trips as `meeting_id`. Tests pin the wire key. — the decoder's convertFromSnakeCase produces `meetingId`. — cost: silent nil.
- X2 (C3): `AutomationRunner` writes `result.json` and the ledger with `AutoNoteJSON.encoder()`/`decoder()` (snake_case `exit_code` etc., E2E 06.6 relies on it).
- X3 (C4): `AutomationRunRecord.succeeded == (skippedReason == nil && !timedOut && exitCode == 0)`. A skipped run creates NO log folder (`logDirectory == ""`), is not in `recentRuns`, and is not yielded on `records()`. Task 5 notifies `automationFailed` only when `skippedReason == nil && !succeeded`. — skips are not failures. — cost: a skipped manual rerun looks silent; manual runs have `dedupeKey nil` so never skip.
- X4 (C5): no global serialization in the runner; actor reentrancy is accepted. Order within one `dispatch` is the `for` loop. Ledger mutations are actor-isolated and happen before the first `await` of the spawn. — cost: a recording_started hook may overlap a minutes hook; both are user scripts with separate logs.
- X5 (C6/N15): `ProcessGroupSpawner` sets `F_SETNOSIGPIPE` on the stdin pipe write end; `SocketServer`/`SocketClient` set `SO_NOSIGPIPE` on every socket fd. No process-wide `signal(SIGPIPE, SIG_IGN)`.
- X6 (U11/U3): `records()` supports multiple subscribers (each gets its own continuation). `AppModel.automationFailures` is seeded at launch from `recentRuns(limit: 20)` filtered `!succeeded`.
- X7 (C7/N5): `AppWiring` gives each listener its own consumer Task over the event stream (per-listener FIFO, listeners independent). A slow automation never delays enqueue or live transcription. (Task 13)
- X8 (R8/N6): Task 13 launches `ClaudeLocator.fillDefaultPath` in a detached Task at startup, off the launch path.
- X9 (R10/C21): Task 13 adds an integration test: real `RecordingSession` (fake audio sources) + `RecordingSessionActivity(session:)` + the SAME `BatchGate` instance in runner and queue; assert gate pauses on `.started` and resumes on `.stopped`. The `batchGatePausedWhileRecording` tautology is replaced by it.
- X10 (3c, plan 05 Task 14 Step 6 gate): before dispatching Task 13, the Lead runs the real `claude -p` check once via a sidekick-runner (`autonote dev summarize --fake <fixture> --out <tmp> --claude`), records the outcome in the ledger and master doc. If `claude` is not logged in, record as 👤 and proceed with Task 13 (fake-backed tests still gate correctness). — the user approved verification through real runs; one small summarization is the cost.
- X11 (R35/N7): Task 13 does NOT delete `Sources/AutoNoteApp/DevChecks.swift` nor the 開発 menu; plan 02's pending 👤 measurements depend on it. Record in the master doc as a deferred cleanup after those measurements.
- X12 (R36/N8): qualify `SwiftUI.Settings { }` and `AutoNoteCore.Settings` wherever both modules are imported (Tasks 13, 15).
- X13 (R6/C13/N4): `QueueAdapter` pre-validates: manifest missing → `.notFound("会議が見つかりません: <id>")`; `regenerate` without `final.json` → `.invalid("文字起こしがありません: <id>")`; `retry` with no eligible job → `.invalid("再試行できる処理がありません: <id>")`; `resolveOverwrite`/`acceptShortRecording` map `QueueError` to `.invalid(description)`.
- X14 (R7): `QueuePort.retry` routing: job `.failed`, or `.waiting` with `notBefore != nil` → `queue.retry`; `done` with `summaryFailure` → `queue.regenerate`; `.waiting` awaiting confirmation → `.invalid("上書きの確認待ちです: <id>")`; no job → X13.
- X15 (R4/U2/C11): `QueueStatus.items` carries every job in the snapshot (incl. done+summaryFailure; NoticeRelay needs them). `QueueItemDTO` gains `notBefore: Date?` (Task 6). `stage` nil → `""`. Presentation (Task 9 `status`, Task 11 queue section, Task 14) hides `state == "done"`. Labels: `state == "failed"` → "失敗"; `notBefore != nil` → "再試行待ち"; `awaitingConfirmation` → "上書きの確認待ち"; running/pending → `StageLabel.text`.
- X16 (R12/C18/N3): `NoticeRelay` is seeded with the first `QueueStatus` after launch as `previous` without emitting; emitted notices are deduped in memory by `meeting:generation(:kind)`. Rows refresh runs before the relay (Task 13 ordering).
- X17 (C10): E2E 06.3 reads `status.recorder.state` (snake_case keys). (Task 16)
- X18 (C12/U7): `SocketClient.send(_:args:responseTimeout:)` gets `responseTimeout: Duration = .seconds(10)` (Task 7); the CLI passes 30 s for `start`/`stop`, 120 s for `import`, default otherwise (Task 10).
- X19 (C14/U8): `QueueHolder` stays as a thin box but Task 13 never replaces the queue after launch; settings changes re-register stages via `queue.register(_:)` (same-name replacement, overview 8g). Streams stay valid.
- X20 (C15): `AppModel` re-reads `rows()` only when the multiset of `(meetingID, state, stage, awaitingConfirmation)` in `QueueStatus` changes, not on progress-only updates.
- X21 (C16): grace copy comes from Task 11's per-second countdown ("N 秒後に停止"); Task 14's header shows that string, not `Banner.grace`.
- X22 (C22/N14): Task 13 skips login-item reconciliation and `SMAppService` calls when `AppIdentity.isDataDirectoryOverridden`. Device first-seen notices and the consent window under E2E are acceptable (GUI session).
- X23 (C25): one validator: Task 15 moves per-definition checks into `AutomationDefinition.problem(duplicateNames:) -> String?` in Automations/, `AutomationsFile` and `AutomationDraft.validate` both call it. Upper bound 86400 added there.
- X24 (R17): `SettingsNormalizer` only normalizes what `Settings` does not (negative `audioRetentionDays` → 0); the tautological test asserts retention instead.
- X25 (R21/R22/U4/N10/N11): `RecorderPort` gains `elapsed() async -> TimelineTime?` (Task 8 protocol + fake; `CoordinatorRecorderPort(coordinator:elapsed:)` closure wired to `session.elapsed()` in Task 13). Menu/timer use it. State recording with `meetingID == nil` renders "開始中…" with no timer. `LiveTranscriptBuffer` resets on the `.started(id)` event, not on `meetingID` change.
- X26 (R27): `PortableDevicesStorage` is created once per store value and reused.
- X27 (C20/U9): subscribe `audio(for:)` on `.started`; the sub-second gap before subscription is accepted for the live view (final transcript comes from files). `finish()` errors are logged and swallowed. `makeFeed` reads the language from `manifests.load(id)`; coordinator holder avoids the init cycle.
- X28 (U1): manifest status → row state: `recording`→.recording; `recorded`/`transcribing`/`transcribed`/`generating`→.processing (progressLabel from the queue item, else "処理待ち"); `minutesGenerated`, `transcriptOnly`, `failed`, `tooShort` map 1:1.
- X29 (U16): `MeetingListBuilder.build(…, timeZone: TimeZone = .current)` parses `IndexEntry.date`/`start` in that zone.
- X30 (U17): `--help`/`-h`/`help` → usage, exit 0; no arguments → usage on stderr, exit 1 (E2E 6 keeps `usage:` + exit 1).
- X31 (S14): manual GUI checks run against `AUTONOTE_DATA_DIR=<tmp>`; automate via CLI + osascript per the user's rule; only first permission dialogs are 👤.
- X32 (R34/N9): implement notifications as planned; Task 12/16 verify empirically whether the alert style sticks; if not, record it and rely on the in-app band as the durable surface.
- X33 (S13): Task 13 is executed as three dispatches with one review each: 13a Core wiring (`AppWiring`, `LiveTranscriptionWiring`, `QueueAssembly`, tests), 13b `AppEnvironment.make` + launch order, 13c app shell (hotkeys, quit confirm, login item, notifications permission).
- X34 (U12): `toggleRecording` in `countdown` → manual start; in `grace` → stop; `togglePause` in `idle`/`countdown`/`grace` → no-op.
- X35 (U5): output folder unset (settings nil/empty) renders "出力フォルダが未設定です" and the band links to settings; unavailable renders the plan's "見つかりません" copy.
- X36 (U10/C23): views read the dictionary via `AppEnvironment` (concrete), as C23 already allows for `output`/`registry`.
- X37 (U13): opening the main window/settings calls `NSApp.activate(ignoringOtherApps: true)` first.
- X38 (U19): Obsidian detection via `NSWorkspace.shared.urlForApplication(toOpen: URL(string: "obsidian://open")!)`; nil → open the file with the default app.
- X39 (U14/U15/U20/U18): decided at task time — Task 15 notes (devices: `setDisposition` for un-ignore; dictionary issues shown as a footer count+list); `transcriptEngine` not shown; file log out of scope for 06 (parked).
- X40 (S16/R33): Task 16 fixes the `-h` sed range when it adds header lines.
- X41 (plan 05 Task 14 Step 6 gate, run 2026-10-27 via X10): real `claude -p` round trip PASSED functionally (exit 0, 7 s, `status == minutes_generated`, 3-line summary in the meeting file, `claude auth status` loggedIn max plan). The third criterion "no new entry under ~/.claude/projects" is relaxed: Claude Code records every session under a project keyed by cwd, and overview §5 deliberately gives AutoNote a dedicated empty `claude-cwd/`, so exactly ONE entry named for that directory appears on first use and never grows per run. New criterion: "the only new projects entry is the `claude-cwd` one". Gate for Task 13 is open. Detail: scratchpad/claude-gate/result.md. — cost if wrong: a stray entry in the user's Claude Code project list, which is the design's intended isolation anyway.
- X14b (amends X14, from Task 8 concern 4): `QueuePort.retry(id)` when NO job exists for the meeting: manifest status `transcriptOnly`/`failed`/`minutesGenerated` with `final.json` present → `queue.regenerate`; `recorded`/`transcribing`/`transcribed`/`generating` (a job should exist) → `.invalid("処理中です: <id>")`; `tooShort` → `.invalid("短すぎる録音です: <id>")`; no manifest → `.notFound`. A `pending`/`running` job → `.invalid("処理中です: <id>")`. — the menu's 議事録 未生成 → 再実行 path must work after restart when the job file is gone. — cost: a regenerate on a meeting the user did not expect; it only re-summarizes.
- X13b: `QueueError` cases map to Japanese copy: `notTooShort` → "短すぎる録音ではありません: <id>"; any other → `.invalid("<id>: " + String(describing:))`. Other thrown errors → `.failed(localizedDescription)` as the brief says (concern 5: use `localizedDescription`).
- X42 (Task 10): CLI success lines for start/stop/pause/resume/bookmark are the implementer's wording (reviewer confirmed consistent). Kept.
- X43 (Task 12 review): `SystemUserNotifier` is the single owner of notification-tap handling, including opening the privacy pane for `.openPrivacySettings`; it exposes `onOpenWindow` for a plain tap without `meeting_id`. Menu/band buttons open the pane themselves (13c). 13b's notice dedupe keys on `UserNotice.id` + `generation`.
- Ruling X-T3a: entries that cannot decode into AutomationDefinition (non-object, missing name/command/on, unknown trigger, non-Bool enabled) are NOT in `items`; each goes to `warnings` as "entries[<i>]: <reason>". `save(_:)` preserves them: it re-reads the current file, writes the given definitions, then appends the preserved raw entries verbatim (JSONSerialization objects) so a load→save never rewrites or loses user data. `importReplacing` validates the source parses as a JSON array, then writes the source bytes verbatim (0600 atomic) and returns `load()`. — Why: §14.5 Automations are user-owned config; the brief's types have no slot for a definition without a valid trigger, and silently rewriting a config file is worse than hiding an entry. — Cost if wrong: a later UI task needs a "broken entry" row; it can read `warnings`.
- Ruling X44: the hang is a correctness defect and is fixed before the 13a review (pre-review concern, not a review fix round). Dispatched to a FRESH opus debugger (brief task-13a-fix1-brief.md) rather than resuming the implementer, because the implementer has 159k tokens / 5.4 h of context and a hang investigation needs a clean context with `sample` evidence — cost if wrong: one extra dispatch. Task 12 fix round still queued (one implementer at a time; shared .build and index).
- Ruling X45: 13b also creates WorkspaceOpener.swift (AppPorts.opener needs a FileOpener) and LoginItem.swift (launch item 6); HotKeyCenter.apply in settingsSaved is left as a `shortcutsChanged` hook for 13c; AutoNoteApp.swift gains the delegate adaptor but keeps the plan 02 temporary menu until 13c. Cost if wrong: 13c re-touches two small files.
- Ruling X46: scripts/e2e-check.sh check_app_launch (and every E2E that launches the app) must set AUTONOTE_DATA_DIR to a SHORT temp dir (mktemp -d /tmp/an-XXXXXX, not the scratchpad) — owned by Task 16; until then the Lead runs e2e with AUTONOTE_DATA_DIR exported. Cost if wrong: a dev build registered as the user's login item.
- Ruling X47: pathTooLong on the socket is logged and the app keeps running without IPC — acceptable for now; Task 16 README notes the data-dir path limit. 2 s main-thread wait in applicationWillTerminate: left to the 13b reviewer / final review.
- Ruling X50: 13c adds placeholder `Window(id: "main")` and `SwiftUI.Settings` scenes (Task 14 / 15 fill them) so env.openWindow, ウィンドウを開く and SettingsLink work now; consent Window id `consent` per brief. Brief's Step 8 `git rm DevChecks.swift` overridden by X11. Cost if wrong: Task 14/15 replace two placeholder views.
- Ruling X51: idle menu-bar symbol follows Core's MenuBarPresentation (waveform idle, hourglass while a job runs) — spec-driven; E2E 7b runs with no jobs so it still reads waveform. Ruling X52: 設定… is a Button that activates the app then calls openSettings (X37 precedence over SettingsLink). Automation-failure item wording 「Automation 失敗: <name>（再実行）」 accepted provisionally; final review checks spec §14.5.
- Ruling X53: `role: .destructive` is restored on 「この会議を削除」 and 「破棄」 — the synthetic-click limitation is a test-harness artifact, not a product reason; the review's fix round carries it. The 再実行→残す→完了-without-minutes observation is a named-risk check for the Task 14 reviewer and, if it is Core behaviour, a final-review item (N-14).
- Ruling X55: the Core resolveOverwrite defect is fixed in this plan (not deferred to the final wave) by a fresh sonnet implementer with a TDD test in the plan 05 queue tests, dispatched after the Task 14 fix round (one implementer at a time). Cost if wrong: one small Core commit on plan-06.
- Ruling X57 (fix wave scope, ONE wave): I1 (answer bands derived from queue state + onPost regardless of center.add + withdraw on resolve = M8), I2 (launch sweep enqueues .recorded manifests without a job + bounded wait in the quit path + test), I3 (CLI timeouts: automations run = timeoutRange.upperBound + kill grace + margin; import = 24 h after connect; CLITests), I4 (refuse save over an unparseable automations.json; tab disables edits with the warning; test), I5 (unsaved-edit confirmation on selection change and 再生成), plus M1, M2 (SettingsStore.update), M4 (automations run exits 1 on failure, child code kept in output — spec §16 wins over Task 10's choice), M5 (minutes.json written only after the Vault write / rolled back on cancel), M9 (notification delegate set synchronously at launch), M11 (timing bounds as recommended), M12 (row context menu 再実行), M13 (shared minutesUsable helper). Accepted/parked: M3, M6, M7, M10.
- Ruling X58 (declined-to-judge items): resolveOverwrite(false) completing `automations` without firing is correct (no Vault write happened); `autonote` linking AutoNoteTestSupport for `dev` commands is pre-existing (plan 01) — accept; batch engine from Settings.defaultLanguage is the plan 04/05 contract — accept; timeSensitive downgrade, Vault rescan cost, one thread per socket connection (0600 socket in 0700 dir) — accept.

### 計画 07（台帳から転記、2026-10-27）
- 台帳 `progress.md`・各タスクのブリーフ/報告/レビュー・`final-review.md`・`fix-wave-report.md`・`fix-wave-re-review.md` の全文は `.superpowers/sdd/2026-10-27-autonote-07-first-run-to-minutes/` に残してある（gitignore 下。セッション限り）。以下は台帳の写し。
- 仕様: `docs/superpowers/specs/2026-10-27-first-run-to-minutes-design.md`（拘束力あり）。ブランチ plan-07、基点 3fd06c9、最終 HEAD 9801107。

#### タスクと担当モデル・コミット
| Task | 内容 | 実装 | レビュー | コミット |
|---|---|---|---|---|
| 1 | `Readiness` モデルと準備カードの文言 | sonnet | sonnet | 972d5b8 |
| 2 | 初回起動の既定値（保存先・whisper モデル）`FirstRunDefaults` | sonnet | sonnet | c4990e0 |
| 3 | ジョブ・要約の失敗を内部名なしで説明する `FailureExplanation` | sonnet | sonnet | c45c47d |
| 4 | 流れの文言、メニューの準備項目、ショートカット表示、保存先の言い方 | opus | opus | cec0a55 |
| 5 | ジョブごとのバッチエンジン解決、エンジンなしのときライブ文字起こしを使う | opus | opus | 6f4c677 |
| 6 | トラックごとの直近入力レベルと静かな入力の規則 | opus | sonnet | 44bd4cc |
| 7 | `ReadinessPort`（初回モデルダウンロード、claude 再検出） | opus | opus | 70a8d9f |
| 8 | `AppModel` が準備状況・入力レベル・今回の録音・自動選択を持つ | opus | opus | 9534828 |
| 9 | 起動時の既定値、ジョブごとのバッチエンジン、同意後にウィンドウを開く（E2E 07.1, 07.2, 07.4） | opus | opus | 1273f73 |
| 10 | メインウィンドウのツールバー録音ボタン、準備カード付きの空状態、入力メーター | opus | opus | 8343c9d |
| 11 | 段階の見出し、短い録音の帯、失敗の帯、保存完了の帯 | opus | opus（要修正）→ sonnet 再レビュー | a2f73f3、修正 01942bd |
| 12 | メニューの準備項目とショートカット表示、設定は一般タブで開く、既定の保存先（E2E 07.3） | opus | opus | cf898b9 |
| 修正波 | 最終レビューの指摘 9 件 | opus | opus | fc06a83, 82987af, 7a91eed, 70aff09, 7bc8835, 4b3eb28, fcc5cfd, d9a21df, 9801107 |

#### 事前スキャン（2026-10-27）
- 計画内のタスク対 23 組と各タスク単独を突き合わせた。型・ポートの Produces/Consumes は全組で一致。同じファイルを順に触る組（4→8 の `AppModel.menuBar`、4↔6 の `LiveAdapters.swift`、6↔7 の `Ports.swift`/`FakePorts.swift`、9→10 の `MainWindow.swift`、9↔12 の `scripts/e2e-check.sh`、10↔11 の `StatusHeader.swift`）は、順序どおりなら衝突なし。レビュー規範と衝突する指示（何も検証しないテスト、論理ブロックの丸写し）は見つからなかった。

#### 裁定
- Ruling: 前提の相違 1〜14 はそのまま採用（計画に記載済み）。— 設計書の意図を優先した Lead の判断 — 間違っていれば該当タスクの手戻り。
- Ruling: Task 3 のテストにある `QueueItemDTO(meetingID:stage:state:message:notBefore:summaryFailure:)` のラベルが現行 init と違えば、現行 init に合わせて書き直してよい（期待値は変えない）。— DTO は Task 3 の変更対象でない — 影響なし。
- Ruling: Task 4 `readinessIssuesInMenu` の末尾 4 項目は現行の順序を正とする。⚠ 項目は「現行末尾の `.openWindow` の直前」に置く。末尾の構成が違えばテストの期待値側を合わせる。— Produces 本文が順序を決めている — 影響は表示順だけ。
- Ruling: Task 8 `withdrawNotice` の識別子は `NoticeContent`／既存の tooShort 通知が使っている id 形式を使う（テストの `"meeting.tooShort.<m1>"` は現行形式の写し。違えば現行に合わせる）。— 通知の id を変えると既存の取り下げが壊れる — 影響なし。
- Ruling: Task 9 E2E 07.4 で `status.queue` が複数件なら、`meeting_id == 20261025-0930-c3d4` の要素を plutil で順に探して判定する。— 項目の意図は message の形式の回帰検知 — 影響なし。
- Ruling: 実装者モデル: Task 1・2・3 は sonnet（1〜2 ファイル・完全仕様）、Task 4〜12 は opus（複数ファイルの統合、GUI 確認）。レビューは sonnet（小さい diff）／opus（5・7・8・9・10・11・12）。
- Ruling: Task 1 の `assumedReady.isComplete == false` は意図どおり（モデルが `.none`）。UI は `isComplete` ではなく rows/bands を見る。変更なし。
- Ruling: Task 2 の `apply` は load() と update() の間に他の書き手が入ると、その値を残したまま `.created(default)` を返す。許容 — `apply` は起動時に 1 回だけ、他の書き手が居ない時点で走り、戻り値の使い道はログ 1 行だけ。
- Ruling: Task 3 で、ラテン文字の段階名は助詞の前に空白が入る（「Automations を待っています」）、`noInternalNamesLeak` は正規表現の前に保存先のパスを除く（パスは利用者のデータ）。どちらも許容。
- Ruling: Task 7 の `retryModelDownload` は `AUTONOTE_DATA_DIR` の上書きを見ない。許容 — 再試行ボタンは `.failed` の行にしか出ず、失敗は上書きが開始しないダウンロードの後にしか起きない。
- Ruling: Task 8 の帯のテストは 500 ms + ポーリング（アプリの既定は 5 秒）、`refresh()` は 30 秒ごとに `readiness.current()` も呼ぶ（stat と isExecutable だけで軽い）。どちらも許容。
- Ruling: Task 9 の MainWindow の開閉フックは body に付ける（のち Task 10 で安定したコンテナへ移した）。ジョブごとの `LazyBatchTranscriber` は whisper モデルをジョブごとに読み直す（保留: EngineChoice ごとにランナーをキャッシュする案）。
- Ruling: 最終レビューの修正波は 1 回だけ — I-1（`outputFolder(forInput:)` で `~` を展開し末尾の `/` を落とす。既定との比較も）、I-2（`NSDocumentsFolderUsageDescription` を追加し、初回起動の保存先作成を同意後に遅らせて、書類フォルダの許可ダイアログが同意画面の後に出るようにする）、I-3（帯のテストを分け、期限つきポーリングにする）、保留から昇格した 2・4・5・6・7、M-1。それ以外は保留のまま。
- Ruling: 初回起動の保存先作成を同意後に遅らせ、NSDocumentsFolderUsageDescription を追加。— `~/Documents/AutoNote` の作成が起動直後に走ると、同意画面より先に macOS の書類フォルダの許可ダイアログが出る。E2E は `AUTONOTE_DATA_DIR` と `consent_notice_shown: true` で走るため、この経路は E2E に映らない。— 同意が済んでいる起動（2 回目以降）は従来どおり起動時に適用。同意直後は `wiring.settingsChanged(old,new)` を呼んで待ち行列の段階を新しい保存先で組み直す（ブリーフの文面を超える追加。無いと次の設定保存まで保存先なしの段階が残る）。
- Ruling: no_speech の失敗帯に 再実行 を先頭に出す（仕様からの意図的な逸脱、仕様の表に注記済み）。— whisper が入った後にその録音を文字起こしし直せないと行き止まりになる（最終レビュー M-1）。— ボタンが 1 つ増えるだけ。`FailureBand` は `.rerun` を既に扱える。
- Ruling: ProcessRunnerTests の wall-clock テストが負荷下で落ちる（計画 07 外・保留。E2E はアイドル時に回す）。— `timeoutEscalatesToSigkillWhenSigtermIsIgnored` が 9.485 秒（上限 10 秒未満）。ほかに `MicrophoneSourceTests.stopReturnsWithinTimeoutWhenEngineStopBlocks` などが負荷平均 8 超で落ちた。計画 07 のファイル外の既存テストで、アイドル時は通る。
- Ruling: 再レビュー（修正波）の Minor 3 件は保留 — 項目 8 のフォールバックに単体テストがない、「帯が消える」テストは帯が一度も出なくても通る（出る側は別テストが見ている）、`~user/…` は展開しない。修正波をもう 1 回回すほどの価値がない。

#### 最終レビュー（opus、cf898b9）と修正波
- 全ブランチ最終レビュー: With fixes — Critical 0 / Important 3 / Minor 11。
  - I-1: 保存先の入力で `~` を展開していない（画面のプレースホルダーとカードは `~/Documents/AutoNote` を見せている）。
  - I-2: 実機の初回起動で書類フォルダの許可ダイアログが同意画面より先に出る。`NSDocumentsFolderUsageDescription` も無い。
  - I-3: 時間頼みの帯のテストが負荷で落ちる。
  - M-1: no_speech の失敗に再実行がない（仕様の表どおりだが行き止まり）。
- 修正波（opus、cf898b9 → 9801107、9 コミット）: 上の裁定のとおり。`swift test` 897/897、`AppModelTests` 5 回連続、`scripts/e2e-check.sh` 38/0。再レビュー（opus）: 9 件すべて Addressed、新規の Critical/Important なし。
- 修正波の内訳: ① `~` 展開と末尾 `/`（fc06a83）② 同意後に保存先を作る＋書類フォルダの用途文言（82987af）③ 期限つきポーリング（7a91eed）④ 同意の OK ボタンにアクセシビリティ名（70aff09）⑤ E2E 07.3 の後始末 Esc に timeout（7bc8835）⑥ 読めない live.json をログに残してから no_speech（4b3eb28）⑦ `ReadinessActionButton` を使う画面の注記（fcc5cfd）⑧ モデル名なしの whisper 選択は既定名に（d9a21df）⑨ no_speech に再実行（9801107）。
- Lead 検証（HEAD 9801107）: `swift test` 897/897（単独実行）。`scripts/e2e-check.sh` は 1・2 回目が項目 1（E2E 内の swift test）で落ちた（再レビューのエージェントが走っていて負荷平均 7+、`ProcessRunnerTests.timeoutEscalatesToSigkillWhenSigtermIsIgnored` が 9.485 秒）。`ProcessRunnerTests` 3/3 と、アイドル時の E2E 3 回目は 38 passed / 0 failed / 0 skipped（07.1〜07.4 すべて PASS）。

#### 繰り越した Minor（未対応。次の計画の該当箇所を触るときに拾う）
- `Readiness.swift:136`: NaN の fraction は `pct` で trap する（`PercentGate` が非有限値を落とすので実害なし。`PercentGate` の非有限・クランプのテストはまだ無い）。
- `outputFolder(forInput:)` の `~user/…` は展開しない。
- `SettingsStore` を挟んだ書き手が load と update の間に入る競合（起動時 1 回のみで無害）。
- Task 3: 要約の各 case をテーブル駆動にできる（見た目だけ）。
- Task 4: `list(seconds: 252, minutes: nil)` のテストがない。
- Task 5: `run` の末尾 2 行が重複（見た目）。
- Task 6: 1 チャンクで `peakDBFS` を 2 回計算する場合がある。一時停止中の減衰のセッションテストがない。
- Task 7: `installGuideURL` は Claude Code のセットアップページを指す（Task 9 で直した）。
- Task 8: `syncTooShortPrompts` が `syncOverwritePrompts` と重複（`syncPrompts(wanted:isKind:)` に括れる）。`InputLevelTracker.observe` が録音器のスナップショットでも走る（1 Hz のティックだけにしたい）。
- Task 9: `AppDelegate.launch` が約 140 行。`PortableOutputFolderPort` / `WorkspaceOpener` の組み立てが 2 か所にある。ジョブごとに whisper モデルを読み直す（EngineChoice ごとのランナーキャッシュ案）。
- Task 10: `recordButton` の `default: EmptyView()` が将来のアクションを黙って飲む。`StatusHeader` の AppKit import が不要かもしれない。
- Task 11: `TooShortView` の文字列を Core の `ShortRecordingCopy` に寄せられる。
- Task 12: `GeneralTab` の `claude_path` は表示時に読んだ値を持つので、窓で「もう一度探す」を押した後に一般タブを保存すると古い空の値を書き戻し得る（最終レビュー M-7）。`.keyboardShortcut(",")` のインデント。
- 最終レビューの Minor: `transcript_engine` の表示名「Apple 音声入力（リアルタイム版）」は、ライブが SpeechTranscriber（Apple Silicon の既定）でも同じ文字列を書く（M-2）。`relayQueueNotices` が進捗の度に `model.refresh()` を呼び、`refresh()` は準備状況の読み取りも含む。`redetectClaude` と並行する `refresh()` が一瞬だけ古い `readiness.claude` を戻す（見た目のみ）。カードの保存先パスは `settings.json` から直接読む。
- 再レビューの Minor: 項目 8（モデル名なしの whisper 選択）のフォールバックに単体テストがない。「帯が消える」テストは帯が出なくても通る。
- 計画 07 外の既存テスト: `ProcessRunnerTests.timeoutEscalatesToSigkillWhenSigtermIsIgnored`、`MicrophoneSourceTests.stopReturnsWithinTimeoutWhenEngineStopBlocks`、`ProcessTapSourceTests`、`WhisperBatchTranscriberTests.cancellationWhilePausedThrowsPromptly` は負荷下で wall-clock の上限を越えることがある。E2E（項目 1 が `swift test` を回す）はアイドル時に回す。

#### 実機確認（GUI 受け入れ・ゼロコンテキスト被験者）
- GUI 受け入れ（opus、HEAD 9801107、画面ロック解除後）: Task 10/11/12 の「起動して確かめる」はすべて PASS。2 分の録音で停止から約 3 分 55 秒後に「議事録を保存しました — …」の帯、その会議が選ばれ、ウィンドウは前面に出ない。claude 無しの設定では「議事録を作れませんでした — Claude Code（claude）が見つかりません」と「入れ方を見る」「もう一度探して再実行」。I-2 の初回起動（同意 → 書類フォルダ許可）は、実データディレクトリに `logs/` があったため未実施 → その後、利用者の決定で同意画面自体を削除（下記）。
- 利用者の決定（2026-10-27、実機確認の後）: 「録音は相手の同意を得て行ってください」の同意画面を出さない。初回起動はメインウィンドウを直接開き、初回既定（保存先・モデル）は起動時に適用。設定キーは `firstRunCompleted`（JSON `first_run_completed`、旧 `consent_notice_shown` も読む）。仕様 §0 を書き換え済み。修正波 2（fdb3ff6〜c20d68e、7 件）で、空状態の文言（1 分未満は「作る」）、保存先の保存時にフォルダを作る、完了後は本文を先頭から表示、「入れ方を見る」の重複をなくす、停止した会議を選ぶ（未保存の編集があるときを除く。計画 07 の `stoppedKeepsExistingSelection` を置き換え）、〰️ を SF Symbol に。再レビュー（opus）: 7/7 Addressed。Lead 検証: `swift test` 900 件（単独実行では既存の wall-clock フレーク 1 件）、E2E 38/0。
- ゼロコンテキスト被験者（`zero-context-brief.md`、新しい `AUTONOTE_DATA_DIR`、`defaults delete`、Desktop フォルダ削除）:
  - 1 回目（9801107、無音）: sonnet は課題 3 到達（環境音を「はあー」と文字起こし）、opus は無音のため no_speech で課題 3 失敗。教訓: 被験者は声を出せないので `say -v Kyoko` の読み上げを裏で流す。
  - 2 回目（c20d68e、声あり）: sonnet・opus とも 6 課題すべて成功、課題 3 で議事録を引用（仕様の成功基準を満たす）。共通の誤操作: 停止直後の「録音を保存しました」の帯が 5 秒で消えて「作る」が上にずれる（修正波 3 で対応）。opus: 保存先を変えると完成済みの会議が「（無題）」になり「Finder で表示」が無効に（修正波 3 で調査・対応）、議事録表示後に AX ツリーが空（修正波 3 で切り分け）、「開発」メニューが一般利用者に見える（修正波 3 で上書き起動/DEBUG のみに）。報告: `docs/superpowers/research/2026-10-27-ux-audit/plan07-tester-{1-sonnet,2-opus,3-sonnet,4-opus}.md`。
- 追加の成果物: 利用者向け手順書 `docs/guide/getting-started.md`（画像 13 枚）、長時間録音のメモリ調査 `docs/superpowers/research/2026-10-27-memory-audit-long-recordings.md`（停止後の whisper 一括処理が約 14 MB/分で 2〜3 時間だと 1.6〜2.7 GB。窓分割は利用者判断）、GitHub Actions（`.github/workflows/ci.yml` は main/PR/手動、`release.yml` はバージョン変更で universal zip の Release。Free の実機枠 約 200 分/月）。
- 修正波 3（被験者再テストの所見、e7883b7 → 45efb92、3 件）: (1) 停止直後の緑の帯は、同じ会議に短い録音の帯か失敗の帯が出るときは出さない（「作る」がずれる誤操作の原因）。(2) 完成した会議の議事録パスとタイトルを `Manifest` の `note_path`・`note_title` に記録し、保存先を変えても一覧・「Finder で表示」・「最新の議事録を開く」が消えない（既存ファイルは移動しない。残課題: 変更後の保存・再生成は新しい保存先に書く、削除は古いフォルダのファイルを消さない、修正前の会議は次に書き直すまで旧挙動）。(3) AX ツリーが空になる現象はアプリではなく scratchpad の axtool の不具合（画面外の Lazy 要素の AXPosition が (inf, inf) で `Int(inf)` が trap → exit 132）。スクロールして見える位置にある文字起こしは行ごとに AXStaticText で読めるので VoiceOver は問題なし。ツール側を修正、リポジトリの変更なし。(4) 「開発」メニューは `AUTONOTE_DATA_DIR` 上書き起動か DEBUG ビルドのときだけ（`AppIdentity.showsDevMenu`）。手元の `scripts/build-app.sh`（既定 debug）と被験者テスト（上書き起動）では引き続き出るが、配布物（release）では出ない。再レビュー（opus）: 3/3 Addressed、Critical/Important なし。保留した Minor: `.failed` の判定は停止時点では効かない（後から失敗が届いたときは帯がずれ得る）、修正前の会議の `note_path` のバックフィル、`tcc-check.sh` の一時フォルダを消さない。Lead 検証（アイドル）: `swift test` 904/904、`scripts/build-app.sh` OK、E2E 38/0。

## 利用者への依頼（後回しにした 👤 手順）

### 計画 02 Task 1（TCC まとめ確認）— 2026-10-26
1. 画面のロックを解除し、表示されている「システムオーディオ録音」の許可ダイアログで「許可」を押す（AutoNote.app が起動したまま待っている）。
2. `scripts/tcc-check.sh audio-persist` を実行（CFBundleVersion を 3→4 に上げて再ビルドし、再起動後にダイアログが出ないことと TCC.db の行を記録する）。終わったら `Resources/Info.plist` と `docs/superpowers/research/` の差分をコミット。
3. 拒否時の挙動: システム設定 > プライバシーとセキュリティ > 画面とシステムオーディオ録音 で AutoNote をオフ → Mac を再起動 → `scripts/tcc-check.sh audio-denied` → オンに戻す。
4. BT 出力: Shokz を接続して出力に切り替え `scripts/tcc-check.sh bt-silence`、内蔵スピーカーに戻してもう一度。
結果が出たら `docs/superpowers/research/2026-10-24-spike-results.md` の「未測定（利用者待ち）」を埋める。`tapOnly` で callbacks=0 なら計画 02 Task 8 の既定を `.withOutputClock` に変える。

### 計画 02 Task 14/16（E2E 02.1 と実機の録音）— 2026-10-26
実測: この Claude Code セッション（責任プロセス Orca Helper `com.stablyai.orca.helper`、TCC に AudioCapture の行なし）から `autonote dev record --seconds 3` を実行すると、`tapOnly` でも `withOutputClock` でも `RecordingSession.start` が coreaudiod 内で約 90 秒止まり、system の chunks は 0（音を鳴らしていても）。スパイク `TapCapture` も同じ環境で frames=0・破棄が約 3 分ブロック。Task 1 で記録した「AudioCapture 許可ダイアログ未応答」の症状と一致するので、集約デバイスのレイアウトではなく許可の状態が原因と判断し、`.tapOnly` の既定は変えていない。E2E 02.1 はこの状態（40 秒タイムアウト）を SKIP として報告する。
1. Terminal.app（スパイクで AudioCapture 許可があった）から `scripts/e2e-check.sh` を実行し、02.1 が PASS になること（mic と system の `seconds` が 5±0.5、`status` が `too_short`）を確認する。SKIP のままなら、表示される「システムオーディオ録音」の許可ダイアログに応答してから再実行。
2. 許可ありで `tapOnly` が受信できるか（system の `chunks` > 0）を確認する。0 のままなら `.build/debug/autonote dev record --seconds 10 --tap-layout withOutputClock --out /tmp/an-rec`（音を鳴らしながら）と比較し、`withOutputClock` だけ受信できる場合は `ProcessTapSource.init` の `layout` 既定を `.withOutputClock` に変える（裁定 X6）。
3. 計画 02 Task 15（後回し可）: `docs/superpowers/plans/2026-10-25-autonote-02-audio-capture.md` の Task 15 Step 1〜4 のとおり、内蔵スピーカー / Shokz での穴埋め、`--voice-processing` の有無、手元の mp3 の `dev import` を実機で確かめ、結果表と要件書 §5.6・§19 を更新してコミットする。

追記（2026-10-27、計画 04 Task 8 の E2E 実行時）: このセッションの `autonote` にマイクとシステム音声の許可が付き、E2E 02.1 が SKIP ではなく実行されるようになった。system トラックは `tapOnly` のまま受信でき（chunks > 0、`seconds` は 5±0.5 内）、上の 1・2 は実質確認済み（`.tapOnly` の既定は維持）。一方 mic トラックが約 5.65 秒で許容 5.0±0.5 を超えて FAIL したため、計画 04 の Lead 追加タスク 8b で原因を調べて直した（結果は計画 04 の裁定 Z23 を参照）。残るのは 3（Task 15）だけ。

### 計画 03 Task 10 Step 4〜7（実機で自動録音を一周）— 2026-10-26
ハーネスは実装済み（`autonote dev auto-record`）。Shokz・3.5mm・USB の挙動はハードウェアが要るので利用者に依頼する。TCC の責任プロセスは起動元の端末になるため Terminal.app から実行する（マイクとシステム音声録音の許可が要る）。
1. `swift build && mkdir -p /tmp/an-dev/vault /tmp/an-dev/data && .build/debug/autonote dev auto-record --vault /tmp/an-dev/vault --data /tmp/an-dev/data | tee /tmp/an-dev/shokz.log` を起動し、ブラウザで音の出る動画を流しておく。
2. 計画 03 本文 Task 10 Step 4 の 1〜8（Shokz: 初回登録 `yes <uid>` → 5 秒後に録音 → 電源オフで猶予 → 10 秒以内に戻して復帰 → 30 秒放置で停止 → WAV を聞く → `cancel` → `quit` 後の再起動で `device.connected` のみ → 任意でスリープ）を順に行い、復帰までの秒数と attach の試行回数（ログ）、`micFallback` の帯が出た回数を記録する。
3. Step 5（3.5mm イヤホン）: 同じ 1〜5 を抜き差しで。`device.first.…` の uid が `BuiltInHeadphoneInputDevice` か、マイク無しイヤホンでも「外部マイク」が現れるかを見る。
4. Step 6（USB、あれば）: `{"kind":"device","event":"added",…}` の行を記録（シリアルは伏せ字）。`uid_kind` が実物と合うか、別ポートで `device_uid` が変わるか、変わったときに型番一致でカウントダウンするか。
5. Step 7: `docs/superpowers/research/2026-10-24-spike-results.md` 項目 10（USB は項目 4）の「結論」「測定値」を埋めてコミット（`docs: record auto-record hardware results (spike item 10)`）。復帰が 20 回で戻らない・声が欠ける場合は Task 7 の `retryInterval`/`maxAttempts` と要件書 §11.5 の方式を見直す必要があるので Lead に報告。

### 計画 04 Task 12（Apple Silicon 機での確認。後回し可）— 2026-10-26
- 計画 00 Task 8 の引き継ぎ。Apple Silicon 機が手元にあるときに `docs/superpowers/plans/2026-10-25-autonote-04-transcription.md` の Task 12 Step 1〜9 を行う（`dev engines` / `dev transcribe --engine speech` / whisper の Metal / 機材の見え方）。結果で `EngineCatalog.defaults(for: .appleSilicon)` の「仮」を確定または変更し、結果表の項目 1・4・7・12 と要件書 §6.2・§19 を更新する。
- 計画 04 Task 9 Step 4（マイクで 60 秒話して 15 秒超の発話が無いことを見る）は任意。やるなら `autonote dev transcribe --mic --engine dictation --segmentation <採用案> --seconds 60`。

### 計画 05 Task 1 と Task 14 Step 6（claude -p の実測。費用がかかるため利用者判断）— 2026-10-27
どちらも実際の `claude -p` を呼ぶので、利用者の claude の使用量を消費する（裁定 P1）。コード側はこれに依存せず完成している。実行するかどうか、失敗時の再試行は利用者が決める。
1. Task 1（`--setting-sources project` で 60 分・120 分の確認。計画 05 Task 1 Step 1）。リポジトリのルートで 2 回だけ実行する:
   ```bash
   python3 -I scripts/make-fake-transcript.py --minutes 60  > "$TMPDIR/transcript-60.txt"
   python3 -I scripts/make-fake-transcript.py --minutes 120 > "$TMPDIR/transcript-120.txt"
   scripts/probe-claude.sh "$TMPDIR/transcript-60.txt"  60min-project
   scripts/probe-claude.sh "$TMPDIR/transcript-120.txt" 120min-project
   ```
   合格: 2 回とも `has_structured_output: true`、`is_error: false`、`subtype: "success"`、最後に `OK: スキーマに合う`。出力 `/tmp/claude-out-*-project.json` はコミットしない。
2. Task 14 Step 6（`autonote dev summarize --claude` で実機の一周。任意）。`scripts/build-app.sh` のあと、`$AUTONOTE_CLI` は `e2e-check.sh` と同じ CLI のパス:
   ```bash
   python3 -I scripts/make-fake-transcript.py --minutes 1   # 出力を Transcript JSON に変換して $TMPDIR/t1.json に保存
   "$AUTONOTE_CLI" dev summarize --fake "$TMPDIR/t1.json" --out "$TMPDIR/claude-check" --claude
   ```
   `t1.json` の形は `{"engine","language":"ja","utterances":[{"start","end","speaker","text","is_final"}]}`。合格: 出力 JSON の `status` が `minutes_generated`、会議ファイルに 3 行の要約がある、`~/.claude/projects` に新しいエントリが増えていない。
   → **2026-10-27 に Lead が実行済み（裁定 X10/X41）**: 終了コード 0、7 秒、`status == minutes_generated`、会議ファイルに 3 行の要約、`claude auth status` はログイン済み（max プラン）。第 3 の基準「`~/.claude/projects` に新しいエントリが増えていない」は緩和した: Claude Code は cwd ごとにセッションを記録し、overview §5 が AutoNote 専用の空の `claude-cwd/` を与えているので、そのディレクトリ名のエントリがちょうど 1 つ現れるのが正しい。利用者がやり直す必要はない。項目 1（60 分・120 分の `--setting-sources project` 計測）は引き続き利用者判断。
3. 結果が出たら Lead が次を更新する。
   - 要件書 §8.1 の括弧書き（60 分・120 分は `--setting-sources user` でだけ測った）を、「60 分・120 分とも `--setting-sources project` で `structured_output` が返った。計画 05 Task 1」に置き換え、§19 の項目 6 に「project でも確認済み」を足す
   - `docs/superpowers/research/2026-10-24-spike-results.md` の項目 6 に project での再測定（回・stdin バイト数・所要時間・入力トークンの内訳・出力トークン・件数・スキーマ検査）を 2 行足し、1 時間あたりの入力トークンと固定の上乗せを 1 行で書く
   - 60 分・120 分の実測入力トークンが推定式（文字数 ÷ 1.0 + 16,000。60 分は 38,300、120 分は 60,557）を超えたら、`PromptBuilder.charsPerToken` と分割閾値（200k）を実測から下げる
   - 失敗した場合は結果をそのまま書く。§8.1 の変更は利用者の判断

### 計画 06（アプリの実機確認。許可ダイアログと実キー操作が要る）— 2026-10-27
自動化できた確認（ビルド、`swift test`、E2E 33 項目、`AUTONOTE_DATA_DIR` の一時ディレクトリでの起動・ソケット・CLI・Automation 実行・ファイル効果）は Lead 側で済んでいる。残りは画面を実際に触るものだけで、手順は `README.md` の「手動で確認すること（利用者の手が要る）」に一覧がある。要点:
1. 初回の許可ダイアログ（マイク、システム音声、通知）に答える。通知のスタイルが「通知パネル」になっていることを確認する。
2. 実キーで ⌃⌥B / ⌃⌥R / ⌃⌥P（合成キーイベントでは Carbon のホットキーが発火しないため、自動では確認できていない）。
3. 2 分ほど録音して、ライブ文字起こし（部分結果は薄い色、上へスクロールすると追従が止まり「最新へ」で戻る）、ブックマークと一時停止の印、停止後に待ち行列へ入ること、30 秒の録音が「短すぎる録音」になり「文字起こしする」「破棄」が効くこと。
4. 「この会議を削除」「破棄」を実際のマウスでクリックする（`role: .destructive` のボタンは合成クリックが届かないため未確認）。確認ダイアログの文言と削除結果を見る。
5. 録音中に「終了」→ 確認が出る。ログイン時起動をオンにしてログアウト・ログインで常駐する（`build/AutoNote.app` を使う場所に置いてから）。
6. 設定画面の各タブの見た目（選べないエンジン行が灰色、ショートカット入力欄、Automation の編集中に CLI で import したときの「元の定義が見つかりません」）。
問題があれば、その画面名と操作を書いて知らせてほしい。コード側はこれに依存せず完成している。

## 再開手順
1. この表で進行中の計画を見る。そのブランチに checkout。
2. `.superpowers/sdd/<計画ファイル名>/progress.md` の台帳で `Task N: complete` を数え、次のタスクから再開。台帳が無ければ `git log` で判断。
3. superpowers:subagent-driven-development の手順に従う。
