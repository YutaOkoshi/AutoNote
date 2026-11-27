# share-to-repo — 会議の記録を共有のリポジトリに載せる見本

AutoNote が書き出した会議ファイル（1 会議 1 Markdown）を「議事録」と「文字起こし」の 2 本に分け、会議の記録を置く別の git リポジトリ（以下「置き場」）に commit / push し、一覧 `INDEX.md` を作り直すスクリプト一式です。毎日の見回り（載せ直し・録画の消し忘れの知らせ）と、git を使わない人のための「読む人向けの写し」（docx）も作れます。

AutoNote の外に置く汎用の見本です。AutoNote 本体はこのフォルダを使いません。自分の Mac に写して、設定を埋めて使います。

- 言語は python3 の標準ライブラリだけ（macOS の `/usr/bin/python3` で動く）。入口は薄いシェル `share-meeting.sh` と `daily-patrol.sh`
- AutoNote の会議ファイルは読むだけで、書き換えも削除もしない。`git push --force` もしない
- 音声・録画は扱わない。置き場に載るのは文字だけ

## できること

| コマンド | すること |
|---|---|
| `share-meeting.sh <会議ファイル> [--kind internal\|customer] [--customer <相手先>] [--recording <録画のファイル名>]` | 1 件を載せる（載せ直しも同じ）。`--kind` の既定は `internal`。前に載せた会議は、指定しなかった項目を前の値から引き継ぐ |
| `share-meeting.sh --unshare <autonote_id>` | 置き場から 2 本を消して push する（git の履歴には残る） |
| `share-meeting.sh --retry-pending` | push できなかった分を送り直す |
| `share-meeting.sh --rebuild-index` | `INDEX.md` を作り直す |
| `share-meeting.sh --rebuild-mirror` | 読む人向けの写しを全部作り直す |
| `daily-patrol.sh` | 毎日の見回り（下の「見回り」） |

置き場の形:

```
<置き場>/
├── README.md     ← 人と Claude への案内（templates/README.md を元に書く）
├── CLAUDE.md     ← 「README.md を読む」の 1 行
├── INDEX.md      ← 会議の一覧。スクリプトが毎回作り直す
└── 2026/
    ├── 2026-12-02_1000_サンプル商事 トライアル打合せ.md                ← 議事録
    └── 文字起こし/
        └── 2026-12-02_1000_サンプル商事 トライアル打合せ_文字起こし.md  ← 文字起こしの全文
```

- 議事録は AutoNote のファイルの `# 題` から `## ブックマーク` の手前まで（と、末尾の議事録の訳文）。`customer` の会議はブックマークの節を省く
- 議事録の中の発言リンク `[[#^t00-07-08|07:09]]` は `（→ 00:07:08）` という時刻の文字に置き換える。文字起こしの `[00:07:08]` の行に当たる
- frontmatter には AutoNote の項目に加えて `kind`・`customer`・`recorded_by`・`transcript_file`・`source_recording_deleted` が入る

## 導入の手順

以下は `~/Library/Application Support/AutoNoteShare/` に置く例です（「AutoNoteShare」と書きます）。

### 1. 置き場を用意して clone する

1. GitHub などに非公開のリポジトリを作り、読む人だけを招く
2. スクリプト専用の clone を作る（人はこの clone を触らない）
   ```sh
   mkdir -p "$HOME/Library/Application Support/AutoNoteShare"
   git clone <置き場の URL> "$HOME/Library/Application Support/AutoNoteShare/repo"
   ```
3. その clone で `git push` が確認なしで通ることを確かめる（launchd から動かすときは、パスワードや鍵の確認が出ると止まる）

### 2. スクリプトと設定を置く

```sh
cp -R examples/automations/share-to-repo "$HOME/Library/Application Support/AutoNoteShare/bin"
cp "$HOME/Library/Application Support/AutoNoteShare/bin/config.env.example" \
   "$HOME/Library/Application Support/AutoNoteShare/config.env"
chmod 600 "$HOME/Library/Application Support/AutoNoteShare/config.env"
```

`config.env` を開いて値を埋めます。項目の説明は `config.env.example` にあります。よく変えるもの:

