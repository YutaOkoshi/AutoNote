# AutoNote 開発者ガイド

AutoNote をソースからビルドし、テストし、変更を入れるための文書。利用者向けの説明は [利用者ガイド](guide/getting-started.md) と [利用者リファレンス](guide/reference.md)、設計の全体は [要件書](superpowers/specs/2026-10-24-autonote-design.md) にある。

## 必要なもの

- macOS 26.0 以降の Mac（Apple Silicon でも Intel でもよい）
- Xcode 26 系（Swift 6.2 以降のツールチェーンと macOS 26 SDK。`Package.swift` は `swift-tools-version:6.2`。CI は Xcode 26.6 / Swift 6.3 を使う）。`xcodebuild`・`libtool`・`lipo` は Xcode に入っている
- cmake（whisper.cpp + llama.cpp の XCFramework のビルドに使う。ninja があれば使う）と git
- Claude Code の CLI（`claude`。議事録生成を実際に動かすとき）
- jq（`scripts/e2e-check.sh` の一部の項目が使う）

## 初回セットアップ

- whisper.cpp と llama.cpp の XCFramework（`tools/whisper.xcframework`。フレームワーク名・モジュール名は `whisper` のまま、`llama.h` も入っている）はリポジトリに含めず、手元でソースからビルドする。初回は `scripts/build-whisper-xcframework.sh` を実行する（数分かかる。`tools/whisper.cpp`（v1.9.5）と `tools/llama.cpp`（b12359 = Homebrew の llama.cpp 1.0.0）が無ければ clone する。既存の checkout がスクリプトで固定したコミットでなければエラーで止まる）。ggml は llama.cpp 側の 1 つだけをビルドし、whisper.cpp もそれを使う（PLaMo 3 Translate には whisper.cpp v1.9.5 同梱の ggml より新しい ggml が要る）。公式の zip は x86_64 スライスが AVX2 なしで Intel では約 7 倍遅いため使わない。成果物の直下の `AutoNoteBuild.txt` に版を記録し、版が違えば作り直す。`scripts/build-app.sh` と `scripts/e2e-check.sh` は毎回このスクリプトを呼ぶ（今の版で作成済みならすぐ終わる）
- XCFramework を作り直した後の `swift build` が `ggml.h has been modified since the module file ... was built` で失敗したら、古いモジュールのキャッシュを消す: `rm -rf .build/out/Intermediates.noindex/SwiftExplicitPrecompiledModules`（または `swift package clean`）
- `tools/` は git の管理外。whisper.cpp のソース、XCFramework、ベンチ用のモデルや音声はここに置き、コミットしない
- 初回の `scripts/build-app.sh` は自己署名のコード署名証明書 `AutoNote Dev` を作ってログインキーチェーンに入れるので（`scripts/make-dev-cert.sh`）、管理者認証のダイアログが出る。同じ証明書と同じ Bundle ID で署名し続けることで、再ビルドしてもマイクなどの許可（TCC）が外れない。リリースと同じ証明書にそろえるなら、作る前に `scripts/signing.sh import-login` で 1Password から取り込む（「リリース署名の鍵」）
- `xcodebuild -create-xcframework` がプラグインの読み込みで失敗する Xcode がある（Xcode 26.5 で確認。直すには `xcodebuild -runFirstLaunch`）。そのときスクリプトは同じ構造の XCFramework を手で組んで続ける

## ビルド・テスト・E2E

