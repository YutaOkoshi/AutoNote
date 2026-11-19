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
- CI と同じ .app を手元で作るなら `AUTONOTE_BUILD_ARCHS="arm64 x86_64" AUTONOTE_CODESIGN_IDENTITY=- scripts/build-app.sh release`（`AUTONOTE_BUILD_ARCHS` を付けなければホストのアーキテクチャだけ、`AUTONOTE_CODESIGN_IDENTITY` を付けなければ `AutoNote Dev` で署名）

### `AUTONOTE_DATA_DIR`

環境変数 `AUTONOTE_DATA_DIR` を設定すると、アプリと CLI は既定のデータ領域（`~/Library/Application Support/AutoNote`）の代わりにそのフォルダを使う。このとき CLI はアプリを自動起動せず、ログイン項目の登録もしない。実データを汚さずに試すときに使う（`scripts/e2e-check.sh` もこれを使う）。

注意: ソケット（`<データ領域>/autonote.sock`）のパスは UNIX ドメインソケットの上限（約 104 バイト）に収まる必要がある。長すぎるとソケットを作れず（`pathTooLong`）、アプリは IPC なしで動く（ログに残るだけで画面には出ない）。`/tmp/an-xxxxxx` のような短いパスにする。

### 録音の開始・停止の理由をログで読む

録音がなぜ始まった・止まったかは `log show --last 1h --predicate 'subsystem == "com.yutaokoshi.autonote"'` で読める（流しながら見るなら `log stream --predicate ...`）。開始・停止・一時停止のたびに、`devices` カテゴリに `recording -> idle on manualStop (origin: hotkey, stop: manual, meeting: <会議 ID>)` のような 1 行が出る。`origin` がきっかけ（`hotkey`・`menu`・`window`・`notificationAction`・`cli`・`countdownFired`・`graceExpired`・`diskFull`・`terminating`・`sessionEnded`・`startFailed`・`deviceConnected`・`deviceDisconnected`。定義は `Sources/AutoNoteCore/Devices/RecordingControlOrigin.swift`）、`stop` が録音に渡した `StopReason` で、何も変えなかった操作は末尾に `ignored` が付く。前後の行で、ショートカットの受信（`HotKeyCenter`）、CLI のコマンドと送信元 PID（`SocketServer`）、機材の追加・削除（`DeviceMonitor` と `devices`）、設定の保存で変わったキー名（`AppWiring`。値は出さない）、録音セッションの開始・終了と秒数（`RecordingSession`）、ライブ文字起こし・ライブ要約の開始・終了を突き合わせる。どれも `notice` 以上なので後から `log show` で読める（`info` と `debug` は残らない）。

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
autonote dev translate <transcript.json> [--target auto|ja|en] [--model <gguf>]
  (without --model: the deterministic fake, "EN: <text>" / "JA: <text>"; --model needs the on-device llama.cpp runtime)