- `VAULT_ROOT` — AutoNote の出力フォルダ（既定 `~/Documents/AutoNote`）
- `REPO_WEB_URL` — 知らせに入れるリンクの元（例 `https://github.com/<owner>/<repo>`）
- `NOTIFY_MODE` — `macos`（既定。Mac の通知と `state/todo.md`）、`slack`（Incoming Webhook）、`dry-run`（送らずに `state/outbox-dry/` に書くだけ）
- Slack の Webhook の URL は秘密です。`config.env` に直接書かず、1Password に置いて `SLACK_WEBHOOK_OP_REF="op://<保管庫>/<項目>/<欄>"` で指します（実行のたびに `op read` で取り出す。ログや状態ファイルには書かない）

### 3. 雛形を置き場に置く

`bin/templates/README.md` と `bin/templates/CLAUDE.md` を置き場の clone の直下に写し、README の中身（読む人・録画の置き方・決まり）を自分の運用に合わせて直してから commit / push します。`INDEX.md` は最初の共有のときにスクリプトが作ります（`templates/INDEX.md` の `{{rows}}` に表が入る）。

### 4. 1 件を載せる

```sh
"$HOME/Library/Application Support/AutoNoteShare/bin/share-meeting.sh" \
  "$HOME/Documents/AutoNote/2026/2026-12-02_1000_サンプル商事 トライアル打合せ.md" \
  --kind customer --customer サンプル商事 --recording 2026-12-02_1000_サンプル商事_トライアル打合せ.mp4
```

- 会議ファイルの場所は `autonote list --json` の `filePath` か、`autonote latest` で分かる
- `--recording` は受け取り箱に置かれた録画のファイル名（`日付_時刻_相手先_用件.mp4`）。渡すと、相手先を名前から読み、知らせに「録画を 7 日以内に消す」期日が入る
- 終了コード: 0 成功、1 失敗（push できない・ぶつかった・ファイルが無い）、2 使い方の誤り

### 5. 見回りを入れる（LaunchAgent）

```sh
SHARE_HOME="$HOME/Library/Application Support/AutoNoteShare"
LABEL="local.share-to-repo.daily-patrol"
mkdir -p "$SHARE_HOME/logs"
sed -e "s|__LABEL__|$LABEL|g" -e "s|__SHARE_HOME__|$SHARE_HOME|g" \
  "$SHARE_HOME/bin/launchd/example.share-to-repo.daily-patrol.plist" > "$HOME/Library/LaunchAgents/$LABEL.plist"
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/$LABEL.plist"
launchctl kickstart "gui/$(id -u)/$LABEL"     # 1 回すぐに走らせて確かめる
```

外すとき:

```sh
launchctl bootout "gui/$(id -u)/$LABEL"
mv "$HOME/Library/LaunchAgents/$LABEL.plist" ~/.Trash/
```

launchd の下から書類フォルダ（`~/Documents`）は読めないことがあります。macOS 26 で試したときは、許可のダイアログは出ずに `Operation not permitted` で黙って拒まれました（git の fetch は通った）。このとき見回りは `state/todo.md` に「会議ファイルのフォルダ（VAULT_ROOT）を読めません」と書き、ほかの手順（送り直し・写しの作り直し）は続けて、終了コード 1 で終わります。初回の実行の後に `todo.md` と `logs/launchd-patrol.out.log` を見てください。読めるようにする方法の例:

- AutoNote の出力フォルダを書類フォルダの外（例 `~/AutoNote`）に変え、`VAULT_ROOT` もそこに向ける
- システム設定 › プライバシーとセキュリティ › フルディスクアクセス で、見回りを動かすプログラム（`/bin/sh` と `python3`）に許可を与える（許す範囲が広いので、選ぶ前によく考える）
- 見回りの載せ直し（手順 2）は使わず、手で `share-meeting.sh` を打つ

## 見回り（`daily-patrol.sh`）

1 日 1 回、次を順に行います。議事録と文字起こしを期限で消す処理はありません。

1. 送れなかった知らせと、push できなかった分（`state/pending.tsv`）を送り直す
2. 載せた会議の AutoNote 側のファイルが変わっていれば載せ直す（AutoNote の画面での編集と、後から書かれる訳文は Automation を出さないため）。題が変わってファイル名が変わっても、`autonote_id` で探す
3. 録画の知らせ
   - `INBOX_DIR`（受け取り箱の同期フォルダ）があるとき: 置いてから（共有した会議は最初に共有した日から）7 日を超えた録画を知らせ、21 日を超えたらオーナーにも知らせて `state/todo.md` に書く。受け取り箱から消えた録画の会議は、置き場の議事録を `source_recording_deleted: はい` に直して push する
   - `INBOX_DIR` が無いとき: 共有から 7 日たった会議ごとに「録画は消しましたか」を 1 回だけ出す
