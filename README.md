# AutoNote

macOS（26.0 以降）のメニューバーで会議を録音し、文字起こしと議事録を作るアプリ。

- 要件書: [docs/superpowers/specs/2026-10-24-autonote-design.md](docs/superpowers/specs/2026-10-24-autonote-design.md)
- 計画 00: [docs/superpowers/plans/2026-10-24-autonote-00-spikes-and-skeleton.md](docs/superpowers/plans/2026-10-24-autonote-00-spikes-and-skeleton.md)

テスト: `swift test`
アプリ（.app）のビルド: `scripts/build-app.sh`
動作確認（E2E）: `scripts/e2e-check.sh`（速い確認だけなら `--quick`）

初回の注意:
- whisper.cpp の XCFramework（`tools/whisper.xcframework`）はリポジトリに含めず、手元でソースからビルドする。初回は `scripts/build-whisper-xcframework.sh` を実行する（数分かかる。`tools/whisper.cpp` が無ければ v1.9.5 を clone する。既存の `tools/whisper.cpp` が commit `d1be6fd`（= v1.9.5）でなければエラーで止まる）。公式の zip は x86_64 スライスが AVX2 なしで Intel では約 7 倍遅いため使わない。`scripts/build-app.sh` と `scripts/e2e-check.sh` は成果物が無ければこのスクリプトを先に呼ぶ。`tools/` は git の管理外
- 初回の `scripts/build-app.sh` は自己署名のコード署名証明書 `AutoNote Dev` を作ってログインキーチェーンに入れるので、管理者認証のダイアログが出る
- whisper.cpp のベンチ用スクリプト（`scripts/setup-whisper.sh`、`scripts/make-sample-audio.sh`、`scripts/bench-whisper.sh`。取得物は `tools/` に置き、コミットしない）と、XCFramework を手元でビルドする `scripts/build-whisper-xcframework.sh` がある。文字起こしの開発用コマンドは `autonote dev engines` / `autonote dev transcribe`（計画 00 のスパイク `Spikes/` は計画 04 で削除した）
- `scripts/e2e-check.sh --quick` はビルドし直さず、前回ビルドした `build/AutoNote.app` をそのまま確かめる

## 使い方（CLI）

アプリ本体と同梱の `autonote`（`build/AutoNote.app/Contents/MacOS/autonote`）が、データ領域の UNIX ソケットで通信する。`/usr/local/bin` へのリンクの作り方は 設定 › 一般 に案内がある。アプリが起動していなければ CLI が起動を試みる（`AUTONOTE_DATA_DIR` を設定しているときは起動しない）。出力は人向けが既定で、`--json` で機械可読。終了コードは成功 0、失敗 1。

| コマンド | 動作 |
|---|---|
| `autonote start [--lang auto\|ja\|en]` | 録音開始（手動扱い） |
| `autonote stop` / `pause` / `resume` | 停止 / 一時停止 / 再開 |
| `autonote bookmark [メモ]` | ブックマーク（録音中のみ） |
| `autonote status [--json]` | 録音器の状態と待ち行列 |
| `autonote list [--since YYYY-MM-DD] [--json]` | 会議一覧 |
| `autonote latest [--open] [--json]` | 最新の議事録ファイルのパス |
| `autonote import <file>` | 音声ファイルの取り込み |
| `autonote regenerate <id>` | 議事録の再生成 |
| `autonote automations list [--json]` / `run <名前> <id>` | Automation の一覧と手動実行 |

## Automations

議事録ができた瞬間などに、利用者のコマンドを自動で走らせる。定義は `~/Library/Application Support/AutoNote/automations.json`（設定 › Automations でも編集できる）。グループや他人が書き込める権限になっている、または自分の所有でないと、安全のため全部無効にして警告する（`chmod 600` で直る）。

```json
[
  {
    "name": "Slack に要約を投稿",
    "enabled": true,
    "on": "minutes_generated",
    "command": "~/bin/post-minutes-to-slack.sh",
    "timeout_sec": 60
  }
]
```

- きっかけ（`on`）: `minutes_generated` / `transcript_only` / `recording_started` / `recording_stopped`
- コマンドは `/bin/zsh -lc` で実行する（ログインシェルの PATH を引き継ぐ）。標準入力には同じ内容の JSON を流す。タイムアウトは 1〜86400 秒
- 環境変数: `AUTONOTE_EVENT`（きっかけ）、`AUTONOTE_MEETING_ID`、`AUTONOTE_FILE`（Vault の会議ファイル。録音開始時は空）、`AUTONOTE_TITLE` / `AUTONOTE_DATE` / `AUTONOTE_START`、`AUTONOTE_JSON`（構造化出力の JSON。議事録生成後のみ）。アプリの環境変数もそのまま引き継ぐ
- ログ（標準出力・標準エラー・終了コード）は `~/Library/Application Support/AutoNote/logs/automations/<実行ごとのフォルダ>/`（`result.json`、`stdout.txt` など）。失敗しても議事録の成否には影響しない
- 定義の検証メッセージ: 「同じ名前の Automation があります」「コマンドを入れてください」「タイムアウトは 1〜86400 秒にしてください」「名前を入れてください」