- テスト: `swift test`
- アプリ（.app）のビルド: `scripts/build-app.sh [debug|release]`（既定は debug）。成果物は `build/AutoNote.app`、同梱の CLI は `build/AutoNote.app/Contents/MacOS/autonote`
- 動作確認（E2E）: `scripts/e2e-check.sh`。CLI・ソケット・ファイルで確かめられる範囲を人の手なしで見る。`--quick` は時間のかかる項目（`swift test`・`build-app`・whisper を使う項目）を飛ばし、前回ビルドした `build/AutoNote.app` をそのまま確かめる。`--verbose` で各コマンドの出力をそのまま見せる
  - インストール済みの AutoNote（`/Applications/AutoNote.app`）が待機中で動いていてもよい。録音中・後処理中は回さず、`/Applications/AutoNote.app/Contents/MacOS/autonote status --json` の `status.recorder.state` が `idle`、`status.queue` が空になるのを待つ（録音中に別のプロセスがマイクを開いたときの影響は確かめていない）。それでも録音中に回した場合、マイクを数秒開く 06.7・09.3・02.1 は、その `recorder.state` が `idle` でない・読めないときに SKIP になる（07.3 がメニューを 1〜2 秒出すのは変わらない）。メニューバーを触る項目（7b・07.3・06.7）は、検査が自分で起動した `build/AutoNote.app` のプロセスだけを pid で指し、同じ名前の別のアプリは開かない・押さない・止めない。別のアプリに届くのは 07.3 の見張りだけ: 自分のメニューを開く前と後に、別の AutoNoteApp のメニューが開いているか（`AXSelected`）を 1 回ずつ読み、その間に新しく開いていたら閉じる操作（`AXCancel`）を送って FAIL にする（宛先の取り違えを見つけるため。利用者が同じときに自分で開いた場合も FAIL になる）
  - 自分のアプリと確かめられない・アクセシビリティの権限が無いときは SKIP、起動したアプリが落ちている（そのアプリを使う項目すべて）・System Events の一覧に出てこない（1 秒おきに 3 回試す）ときは FAIL になる
  - 2026-11-28 のこの修正（PR #25）より前に main から切ったブランチは、main を取り込んでから E2E を回す。古い `scripts/e2e-check.sh` は名前でアプリを指すので、インストール済みのアプリのメニューを開いたままにする。複数の worktree で同時に回すのも避ける（07.3 の見張りが互いのメニューを取り違えと見て FAIL にしうる）
  - GUI を触る項目を足すときは、`tell process "AutoNoteApp"` と名前で指さない・System Events の参照を AppleScript の変数に入れない・キー入力を送らない（理由はスクリプトのコメントにある）。スクリプトの `app_ax` はこの形でステータス項目（メニューバー項目）に命令を送る補助で、ウィンドウなど他の要素には向かない。他の要素を触るなら、同じ形（pid で引く `tell` の入れ子）の補助を足す
  - 項目 7b と 06.7 は、メニューバー項目の名前（OS の言語で変わる）ではなく、アプリが付ける固定の `AXIdentifier`（`autonote-status-item`。`MenuBarLabel.accessibilityID`）を見る。識別子の無い古い `build/AutoNote.app` では FAIL するので、`--quick` の前に 1 回 `scripts/build-app.sh` で作り直す
  - 項目 08.1（確定版のメモリが入力の長さに比例しない）は `MallocLargeCache=0` で測る。しきい値と実測値はスクリプトのコメントにある
- Bluetooth ヘッドセットの実機確認: `scripts/bt-verify.sh --bt-name <名前の一部>`。ヘッドセットの切断・接続（blueutil）、一時プロファイルの Chrome で鳴らすトーンや WebRTC のループバック、独立したタップでの計測を、人の手なしで回す。修正前と修正後のビルドを比べられる。入力・出力が動作中なら始めない。結果は `summary.md`・`results.json`。修正は v0.7.0 で main に入ったので、既定の探し方でも `--build-before` でも修正前のビルドは得られない。修正前と比べるなら v0.7.0 より前のコミットを自分でビルドして `--before-app` で渡し、修正後だけを見るなら `--plan baseline,verify` を使う（既定の計画のままだと `✗ before app missing` で止まり、`--dry-run` も安全条件の表示まで進まない）。実機の実行は、待機中の `/Applications` の AutoNote を実験の間だけ終了して、終わったら起動し直す（録音中なら始めない）。`--dry-run` は何も起動・終了せず、足りない前提（修正前・修正後のアプリなど）を表示するだけで終了コード 0 を返す。`scripts/e2e-check.sh` の項目 17 は、構文・計測プログラムのコンパイル・`--dry-run` だけを見る
- CI と同じ .app を手元で作るなら `AUTONOTE_BUILD_ARCHS="arm64 x86_64" AUTONOTE_CODESIGN_IDENTITY=- scripts/build-app.sh release`（`AUTONOTE_BUILD_ARCHS` を付けなければホストのアーキテクチャだけ、`AUTONOTE_CODESIGN_IDENTITY` を付けなければ `AutoNote Dev` で署名）

### `AUTONOTE_DATA_DIR`

環境変数 `AUTONOTE_DATA_DIR` を設定すると、アプリと CLI は既定のデータ領域（`~/Library/Application Support/AutoNote`）の代わりにそのフォルダを使う。このとき CLI はアプリを自動起動せず、ログイン項目の登録もしない。実データを汚さずに試すときに使う（`scripts/e2e-check.sh` もこれを使う）。

