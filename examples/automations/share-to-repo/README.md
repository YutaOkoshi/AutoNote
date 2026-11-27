# share-to-repo — 会議の記録を共有のリポジトリに載せる見本

AutoNote が書き出した会議ファイル（1 会議 1 Markdown）を「議事録」と「文字起こし」の 2 本に分け、会議の記録を置く別の git リポジトリ（以下「置き場」）に commit / push し、一覧 `INDEX.md` を作り直すスクリプト一式です。毎日の見回り（載せ直し・録画の消し忘れの知らせ）と、git を使わない人のための「読む人向けの写し」（docx）も作れます。

AutoNote の外に置く汎用の見本です。AutoNote 本体はこのフォルダを使いません。自分の Mac に写して、設定を埋めて使います。

**この版は、載せたい会議を 1 件ずつ手で `share-meeting.sh` に渡します。** AutoNote の Automation（会議ができたら自動で走るコマンド）から載せる入口は、まだありません。`share-meeting.sh` をそのまま Automation に登録すると、載せたくない会議も含めて全部が `internal` として置き場に載るので、登録しないでください。自動で動くのは、一度載せた会議の載せ直しと録画の知らせを行う毎日の見回りだけです。

- 言語は python3 の標準ライブラリだけ（macOS の `/usr/bin/python3` で動く）。入口は薄いシェル `share-meeting.sh` と `daily-patrol.sh`
- AutoNote の会議ファイルは読むだけで、書き換えも削除もしない。`git push --force` もしない
- 音声・録画は扱わない。置き場に載るのは文字だけ

この文書での呼び方: **持ち主**はスクリプトを動かす Mac の人、**録画した人**は会議を録画して受け取り箱に置く人、**読む人**は置き場や写しで議事録を読む人、**受け取り箱**は録画を置いてもらう共有フォルダです。

## できること

| コマンド | すること |
|---|---|
| `share-meeting.sh <会議ファイル> [--kind internal\|customer] [--customer <相手先>] [--recording <録画のファイル名>] [--recorded-by <録った人の呼び名>]` | 1 件を載せる（載せ直しも同じ）。`--kind` の既定は `internal`（顧客の会議は必ず `--kind customer` を付ける）。前に載せた会議は、指定しなかった項目を前の値から引き継ぐ |
| `share-meeting.sh --unshare <autonote_id>` | 置き場から 2 本を消して push する（git の履歴には残る）。読む人向けの写しからも消える。`autonote_id` の調べ方は下 |
| `share-meeting.sh --recording-deleted <autonote_id>` | その会議の録画を消したことを記録し、置き場の議事録を `source_recording_deleted: はい` にして push する。受け取り箱のフォルダを見回りに見せていない運用（`INBOX_DIR` なし）では、これが `はい` にする唯一の入口。`INBOX_DIR` がある運用でも、見回りを待たずに `はい` にしたいときに使える |
| `share-meeting.sh --recording-deleted <autonote_id> --undo` | 間違って `はい` になったものを `まだ` に戻して push する |
| `share-meeting.sh --retry-pending` | push できなかった分を送り直す |
| `share-meeting.sh --rebuild-index` | `INDEX.md` を作り直す |
| `share-meeting.sh --rebuild-mirror` | 読む人向けの写しを全部作り直す |
| `share-meeting.sh --print-template <雛形の名前>` | `templates/` の雛形に設定の値（録画を消すまでの日数・録画の形式）を差し込んで標準出力に出す。名前は `README.md`・`CLAUDE.md`・`mirror-readme.md` |
| `daily-patrol.sh` | 毎日の見回り（下の「見回り」） |

`autonote_id` は会議 1 件ごとの番号です。置き場の議事録の先頭（frontmatter）の `autonote_id:` の行に書いてあります。`autonote list --json` の `id` と、`state/shared.tsv` の 1 列目も同じ値です（`INDEX.md` と「会議の一覧」には出ません）。共有したときの出力「共有しました: <ファイル>（autonote_id: …）」にも出ます。載せた会議の番号とファイルの一覧は、`cut -f1,2 "$HOME/Library/Application Support/AutoNoteShare/state/shared.tsv"` で見られます。

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

