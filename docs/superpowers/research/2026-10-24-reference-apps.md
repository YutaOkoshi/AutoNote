# 参考リポジトリ調査（AutoNote 要件書向け）

調査日: 2026-10-24。3 リポジトリとも存在し、リダイレクトなし。いずれも Swift 製 macOS メニューバーアプリ、スター 0〜7、Issue なし（＝Issue 由来のハマりどころ情報は無い。知見は README とコードコメントのみ）。
ソース取得: raw.githubusercontent.com と GitHub API。主要ファイルを実読。

## 1. kannyjyk/meetnote（最も作り込まれている）
出典: https://github.com/kannyjyk/meetnote （README.md, SETUP.md, MeetNote/Sources/MeetNote/**）

1. **言語/UI/OS/ビルド**: Swift 6 + SwiftUI、SwiftPM（MeetNote/Package.swift）。`LSUIElement`（メニューバー常駐、ライブラリウィンドウ時のみ Dock 表示）。macOS 14.4+、**Apple Silicon 必須**（whisper.cpp を arm64 静的ライブラリで同梱: Vendor/lib/*.a、Metal 有効）。ビルドは `MeetNote/build_app.sh`、配布は `package.sh`（ad-hoc 署名・未公証→`xattr -dr com.apple.quarantine` が必要）。
2. **音声**: システム音は **Core Audio process tap**（`CATapDescription(stereoMixdownOfProcesses:)`＋`AudioHardwareCreateProcessTap`＋private aggregate device。AudioCap 参考）。会議アプリ単体の音だけを取り自分のマイクは混ざらない。会議アプリ未検出の手動録音時は `stereoGlobalTapButExcludeProcesses` で全体を取る。`muteBehavior = .unmuted`。マイクは別トラック。**2 トラックを別 WAV（me.wav / others.wav、16kHz mono 16bit、約 1.9MB/分/トラック）で保存**し、クロックずれの混合問題を回避。権限は「マイク」＋「画面とシステムオーディオ録音」。後者が無いと**エラー無しで無音ファイル**になる。Intel 不可。
3. **文字起こし**: whisper.cpp 直リンク（C ブリッジ CWhisper）、モデル `ggml-large-v3-turbo-q5_0`（574MB。Medium 539MB / Small 190MB 選択可）。**録音後バッチ**。無音で分割した最大 45 秒チャンクごとに言語検出（候補は中英に制限、`allowedLanguages`）、beam 5、temperature 0（+0.2 フォールバック）、no-speech 閾値を上げ幻覚を捨てる、無音区間は事前削除、繰り返し/定型文フィルタ。実測: 混在言語 57 秒を 0.8 秒。日本語は候補に追加すれば可（コード上 `allowedLanguages` を変える設計）。
4. **話者分け**: マイク＝自分、相手トラックは FluidAudio（Core ML・Neural Engine）でダイアライズ。77 分会議で 28 秒。名前付けした声紋を `voices.json` に保存し次回自動割当（コサイン距離 ≤0.30 自動／0.30–0.45 は「Who is who」で確認／発話 30 秒未満は登録しない。実測で別人の最近接ペア 0.502）。**自動推測からは学習しない**（✨表示）。
5. **要約**: **Apple Foundation Models（オンデバイス、macOS 26 + Apple Intelligence）**。長文は分割→縮約→統合（コンテキスト数千トークン制約）。非対応環境はキーワード抽出（約束表現を含む行）にフォールバック。出力は概要/決定/要点/ToDo/タイトル（12 文字程度）。LLM の癖への対策がコード化: プレースホルダ/重複 ToDo の除去（架空 ToDo は無い方がまし）、タイトルが「会議」等のジャンル名なら捨てる、「決定なし」という文を捨てる、要約言語は「発話秒数が多い方」で決定（文字数だと中国語が不利）、指定言語を Apple Intelligence が拒否したら他言語で再試行。
6. **保存**: 既定 `~/Documents/MeetNotes/<会議フォルダ>/`。中身: `Notes.md`（中国語 UI では `纪要.md`、両方読める）、`meeting.json`（機械可読。UI が Markdown を逆パースしない）、`transcript.json`、`others.wav`、`me.wav`。Markdown は ToDo を先頭、全文タイムスタンプ付き文字起こしを後ろ。ToDo チェックで MD と JSON の両方更新。**frontmatter は使わない**（見出し＋本文）。Obsidian 連携の記述なし（共有は macOS 共有シート/Markdown 保存）。音声は保持期間ポリシー（30 日で Apple Lossless/AAC 24kbps 圧縮、180 日削除、転写後即削除）、メモ類は残る。
7. **自動化**: **自動録音開始**あり — Core Audio のプロセス一覧を監視し、対応アプリ（Zoom/Teams/Webex/Lark/Slack/Discord 等、ブラウザは既定オフ）が「マイク使用」または「30 秒連続再生」で開始、両シグナル消失 25 秒後に停止（MeetingDetector.swift）。Teams/Zoom はヘルパープロセスなのでバンドル ID の前置一致。30 秒未満の録音は誤検知として破棄。**CLI が豊富**（`--record/--stop`（起動中アプリ操作）、`--list-meetings`、`--resummarize`、`--diarize`、`--transcribe(-file)`、`--share`、`--voices`、`--deecho`、`--storage/--tidy`、`--test-tap`、`--test-mic`、`--audio-processes`、`--check-ai`）。MCP はなし。
8. **工夫/ハマりどころ**: (a) 権限不足で無音ファイルが出る→セットアップ画面と `--test-tap` で検証。(b) スピーカー利用時にマイクが相手音声を二重収録（マイクトラックの 38–61%）→ EchoFilter で転写後に重複除去（16 会議・約 5,500 行で調整、重複の 48% を除去、非エコー会議の誤除去 0.76%）、再転写不要。(c) 会議中の入出力デバイス変更は非対応（tap が死ぬ）。(d) 再ビルドで TCC 権限が再要求される。(e) Discord に無言で居座るとマイクを握り続け録り続ける。(f) 録音同意の注意書きをセットアップ/設定/メニューバーに常時表示。(g) 小さい発話が無音フィルタで落ちることがある。
9. **真似したい**: process tap + 2 トラック別保存／無音検出の権限チェック／検出ルール（マイク使用 or 30 秒再生、25 秒デバウンス、30 秒未満破棄）／md+json 二重保存／要約の LLM 癖フィルタ／再生成時にユーザー編集（チェック済み ToDo）を保持／音声保持ポリシー／CLI の網羅性。**避けたい**: Apple Silicon・macOS 14.4/26 限定（AutoNote が Intel を要件に含むなら不可）、Apple Intelligence 依存、ad-hoc 署名による権限リセット、日本語を想定していない中英ハードコード。

## 2. Livin21/meetnote
出典: https://github.com/Livin21/meetnote （README.md, Sources/MeetnoteCore/*, Sources/meetnote/Main.swift）

1. **言語/UI/OS/ビルド**: Swift 6（言語モード v5）、SwiftPM、**macOS 26+ / Apple Silicon**。ターゲット 3 つ: MeetnoteCore（エンジン）/ `meetnote` CLI / MeetnoteBar（メニューバー App）。Command Line Tools のみでビルド可（`scripts/make-app.sh`）。CLI は Info.plist を `-sectcreate __TEXT __info_plist` でバイナリに埋め込み TCC 説明文を付与。
2. **音声**: システム音は **Core Audio process tap の全体タップ**（`stereoGlobalTapButExcludeProcesses: []`）＋private aggregate device（出力デバイスをクロック源に）。マイクは別途 MicCapture。リアルタイムでバッファを各文字起こしに流す。権限「System Audio Recording Only」は**自動プロンプトが出ず手動追加**、未許可だと無音。`doctor`/「Test system audio」ボタンが**テスト音を鳴らしてタップが聞こえるか検証**し、無音なら設定画面を開く。ad-hoc 署名のため**再ビルドごとに権限が無効化**。Intel 不可。
3. **文字起こし**: **Apple SpeechAnalyzer / SpeechTranscriber（macOS 26）、完全オンデバイス、ストリーミング（リアルタイム）**。マイク用とシステム音用に 2 インスタンス、確定結果のみ使用。`--locale ja_JP` 等で en/de/es/fr/it/ja/ko/pt/zh/yue を選べ**日本語対応**（モデルは初回自動 DL）。`bestAvailableAudioFormat` に変換して投入。
4. **話者分け**: Me（マイク）/ Them（システム音全員を併合）のみ。個々のリモート話者は区別しない。要約時に `--with "Asha, Ben"` や `MEETNOTE_NAMES` で参加者名を渡し、LLM に聞き間違い名を補正させる。
5. **要約**: **LM Studio のローカル OpenAI 互換サーバ（http://localhost:1234 /v1/chat/completions）**を URL 直叩き。モデル自動選択（google/gemma-4-26b-a4b → qwen → 先頭のチャットモデル。MoE gemma は 28 秒、推論型 qwen は 149 秒考えて出力なしだったという実測コメントあり）。temperature 0.3、`/api/v0/models` で実際のロード済みコンテキスト長を取得、足りなければ `lms unload/load --context-length` で再ロード。16k 文字単位 map-reduce。`<think>` ブロックを除去。サーバ停止時は文字起こしだけ保存し後で `summarize` 可能。
6. **保存**: `~/Documents/MeetNote`（`MEETNOTE_DIR`/設定で変更）。`YYYY-MM-DD-<topic>.md`（要約: TL;DR / Decisions / Action items / Open questions / Discussion タイムライン）と `transcripts/YYYY-MM-DD-HHMM-<topic>.md`（`[mm:ss] Me: …`）。同名は `-2` 連番。要約冒頭に `> on-device transcript + local model … · raw transcript: [リンク]` の引用行。YAML frontmatter なし。Obsidian 連携の記述なし（フォルダ指定のみ）。設定は共有 UserDefaults suite（`dev.livin.meetnote.shared`）で CLI とアプリが共有、環境変数が最優先。
7. **自動化**: 自動録音開始/デバイス検知なし。**CLI 中心**（`meetnote start <topic>`, `summarize`, `doctor`、Ctrl-C で停止→転写→要約、`--max-hours` 安全弁）。README に「AI エージェントに貼るセットアップ手順プロンプト」を掲載。MCP なし。
8. **工夫**: doctor によるテスト音検証、設定の優先順位（env→共有 defaults→既定）、LLM モデルの実測に基づく既定選択、コンテキスト長の動的対応、サーバ不在でも成果物が残る設計。
9. **真似したい**: doctor コマンド、設定優先順位、LLM 呼び出しの堅牢化（ロード済みコンテキスト確認・map-reduce・think 除去）、要約と生文字起こしの 2 ファイル分離＋相互リンク、参加者名ヒント。**避けたい**: macOS 26 限定、Me/Them だけの話者分け、LM Studio 常駐必須、権限の手動追加。

## 3. abishop1990/meetnotes
出典: https://github.com/abishop1990/meetnotes （README.md, Sources/MeetNotes/*, scripts/diarize.py）

1. **言語/UI/OS/ビルド**: Swift + SwiftUI メニューバー（popover）、SwiftPM、**macOS 14+、Apple Silicon 推奨**。`make-app.sh`（CLT のみ）。CLI 兼用（`--list-devices`, `--route-output`, `--transcribe`, `--diarize`）。
2. **音声**: **BlackHole 2ch（仮想デバイス）＋マイクを AVCaptureSession で 2 ファイルに別録**（AVCaptureAudioFileOutput）。アプリが CoreAudio で「スピーカー＋BlackHole の Multi-Output Device」を作りシステム出力に設定（`SystemOutput.swift`、Restore で戻す）。BlackHole 導入はパスワード要求＋再起動。ScreenCaptureKit/process tap は不使用。→ **BlackHole 方式は macOS 14 未満や Intel でも原理的には動くが、whisper-cpp の Homebrew 版が前提（x86 の /usr/local/bin も探索）で Intel 検証の記述はない**。両トラックのレベルメーター、Meet 側が無音なら警告表示。
3. **文字起こし**: **whisper.cpp の `whisper-cli` を外部プロセス呼び出し**（Homebrew `whisper-cpp`）、モデル `~/.whisper/ggml-large-v3-turbo.bin`（約 1.6GB、実時間の約 10 倍速）。**バッチ**。`-l en` 固定（コード上）なので**日本語は要改修**。`--max-context 0`（前窓テキストを戻さない＝繰り返しループの典型原因を断つ）、`--suppress-nst`、`-oj` JSON 出力、afconvert で 16k mono 正規化。`vocabulary.txt`（ノートフォルダ内）を `--prompt` に渡して固有名詞を補正。
4. **話者分け**: You/Others はトラックの音量で判定。リモートは任意で **sherpa-onnx（pyannote segmentation-3.0 + NeMo TitaNet）を Python venv で実行**（`scripts/diarize.py`, setup-diarization.sh, 約 50MB）。Voice 1, 2… を付与し、冒頭に Speakers 表（発話時間・初出）。最大話者数と clustering 閾値（0.7）を調整可。発話 8 秒未満の声は Others に畳む。whisper と diarize を並列実行。
5. **要約**: **なし**。Markdown に「Specs & decisions to confirm」「Action items」の空チェックリストを置き、人間が埋めるか、ファイルを LLM に渡す想定（話者名のリネームも同様）。
6. **保存**: `<folder>/YYYY-MM-DD_HHMM-<name>.md` ＋ 音声 `…-you.wav` / `…-others.wav`（既定保持、再処理用）。見出し直下に箇条書きメタ（Date/Duration/Input/Audio/Transcribed by）、Speakers、`**[mm:ss] You:** text` の段落（1.5 秒超の間か話者交代で段落分割）、折りたたみ `<details>` の Diagnostics。frontmatter なし。Obsidian 連携記述なし。
7. **自動化**: 自動開始なし。ログイン時起動と CLI のみ。
8. **工夫**: スピーカー使用時のエコー対策＝100ms スライスごとに音量差 10dB 超なら小さい側をミュート（20ms クロスフェード）してから whisper に渡す。繰り返し除去（2–8 語が 3 回以上連続→圧縮）。Diagnostics に処理内容を記録。音声保持で設定違いの再生成が可能。同意に関する注意書き。
9. **真似したい**: Diagnostics ブロック、vocabulary.txt、`--max-context 0`、繰り返し除去、段落整形ルール、ヘッドホン推奨の明示。**避けたい**: BlackHole の手動導入と出力デバイス強制切替（音量調整が効かなくなる等の副作用）、英語固定、Python venv 依存、要約なし。

## 横断比較表
| 項目 | kannyjyk | Livin21 | abishop1990 |
|---|---|---|---|
| OS / CPU | 14.4+, Apple Silicon | 26+, Apple Silicon | 14+, AS 推奨 |
| システム音 | process tap（対象アプリ限定/全体） | process tap（全体） | BlackHole + Multi-Output |
| マイク/分離 | 別 WAV 2 本 | 別ストリーム | 別ファイル 2 本 |
| 文字起こし | whisper.cpp 同梱, 録音後 | Apple SpeechAnalyzer, リアルタイム | whisper-cli 外部実行, 録音後 |
| 日本語 | 設定で可（候補制限を変更） | ja_JP 可 | 英語固定（要改修） |
| 話者分け | Me / FluidAudio + 声紋ライブラリ | Me / Them のみ | You/Others + 任意 sherpa-onnx |
| 要約 | Apple Foundation Models（+キーワード fallback） | LM Studio ローカル LLM | なし |
| 保存 | フォルダ毎 Notes.md + json + wav | 要約 md + transcripts/ md | 1 md + wav |
| frontmatter / Obsidian | なし / なし | なし / なし | なし / なし |
| 自動開始 | あり（プロセス監視） | なし | なし |
| CLI / MCP | 豊富 / なし | あり / なし | あり / なし |
| Intel | ✗ | ✗ | 原理的に可だが未検証 |

## AutoNote への示唆
- **システム音は process tap が本命**（仮想デバイス不要・ミュートや音量に影響しない）。ただし macOS 14.4+ 要。Intel や 14.4 未満を要件にするなら BlackHole 方式が唯一の道で、体験と引き換えになる。→ 要件で対象 OS/CPU を先に確定すべき。
- **マイクと相手音声は別トラックで保存**する（3 つ中 2 つが採用、混合クロック問題と Me/Others 分離が同時に解決）。保存は 16kHz mono。
- **権限は「無音ファイルが静かに出来る」のが最大の罠**。初回セットアップでテスト音検証を必須化、録音中の無音警告、doctor 的な診断コマンドを要件に入れる。署名を安定させないと再ビルドごとに権限が飛ぶ。
- **文字起こしは whisper.cpp + large-v3-turbo 系が事実上の標準**。日本語対応は言語固定/候補制限と無音幻覚対策（no-speech 閾値、`max-context 0`、繰り返し除去、事前 VAD、固有名詞 prompt/vocabulary）を最初から要件に。Apple SpeechAnalyzer は即時性が利点だが macOS 26 限定。
- **要約は差し替え可能な層にする**（CLI/ローカル HTTP/オンデバイス）。LLM 出力の後処理（架空 ToDo・定型タイトル・「決定なし」の除去、長文は map-reduce、think 除去、再生成でユーザー編集保持）を要件化。要約失敗時も文字起こしは必ず残す。
- **保存形式**: 人間可読 Markdown（ToDo と要約を上、全文を下）＋機械可読 JSON、要約と生文字起こしは別ファイルで相互リンクが無難。3 つとも frontmatter/Obsidian 非対応なので、AutoNote で YAML frontmatter（date, duration, participants, tags 等）と Obsidian 保存先指定を入れれば差別化になる。
- **自動録音**: kannyjyk の「会議アプリがマイク使用 or 30 秒連続再生で開始、25 秒デバウンスで停止、30 秒未満は破棄」が実用的な基準。常時マイクを握るアプリ（Discord 等）の誤検知は除外設定で対処。ブラウザ会議は誤録音リスクが高く既定オフ。
- **スピーカー使用時のエコー**は実害が大きい（相手発話の 38–61% がマイクにも入る）。転写後 de-echo かエネルギー比ミュートを検討、ヘッドホン推奨を UI に明記。
- **話者分け**は段階導入が現実的: v1 は Me/Others、v2 でダイアライズ、声紋ライブラリは誤学習を避ける（自動推測から学習しない・閾値 2 段階）設計を参考に。
- **録音同意の注意書き**を UI に常時表示（3 つとも README か UI に記載）。
- 注意: 3 リポジトリとも Issue なし・小規模個人開発のため、長期運用での不具合情報は得られていない。実機検証が必要。
