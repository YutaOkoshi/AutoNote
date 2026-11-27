# share-to-repo — 会議の記録を共有のリポジトリに載せる見本

AutoNote が書き出した会議ファイル（1 会議 1 Markdown）を「議事録」と「文字起こし」の 2 本に分け、会議の記録を置く別の git リポジトリ（以下「置き場」）に commit / push し、一覧 `INDEX.md` を作り直すスクリプト一式です。毎日の見回り（載せ直し・録画の消し忘れの知らせ）と、git を使わない人のための「読む人向けの写し」（docx）も作れます。

AutoNote の外に置く汎用の見本です。AutoNote 本体はこのフォルダを使いません。自分の Mac に写して、設定を埋めて使います。

- 言語は python3 の標準ライブラリだけ（macOS の `/usr/bin/python3` で動く）。入口は薄いシェル `share-meeting.sh` と `daily-patrol.sh`
- AutoNote の会議ファイルは読むだけで、書き換えも削除もしない。`git push --force` もしない
- 音声・録画は扱わない。置き場に載るのは文字だけ

この文書での呼び方: **持ち主**はスクリプトを動かす Mac の人、**録画した人**は会議を録画して受け取り箱に置く人、**読む人**は置き場や写しで議事録を読む人、**受け取り箱**は録画を置いてもらう共有フォルダです。

## できること

| コマンド | すること |
|---|---|
| `share-meeting.sh <会議ファイル> [--kind internal\|customer] [--customer <相手先>] [--recording <録画のファイル名>]` | 1 件を載せる（載せ直しも同じ）。`--kind` の既定は `internal`。前に載せた会議は、指定しなかった項目を前の値から引き継ぐ |
| `share-meeting.sh --unshare <autonote_id>` | 置き場から 2 本を消して push する（git の履歴には残る）。読む人向けの写しからも消える。`autonote_id` の調べ方は下 |
| `share-meeting.sh --retry-pending` | push できなかった分を送り直す |
| `share-meeting.sh --rebuild-index` | `INDEX.md` を作り直す |
| `share-meeting.sh --rebuild-mirror` | 読む人向けの写しを全部作り直す |
| `share-meeting.sh --print-template <雛形の名前>` | `templates/` の雛形に設定の値（録画を消すまでの日数・録画の形式）を差し込んで標準出力に出す。名前は `README.md`・`CLAUDE.md`・`mirror-readme.md` |
| `daily-patrol.sh` | 毎日の見回り（下の「見回り」） |

`autonote_id` は会議 1 件ごとの番号です。置き場の議事録の先頭（frontmatter）の `autonote_id:` の行に書いてあります。`autonote list --json` の `id` と、`state/shared.tsv` の 1 列目も同じ値です（`INDEX.md` と「会議の一覧」には出ません）。

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

## 前提

導入の前に、次の 4 つを確かめます。

1. **このフォルダが手元にある** — AutoNote を Release の zip で入れただけの Mac には `examples/` がありません。AutoNote のリポジトリを取ってきます（`git clone <AutoNote のリポジトリの URL>`、または GitHub のリポジトリのページの Code › Download ZIP）。以下のコマンドは、取ってきたリポジトリのルートで打ちます
2. **Command Line Tools が入っている** — `git` と `/usr/bin/python3` は Command Line Tools のものを使います。`xcode-select -p` がパスを返さなければ、`xcode-select --install` で入れてから進みます
3. **置き場の clone に git の名前とメールがある** — commit に要ります。無いとスクリプトは設定のコマンドを示して止まります。手順 1 で設定します
4. **置き場への push が、パスワードなどを聞かれずに通る** — スクリプトは git に何も聞かせない設定（`GIT_TERMINAL_PROMPT=0`）で動かすので、聞かれる状態だと push は失敗します。手順 3 で確かめます

## 導入の手順

以下は `~/Library/Application Support/AutoNoteShare/` に置く例です（「AutoNoteShare」と書きます）。

### 1. 置き場を用意して clone する

1. GitHub などに非公開のリポジトリを作り、読む人だけを招く
2. スクリプト専用の clone を作る（導入が済んだら、人はこの clone を触らない）
   ```sh
   mkdir -p "$HOME/Library/Application Support/AutoNoteShare"
   git clone <置き場の URL> "$HOME/Library/Application Support/AutoNoteShare/repo"
   ```