- 議事録に入るのは、AutoNote のファイルの `# 題` から、`internal` の会議は `## ブックマーク` の節の終わりまで、`customer` の会議はその手前まで（ブックマークに付けたメモを顧客の記録に出さないため）。どちらも、末尾に議事録の訳文があれば付く
- 置き場のファイル名は、AutoNote の会議ファイルと同じ名前（Unicode の形は NFC にそろえる。Mac のディスク上では濁点が分かれた形になっていても、git と一覧のリンクは同じ形になる）
- 議事録の中の発言リンク `[[#^t00-07-08|07:09]]` は `（→ 00:07:08）` という時刻の文字に置き換える。文字起こしの `[00:07:08]` の行に当たる
- frontmatter には AutoNote の項目に加えて `kind`・`customer`・`recorded_by`・`transcript_file`・`source_recording_deleted` が入る
- `recorded_by`（録った人）は、`customer` の会議には設定の `DEFAULT_RECORDED_BY`、`internal` の会議には `OWNER_NAME` が入る。合わない会議（録画した人が録った社内の会議、持ち主が自分で録った顧客の会議）は `--recorded-by <呼び名>` で渡す。一度渡した呼び名は、その会議の載せ直しでも引き継ぐ

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

`config.env` を開いて値を埋めます。項目の説明は `config.env.example` にあります。`config.env` が見つからないとき、スクリプトは「警告: 設定ファイルがありません: <探した場所>」と 1 行出して既定値で動きます（置き場所や `SHARE_CONFIG` の間違いに気づけるように）。日数などの数字の項目に数字でないものを書くと、どの項目かを示して終了コード 2 で終わります。よく変えるもの:

- `VAULT_ROOT` — AutoNote の出力フォルダ（既定 `~/Documents/AutoNote`）
- `SHARE_BRANCH` — 置き場のブランチ名（既定 `main`）。置き場の既定のブランチが `master` などのときは合わせる（`git -C "$HOME/Library/Application Support/AutoNoteShare/repo" branch --show-current` で分かる）。違っていると、共有は「置き場にブランチ … がありません」と出して止まる
- `REPO_WEB_URL` — 知らせに入れるリンクの元（例 `https://github.com/<owner>/<repo>`）
- `RECORDING_KEEP_DAYS` — 録画を消すまでの日数（既定 7）。知らせの期日と、雛形の案内文の日数に入る
- `NOTIFY_MODE` — 知らせ（「議事録が並びました」「録画を消してください」など）の出し方。**誰に届くかが変わります**
  - `macos`（既定）— この Mac の通知と `state/notices.md` に出る。見られるのは持ち主だけで、録画した人・読む人には届かない。この設定のまま使うなら、「議事録が並んだこと」と「録画を消す期日」は持ち主が自分で伝える
  - `slack` — Incoming Webhook の先のチャンネルに出る。録画した人・読む人に届けるなら、その人たちをチャンネルに入れておく。宛先を分ける設定は無いので、持ち主あての知らせと見回りの失敗の知らせも同じチャンネルに出る。知らせに入るのは会議の題・日時・録画のファイル名で（発言の中身は入らない）、失敗の知らせには Mac のフォルダのパスやファイル名が入ることがある。題に顧客名を入れている会議では、顧客名がチャンネルに出る
  - `dry-run` — 送らずに `state/outbox-dry/` に書くだけ（試すとき用）
  - 手を打つ必要があること（置き場の直しとぶつかった・長く残っている録画がある・clone に人が触った跡がある、など）は、どの設定でも `state/todo.md` にも書く。`todo.md` は要対応だけ、`notices.md` はただのお知らせ、と分かれている
- Slack の Webhook の URL は秘密です。`config.env` に直接書かず、1Password に置いて `SLACK_WEBHOOK_OP_REF="op://<保管庫>/<項目>/<欄>"` で指します。スクリプトは 1 回の実行につき 1 度だけ `op read` で取り出し、メモリにだけ持ちます（ログや状態ファイルには書かない）
  - 1Password のアプリと連携した `op` は、取り出すときに承認（Touch ID など）を求めます。手で `share-meeting.sh` を打つときは、その場で承認できます
  - **launchd の見回りから使うなら、`config.env` の `OP_CMD` に `op` の絶対パスを書きます**（ターミナルで `command -v op` と打った結果。例 `/opt/homebrew/bin/op`）。launchd がプログラムに渡す PATH は `/usr/bin:/bin:/usr/sbin:/sbin` で、Homebrew のフォルダが入っていないため、名前だけの `op` は見つかりません。見つからないと「op が見つかりません」と出て、知らせは `state/outbox/` に残ります
  - 見回りは無人で走るので、その時刻に承認できなければ `op read` は失敗し、知らせは `state/outbox/` に残って次の実行で送り直されます。見回りから Slack に確実に出すには、次のどちらかが要ります（どちらも、この見本では実際の launchd の下で試していません）
    - その時刻に Mac と 1Password を解錠しておく
    - 1Password のサービスアカウントを使う。トークン（`OP_SERVICE_ACCOUNT_TOKEN`）は、見回りのプロセスの環境変数として渡す必要があります（`config.env` に書いても `op` には渡りません）。launchd では LaunchAgent の plist の `EnvironmentVariables` に書くことになり、秘密を plist に平文で置く形になります。そうするなら、plist を `chmod 600` にし、サービスアカウントが読める項目を Webhook の 1 つに絞ります
  - どの形でも、手順 5 で見回りを 1 回走らせた後に `logs/notify-YYYY-MM.log` を見て、`kept-in-outbox` の行が出ていないことを確かめます

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
   置き場が空（作ったばかり）なら、この push が置き場の最初の commit になります。飛ばして手順 4 に進むと、共有は「置き場が空です」と出して止まります。`--dry-run` は commit が 1 つも無い空の clone では「送るものが無い」というエラーになるので、commit の後に打ちます。ここでパスワードや鍵の確認が出るなら、出ないように git の認証を設定してから先へ進みます（launchd から動かすときは、確認が出ると push できない）