注意: ソケット（`<データ領域>/autonote.sock`）のパスは UNIX ドメインソケットの上限（約 104 バイト）に収まる必要がある。長すぎるとソケットを作れず（`pathTooLong`）、アプリは IPC なしで動く（ログに残るだけで画面には出ない）。`/tmp/an-xxxxxx` のような短いパスにする。

### 録音の開始・停止の理由をログで読む

録音がなぜ始まった・止まったかは `log show --last 1h --predicate 'subsystem == "com.yutaokoshi.autonote"'` で読める（流しながら見るなら `log stream --predicate ...`）。開始・停止・一時停止のたびに、`devices` カテゴリに `recording -> idle on manualStop (origin: hotkey, stop: manual, meeting: <会議 ID>)` のような 1 行が出る。`origin` がきっかけ（`hotkey`・`menu`・`window`・`notificationAction`・`cli`・`countdownFired`・`graceExpired`・`diskFull`・`terminating`・`sessionEnded`・`startFailed`・`deviceConnected`・`deviceDisconnected`。定義は `Sources/AutoNoteCore/Devices/RecordingControlOrigin.swift`）、`stop` が録音に渡した `StopReason` で、何も変えなかった操作は末尾に `ignored` が付く。前後の行で、ショートカットの受信（`HotKeyCenter`）、CLI のコマンドと送信元 PID（`SocketServer`）、機材の追加・削除（`DeviceMonitor` と `devices`）、設定の保存で変わったキー名（`AppWiring`。値は出さない）、録音セッションの開始・終了と秒数（`RecordingSession`）、ライブ文字起こし・ライブ要約の開始・終了を突き合わせる。どれも `notice` 以上なので後から `log show` で読める（`info` と `debug` は残らない）。

### 使われなかった設定値とライブ要約の失敗をログで読む

利用者向けの読み方とコマンドは [利用者リファレンス](guide/reference.md) の「ログで理由を調べる」にある。開発で知っておくこと:

- `settings.json` の値を使わなかったとき（知らない `live_engine`、確定版に書いた Apple のエンジン、未ダウンロードのモデル、退避したファイルなど）は `Settings` カテゴリに `settings: ignored ...` が `notice` で出る（`SettingsDiagnostics`）。同じ行は 30 分に 1 回まで（`repeatInterval`）で、プロセスごとに数える。アプリは `AppModel.refresh`（30 秒ごと）で設定とエンジンの解決をやり直すので、値が使われていないあいだは 30 分ごとに出直す（退避の行だけは、退避したときの 1 回きり）。値を引用するのはエンジン・モデル・翻訳の項目だけで、`claude_env` は個数だけ
- ライブ文字起こしの開始の行（`LiveTranscriptionWiring`）は、実際に動いたエンジンを `engine:` で示す（`EngineChoice.displayName`）
- ライブ要約の `claude -p` が失敗すると、`ClaudeLiveSummarizer` カテゴリに `live claude -p failed: <種類> (exit N): <claude のエラー文>` が `error` で出る。エラー文は `ClaudeResultClassifier.failureText`（エラーエンベロープの `subtype`・`result`・`errors` と stderr）で、`claude_env` の値（8 文字以上）と `sk-…` 形のトークンを `***` にしてから 1 行・200 文字に切る（切ってから伏せると、切れ目にかかった値が残る）。指示文・文字起こし・成功時の出力は出さない。文が何も無いときは出力の形（バイト数）だけ、`claude` を起動できなかったときは `live claude -p did not run: <型> (<domain> <code>)` が出る。会議 ID はこの行には無い（スケジューラの `live summary: failed (...) (<会議 ID>)` は `NSLog` で出るので、時刻で突き合わせる）
- 録音の最初の確認（`checkReady`: 実行ファイルの確認と `claude auth status --json`）や `LiveSummarizerFactory` が失敗すると、スケジューラはその録音の要約を止めて以後呼ばない。このときは `live claude -p unavailable: <種類> (<理由>)` が同じカテゴリに出る（確認の終了コード、JSON の `loggedIn`、stderr。stdout と `claude` のパスは出さない）
- `swift test` と `autonote` の CLI も同じ行を本物のログに書く（テストは架空の値を使う）。アプリの行だけを読むなら、条件に `AND process == "AutoNoteApp"` を足す

## リポジトリ構成