3. その clone に、commit に使う名前とメールを設定する（すでに `git config --global` で設定してあれば要らない）
   ```sh
   git -C "$HOME/Library/Application Support/AutoNoteShare/repo" config user.name "<名前>"
   git -C "$HOME/Library/Application Support/AutoNoteShare/repo" config user.email "<メール>"
   ```

スクリプトの commit は、git のフック（`core.hooksPath`）と署名（`commit.gpgsign`）を使わずに行います。自分の作業用に入れたフックや署名の設定で、スクリプトの commit が途中で失敗しないようにするためです。

### 2. スクリプトと設定を置く

```sh
cp -R examples/automations/share-to-repo "$HOME/Library/Application Support/AutoNoteShare/bin"
cp "$HOME/Library/Application Support/AutoNoteShare/bin/config.env.example" \
   "$HOME/Library/Application Support/AutoNoteShare/config.env"
chmod 600 "$HOME/Library/Application Support/AutoNoteShare/config.env"
```

この `cp -R` は最初の 1 回だけです。2 回目からは下の「更新するとき」の手順を使います。

`config.env` を開いて値を埋めます。項目の説明は `config.env.example` にあります。よく変えるもの:

- `VAULT_ROOT` — AutoNote の出力フォルダ（既定 `~/Documents/AutoNote`）
- `REPO_WEB_URL` — 知らせに入れるリンクの元（例 `https://github.com/<owner>/<repo>`）
- `RECORDING_KEEP_DAYS` — 録画を消すまでの日数（既定 7）。知らせの期日と、雛形の案内文の日数に入る
- `NOTIFY_MODE` — 知らせ（「議事録が並びました」「録画を消してください」など）の出し方。**誰に届くかが変わります**
  - `macos`（既定）— この Mac の通知と `state/notices.md` に出る。見られるのは持ち主だけで、録画した人・読む人には届かない。この設定のまま使うなら、「議事録が並んだこと」と「録画を消す期日」は持ち主が自分で伝える
  - `slack` — Incoming Webhook の先のチャンネルに出る。録画した人・読む人に届けるなら、その人たちをチャンネルに入れておく
  - `dry-run` — 送らずに `state/outbox-dry/` に書くだけ（試すとき用）
  - 手を打つ必要があること（置き場の直しとぶつかった・長く残っている録画がある・clone に人が触った跡がある、など）は、どの設定でも `state/todo.md` にも書く。`todo.md` は要対応だけ、`notices.md` はただのお知らせ、と分かれている
- Slack の Webhook の URL は秘密です。`config.env` に直接書かず、1Password に置いて `SLACK_WEBHOOK_OP_REF="op://<保管庫>/<項目>/<欄>"` で指します。スクリプトは 1 回の実行につき 1 度だけ `op read` で取り出し、メモリにだけ持ちます（ログや状態ファイルには書かない）
  - 1Password のアプリと連携した `op` は、取り出すときに承認（Touch ID など）を求めます。手で `share-meeting.sh` を打つときは、その場で承認できます
  - launchd の見回り（毎朝）は無人で走るので、その時刻に承認できなければ `op read` は失敗し、知らせは `state/outbox/` に残って次の実行で送り直されます。見回りから Slack に出したいなら、その時刻に 1Password を解錠しておくか、1Password のサービスアカウントで `op` を使えるようにしておきます

### 3. 雛形を置き場に置き、push を確かめる

置き場の README（読む人と Claude への案内）と CLAUDE.md を、雛形から作ります。`--print-template` は、手順 2 の設定の値（録画を消すまでの日数など）を差し込んだ文を出します。

```sh
SHARE_HOME="$HOME/Library/Application Support/AutoNoteShare"
"$SHARE_HOME/bin/share-meeting.sh" --print-template README.md > "$SHARE_HOME/repo/README.md"
"$SHARE_HOME/bin/share-meeting.sh" --print-template CLAUDE.md > "$SHARE_HOME/repo/CLAUDE.md"
```

1. できた `repo/README.md` を開き、中身（読む人・録画の置き方・知らせの届き方・決まり）を自分の運用に合わせて直す
2. commit し、push がパスワードなどを聞かれずに通るかを `--dry-run`（実際には送らない）で確かめてから push する
   ```sh
   git -C "$SHARE_HOME/repo" add README.md CLAUDE.md
   git -C "$SHARE_HOME/repo" commit -m "docs: add README and CLAUDE.md"
   git -C "$SHARE_HOME/repo" push --dry-run     # 何も聞かれずに終わること
   git -C "$SHARE_HOME/repo" push
   ```
   `--dry-run` は commit が 1 つも無い空の clone では「送るものが無い」というエラーになるので、commit の後に打ちます。ここでパスワードや鍵の確認が出るなら、出ないように git の認証を設定してから先へ進みます（launchd から動かすときは、確認が出ると push できない）