## ショートカット

既定は ⌃⌥B（ブックマーク）、⌃⌥R（録音の開始・停止）、⌃⌥P（一時停止・再開）。設定 › ショートカット で変えられる。グローバルホットキーなので、アクセシビリティの許可は要らない。

## 通知

通知は音を鳴らさない。表示スタイルは システム設定 › 通知 の AutoNote に従い、アプリ内では通知パネルに出る。

## ログイン時起動

設定 › 一般 でオンにすると、いま動かしている `AutoNote.app` の場所がログイン項目として登録される。`build/AutoNote.app` を動かすと登録先が変わるので、使う場所（例: `/Applications`）に置いてからオンにする。

## 開発用: `AUTONOTE_DATA_DIR`

環境変数 `AUTONOTE_DATA_DIR` を設定すると、アプリと CLI は既定のデータ領域（`~/Library/Application Support/AutoNote`）の代わりにそのフォルダを使う。このとき CLI はアプリを自動起動せず、ログイン項目の登録もしない。実データを汚さずに試すときに使う（`scripts/e2e-check.sh` もこれを使う）。

注意: ソケット（`<データ領域>/autonote.sock`）のパスは UNIX ドメインソケットの上限（約 104 バイト）に収まる必要がある。長すぎるとソケットを作れず（`pathTooLong`）、アプリは IPC なしで動く（ログに残るだけで画面には出ない）。`/tmp/an-xxxxxx` のような短いパスにする。

## CI / リリース（GitHub Actions）

- `.github/workflows/ci.yml`: main への push・PR・手動実行（workflow_dispatch）で、macOS 26（`macos-26`、Xcode 26.6）上で `swift build` と `swift test`（時間依存のテストが負荷で落ちることがあるので、失敗したら `--no-parallel` で 1 回だけ再実行）を走らせる。開発ブランチへの push だけでは走らない（PR を開くと走る）。docs/ と `*.md` だけの変更でも走らない。同じブランチの古い実行は取り消す。whisper.xcframework と `.build` はキャッシュする
- `.github/workflows/release.yml`: main への push か手動実行で `Resources/Info.plist` の `CFBundleShortVersionString` を読み、`v<version>` のタグが無ければ `macos-26` の 1 ジョブでビルド・テストし、arm64 + x86_64 のユニバーサルでアドホック署名した `AutoNote-<version>-macos-universal.zip` を添えた GitHub Release を作る。タグがあれば何もしない
- バージョンの上げ方: `Resources/Info.plist` の `CFBundleShortVersionString`（例 0.1.0 → 0.2.0）と `CFBundleVersion`（ビルド番号。1 つ上げる）の 2 か所を直して main に push する
- 配布物は Developer ID 署名・公証をしていない。初回は右クリック →「開く」か `xattr -d com.apple.quarantine AutoNote.app`
- 無料枠の目安: private リポジトリの GitHub Free は月 2,000 分で、macOS ランナーは Linux の約 10 倍の速さで枠を減らす（分単価 $0.062 対 $0.006）ので、月の実機枠は 約 200 分。CI 1 回 ≒ 実機 8〜10 分（月 約 20 回）、Release 1 回 ≒ 実機 15〜20 分（バージョンを上げた main への push では CI も同時に走る）。キャッシュが切れた回は whisper のビルドで 10 分ほど増える。支払い方法を登録していなければ、枠を超えると止まるだけで課金はされない
- CI と同じ .app を手元で作るなら `AUTONOTE_BUILD_ARCHS="arm64 x86_64" AUTONOTE_CODESIGN_IDENTITY=- scripts/build-app.sh release`（`AUTONOTE_BUILD_ARCHS` を付けなければホストのアーキテクチャだけ、`AUTONOTE_CODESIGN_IDENTITY` を付けなければ `AutoNote Dev` で署名）

## 設定値: `scripts/config.sh`

Bundle ID（`AUTONOTE_BUNDLE_ID`）と署名証明書名（`AUTONOTE_CERT_NAME`）の唯一の定義。`build-app.sh`・`e2e-check.sh`・`tcc-check.sh` などがここを読む。変えるときはここだけを直す。

## 手動で確認すること（利用者の手が要る）

`scripts/e2e-check.sh` は CLI・ソケット・ファイルで確かめられる範囲を自動で見る。次は人の操作が要るので、リリース前に手で確かめる。

- 初回の許可ダイアログ（マイク、システム音声録音、通知）に応える。画面ロック中は出ない
- 実機で録音して、文字起こしと議事録が Vault にできる
- ホットキー（⌃⌥B / ⌃⌥R / ⌃⌥P）を実際のキー操作で押して動く
- 「この会議を削除」「録音を破棄」などの破壊的なボタンの確認ダイアログ
- ログイン時起動のオン・オフ（システム設定 › 一般 › ログイン項目に出る）と、ログアウト→ログイン後の自動起動