3. 読む人向けの写し（下の「読む人が git を使わない場合」）を使うなら、写しの「はじめに」の元になる `bin/templates/mirror-readme.md` も同じように直す。文中の `{{keep_days}}`・`{{exts}}` は消さずに残す（写しを作るときに設定の値が入る）。直した文は、次の共有・見回り・`--rebuild-mirror` のどれかで「はじめに」に入る

`INDEX.md` は最初の共有のときにスクリプトが作ります（`templates/INDEX.md` の `{{rows}}` に表が入る）。

`RECORDING_KEEP_DAYS` を後から変えたときは、置き場の `README.md` の日数を手で直します（置き場の README は最初に作ったきりで、スクリプトは書き換えません。写しの「はじめに」は自動で変わります）。

### 4. 1 件を載せる

```sh
"$HOME/Library/Application Support/AutoNoteShare/bin/share-meeting.sh" \
  "$HOME/Documents/AutoNote/2026/2026-12-02_1000_サンプル商事 トライアル打合せ.md" \
  --kind customer --customer サンプル商事 --recording 2026-12-02_1000_サンプル商事_トライアル打合せ.mp4
```

- 会議ファイルの場所は `autonote list --json` の `file_path` か、`autonote latest` で分かる
- **顧客の会議は必ず `--kind customer` を付ける。** `--recording` や `--customer` を渡しても種類は変わらず、省くと `internal`（社内）として載り、ブックマークの節（付けたメモ）も置き場に出る。`--recording` か `--customer` を付けて `--kind` を省くと、スクリプトは警告を 1 行出す（共有は続く）。間違えたら `--kind customer` を付けて載せ直す（ブックマークの節は置き場の今の版からは消えるが、git の履歴には残る）
- `--recording` は、受け取り箱に置かれた録画の**ファイル名だけ**を渡す（`日付_時刻_相手先_用件.mp4`）。Finder からドラッグしてフルパスが入っても、スクリプトは最後のファイル名だけを使う。渡すと、相手先を名前から読み、知らせに録画を消す期日（最初に共有した日から `RECORDING_KEEP_DAYS` 日後。既定 7）が入る。最初の共有で付け忘れて、後から `--recording` を付けて載せ直したときも、その回の知らせ（「更新しました」）に期日が入る
- 1 本の録画は 1 つの会議に付ける。同じ録画の名前を 2 つの会議に渡す使い方は想定していない（見回りが「消した」にするのは片方だけになる）
- `--recording` の名前を前と違うものに変えて載せ直すと、録画についての印（「消した」・見回りが出した確認の知らせ）は新しい録画のものとして付け直しになり、置き場の議事録は `source_recording_deleted: まだ` に戻る
- `INBOX_DIR`（受け取り箱のフォルダ）を設定していて、その名前の録画が受け取り箱に無いときは、警告を出して共有は続ける。名前の打ち間違いなら `--recording` を直して載せ直す。同期が遅れているだけなら、そのままでよい
- 「警告: 録画の名前の日時（…）と会議の日時（…）が違います」と出ても、共有は続く。置き場と一覧に載るのは、録画の名前ではなく AutoNote の会議の日時。録画を `autonote import`（CLI）で取り込むと、会議の日時は録画ファイルの作成日時になるので、同期フォルダを通ったファイルでは実際の会議の日時とずれることがある。取り込むときに AutoNote の画面で日時を録画の名前に合わせておくと、ずれない
- 終了コード: 0 成功、1 失敗（push できない・ぶつかった・ファイルが無い）、2 使い方の誤り

### 5. 見回りを入れる（LaunchAgent）

先に 1 つ確かめます。`VAULT_ROOT`（AutoNote の出力フォルダ）が書類フォルダ（`~/Documents`）の中にあるなら — AutoNote の既定がそうです — 下の「launchd から会議ファイルのフォルダを読めないとき」を先に読んでください。そのまま入れると、見回りの載せ直しは動きません。

