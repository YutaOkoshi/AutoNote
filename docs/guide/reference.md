# AutoNote リファレンス — CLI・Automations・ショートカット・通知・ログイン時起動

はじめて使うときの手順は [利用者ガイド](getting-started.md) を見る。

## 使い方（CLI）

アプリ本体と同梱の `autonote`（`AutoNote.app/Contents/MacOS/autonote`）が、データ領域の UNIX ソケットで通信する。`/usr/local/bin` へのリンクの作り方は 設定 › 一般 に案内がある。アプリが起動していなければ CLI が起動を試みる（`AUTONOTE_DATA_DIR` を設定しているときは起動しない。[開発者ガイド](../development.md) を参照）。出力は人向けが既定で、`--json` で機械可読。終了コードは成功 0、失敗 1。

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

設定 › 一般 でオンにすると、いま動かしている `AutoNote.app` の場所がログイン項目として登録される。ダウンロードフォルダや `build/AutoNote.app` から動かすと登録先がそこになるので、使う場所（例: `/Applications`）に置いてからオンにする。