3. 読む人向けの写し（下の「読む人が git を使わない場合」）を使うなら、写しの「はじめに」の元になる `bin/templates/mirror-readme.md` も同じように直す。文中の `{{keep_days}}`・`{{exts}}` は消さずに残す（写しを作るときに設定の値が入る）。直した文は、次の共有・見回り・`--rebuild-mirror` のどれかで「はじめに」に入る

`INDEX.md` は最初の共有のときにスクリプトが作ります（`templates/INDEX.md` の `{{rows}}` に表が入る）。

`RECORDING_KEEP_DAYS` を後から変えたときは、置き場の `README.md` の日数を手で直します（置き場の README は最初に作ったきりで、スクリプトは書き換えません。写しの「はじめに」は自動で変わります）。

### 4. 1 件を載せる

```sh
"$HOME/Library/Application Support/AutoNoteShare/bin/share-meeting.sh" \
  "$HOME/Documents/AutoNote/2026/2026-12-02_1000_サンプル商事 トライアル打合せ.md" \
  --kind customer --customer サンプル商事 --recording 2026-12-02_1000_サンプル商事_トライアル打合せ.mp4
```

- 会議ファイルの場所は `autonote list --json` の `filePath` か、`autonote latest` で分かる
- `--recording` は、受け取り箱に置かれた録画の**ファイル名だけ**を渡す（`日付_時刻_相手先_用件.mp4`）。Finder からドラッグしてフルパスが入っても、スクリプトは最後のファイル名だけを使う。渡すと、相手先を名前から読み、知らせに録画を消す期日（最初に共有した日から 7 日後）が入る
- `INBOX_DIR`（受け取り箱のフォルダ）を設定していて、その名前の録画が受け取り箱に無いときは、警告を出して共有は続ける。名前の打ち間違いなら `--recording` を直して載せ直す。同期が遅れているだけなら、そのままでよい
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

#### launchd から会議ファイルのフォルダを読めないとき

`launchctl kickstart` で 1 回走らせた後に、`state/todo.md` と `logs/launchd-patrol.out.log` を見てください。`todo.md` に「会議ファイルのフォルダ（VAULT_ROOT）を読めません」の行があれば、macOS が launchd の下のプログラムに、そのフォルダを読ませていません。

macOS 26 で、`VAULT_ROOT` が書類フォルダ（`~/Documents`）の中にある設定で試したときに分かったこと:

- 許可を求める画面は出ない。フォルダの読み取りが `Operation not permitted` で拒まれるだけなので、ログを見ないと気づけない
- 同じ実行の中で、置き場への git の fetch は通った。拒まれたのは会議ファイルのフォルダだけ
- 同じ Mac で、ターミナルから手で打った `share-meeting.sh` は同じフォルダを読めた

このとき見回りは止まりません。`todo.md` に上の 1 行を書き（同じ文は重ねて書かない）、知らせを 1 通出し、会議ファイルを読む手順（下の「見回り」の 2 の載せ直しと、1 のうち会議を作り直す分）を飛ばして、ほかの手順（clone に残っていた commit の push・録画の知らせ・写しの作り直し）を続け、終了コード 1 で終わります。

直し方は次のどれかです。この見本で確かめたのは上の振る舞いまでで、それぞれの直し方を実際に試してはいません。

- AutoNote の出力フォルダを書類フォルダの外（例 `~/AutoNote`）に変え、`VAULT_ROOT` もそこに向ける
- システム設定 › プライバシーとセキュリティ › フルディスクアクセス で、見回りを動かすプログラムに許可を与える。LaunchAgent が呼ぶのは `/bin/sh` で、そこから `python3` が動くが、どの実行ファイルに与えれば足りるかは確かめていない。フルディスクアクセスは許す範囲が広いので、選ぶ前によく考える
- 見回りの載せ直しは当てにせず、AutoNote の側で議事録を直した後は、手で `share-meeting.sh` を打って載せ直す

直した後は、もう一度 `launchctl kickstart "gui/$(id -u)/$LABEL"` を打ち、`logs/launchd-patrol.out.log` に「読めません」が新しく出ていないことを確かめます。