```sh
SHARE_HOME="$HOME/Library/Application Support/AutoNoteShare"
LABEL="local.share-to-repo.daily-patrol"
mkdir -p "$SHARE_HOME/logs" "$HOME/Library/LaunchAgents"
sed -e "s|__LABEL__|$LABEL|g" -e "s|__SHARE_HOME__|$SHARE_HOME|g" \
  "$SHARE_HOME/bin/launchd/example.share-to-repo.daily-patrol.plist" > "$HOME/Library/LaunchAgents/$LABEL.plist"
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/$LABEL.plist"
launchctl kickstart "gui/$(id -u)/$LABEL"     # 1 回すぐに走らせて確かめる
```

見回りが走る時刻は毎日 9:00 です（雛形の `StartCalendarInterval` の `Hour` と `Minute`）。変えるときは、`~/Library/LaunchAgents/$LABEL.plist` のその 2 つの数字を直し、下の「外すとき」の `launchctl bootout` と、上の `launchctl bootstrap` を打ち直します。その時刻に Mac が眠っていたら、launchd は起きた後に 1 回走らせます（眠っている間に何日か過ぎても 1 回にまとまる。`man launchd.plist` の `StartCalendarInterval` の説明による）。電源が切れていた・ログインしていなかった時刻の分がどうなるかは、この見本では確かめていません。録画の知らせは日数で数えるので、走らなかった日があっても、次に走った見回りで出ます。

走らせた後に見るもの（`kickstart` は見回りが終わるのを待たずに戻るので、終わってから見る）:

- **見回りが終わったこと** — `logs/patrol-YYYY-MM.log` の最後に、いまの時刻の `done` と `rc=0` の行が付く（タブ区切り。`rc=1` なら失敗があったので、下を見る）。この行が付く前に下を見ると、何も出ていないので「問題なし」に見えてしまう
- `state/todo.md` に新しい行が無いこと（特に「会議ファイルのフォルダ（VAULT_ROOT）を読めません」）
- `logs/launchd-patrol.out.log` に「…読めません」「…できませんでした」「…止まりました」の行が新しく出ていないこと、`logs/launchd-patrol.err.log` に新しい行が無いこと（載せ直しがあった日は、out.log に「共有しました: …」が出る。これは失敗ではない）
- Slack を使うなら、`logs/notify-YYYY-MM.log` に `kept-in-outbox` が無いこと

外すとき（日を置いて別のターミナルで打つことになるので、`LABEL` から書きます）:

```sh
LABEL="local.share-to-repo.daily-patrol"
launchctl bootout "gui/$(id -u)/$LABEL"
mv "$HOME/Library/LaunchAgents/$LABEL.plist" ~/.Trash/
```

#### launchd から会議ファイルのフォルダを読めないとき

`todo.md` に「会議ファイルのフォルダ（VAULT_ROOT）を読めません」の行があれば、macOS が launchd の下のプログラムに、そのフォルダを読ませていません。

**先に正直に書くと、AutoNote の既定の設定（出力フォルダが書類フォルダの中）で、見回りの載せ直しが最後まで動くことを確かめた形は、この見本にはまだありません。** 下のアは「許可を求める画面が出る所」まで、イとウは手順だけで、どれも最後までは確かめていません。勧める順は次のとおりです。

1. まず **ア**（アプリ経由）。許可の画面が出る所までは確かめてある。許可した後に見回りが走ることは、入れた人が上の「走らせた後に見るもの」で確かめる
2. アで動かなければ **イ**（AutoNote の出力フォルダを書類フォルダの外へ）
3. どちらも採れなければ **ウ**（載せ直しを手で打つ）。見回りのほかの手順（送り直し・録画の知らせ・写し）は、会議ファイルを読めなくても動く

エ（フルディスクアクセス）は許す範囲が広いので、この順には入れていません。

macOS 27.2 で、`VAULT_ROOT` が書類フォルダ（`~/Documents`）の中にある設定で試して分かったこと:

- 上の手順の形（launchd がシェルを直接呼ぶ）では、許可を求める画面は出ない。フォルダの読み取りが `Operation not permitted` で拒まれるだけなので、ログを見ないと気づけない
- 同じ実行の中で、置き場への git の fetch は通った。拒まれたのは会議ファイルのフォルダだけ
- 同じ Mac で、ターミナルから手で打った `share-meeting.sh` は同じフォルダを読めた

このとき見回りは止まりません。`todo.md` に上の 1 行を書き（同じ文は重ねて書かない）、知らせを 1 通出し、会議ファイルを読む手順（下の「見回り」の 2 の載せ直しと、1 のうち会議を作り直す分）を飛ばして、ほかの手順（clone に残っていた commit の push・録画の知らせ・写しの作り直し）を続け、終了コード 1 で終わります。読めない間は、見回りのたび（毎朝）に同じ知らせが出ます。