- `Sources/AutoNoteCore`: 録音・文字起こし・議事録生成・Vault 書き出し・IPC・Automations などの中核ロジック（UI なし）
- `Sources/AutoNoteApp`: SwiftUI のメニューバーアプリ（メインウィンドウ、設定、ホットキー、通知、ログイン項目）
- `Sources/autonote`: 同梱の CLI。公開コマンドと、開発用の `autonote dev ...`
- `Sources/AutoNoteTestSupport`: テストと `autonote dev` が使う偽物（音声デバイス・時計・ディスク・whisper など）とフィクスチャの読み込み
- `Tests/AutoNoteCoreTests`: 単体テスト
- `Tests/Fixtures`: テスト用の会議データ。内容はすべて架空
- `Resources/`: `Info.plist` などアプリに同梱するもの。`Resources/mermaid/` は議事録の構成図のプレビューに使う mermaid.js（下の「同梱しているもの」）
- `scripts/`: ビルド・E2E・ベンチ・スパイク用のスクリプト（下の一覧）
- `.github/`: CI とリリースのワークフロー、その補助スクリプト
- `docs/`: 利用者ガイド、この文書、要件書と設計書（`superpowers/specs/`）、調査記録（`superpowers/research/`）

## 開発の約束事

- 最低 OS は macOS 26.0。`swift-tools-version: 6.2`、Swift 6 言語モード（strict concurrency）
- `AutoNoteCore` の型・関数で他ターゲットから使うものは `public` にする
- Intel と Apple Silicon の両方で動かす。機種差は実行時に判定し、`#if arch` で機能を落とさない
- 機種とモデルの相性（重すぎるモデルの警告）の判定規則は `Sources/AutoNoteCore/Transcription/WhisperModelFit.swift`、機種の値（物理コア・メモリ）と確定版のスレッド数の自動計算は `MachineProfile.swift` の 1 か所に置く。文言は `Presentation/FitWarningPresentation.swift`。規則を変えたら [利用者ガイドの 9 節](guide/getting-started.md) の表も直す
- 署名は自己署名の `AutoNote Dev`、Bundle ID は `com.yutaokoshi.autonote`。どちらも `scripts/config.sh` が唯一の定義（`AUTONOTE_BUNDLE_ID` と `AUTONOTE_CERT_NAME`。`build-app.sh`・`e2e-check.sh`・`make-dev-cert.sh` などがここを読む。変えるときはここだけを直す）。App Sandbox なし、Hardened Runtime なし
- 音声・文字起こし・議事録・個人の機材識別子をコミットしない。フィクスチャは架空のデータで作る
- 音声はローカルから出さない。外部に渡すのは `claude -p` への文字起こしテキストだけ
- `claude` の起動（引数と子プロセスの環境変数）は `Sources/AutoNoteCore/Minutes/ClaudeLaunch.swift` の 1 か所で組み立てる。議事録とリアルタイム要約は設定の `claude_args` と `claude_env` を、ログイン確認（`claude auth status`）は `claude_env` だけをここで足す
- TDD で進める（失敗するテストを書く → 実装する → 通す）。ハードウェアが要る部分だけ手動で確認する
- コミットメッセージは英語の Conventional Commits
- タスクを完了とする前に `scripts/e2e-check.sh` を回す

## 開発用コマンドとスクリプト

`autonote dev ...` は開発者向けのサブコマンドで、公開の usage には出ない。引数なしで実行すると次の usage を出す（`Sources/autonote/DevCommands.swift`）。

```text
autonote dev render-fixture --out <dir> [--fixtures <dir>] [--no-compare]
autonote dev record --seconds <N> --out <dir> [--mic-uid <UID>] [--voice-processing] [--tap-layout tapOnly|withOutputClock] [--check-permission]
autonote dev import <file> --out <dir> [--lang auto|ja|en] [--start <ISO8601>]
autonote dev auto-record --vault <dir> --data <dir> [--countdown N] [--grace N] [--lang ja|en|auto]
  stdin: yes|no|never <uid>, start <uid>, cancel, manual, pause, resume, bookmark [note], lang ja|en|auto, stop, quit
autonote dev devices [--watch]
autonote dev engines [--data <dir>]
autonote dev transcribe <audio> --engine dictation|speech|whisper|whisper-live [--model <name> | --model-path <ggml.bin>] [--data <dir>] [--lang ja|en|auto] [--hints "w1,w2"] [--realtime] [--segmentation default|frequent|silence] [--max-seconds N] [--gpu on|off] [--text-out <path>]
autonote dev transcribe --mic --engine dictation|speech|whisper-live --seconds N [same options]
autonote dev models list|download <name>|delete <name> [--data <dir>]
autonote dev summarize --fake <transcript.json> --out <dir> [--minutes <minutes.json>] [--fail-summary] [--claude]
  (--minutes is required unless --fail-summary or --claude is given)
autonote dev live-summary <live.json> [--state <state.json>] [--questions <questions.json>] [--claude]
autonote dev translate <transcript.json> [--target auto|ja|en] [--model <gguf>] [--minutes <minutes.json>] [--live-summary <live-summary.json>]
  (without --model: the deterministic fake, "EN: <text>" / "JA: <text>"; --model needs the on-device llama.cpp runtime;
   --minutes / --live-summary also translate the summary's texts into the opposite of its language, or the fixed target)
```

