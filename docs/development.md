# AutoNote 開発者ガイド

AutoNote をソースからビルドし、テストし、変更を入れるための文書。利用者向けの説明は [利用者ガイド](guide/getting-started.md) と [利用者リファレンス](guide/reference.md)、設計の全体は [要件書](superpowers/specs/2026-10-24-autonote-design.md) にある。

## 必要なもの

- macOS 26.0 以降の Mac（Apple Silicon でも Intel でもよい）
- Xcode 26 系（Swift 6.2 以降のツールチェーンと macOS 26 SDK。`Package.swift` は `swift-tools-version:6.2`。CI は Xcode 26.6 / Swift 6.3 を使う）。`xcodebuild`・`libtool`・`lipo` は Xcode に入っている
- cmake（whisper.cpp の XCFramework のビルドに使う。ninja があれば使う）と git
- Claude Code の CLI（`claude`。議事録生成を実際に動かすとき）
- jq（`scripts/e2e-check.sh` の一部の項目が使う）

## 初回セットアップ

- whisper.cpp の XCFramework（`tools/whisper.xcframework`）はリポジトリに含めず、手元でソースからビルドする。初回は `scripts/build-whisper-xcframework.sh` を実行する（数分かかる。`tools/whisper.cpp` が無ければ v1.9.5 を clone する。既存の `tools/whisper.cpp` が commit `d1be6fd`（= v1.9.5）でなければエラーで止まる）。公式の zip は x86_64 スライスが AVX2 なしで Intel では約 7 倍遅いため使わない。`scripts/build-app.sh` と `scripts/e2e-check.sh` は成果物が無ければこのスクリプトを先に呼ぶ
- `tools/` は git の管理外。whisper.cpp のソース、XCFramework、ベンチ用のモデルや音声はここに置き、コミットしない
- 初回の `scripts/build-app.sh` は自己署名のコード署名証明書 `AutoNote Dev` を作ってログインキーチェーンに入れるので（`scripts/make-dev-cert.sh`）、管理者認証のダイアログが出る。同じ証明書と同じ Bundle ID で署名し続けることで、再ビルドしてもマイクなどの許可（TCC）が外れない
- `xcodebuild -create-xcframework` がプラグインの読み込みで失敗する Xcode がある（Xcode 26.5 で確認。直すには `xcodebuild -runFirstLaunch`）。そのときスクリプトは同じ構造の XCFramework を手で組んで続ける

## ビルド・テスト・E2E

- テスト: `swift test`
- アプリ（.app）のビルド: `scripts/build-app.sh [debug|release]`（既定は debug）。成果物は `build/AutoNote.app`、同梱の CLI は `build/AutoNote.app/Contents/MacOS/autonote`
- 動作確認（E2E）: `scripts/e2e-check.sh`。CLI・ソケット・ファイルで確かめられる範囲を人の手なしで見る。`--quick` は時間のかかる項目（`swift test`・`build-app`・whisper を使う項目）を飛ばし、前回ビルドした `build/AutoNote.app` をそのまま確かめる。`--verbose` で各コマンドの出力をそのまま見せる
- CI と同じ .app を手元で作るなら `AUTONOTE_BUILD_ARCHS="arm64 x86_64" AUTONOTE_CODESIGN_IDENTITY=- scripts/build-app.sh release`（`AUTONOTE_BUILD_ARCHS` を付けなければホストのアーキテクチャだけ、`AUTONOTE_CODESIGN_IDENTITY` を付けなければ `AutoNote Dev` で署名）

### `AUTONOTE_DATA_DIR`

環境変数 `AUTONOTE_DATA_DIR` を設定すると、アプリと CLI は既定のデータ領域（`~/Library/Application Support/AutoNote`）の代わりにそのフォルダを使う。このとき CLI はアプリを自動起動せず、ログイン項目の登録もしない。実データを汚さずに試すときに使う（`scripts/e2e-check.sh` もこれを使う）。

注意: ソケット（`<データ領域>/autonote.sock`）のパスは UNIX ドメインソケットの上限（約 104 バイト）に収まる必要がある。長すぎるとソケットを作れず（`pathTooLong`）、アプリは IPC なしで動く（ログに残るだけで画面には出ない）。`/tmp/an-xxxxxx` のような短いパスにする。

## リポジトリ構成