**ア. 見回りを小さなアプリ経由で呼ぶ**（許可を求める画面が出る形）。macOS はフォルダの許可をアプリごとに決めるので、見回りを呼ぶだけのアプリを作り、LaunchAgent からはそのアプリを開きます。

```sh
SHARE_HOME="$HOME/Library/Application Support/AutoNoteShare"
LABEL="local.share-to-repo.daily-patrol"
mkdir -p "$HOME/Library/LaunchAgents"
"$SHARE_HOME/bin/launchd/make-patrol-app.sh" "$SHARE_HOME"      # SharePatrol.app を作る（osacompile。中身は daily-patrol.sh を呼ぶだけ）
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null               # 前の形を入れていたら外す
sed -e "s|__LABEL__|$LABEL|g" -e "s|__SHARE_HOME__|$SHARE_HOME|g" \
  "$SHARE_HOME/bin/launchd/example.share-to-repo.daily-patrol-app.plist" > "$HOME/Library/LaunchAgents/$LABEL.plist"
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/$LABEL.plist"
launchctl kickstart "gui/$(id -u)/$LABEL"
```

- 直前の `bootout` の後すぐの `bootstrap` が失敗することがあるかどうかは確かめていません。失敗したら、数秒おいて `bootstrap` の行だけ打ち直します
- この形で確かめたこと: `kickstart` の直後に macOS の確認のウィンドウが 1 つ現れ、見回りは会議ファイルのフォルダを開く所で、答えを待って止まった（シェルを直接呼ぶ形では、同じ所がすぐ `Operation not permitted` になった）
- 確かめていないこと: そのウィンドウの文面と、「許可」を押した後に見回りが最後まで走ること、次の日からは聞かれずに走ること。許可を押すのは Mac の持ち主で、押した後は上の「走らせた後に見るもの」で確かめます
- 答えるまで見回りは待ち続けます（launchd は前の実行が終わるまで次を始めないので、その間は次の日の見回りも始まらない）。答えを後から変える場所は、macOS の設定の プライバシーとセキュリティ › ファイルとフォルダ のはずですが、SharePatrol の行ができることは確かめていません
- 見回りの終了コードは launchd には伝わりません（launchd が見るのは `open` の終了コード）。代わりに、見回りが終わるたびに `logs/launchd-patrol.out.log` に `patrol exit <終了コード>` の行が付きます（`logs/patrol-YYYY-MM.log` の `done` の行も、直接呼ぶ形と同じく付く）
- アプリは `SharePatrol.app` の置き場所から `config.env`・`bin/`・`logs/` を探すので、AutoNoteShare の直下から動かしません。作り直すと、許可をもう一度聞かれることがあります

**イ. AutoNote の出力フォルダを書類フォルダの外（例 `~/AutoNote`）に変え、`VAULT_ROOT` もそこに向ける。** この見本では試していません。

**ウ. 見回りの載せ直しは当てにしない。** AutoNote の側で議事録を直した後は、手で `share-meeting.sh` を打って載せ直します。この場合、毎朝の「読めません」の知らせは出続け、見回りの終了コードも 1 のままです（止める設定はありません）。ほかの失敗の知らせ（「見回りで失敗がありました」）とは別の文なので、見分けは付きます。

**エ. フルディスクアクセスを与える**（システム設定 › プライバシーとセキュリティ › フルディスクアクセス）。LaunchAgent が呼ぶのは `/bin/sh` で、そこから `python3` が動きますが、どの実行ファイルに与えれば足りるかは確かめていません。許す範囲が広いので、選ぶ前によく考えます。

直した後は、もう一度 `launchctl kickstart "gui/$(id -u)/$LABEL"` を打ち、上の「走らせた後に見るもの」を確かめます。

受け取り箱（`INBOX_DIR`）や写しの置き先（`MIRROR_DIR`）を同期フォルダ（`~/Library/CloudStorage/…` など）に置いた場合に、launchd の下から読み書きできるかどうかは、この見本では確かめていません。読めないときは、見回りが `todo.md` に「受け取り箱（INBOX_DIR）を読めません」「読む人向けの写しを作れませんでした」と書きます。

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

1 日 1 回、次を順に行います。議事録と文字起こしを期限で消す処理はありません。1 つの手順が失敗しても残りの手順は走り、どれかが失敗していれば終了コード 1 で終わります（写しを作れない・`autonote list` を読めない、も 1）。