`scripts/` の一覧:

| スクリプト | 用途 |
|---|---|
| `config.sh` | Bundle ID と署名証明書名の唯一の定義。他のスクリプトが source する |
| `build-app.sh` | `AutoNote.app` を組み立てて署名する |
| `build-whisper-xcframework.sh` | `tools/whisper.cpp`（v1.9.5）と `tools/llama.cpp`（b12359）を 1 つの ggml でビルドし、`tools/whisper.xcframework` を作る（x86_64 は AVX2 付き、arm64 は Metal・Core ML） |
| `make-dev-cert.sh` | 自己署名の証明書 `AutoNote Dev` をログインキーチェーンに作り、コード署名用に信頼する（冪等） |
| `e2e-check.sh` | E2E の動作確認 |
| `tcc-check.sh` | マイク・システム音声録音などの許可（TCC）の持続と許可なしの挙動を、手順を自動化して記録する。終了・操作するのは `build/AutoNote.app` から起動したプロセスだけ。別の場所の AutoNoteApp（インストール済みのアプリなど）が動いていると、何もせずに終了コード 3 で止まる（録音中・後処理中でないのを確かめて自分で終了し、終わったら起動し直す）。`audio-persist` の初回と `--reset`、`dictation` は `tccutil reset` を実行する。許可は Bundle ID 単位なので、インストール済みの AutoNote の許可も消え、許可し直すまでシステム音声の録音・音声認識が使えない |
| `setup-whisper.sh` | whisper.cpp を `tools/whisper.cpp` に clone してビルドし、ベンチ用のモデルを取る |
| `make-sample-audio.sh` | ベンチ用のサンプル音声を `scripts/samples/*.txt` から合成して `tools/samples/` に置く |
| `bench-whisper.sh` | whisper.cpp のモデル別ベンチを取り、Markdown の表で出す |
| `cer.py` | 文字誤り率（CER）を出す。`python3 -I` で実行する |
| `make-fake-transcript.py` | 指定した分数の偽の会議文字起こしを作る |
| `probe-claude.sh` | `claude -p` の構造化出力と実行環境の固定を確かめる。指示文はアプリの既定（`DefaultPrompt`）を抜き出して使い、議事録スキーマ v2 で検査し、`.build/debug/autonote` があれば `MinutesOutput` として decode できるかも見る |
| `probe_prompt.py` | `probe-claude.sh` の補助（既定の指示文の抜き出しとスキーマ検査）。`python3 -I` で実行する |
| `minutes-schema.json` | 議事録生成で `claude -p --json-schema` に渡す出力スキーマ |
| `samples/` | ベンチの参照テキスト（日本語 5 分、英語 30 秒、日本語 10 文） |

## 同梱しているもの

| もの | 版 | ライセンス | 置き場所 | 用途 |
|---|---|---|---|---|
| mermaid.js（`dist/mermaid.min.js`） | 11.4.1（npm の `mermaid@11.4.1`、tarball の shasum `577fad5c31a01a06d9f793e298d411f1379eecc8`） | MIT（`Resources/mermaid/LICENSE`） | `Resources/mermaid/` → `AutoNote.app/Contents/Resources/mermaid/`（`scripts/build-app.sh` が入れる） | 詳細画面「要約」タブの構成図の「プレビュー」。WKWebView にインラインで読み込み、ネットワークに出ない（CSP で外部読み込みを禁止し、WebKit のコンテンツルールで http(s) をすべて止め、データストアは非永続） |

版を上げるときは npm の tarball から `package/dist/mermaid.min.js` と `package/LICENSE` を取り出して差し替え、上の表を直す。

## CI / リリース（GitHub Actions）

