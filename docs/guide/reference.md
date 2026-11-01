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

### 分かれた録音を 1 つの会議にまとめる（`autonote merge`）

1 つの会議が途中の停止やクラッシュで複数の録音に分かれたときは、`autonote merge <id> <id> [<id>...]`（会議 ID は `autonote list --json` で分かる）か、メインウィンドウの一覧で ⌘クリック / ⇧クリックで 2 件以上を選び、右クリックの「1 つの会議に統合」でまとめる。新しい会議が 1 つでき、最初の録音の開始から最後の録音の終了までを 1 本の時間軸として、文字起こしから処理し直す（録音と録音の隙間は一時停止として扱う）。統合できるのは、録音中・処理中でなく、取り込んだ音声でなく、時間が重ならず、言語が同じ会議だけで、当てはまらなければ理由を出して何もしない（CLI は終了コード 1）。統合元の会議は消さず、manifest に `merged_into`（新しい会議の ID）を書いて一覧から外し、統合元の議事録ノートは Vault と `_index.md` から外す。統合元の録音ファイルは保持期間の設定どおりに消える。

統合を取り消す操作はない。元に戻すには、アプリを終了してから、データ領域の `recordings/<統合元の ID>/manifest.json` から `"merged_into"` の行を消し（統合元ごとに行う）、新しい会議の `recordings/<新しい ID>/`・`transcripts/<新しい ID>/`・`queue/jobs/<新しい ID>.json`・`vault-state/<新しい ID>.json` を削除する（Vault に新しい会議のノートが書かれていればそれも削除する）。統合元のノートは戻らないので、必要なら統合元ごとに `autonote regenerate <id>` で書き直す。

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
- 環境変数: `AUTONOTE_EVENT`（きっかけ）、`AUTONOTE_MEETING_ID`、`AUTONOTE_FILE`（Vault の会議ファイル。録音開始時は空）、`AUTONOTE_TITLE` / `AUTONOTE_DATE` / `AUTONOTE_START`、`AUTONOTE_JSON`（構造化出力の JSON ＝ `minutes.json` のパス。議事録生成後のみ）。アプリの環境変数もそのまま引き継ぐ
- `minutes.json` のキー（議事録スキーマ v2）: `schema_version`（2。無ければ v1）、`title`、`summary`（3〜5 段落の文字列の配列）、`decisions[]`（`text`, `t`）、`agenda[]`（`title`, `body`, `t`）、`next_actions[]`（`text`, `owner`, `due`, `t`, `priority` = `high`/`medium`/`low`）、`suggested_terms[]`、`attendees[]`（`name`, `role`）、`key_points[]` / `insights[]` / `follow_ups[]`（`text`, `t`）、`questions[]`（`question`, `asked_by`, `is_resolved`, `answer`, `t`）、`deadlines[]`（`description`, `date`, `owner`, `t`）、`risks[]`（`description`, `severity` = `high`/`medium`/`low`, `mitigation`, `t`）、`architecture_diagram`（Mermaid のソースか null）。`t` は根拠となる発言の時刻 `HH:MM:SS`。v1 からある 6 キー（`title` `summary` `decisions` `agenda` `next_actions` `suggested_terms`）の名前と型は変わらない。v1 で作った `minutes.json` には v2 のキーが無いことがある
- ログ（標準出力・標準エラー・終了コード）は `~/Library/Application Support/AutoNote/logs/automations/<実行ごとのフォルダ>/`（`result.json`、`stdout.txt` など）。失敗しても議事録の成否には影響しない
- 定義の検証メッセージ: 「同じ名前の Automation があります」「コマンドを入れてください」「タイムアウトは 1〜86400 秒にしてください」「名前を入れてください」

## ショートカット

既定は ⌃⌥B（ブックマーク）、⌃⌥R（録音の開始・停止）、⌃⌥P（一時停止・再開）。設定 › ショートカット で変えられる。グローバルホットキーなので、アクセシビリティの許可は要らない。

## 通知

通知は音を鳴らさない。表示スタイルは システム設定 › 通知 の AutoNote に従い、アプリ内では通知パネルに出る。

## ログイン時起動

設定 › 一般 でオンにすると、いま動かしている `AutoNote.app` の場所がログイン項目として登録される。ダウンロードフォルダや `build/AutoNote.app` から動かすと登録先がそこになるので、使う場所（例: `/Applications`）に置いてからオンにする。