```

`scripts/` の一覧:

| スクリプト | 用途 |
|---|---|
| `config.sh` | Bundle ID と署名証明書名の唯一の定義。他のスクリプトが source する |
| `build-app.sh` | `AutoNote.app` を組み立てて署名する |
| `build-whisper-xcframework.sh` | `tools/whisper.cpp`（v1.9.5）と `tools/llama.cpp`（b12359）を 1 つの ggml でビルドし、`tools/whisper.xcframework` を作る（x86_64 は AVX2 付き、arm64 は Metal・Core ML） |
| `make-dev-cert.sh` | 自己署名の証明書 `AutoNote Dev` をログインキーチェーンに作り、コード署名用に信頼する（冪等） |
| `e2e-check.sh` | E2E の動作確認 |
| `tcc-check.sh` | マイク・システム音声録音などの許可（TCC）の持続と許可なしの挙動を、手順を自動化して記録する |
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
- 1Password と Secrets に入れる: `scripts/signing.sh export-to-1password`（`op` のサインインが要る。鍵の書き出しで macOS がキーチェーンのパスワードを 1 回たずねる）
- 別の Mac で手元のビルドを同じ証明書にそろえる: `scripts/signing.sh import-login`（1Password から login キーチェーンへ。管理者認証のダイアログが出る）。その Mac に別の「AutoNote Dev」があると止まる（削除するとその Mac の手元ビルドの許可は一度外れる）
- release.yml と同じ手順を手元で確かめる: `scripts/signing.sh selftest`（使い捨ての証明書と一時キーチェーンで import-ci → sign-app.sh → check。login キーチェーンと検索リストは変えない）
- 推奨（未設定）: main にブランチ保護（直接 push の禁止・レビュー必須）を掛けると、鍵で署名されるコードを変えられる経路がさらに狭まる。自動マージの流れを止めるので、今は掛けていない

### 鍵が漏れたときの手順

自己署名の鍵は失効できない。漏れた鍵で署名されたものは、利用者の Mac で今のアプリと同じ署名と見なされる（自動アップデートは「このリポジトリの releases に置かれ、署名が一致する」ものだけを入れるので、攻撃者がこのリポジトリにリリースを置けない限り自動では入らないが、手で配られたものは区別できない）。

1. すぐに Environment「release」の Secrets を消す（`gh secret delete AUTONOTE_SIGNING_P12_BASE64 --env release`、`AUTONOTE_SIGNING_P12_PASSWORD` も）。漏れた経路（Actions のログ、手元のファイル、1Password の共有）を調べて塞ぐ
2. 新しい証明書を作る（`scripts/make-dev-cert.sh` を、別の名前か、古い「AutoNote Dev」を消した Mac で）。`scripts/config.sh` の `AUTONOTE_CERT_NAME` と `AUTONOTE_CERT_SHA1` を新しい値にし、`scripts/signing.sh export-to-1password` で 1Password と Secrets を差し替える。古い 1Password の項目は「失効」と分かる名前にして残す
3. 新しい証明書で署名した版は、今のアプリの署名と一致しないので **全利用者の自動アップデートが止まる**（アプリは「署名がこのアプリと違う」として入れ替えない）。利用者は GitHub から手で入れ替える必要があり、そのとき **マイク・システム音声の許可も一度外れる**
4. 利用者に告知する: リリースノートと README の冒頭に、鍵を替えたこと・手で入れ替える手順・許可をもう一度与えること・漏れた鍵で署名された配布物（いつ以降のもの）を開かないことを書く

## 自動アップデート

- アプリは起動時と 1 時間ごとに「最後の確認から 24 時間たったか」を見て、たっていれば `https://api.github.com/repos/YutaOkoshi/AutoNote/releases/latest` を認証なしで読む（User-Agent は `AutoNote` だけ）。新しい版の zip（GitHub の SHA-256 つき）を `<データ領域>/updates/<版>/` に落として照合・展開し、署名が「いま動いているアプリの designated requirement」を満たすこと、bundle identifier と版を確かめる。リダイレクト先は GitHub のホスト（`github.com`・`*.githubusercontent.com`）だけ、すべて HTTPS
- 入れ替えるのは、録音・カウントダウン・猶予中でなく、後処理キューと翻訳のジョブが無く、メインウィンドウが閉じているとき。待つ間はメニューに「アップデートして再起動（x.y.z）」が出る（選ぶと録音中でなければすぐ入れ替える）。入れ替えは終了後に動く補助（`<データ領域>/updates/install.sh`）が、退避 → 移動 → 署名の再検査 → 起動 → 起動確認の順に行い、失敗したら退避したものを戻して起動する。結果は `updates/last-install.json`、記録は `updates/install.log`
- 設定の「一般 › アップデート」で切れる（`settings.json` の `auto_update_enabled`、既定はオン）。「今すぐ確認」は切っていても動き、前に入れ替えに失敗した版も試し直す
- アプリの場所に書き込めない、アドホック署名の版から動いている、.app として動いていない、のどれかなら自動では入れ替えず「手動での更新が必要」と出す
- 開発用: `AUTONOTE_UPDATE_FEED_URL` で確認先を差し替えられる。効くのは debug 構成のビルドで `AUTONOTE_DATA_DIR` も設定したときだけ（リリースビルドでは無視する）。`autonote dev update --status | --now | --check [--feed <url>] [--app <path>]`（`--feed` も debug ビルドだけ）
- E2E: `scripts/update-e2e.sh`（`scripts/e2e-check.sh` の項目 15）。一時ディレクトリに置いたアプリの写しと python3 の偽サーバーで、SHA-256 違い・署名違いの拒否、起動できない版からの復旧、録音中の延期、入れ替えと再起動、入れ替え前後の designated requirement の一致を見る

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