- `.github/workflows/ci.yml`: main への push・PR・手動実行（workflow_dispatch）で、macOS 26（`macos-26`、Xcode 26.6）上で `swift build` と `swift test`（時間依存のテストが負荷で落ちることがあるので、失敗したら `--no-parallel` で 1 回だけ再実行）を走らせる。開発ブランチへの push だけでは走らない（PR を開くと走る）。docs/ と `*.md` だけの変更でも走らない。同じブランチの古い実行は取り消す。whisper.xcframework と `.build` はキャッシュする
- `.github/workflows/release.yml`: main への push か手動実行で `Resources/Info.plist` の `CFBundleShortVersionString` を読み、`v<version>` のタグが無ければ次の順に進む。タグがあれば何もしない
  1. `build`（`macos-26`、鍵なし）: ビルド・テストし、arm64 + x86_64 のユニバーサルの .app を組み立てる（ここではアドホック署名）
  2. `sign`（`macos-26`、`environment: release`）: Environment「release」の Secrets（`AUTONOTE_SIGNING_P12_BASE64`・`AUTONOTE_SIGNING_P12_PASSWORD`）を一時キーチェーンに取り込み（`scripts/signing.sh import-ci`）、`scripts/sign-app.sh` で「AutoNote Dev」の証明書で署名し直し、designated requirement の証明書が `scripts/config.sh` の `AUTONOTE_CERT_SHA1` と一致するかを `scripts/signing.sh check` で確かめる。Secrets が無い（fork など）と失敗し、リリースは作られない
  3. `publish`（`contents: write`）: `AutoNote-<version>-macos-universal.zip` を添えた GitHub Release を作る
- ワークフローの `permissions` は既定を空にしてジョブごとに最小だけ与える。外部のアクションはコミットの SHA で固定する（コメントに版）。`pull_request_target` は使わない
- 配布物は Developer ID 署名・公証をしていない。初回だけ、開こうとして拒否されたら、システム設定 › プライバシーとセキュリティ の下にある「このまま開く」を押す。または `xattr -d com.apple.quarantine /Applications/AutoNote.app`。以後はアプリ内の自動アップデートで入れ替わる（アプリが自分で取得したファイルには quarantine が付かない）

## リリース署名の鍵

手元のビルドとすべてのリリースを、同じ自己署名の証明書「AutoNote Dev」（SHA-1 は `scripts/config.sh` の `AUTONOTE_CERT_SHA1`）で署名する。macOS の許可（マイク・システム音声）と自動アップデートの署名検査は「bundle identifier と証明書」にひもづくので、版が変わっても保たれる。

- 鍵（p12 とそのパスワード）の正は 1Password（「AutoNote release signing (p12)」「AutoNote release signing (p12 password)」）。GitHub には Environment「release」の Secrets にだけ写しを置く。リポジトリ全体の Secrets には置かない。「release」の deployment branch は `main` だけ（PR や他のブランチのワークフローからは読めない）
- 1Password と Secrets に入れる: `scripts/signing.sh export-to-1password`（`op` のサインインと `swift` が要る。「AutoNote Dev」の 1 件だけを書き出し（`scripts/export-identity.swift`）、macOS がキーチェーンのパスワードを 1 回たずねる。同名の項目が 1Password にあれば止まる）
- 別の Mac で手元のビルドを同じ証明書にそろえる: `scripts/signing.sh import-login`（1Password から login キーチェーンへ。管理者認証のダイアログが出る）。その Mac に別の「AutoNote Dev」があると止まる（削除するとその Mac の手元ビルドの許可は一度外れる）
- release.yml と同じ手順を手元で確かめる: `scripts/signing.sh selftest`（使い捨ての証明書と一時キーチェーンで import-ci → sign-app.sh → check。login キーチェーンは変えない。検索リストは途中で一時キーチェーンを足し、終わると戻す）
  - 使い捨ての証明書には信頼設定が無い（ランナーと同じ）。codesign が `--keychain` なしでも識別子を引けることを確かめる
  - import-ci は一時キーチェーンを検索リストの先頭に足し、delete-keychain が外す。足さないと、macOS 26 のランナーの codesign は `--keychain` を渡しても `<SHA-1>: no identity found` で止まる（v0.7.0 の sign ジョブ）
- 利用者の Mac と同じ条件（署名者の証明書が信頼されておらず、キーチェーンにも無い）で更新の検査を確かめる: `E2E_UPDATE_IDENTITY=untrusted scripts/update-e2e.sh`（項目 16u。`scripts/e2e-check.sh` の項目 16 は 16 と 16u の両方を回す。アプリは起動しない。署名が変わるとマイクの許可を求め直し、この Mac の AutoNote の許可を上書きするため）
- 推奨（未設定）: main にブランチ保護（直接 push の禁止・レビュー必須）を掛けると、鍵で署名されるコードを変えられる経路がさらに狭まる。自動マージの流れを止めるので、今は掛けていない

### 前提と、それが成り立たない場合（開発者の Mac）