1. 送れなかった知らせと、push できなかった分（`state/pending.tsv`）を送り直す
2. 載せた会議の AutoNote 側のファイルが変わっていれば載せ直す（AutoNote の側で議事録を直したり、訳文が後から付いたりしても、もう一度手で打たなくて済むように）。題が変わってファイル名が変わっても、Obsidian で別のフォルダに整理しても、`VAULT_ROOT` の下なら `autonote_id` で探す（AutoNote と同じく、`_autonote` と、名前が `.` で始まるフォルダは見ない）。どこにも見つからない会議は、持ち主あてに「共有した会議の、AutoNote 側の会議ファイルが見つかりません」を 1 回出して `todo.md` に書く（置き場の記録は消さない）
3. 録画の知らせ（日数は `RECORDING_KEEP_DAYS`＝既定 7、`RECORDING_OWNER_DAYS`＝既定 21。その日数がたった後の最初の見回りで 1 回出す。文には実際にたった日数が入るので、Mac の電源が切れていた日があると 7 より大きい数になる）
   - `INBOX_DIR`（受け取り箱の同期フォルダ）があるとき:
     - **共有した会議の録画**は、最初に共有した日から数える。7 日たったら「受け取り箱の録画を消してください」を 1 回、21 日たったら持ち主あての知らせを 1 回出して `state/todo.md` にも書く
     - **まだ共有していない録画**は、見回りが最初に見つけた日から数える。7 日たったら、持ち主あてに「まだ共有していない録画があります」を 1 回出して `todo.md` に書く（取り込む前の録画なので、「消してください」とは言わない）。21 日たったらもう 1 回。その録画が後から共有されたら、そこから数え直して「消してください」を出す
     - 録画として数えるのは、受け取り箱の直下にある mp4・m4a・mp3・wav・mov だけ。ほかのファイルとサブフォルダは見ない。置いてもらう形式は AutoNote が取り込める mp4・m4a・mp3・wav（雛形の案内文もこの 4 つ）で、mov は「置かれてしまったもの」にも知らせを出すために数えている
     - 受け取り箱で一度でも見えた録画（見回りが見た、または共有のときに受け取り箱にあった）が、後の見回りで無くなっていたら「消した」とみなし、その会議の置き場の議事録を `source_recording_deleted: はい` に直して push する。知らせを見てすぐ消しても、こう扱われる
     - `--recording` で渡した名前の録画が、受け取り箱で一度も見えていないときは「消した」にはせず、「受け取り箱に見当たらない録画があります」を 1 回だけ知らせる（名前の打ち間違いか、同期の遅れ）
     - 受け取り箱に録画が 1 つも無い日は、「消した」「見当たらない」の判定をしない（同期が止まってフォルダが空に見えるだけの日に、全部を「消した」にしないため）。そのため、受け取り箱の最後の 1 つを消した日には `はい` にならず、次に別の録画が置かれた後の見回りで `はい` になる。待たずに `はい` にしたいときは `share-meeting.sh --recording-deleted <autonote_id>`
     - 録画した人が受け取り箱でファイル名を変えただけでも、古い名前の録画は「見えていて、無くなった」ので `はい` になる。`--recording <新しい名前>` を付けて載せ直すと `まだ` に戻る。名前を変えずに戻すなら `--recording-deleted <autonote_id> --undo`
   - `INBOX_DIR` が無いとき: `--recording` を渡して共有した会議ごとに、共有から 7 日たった後の最初の見回りで「録画は消しましたか」を 1 回だけ出す。**この設定では、見回りは録画が消えたことを知る手段が無いので、`source_recording_deleted` は自動では `はい` になりません。** 消したら `share-meeting.sh --recording-deleted <autonote_id>` を打ちます（知らせの文には、その会議の番号が入った形で出るので、そのまま写せる。間違えて打ったら、後ろに `--undo` を付けて打ち直す）
   - 置き場の議事録の `source_recording_deleted` は、「消した」の印（`state/shared.tsv` の `recording_deleted`）に合わせる。印があるのに `はい` でない会議・印が無いのに `はい` の会議があれば、見回りのたびに書き直して push する（push できなかった・衝突で捨てられた分も、ここで追いつく）
4. `AUTONOTE_CLI` があれば、AutoNote から消えた共有の会議を知らせる（自動では消さない。取り下げるなら `--unshare`）
5. 読む人向けの写しのうち、足りないもの・古いものを作り直す

見回りは無人で走るので、失敗は次の形で持ち主に届きます。**ときどき `state/todo.md` を見てください。**