## 更新するとき

AutoNote のリポジトリを新しくした後、スクリプトを入れ直す手順です。リポジトリのルートで打ちます。

```sh
rsync -a --exclude templates/ --exclude __pycache__/ examples/automations/share-to-repo/ \
  "$HOME/Library/Application Support/AutoNoteShare/bin/"
```

- 手順 2 の `cp -R` をもう一度打ってはいけません。すでにある `bin` に対して打つと、`bin/share-to-repo/` という入れ子の中に写り、launchd が呼ぶ `bin/daily-patrol.sh` は古い版のまま動き続けます
- `templates/` を除いているのは、手順 3 で直した雛形（`mirror-readme.md` など）を上書きしないためです。見本の雛形が変わったときは、`diff -r examples/automations/share-to-repo/templates "$HOME/Library/Application Support/AutoNoteShare/bin/templates"` で見比べ、要る所を手で取り込みます
- 直した雛形は、`bin` の外にも自分の写しを持っておくと安全です（`bin` を作り直しても戻せる）
- `config.env`・`state/`・`logs/`・`repo/` は `bin` の外にあるので、この手順では変わりません。新しい設定の項目は `config.env.example` を見て、要るものだけ `config.env` に足します

## 見回り（`daily-patrol.sh`）

1 日 1 回、次を順に行います。議事録と文字起こしを期限で消す処理はありません。1 つの手順が失敗しても残りの手順は走り、どれかが失敗していれば終了コード 1 で終わります。

1. 送れなかった知らせと、push できなかった分（`state/pending.tsv`）を送り直す
2. 載せた会議の AutoNote 側のファイルが変わっていれば載せ直す（AutoNote の画面での編集と、後から書かれる訳文は Automation を出さないため）。題が変わってファイル名が変わっても、`autonote_id` で探す
3. 録画の知らせ（日数は `RECORDING_KEEP_DAYS`＝既定 7、`RECORDING_OWNER_DAYS`＝既定 21。ちょうどその日数がたった日に出す）
   - `INBOX_DIR`（受け取り箱の同期フォルダ）があるとき:
     - 受け取り箱に残っている録画を、共有した会議の録画は最初に共有した日から、まだ共有していない録画は見回りが最初に見つけた日から数える。7 日たったら「録画を消してください」を 1 回、21 日たったら持ち主あての知らせを 1 回出して `state/todo.md` にも書く
     - 録画として数えるのは、受け取り箱の直下にある mp4・m4a・mov・wav・mp3 だけ。ほかのファイルとサブフォルダは見ない。受け取り箱には録画だけを置く
     - 見回りが一度でも受け取り箱で見た録画が、後の見回りで無くなっていたら「消した」とみなし、その会議の置き場の議事録を `source_recording_deleted: はい` に直して push する
     - `--recording` で渡した名前の録画が、受け取り箱で一度も見えていないときは「消した」にはせず、「受け取り箱に見当たらない録画があります」を 1 回だけ知らせる（名前の打ち間違いか、同期の遅れ）
     - 受け取り箱に録画が 1 つも無い日は、「消した」「見当たらない」の判定をしない（同期が止まってフォルダが空に見えるだけの日に、全部を「消した」にしないため）。そのため、受け取り箱の最後の 1 つを消した日には `はい` にならず、次に別の録画が置かれた後の見回りで `はい` になる
   - `INBOX_DIR` が無いとき: `--recording` を渡して共有した会議ごとに、共有から 7 日たった日に「録画は消しましたか」を 1 回だけ出す
4. `AUTONOTE_CLI` があれば、AutoNote から消えた共有の会議を知らせる（自動では消さない。取り下げるなら `--unshare`）
5. 読む人向けの写しのうち、足りないもの・古いものを作り直す

## 失敗したとき