自動アップデートが守れるのは「署名の鍵を持たない者」まで。リポジトリにリリースを置ける者（push 権限やトークンを持つ者）でも、鍵が無ければ署名が合わず、利用者の Mac には入らない。

しかし **リリースの鍵は開発者の Mac の login キーチェーンにもある**（手元のビルドとリリースを同じ証明書にして許可を保つための選択）。その秘密鍵は `/usr/bin/codesign` からなら確認なしで使え、同じ Mac には `gh` のログイン（`gh auth token` で取り出せる）もあり、main にブランチ保護も無い。だから **開発者の Mac で利用者として動くプロセスが 1 つ乗っ取られれば**、そのプロセスは次のことができる: 悪性の .app を `codesign` でこの鍵で署名する → `gh release create` で latest に置く → 全利用者の AutoNote が 24 時間以内に「署名が一致する新しい版」として入れ替え、マイク・システム音声の許可を保ったまま起動する。自己署名なので失効もできない。この場合は「鍵が漏れた」として下の手順に進むしかない。

緩和策（どれも未実施。上ほど効く）:

- リリースの鍵を手元の鍵と分け、鍵は Environment「release」の Secrets だけに置く。代わりに、手元のビルドとリリース版を行き来するたびに許可が外れる
- 分けない場合でも、手元の鍵を専用のキーチェーンに移し、ふだんはロックしておく（使うときだけ解錠する）。ACL も codesign の「常に許可」にしない
- main にブランチ保護（直接 push の禁止・レビュー必須）を掛け、GitHub の immutable releases（公開後の asset の差し替えを防ぐ）を有効にする
- `gh` のトークンを必要最小の権限・短い期限のものにし、ふだんの Mac にリリースを作れるトークンを置かない
- リリースの作成を GitHub の通知で見張り、身に覚えのないリリースはすぐ消して下の手順に進む

### 鍵が漏れたときの手順

自己署名の鍵は失効できない。漏れた鍵で署名されたものは、利用者の Mac で今のアプリと同じ署名と見なされる（自動アップデートは「このリポジトリの releases に置かれ、署名が一致する」ものだけを入れるので、鍵を持つ者がこのリポジトリにリリースを置ければ自動で入る。手で配られたものも区別できない）。

1. すぐに Environment「release」の Secrets を消す（`gh secret delete AUTONOTE_SIGNING_P12_BASE64 --env release`、`AUTONOTE_SIGNING_P12_PASSWORD` も）。漏れた経路（Actions のログ、手元のファイル、1Password の共有）を調べて塞ぐ
2. 新しい証明書を作る（`scripts/make-dev-cert.sh` を、別の名前か、古い「AutoNote Dev」を消した Mac で）。`scripts/config.sh` の `AUTONOTE_CERT_NAME` と `AUTONOTE_CERT_SHA1` を新しい値にし、`scripts/signing.sh export-to-1password` で 1Password と Secrets を差し替える。古い 1Password の項目は「失効」と分かる名前にして残す
3. 新しい証明書で署名した版は、今のアプリの署名と一致しないので **全利用者の自動アップデートが止まる**（アプリは「署名がこのアプリと違う」として入れ替えない）。利用者は GitHub から手で入れ替える必要があり、そのとき **マイク・システム音声の許可も一度外れる**
4. 利用者に告知する: リリースノートと README の冒頭に、鍵を替えたこと・手で入れ替える手順・許可をもう一度与えること・漏れた鍵で署名された配布物（いつ以降のもの）を開かないことを書く

## 自動アップデート