- 見回りで起きた失敗は、`state/todo.md` に 1 行ずつ書く。同じ文は、前の行が残っている間は重ねて書かない。書くのは、置き場に送れない・git のコマンドが失敗した・ロックを取れない・写しを作れない・受け取り箱を読めない・`VAULT_ROOT` のフォルダが無い・clone に人の直しかけがある・送り直しを待っている会議の会議ファイルが見つからない・`autonote list` を読めない・手順が途中で止まった、のどれか
- 失敗があった日は、持ち主あての知らせ「見回りで失敗がありました（N 件）。state/todo.md を見てください」を 1 日 1 通まで出す（失敗が続けば、次の日も 1 通）

## 失敗したとき

| 場面 | 振る舞い |
|---|---|
| push できない（ネットワーク・認証・障害） | commit は clone に残し、1 で終わって `state/pending.tsv` に入れる。次の `--retry-pending` か見回りが送り直す。出る文に、分かった範囲の理由（つながらない・push を断られた、と git の言い分の 1 行目）が入る。fetch と push は 120 秒で打ち切り、時間切れも同じ扱い |
| 置き場が空・ブランチ名が違う | 「置き場が空です（…手順 3 を先に行う）」「置き場にブランチ … がありません（あるのは …）。SHARE_BRANCH を…」と出して、上と同じく `pending.tsv` に入れる。**これは送り直しても通りません。** 文のとおりに直してから `--retry-pending` |
| 置き場のファイルが GitHub の画面などで直されていた | **多くの場合、知らせなしで上書きされます。** 置き場は AutoNote の中身の写しで、直す場所は AutoNote です。直しが clone に取り込まれた後（別の会議の共有や見回りのたびに取り込む）にその会議が載せ直されると、スクリプトは AutoNote の中身でファイルを書き直し、出るのは「更新しました」だけです。直しは置き場の git の履歴には残ります |
| 上のうち、直しがまだ clone に入っておらず、同じ行を AutoNote 側でも変えていた（ぶつかった） | まだ push していない commit をすべて捨て、clone を置き場と同じ中身に戻して、1 で終わる。`state/todo.md` と知らせに「GitHub 側で直されています: <ファイル>」と出す（同じ衝突の知らせは、1 回の実行で 1 通だけ）。ぶつかった会議は `state/pending.tsv` に入り、次の送り直しが AutoNote の中身から作り直して載せるので、この場合も GitHub 側の直しは上書きされる。push できずに残っていた commit の送り直しでぶつかったときは、同じ実行のうちに載せ直すところまで進む。残したい直しは、置き場の git の履歴から拾って AutoNote の会議ファイルに反映する。ほかの会議の共有は止まらない |
| ほかの実行がロックを持っている（写しの作り直しが長引いている、など） | 共有と取り下げは 120 秒待ち、取れなければ 1 で終わって `state/pending.tsv` に入れる。次の `--retry-pending` か見回りが送り直す。落ちた実行が残したロックは、書いてあるプロセスがもう居なければ次の実行が外す。そのプロセス番号を別のプロセスが使っている間は外れないので、何日も「ロックを … 取れません」が続くときは、ほかに実行が無いこと（`pgrep -fl daily_patrol.py` と `pgrep -fl share_meeting.py` が何も出さない）を確かめてから `state/lock` のフォルダをゴミ箱に移す |
| clone に git の名前かメールが無い | 設定のコマンドを示して 1 で終わり、`todo.md` に書いて `state/pending.tsv` に入れる。設定してから `--retry-pending` |
| git のコマンドが途中で失敗した | その回に clone に書いたものを元に戻し、1 で終わって `state/pending.tsv` に入れる。見回りで起きたときは `todo.md` に git の言い分の 1 行目を書く |
| 送り直しを待っている会議（`pending.tsv`）の会議ファイルが、AutoNote 側で消されたか `VAULT_ROOT` の外に動かされた | その会議の commit がもう置き場に届いていれば、clone の議事録から `shared.tsv` の行を作って待ちから外し、「議事録が並びました」を出して、持ち主あてに「会議ファイルが見つかりません（置き場には載っています）」と `todo.md` に書く（録画の知らせなどは、ふつうに共有した会議と同じに続く）。届いていなければ、待ちに残したまま 1 で終わり、`todo.md` に書く。ファイルを戻すか、`--unshare <autonote_id>` で待ちから外す |
| `VAULT_ROOT` のフォルダ自体が無い（外付けのディスクがつながっていない、など） | 会議ファイルを読む手順を飛ばして 1 で終わり、`todo.md` に 1 行書く（会議ごとの「見つかりません」は出さない） |
| 前の実行が途中で落ちて、書きかけが clone に残った | 次の実行の始めに、スクリプトが書く場所（`INDEX.md` と年のフォルダ）を最後の commit の状態に戻してから進む |
| clone に、スクリプトが書かないファイルの直しかけ（未コミットの変更）がある | 何もせず 1 で終わり、原因のファイル名を出して `todo.md` に書く（導入の手順 3 で `README.md` を直して commit し忘れた、など）。commit するか元に戻す。git が追跡していないファイル（Finder が作る `.DS_Store`、clone の直下に置いたメモ）は気にせず進み、commit もしない。ただし `INDEX.md` と年のフォルダ（`2026/` など）の中はスクリプトのものなので、そこに置いたファイルは書きかけとして消される |
| 同じ名前で別の会議 | AutoNote と同じく `-2` `-3` を付ける |
| 題が変わった | 古い 2 本を消して新しい名前で置く。`kind`・相手先・最初に共有した日は引き継ぐ |
| 知らせを送れない | 共有は成功（0）のまま。`state/outbox/` に置いて次の実行で送り直す。3 日送れなければ `todo.md` |
| 文字起こしの章が無い | 議事録だけを置き、`transcript_file: なし` |
| 見回りが会議ファイルのフォルダを読めない | `todo.md` と知らせに出し、載せ直しだけ飛ばして続ける（上の「launchd から会議ファイルのフォルダを読めないとき」） |