4. `AUTONOTE_CLI` があれば、AutoNote から消えた共有の会議を知らせる（自動では消さない。取り下げるなら `--unshare`）
5. 読む人向けの写しのうち、足りないもの・古いものを作り直す

## 失敗したとき

| 場面 | 振る舞い |
|---|---|
| push できない（ネットワーク・認証・障害） | commit は clone に残し、1 で終わって `state/pending.tsv` に入れる。次の `--retry-pending` か見回りが送り直す |
| 置き場の同じ所が GitHub の画面などで直されていた | 何も書かずに止まり（その回の commit は取り消す）、`state/todo.md` と知らせに「GitHub 側で直されています」。中身を AutoNote に反映してから載せ直す |
| 同じ名前で別の会議 | AutoNote と同じく `-2` `-3` を付ける |
| 題が変わった | 古い 2 本を消して新しい名前で置く。`kind`・相手先・最初に共有した日は引き継ぐ |
| 知らせを送れない | 共有は成功（0）のまま。`state/outbox/` に置いて次の実行で送り直す。3 日送れなければ `todo.md` |
| 文字起こしの章が無い | 議事録だけを置き、`transcript_file: なし` |
| clone に人が触った跡（未コミットの変更）がある | 何もせず 1 で終わり、`todo.md` に書く |

状態はすべて `state/` にあります。`shared.tsv`（載せた会議 1 件に 1 行。見出しの列名は変えない）、`pending.tsv`、`inbox-seen.tsv`、`todo.md`、`outbox/`。書き込みは `state/lock`（mkdir で取るロック。最長 120 秒待つ）を通すので、同時に 2 本走っても壊れません。ログは `logs/share-YYYY-MM.log` などに 1 行ずつ（会議の中身は書かない）。

## 読む人が git を使わない場合（読む人向けの写し）

置き場は持ち主と Claude 用の裏の保管として残し、読む人には同期フォルダ（例: Google ドライブのデスクトップ版が同期するフォルダ）に整形した文書を写せます。`config.env` に `MIRROR_DIR` を書くと、共有のたびに（push の成否とは別に）次を作り直します。

```
<MIRROR_DIR>/
├── はじめに.docx           ← 読み方の案内（templates/mirror-readme.md）
├── 会議の一覧.docx         ← INDEX.md と同じ中身。リンクの代わりにファイルの名前を書く
├── 議事録/2026/<名前>.docx
└── 文字起こし/2026/<名前>_文字起こし.docx
```

- 中身は置き場の 2 本と同じ文です。frontmatter の代わりに、先頭に「日時・相手先」の 1 行を置きます
- 形式は `MIRROR_FORMAT` で `docx`（既定）・`md`・`docx,md`。docx は macOS 標準の `/usr/bin/textutil` で作ります（`DOCX_CMD` で別のコマンドに差し替えられる。引数は `<入力の HTML> <出力の docx>`）
- textutil の docx は表を持てないため、表は 1 行ずつ「見出し: 値 ／ 見出し: 値」の段落にして書きます。箇条書きも字下げした段落になります
- 写しは state の下の作業フォルダで作ってから置き換えるので、同期フォルダに書きかけのファイルは置きません。写したファイルは `state/mirror-files.tsv` に記録し、消すのはそこにあるものだけです（読む人が置いたファイルは残る）
- 写しを作れなくても共有は成功（0）のままで、`todo.md` に 1 行書き、次の見回りで作り直します
- 知らせのリンクは `MIRROR_WEB_URL`（写しのフォルダの URL）があればそれを使い、読む人に GitHub の URL を見せません

読む人には「はじめに」を読んでもらい、その人の Claude には同期フォルダをつないで「はじめに を読んでから、会議の一覧 → 議事録 → 文字起こし の順に読んで」と頼んでもらいます。

## テスト

```sh
examples/automations/share-to-repo/tests/run-tests.sh        # -v で 1 件ずつ表示
```

一時フォルダの中だけで動きます（push 先は `git init --bare` の一時リポジトリ、知らせは `dry-run` か偽物のコマンド、Slack はローカルの偽のサーバー）。本物の GitHub・Slack・`autonote`・`osascript`・`op` は呼ばず、AutoNote のデータ領域と出力フォルダにも触りません。フィクスチャの会議はすべて作り物です。macOS では textutil で docx を 1 件だけ実際に作るテストも走ります。