- アプリは起動時と 1 時間ごとに「最後の確認から 24 時間たったか」を見て、たっていれば `https://api.github.com/repos/YutaOkoshi/AutoNote/releases/latest` を認証なしで読む（User-Agent は `AutoNote` だけ）。新しい版の zip（GitHub の SHA-256 つき）を `<データ領域>/updates/<版>/` に落として照合・展開し、署名が「いま動いているアプリの designated requirement」を満たすこと、bundle identifier と版を確かめる。リダイレクト先は GitHub のホスト（`github.com`・`*.githubusercontent.com`）だけ、すべて HTTPS
- zip は署名を確かめる前に 2 回見る: 展開の前に目次（絶対パス・`..`・`AutoNote.app` 以外の最上位の項目・シンボリックリンクの下の項目・デバイスを拒む。項目数 1 万・展開後 2 GB まで。512 MB を超えるリリースは取得しない）、展開の後に中身（`AutoNote.app` が本物のフォルダで、リンクがすべてその中を指す）。`ditto -x -k` 自体も `../` と絶対パスを展開先の中に書き、リンク越しの書き込みは拒む（2026-11-19 に実測）が、外を指すリンクはそのまま作るので、後の検査が要る
- 入れ替えるのは、録音・カウントダウン・猶予中でなく、後処理キューと翻訳のジョブが無く、音声の取り込み・モデルのダウンロード・Automation の実行中でもなく、メインウィンドウが閉じているとき。待つ間はメニューに「アップデートして再起動（x.y.z）」が出る（選ぶと録音中でなければすぐ入れ替える）。入れ替える直前に、取得した版をもう一度検査し、録音の状態をコーディネーターから読み直す
- 補助（`<データ領域>/updates/install.sh`）はアプリの終了が決まってから（`applicationWillTerminate`）起動するので、終了が取り消されたら何も起きない。補助は、アプリの終了を待つ → 取得した版が本物のフォルダかを見る → アプリの隣（`.AutoNote-update.app`）へ移す → `codesign --verify --deep --strict -R=<今の版の要件>` → アプリと 1 回で入れ替える（`renamex_np` の `RENAME_SWAP`、`autonote dev update --swap`。`/Applications/AutoNote.app` が無くなる瞬間が無い）→ 起動 → 新しい版が書く pid（`updates/launched.pid`）を待って生きているかを見る、の順に進む。起動を確かめられなければ新しい版のプロセスを止め、もう一度入れ替えて元の版を起動する。補助は 1 つだけ動く（`updates/install.lock`）。途中で止まって残った `.AutoNote-update.app` は次の起動で消す。結果は `updates/last-install.json`、記録は `updates/install.log`
- 確認先に届かなかったときは、最後の確認時刻を進めず、1・2・4・8・16 時間あけて問い合わせ直す（その後は 1 日に 1 回。`updates/state.json` の `network_failures`・`retry_at`）。要求は `User-Agent: AutoNote` と `Accept-Language: en`（Mac の言語の設定は送らない）
- 設定の「一般 › アップデート」で切れる（`settings.json` の `auto_update_enabled`、既定はオン）。「今すぐ確認」は切っていても動き、前に入れ替えに失敗した版も試し直す
- アプリの場所に書き込めない、アドホック署名の版から動いている、.app として動いていない、のどれかなら自動では入れ替えず「手動での更新が必要」と出す
- 開発用: `AUTONOTE_UPDATE_FEED_URL` で確認先を差し替えられる。効くのは debug 構成のビルドで `AUTONOTE_DATA_DIR` も設定したときだけ（リリースビルドでは無視する）。`autonote dev update --status | --now | --check [--feed <url>] [--app <path>]`（`--feed` も debug ビルドだけ）
- E2E: `scripts/update-e2e.sh`（`scripts/e2e-check.sh` の項目 16）。一時ディレクトリに置いたアプリの写しと python3 の偽サーバーで、SHA-256 違い・署名違い・展開先の外へ書く zip・外を指すリンクを含む zip の拒否、起動できない版からの復旧、録音中の延期、入れ替えと再起動、入れ替え前後の designated requirement の一致を見る

## バージョンの上げ方

次の 3 か所を同じ版にそろえて main に push する。

- `Resources/Info.plist` の `CFBundleShortVersionString`（例 0.2.0 → 0.2.1）
- `Resources/Info.plist` の `CFBundleVersion`（ビルド番号。1 つ上げる）
- `Sources/AutoNoteCore/AutoNoteVersion.swift` の `AutoNoteVersion.current`（`autonote --version` が出す版）

`Info.plist` の `CFBundleShortVersionString` と `AutoNoteVersion.current` が違うと、release.yml（`.github/scripts/release-version.sh`）はリリースを作らずに止まる。`scripts/e2e-check.sh` の項目 5b も同じ食い違いを FAIL にする。

## 手動で確認すること（利用者の手が要る）

`scripts/e2e-check.sh` は CLI・ソケット・ファイルで確かめられる範囲を自動で見る。次は人の操作が要るので、リリース前に手で確かめる。

- 初回の許可ダイアログ（マイク、システム音声録音、通知）に応える。画面ロック中は出ない
- 実機で録音して、文字起こしと議事録が Vault にできる
- ホットキー（⌃⌥B / ⌃⌥R / ⌃⌥P）を実際のキー操作で押して動く
- 「この会議を削除」「録音を破棄」などの破壊的なボタンの確認ダイアログ
- ログイン時起動のオン・オフ（システム設定 › 一般 › ログイン項目に出る）と、ログアウト→ログイン後の自動起動