- `Sources/AutoNoteCore`: 録音・文字起こし・議事録生成・Vault 書き出し・IPC・Automations などの中核ロジック（UI なし）
- `Sources/AutoNoteApp`: SwiftUI のメニューバーアプリ（メインウィンドウ、設定、ホットキー、通知、ログイン項目）
- `Sources/autonote`: 同梱の CLI。公開コマンドと、開発用の `autonote dev ...`
- `Sources/AutoNoteTestSupport`: テストと `autonote dev` が使う偽物（音声デバイス・時計・ディスク・whisper など）とフィクスチャの読み込み
- `Tests/AutoNoteCoreTests`: 単体テスト
- `Tests/Fixtures`: テスト用の会議データ。内容はすべて架空
- `Resources/`: `Info.plist` などアプリに同梱するもの
- `scripts/`: ビルド・E2E・ベンチ・スパイク用のスクリプト（下の一覧）
- `.github/`: CI とリリースのワークフロー、その補助スクリプト
- `docs/`: 利用者ガイド、この文書、要件書と設計書（`superpowers/specs/`）、調査記録（`superpowers/research/`）

## 開発の約束事

- 最低 OS は macOS 26.0。`swift-tools-version: 6.2`、Swift 6 言語モード（strict concurrency）
- `AutoNoteCore` の型・関数で他ターゲットから使うものは `public` にする
- Intel と Apple Silicon の両方で動かす。機種差は実行時に判定し、`#if arch` で機能を落とさない
- 署名は自己署名の `AutoNote Dev`、Bundle ID は `com.yutaokoshi.autonote`。どちらも `scripts/config.sh` が唯一の定義（`AUTONOTE_BUNDLE_ID` と `AUTONOTE_CERT_NAME`。`build-app.sh`・`e2e-check.sh`・`make-dev-cert.sh` などがここを読む。変えるときはここだけを直す）。App Sandbox なし、Hardened Runtime なし
- 音声・文字起こし・議事録・個人の機材識別子をコミットしない。フィクスチャは架空のデータで作る
- 音声はローカルから出さない。外部に渡すのは `claude -p` への文字起こしテキストだけ
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
autonote dev live-summary <live.json> [--state <state.json>] [--claude]
```

`scripts/` の一覧:

| スクリプト | 用途 |
|---|---|
| `config.sh` | Bundle ID と署名証明書名の唯一の定義。他のスクリプトが source する |
| `build-app.sh` | `AutoNote.app` を組み立てて署名する |
| `build-whisper-xcframework.sh` | `tools/whisper.cpp`（v1.9.5）から `tools/whisper.xcframework` を作る（x86_64 は AVX2 付き、arm64 は Metal・Core ML） |
| `make-dev-cert.sh` | 自己署名の証明書 `AutoNote Dev` をログインキーチェーンに作り、コード署名用に信頼する（冪等） |
| `e2e-check.sh` | E2E の動作確認 |
| `tcc-check.sh` | マイク・システム音声録音などの許可（TCC）の持続と許可なしの挙動を、手順を自動化して記録する |
| `setup-whisper.sh` | whisper.cpp を `tools/whisper.cpp` に clone してビルドし、ベンチ用のモデルを取る |
| `make-sample-audio.sh` | ベンチ用のサンプル音声を `scripts/samples/*.txt` から合成して `tools/samples/` に置く |
| `bench-whisper.sh` | whisper.cpp のモデル別ベンチを取り、Markdown の表で出す |
| `cer.py` | 文字誤り率（CER）を出す。`python3 -I` で実行する |
| `make-fake-transcript.py` | 指定した分数の偽の会議文字起こしを作る |
| `probe-claude.sh` | `claude -p` の構造化出力と実行環境の固定を確かめる |
| `minutes-schema.json` | 議事録生成で `claude -p --json-schema` に渡す出力スキーマ |
| `samples/` | ベンチの参照テキスト（日本語 5 分、英語 30 秒、日本語 10 文） |

## CI / リリース（GitHub Actions）

- `.github/workflows/ci.yml`: main への push・PR・手動実行（workflow_dispatch）で、macOS 26（`macos-26`、Xcode 26.6）上で `swift build` と `swift test`（時間依存のテストが負荷で落ちることがあるので、失敗したら `--no-parallel` で 1 回だけ再実行）を走らせる。開発ブランチへの push だけでは走らない（PR を開くと走る）。docs/ と `*.md` だけの変更でも走らない。同じブランチの古い実行は取り消す。whisper.xcframework と `.build` はキャッシュする
- `.github/workflows/release.yml`: main への push か手動実行で `Resources/Info.plist` の `CFBundleShortVersionString` を読み、`v<version>` のタグが無ければ `macos-26` の 1 ジョブでビルド・テストし、arm64 + x86_64 のユニバーサルでアドホック署名した `AutoNote-<version>-macos-universal.zip` を添えた GitHub Release を作る。タグがあれば何もしない
- 配布物は Developer ID 署名・公証をしていない。一度開こうとして拒否されたら、システム設定 › プライバシーとセキュリティ の下にある「このまま開く」を押す。または `xattr -d com.apple.quarantine /Applications/AutoNote.app`

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