| 場面 | 振る舞い |
|---|---|
| push できない（ネットワーク・認証・障害） | commit は clone に残し、1 で終わって `state/pending.tsv` に入れる。次の `--retry-pending` か見回りが送り直す |
| 置き場の同じ所が GitHub の画面などで直されていた（ぶつかった） | まだ push していない commit をすべて捨て、clone を置き場と同じ中身に戻して、1 で終わる。`state/todo.md` と知らせに「GitHub 側で直されています: <ファイル>」と出す（同じ衝突の知らせは、1 回の実行で 1 通だけ）。ぶつかった会議は `state/pending.tsv` に入り、次の送り直しが AutoNote の中身から作り直して載せるので、**GitHub 側の直しは上書きされる**。push できずに残っていた commit の送り直しでぶつかったときは、同じ実行のうちに載せ直すところまで進む。残したい直しは、置き場の git の履歴から拾って AutoNote の会議ファイルに反映する（履歴は消えない）。ほかの会議の共有は止まらない |
| ほかの実行がロックを持っている（写しの作り直しが長引いている、など） | 共有と取り下げは 120 秒待ち、取れなければ 1 で終わって `state/pending.tsv` に入れる。次の `--retry-pending` か見回りが送り直す |
| clone に git の名前かメールが無い | 設定のコマンドを示して 1 で終わり、`todo.md` に書いて `state/pending.tsv` に入れる。設定してから `--retry-pending` |
| git のコマンドが途中で失敗した | その回に clone に書いたものを元に戻し、1 で終わって `state/pending.tsv` に入れる |
| 同じ名前で別の会議 | AutoNote と同じく `-2` `-3` を付ける |
| 題が変わった | 古い 2 本を消して新しい名前で置く。`kind`・相手先・最初に共有した日は引き継ぐ |
| 知らせを送れない | 共有は成功（0）のまま。`state/outbox/` に置いて次の実行で送り直す。3 日送れなければ `todo.md` |
| 文字起こしの章が無い | 議事録だけを置き、`transcript_file: なし` |
| clone に人が触った跡（未コミットの変更）がある | 何もせず 1 で終わり、`todo.md` に書く |
| 見回りが会議ファイルのフォルダを読めない | `todo.md` と知らせに出し、載せ直しだけ飛ばして続ける（上の「launchd から会議ファイルのフォルダを読めないとき」） |

状態はすべて `state/` にあります。`shared.tsv`（載せた会議 1 件に 1 行。見出しの列名は変えない）、`pending.tsv`、`inbox-seen.tsv`（見回りが受け取り箱で見た録画）、`mirror-files.tsv`（写したファイル）、`todo.md`（要対応）、`notices.md`（`NOTIFY_MODE=macos` のときのお知らせ）、`outbox/`。書き込みは `state/lock`（mkdir で取るロック。最長 120 秒待つ）を通すので、同時に 2 本走っても状態は壊れません。待っても取れなかった共有は、上の表のとおり後で送り直されます。ログは `logs/share-YYYY-MM.log` などに 1 行ずつ（会議の中身は書かない）。

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
- 「はじめに」は `bin/templates/mirror-readme.md` から作ります。読む人に配る前に、自分の運用に合わせて直してください（導入の手順 3）
- 形式は `MIRROR_FORMAT` で `docx`（既定）・`md`・`docx,md`。docx は macOS 標準の `/usr/bin/textutil` で作ります（`DOCX_CMD` で別のコマンドに差し替えられる。引数は `<入力の HTML> <出力の docx>`）
- textutil の docx は表を持てないため、表は 1 行ずつ「見出し: 値 ／ 見出し: 値」の段落にして書きます。箇条書きも字下げした段落になります
- 写しは state の下の作業フォルダで作ってから置き換えるので、同期フォルダに書きかけのファイルは置きません。写したファイルは `state/mirror-files.tsv` に記録し、消すのはそこにあるものだけです（読む人が置いたファイルは残る）
- `--unshare` で取り下げた会議は、写しからも消えます
- 写しを作れなくても共有は成功（0）のままで、`todo.md` に 1 行書き、次の見回りで作り直します
- 知らせのリンクは `MIRROR_WEB_URL`（写しのフォルダの URL）があればそれを使い、読む人に GitHub の URL を見せません

読む人には「はじめに」を読んでもらい、その人の Claude には同期フォルダをつないで「はじめに を読んでから、会議の一覧 → 議事録 → 文字起こし の順に読んで」と頼んでもらいます。

## テスト

```sh
examples/automations/share-to-repo/tests/run-tests.sh        # -v で 1 件ずつ表示
```

一時フォルダの中だけで動きます（push 先は `git init --bare` の一時リポジトリ、知らせは `dry-run` か偽物のコマンド、Slack はローカルの偽のサーバー）。本物の GitHub・Slack・`autonote`・`osascript`・`op` は呼ばず、AutoNote のデータ領域と出力フォルダにも触りません。フィクスチャの会議はすべて作り物です。macOS では textutil で docx を 1 件だけ実際に作るテストも走ります。