状態はすべて `state/` にあります。`shared.tsv`（載せた会議 1 件に 1 行。見出しの列名は変えない）、`pending.tsv`、`inbox-seen.tsv`（見回りが受け取り箱で見た録画）、`mirror-files.tsv`（写したファイル）、`todo.md`（要対応）、`notices.md`（`NOTIFY_MODE=macos` のときのお知らせ）、`outbox/`、`problem-notice-day`（見回りの失敗の知らせを最後に出した日）。共有・取り下げ・見回りの各手順は、`state/lock`（mkdir で取るロック。最長 120 秒待つ）を取ってから clone と `shared.tsv` に書くので、同時に 2 本走っても置き場と台帳は壊れません。待っても取れなかった共有は、上の表のとおり後で送り直されます。ロックを取れなかったときの `pending.tsv` への追記と `todo.md` への追記はロックの外で行うので、ちょうど同時に 2 本が書くと、片方の 1 行が残らないことがあります（ファイル自体は壊れない）。ログは `logs/share-YYYY-MM.log` などに 1 行ずつ（会議の中身は書かない）。

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
- 議事録の構成図（Mermaid）は図にならず、`flowchart LR` のような元の文字のまま出ます。Obsidian の形のリンク（`[[別のノート]]` など）も、記号ごとそのまま出ます（発言リンクだけは「（→ 00:07:08）」に置き換わる）。読む人に配る前に知っておいてください
- 写しは state の下の作業フォルダで作ってから置き換えるので、同期フォルダに書きかけのファイルは置きません。写したファイルは `state/mirror-files.tsv` に記録し、消すのはそこにあるものだけです（読む人が置いたファイルは残る）
- `--unshare` で取り下げた会議は、写しからも消えます
- 写しのファイルを読む人が直してしまっても、スクリプトは気づきません（作り直すのは、元の議事録が変わったときと、ファイルが無くなったとき）。直された版は、その会議が次に載せ直されるまで残ります。すぐ戻すには `share-meeting.sh --rebuild-mirror` を打ちます
- 写しを作れなくても共有は成功（0）のままで、`todo.md` に 1 行書き、次の見回りで作り直します
- 知らせのリンクは `MIRROR_WEB_URL`（写しのフォルダの URL）があればそれを使い、読む人に GitHub の URL を見せません

読む人には「はじめに」を読んでもらい、その人の Claude には同期フォルダをつないで「はじめに を読んでから、会議の一覧 → 議事録 → 文字起こし の順に読んで」と頼んでもらいます。

## 分かっている制約

- 一覧の「一行の要約」は、議事録の `## 要約` の節から取ります。この節が `## 3行要約` だった頃の AutoNote で作った古い会議は、`INDEX.md` と「会議の一覧」の要約の欄が「—」になります（議事録の本文は欠けずに載る）
- 1 本の録画を 2 つの会議に付ける使い方は想定していません（導入の手順 4）
- launchd の下で書類フォルダの中の会議ファイルを読む形は、最後までは確かめていません（「launchd から会議ファイルのフォルダを読めないとき」）

## テスト

```sh
examples/automations/share-to-repo/tests/run-tests.sh        # -v で 1 件ずつ表示
```

一時フォルダの中だけで動きます（push 先は `git init --bare` の一時リポジトリ、知らせは `dry-run` か偽物のコマンド、Slack はローカルの偽のサーバー）。本物の GitHub・Slack・`autonote`・`osascript`・`op` は呼ばず、AutoNote のデータ領域と出力フォルダにも触りません。フィクスチャの会議はすべて作り物です。macOS では textutil で docx を 1 件だけ実際に作るテストも走ります。
