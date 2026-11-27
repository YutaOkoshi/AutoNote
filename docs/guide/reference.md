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

### メインウィンドウの一覧の右クリック

左の会議一覧で 1 件を右クリックすると、詳細画面のボタンと同じ操作を一覧から直接呼べる。

| 項目 | 出る会議 | 動作 |
|---|---|---|
| 再実行: <Automation 名> | Automation が失敗した会議 | その Automation をもう一度走らせる（失敗したものごとに 1 項目） |
| 再生成 | 議事録か文字起こしができている会議（状態「完了」「議事録 未生成」） | 議事録を作り直す（`autonote regenerate` と同じ）。詳細に表示中の会議の議事録に未保存の編集があれば、先に 保存 / 破棄 / キャンセル を聞く |
| Finder で表示 | すべて | 議事録ファイルを Finder で選んだ状態で開く。ファイルがまだ無ければ録音のフォルダを開く |
| この会議を削除 | 録音中・処理中以外 | 確認のあと、音声、アプリ内のデータ、Vault の会議ファイル、`_index.md` の行をまとめて削除する。元に戻せない |

2 件以上を選んで右クリックしたときは「1 つの会議に統合」だけが出る（次の節）。

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
- 見本: 会議ファイルを議事録と文字起こしに分けて共有の git リポジトリ（と、git を使わない人向けの同期フォルダ）に載せるスクリプトが [`examples/automations/share-to-repo/`](../../examples/automations/share-to-repo/README.md) にある（AutoNote の外で動かす。この版は載せたい会議を 1 件ずつ手で渡す形で、Automations にそのまま登録するものではない）

## ショートカット

既定は ⌃⌥B（ブックマーク）、⌃⌥R（録音の開始・停止）、⌃⌥P（一時停止・再開）。設定 › ショートカット で変えられる。グローバルホットキーなので、アクセシビリティの許可は要らない。

## 通知

通知は音を鳴らさない。表示スタイルは システム設定 › 通知 の AutoNote に従い、アプリ内では通知パネルに出る。

### 録音に音が入っていないとき

録音中、ほかのアプリが音を出しているのにシステム音声が無音のまま届く、またはまったく届かないとき、AutoNote は音の取り込みを自動で作り直す（マイクが完全な無音を返し続けるときも同じ）。それでも戻らないときは、次のように知らせる。

| いつ | どこに | 何が出るか |
|---|---|---|
| 録音中、作り直しても 1 分以上戻らない | 通知 | 「システム音声が 1 分以上録音に入っていません（ほかのアプリは音を出しています）。相手の声が録れていない可能性があります。録音は続けています」 |
| 録音中、マイクかシステム音声を録音できなくなった | 通知 | 「システム音声を録音できていません。…録音を止めて始め直してください」と「システム設定を開く」 |
| 録音を止めた後 | 会議一覧の行 | 橙色の「録音の欠損: システム音声 約 12 分」（どちらの音が、どれだけ欠けたか）。黄色い三角（無音の可能性）とは別の表示 |
| 議事録ができた後 | 議事録の題名のすぐ下 | 「録音が一部欠けている可能性があります（システム音声 約 12 分）。その間の発言は文字起こしと議事録に入っていません。」 |

一覧と議事録に出るのは、欠けた時間が 30 秒以上で、かつ録音の長さの 1 割以上のとき（録音できなくなったときは長さによらず出る）。議事録はそのまま作られる。

「可能性」と書いているのは、見分けられない場合があるため。会議アプリが音の出口を開いたまま無音を流している間（相手が全員ミュートしている、再生を一時停止した直後の約 10 秒など）も、録音側からは「音を出しているのに無音」に見える。相手が話していたのに欠損と出たときは、会議アプリの音の出力先を確かめ、録音を止めて始め直す。

誰も音を出していない時間（対面の会議をマイクだけで録るときなど）は欠損に数えない。

## ログイン時起動

設定 › 一般 でオンにすると、いま動かしている `AutoNote.app` の場所がログイン項目として登録される。ダウンロードフォルダや `build/AutoNote.app` から動かすと登録先がそこになるので、使う場所（例: `/Applications`）に置いてからオンにする。

## アプリが異常終了したとき

それまでの録音は残り、次の起動時に「前回の録音が途中で終わっています。文字起こしと議事録を作りますか？」と聞かれる（「はい」で修復して処理する）。ただし録音は自動では再開しないので、会議が続いていれば録音を開始し直す。

## 設定ファイル（settings.json）

設定画面の値は `~/Library/Application Support/AutoNote/settings.json` に保存される。ふつうは設定画面で変えればよい。手で書き換えるときはアプリを終了してから編集する。

- `default_language`: 文字起こしの既定の言語。`auto` / `ja`（既定）/ `en`。設定 › 文字起こし ›「言語」の「既定の言語」と同じ
- `live_engine` / `live_model`: リアルタイム版のエンジンと、whisper のときのモデル。`live_engine` は `dictation` / `speech` / `whisper`。書かないとこの Mac の既定（Apple Silicon は `speech`、Intel は `dictation`）。`live_model` は `live_engine` が `whisper` のときだけ読まれ、`base` / `small` / `large-v3-turbo` / `large-v3-turbo-q5_0` のうちダウンロード済みのもの（書かないと `small`）。設定 › 文字起こし ›「リアルタイム」の「エンジン」と同じ
- `final_engine` / `final_model`: 確定版のエンジンとモデル。`final_engine` に書けるのは `whisper` だけ。`final_model` は `final_engine` を書いたときだけ読まれ、名前は `live_model` と同じ（書かないと `large-v3-turbo`）。設定 › 文字起こし ›「確定版」の「エンジン」と同じ
- `live_summary_model`: リアルタイム要約に使う Claude のモデル名（既定 `haiku`）。設定 › 一般 ›「リアルタイム要約」の「モデル」と同じ
- `final_threads`: 確定版の whisper が使う CPU のスレッド数（整数、1〜8。範囲外は端に丸める）。書かない（または `null`）と自動で、物理コア数 − 1（上限 4、下限 1）になり、他の作業のために 1 コア空ける。設定 › 文字起こし ›「確定版」の「文字起こしに使う CPU」と同じ。変えると次のジョブから効く（キューを組み直す）。ライブの whisper は常に 2 スレッドで、この値に関係しない
- `claude_args`: AutoNote が `claude` を起動するとき（議事録の作成、リアルタイム要約）に、AutoNote 自身の引数の後ろに付ける追加の引数（文字列の配列。既定 `[]`）。ただしログインの確認（`claude auth status --json`）には付けない（`auth` が受け付けない引数でログインしていない扱いになるのを避けるため。環境変数 `claude_env` は付ける）。配列の 1 要素が 1 つの引数で、空白を含んでも分けない。AutoNote の引数（`-p` など）と重なっても手を加えない。設定 › 一般 ›「Claude の起動」の「引数」と同じ
- `claude_env`: 議事録の作成、リアルタイム要約、ログインの確認の 3 つの起動で `claude` に渡す環境変数（名前 → 値のオブジェクト。既定 `{}`）。AutoNote が組み立てる環境（`claude` のフォルダとシステムのフォルダを前に足した `PATH` を含む）より優先し、`PATH` を書けばその値をそのまま使う。名前は英字・数字・`_` だけで数字で始めない（`^[A-Za-z_][A-Za-z0-9_]*$`）。設定画面ではそれ以外の名前は保存できず、手で書いた不正な名前は読み込み時に無視する。例: 別の設定フォルダの Claude Code を使うなら `"claude_env": {"CLAUDE_CONFIG_DIR": "/Users/<あなた>/.claude-work"}`。設定 › 一般 ›「Claude の起動」の「環境変数」と同じ

`claude_args` と `claude_env` は、議事録は次の作成から、リアルタイム要約は次の録音から効く（アプリの再起動は要らない）。

手で書いた値を AutoNote が使わなかったときの調べ方は、下の「ログで理由を調べる」を参照。

翻訳（設定 › 翻訳。どれも書かなければ既定）:

- `translation_mode`: `off`（既定）/ `after_recording`（録音後に訳す）/ `during_recording`（録音中も訳す。Intel では録音後だけになる）
- `translation_target`: `auto`（既定。日本語 ↔ 英語を発話ごとに反転）/ `ja` / `en`
- `translation_model`: `0.8b` / `2b` / `8b`。書かないとこの Mac の既定（Apple Silicon かつメモリ 16 GB 以上は `2b`、それ以外は `0.8b`）。メモリ 16 GB 未満の `8b` は既定に戻す
- `translation_license_version`: 同意した PLaMo Community License の版。これが今の版でない限り、翻訳モデルはダウンロードも使用もしない
- `translation_shown`: 文字起こしの「訳文」スイッチ（既定 `true`）

翻訳モデルは `~/Library/Application Support/AutoNote/models/translation/` に、訳文は会議ごとに `transcripts/<会議ID>/translation.json`（確定版の訳）と `live-translation.json`（録音中の訳。確定版の訳ができると消える）に保存する。文字起こしのファイル（`final.json` など）は書き換えない。モデルの重みには PLaMo Community License が適用され、業務（社内利用を含む）で使う場合は PFN への事前登録が要る（README の「翻訳モデル」を参照）。

## ログで理由を調べる

設定が効いていない、リアルタイム要約が出ない・更新されない、というときは macOS のログに理由が残っている（この節の行が出るのは 0.8.1 以降の版）。ターミナルで次の形のコマンドを打つ（`--last 1h` は「直近 1 時間」。`process == "AutoNoteApp"` はアプリ本体の行だけに絞る）。

### 使われなかった設定値

次のどれかに当たると、その項目は書いた値ではなく既定で動き、ログに 1 行出る。

- 知らない値: `live_engine`（`dictation` / `speech` / `whisper` のどれか）、`final_engine`（`whisper` だけ）、`translation_mode`、`translation_target`。`translation_mode` と `translation_target` は文字列でない値を書いたときも同じ（その項目だけ既定）
- この Mac で動かせないエンジン: 値は正しくても、`final_engine` に `dictation` / `speech` を書いた、`live_model` / `final_model` のモデルをダウンロードしていない・名前が違う、選んだ言語に対応していない、のどれか
- `claude_env` の不正な名前（無視した個数だけが出る。名前と値は出ない）
- `settings.json` 全体が読めない（JSON として壊れている、`translation_mode` と `translation_target` 以外の項目で値の型が違う（`live_engine` に数値を書いた、など）、`default_language` が知らない値、など）。このときはファイルを同じフォルダの `settings.json.corrupt-<日時>` に退避し、すべて既定で動く

ここに無いものはログに出さずに置き換わる: 範囲外の数値は端に丸め、空の `live_summary_model` は `haiku`、知らない `translation_model` はこの Mac の既定になり、`live_engine` / `final_engine` を書かずに書いた `live_model` / `final_model` と、打ち間違えたキーは読まれない。

読み方: AutoNote は起動しているあいだ 30 秒ごとに設定を読み直し、同じ内容の行は 30 分に 1 回出す。値が使われていないあいだは 30 分ごとに出直すので、録音しなくても直近 1 時間のログに入る。`settings.json` を書き換えた直後なら、起動して 1 分待ってから次を打つ。

```sh
log show --last 1h --predicate 'subsystem == "com.yutaokoshi.autonote" AND category == "Settings" AND process == "AutoNoteApp"'
```

出る行の例:

```text
settings: ignored live_engine "system" (known: dictation, speech, whisper); using this Mac's default engine
settings: ignored final_engine "speech" (only whisper can be the final engine); using whisper.cpp large-v3-turbo
settings: ignored live_engine "whisper" with model "small" (model small is not downloaded); using Apple SpeechTranscriber
settings: settings.json could not be read (invalid value at default_language); moved to settings.json.corrupt-20261127-221500, using the defaults
```

`live_engine` に `whisper` だけを書いてモデルを書いていないときは、行の `with model "…"` に既定のモデル名（リアルタイム版は `small`）が入る。

`settings.json` を退避した行だけは、退避したそのときに 1 回しか出ない（次からはファイルが無いので、黙って既定で動く）。設定が全部既定に戻っていたら、まず退避されたファイルがあるかを見る。

```sh
ls ~/Library/Application\ Support/AutoNote/ | grep corrupt
```

`settings.json` が退避されたときの戻し方: AutoNote を終了し、`settings.json.corrupt-<日時>` の中身を直して、名前を `settings.json` に戻してから起動する。退避されたまま設定画面で何かを保存すると、既定から新しい `settings.json` が作られる（退避されたファイルは残るので、そこから値を写せる）。

### 実際に動いたエンジン

リアルタイム版は、録音を始めるたびに次の行が出る（上のコマンドとはカテゴリが違う）。

```sh
log show --last 1h --predicate 'subsystem == "com.yutaokoshi.autonote" AND category == "LiveTranscriptionWiring" AND process == "AutoNoteApp"'
```

```text
20261127-1000-ab12: live transcript started (on recording started, engine: Apple SpeechTranscriber)
```

`engine:` の値と設定値の対応は、`Apple DictationTranscriber` = `dictation`、`Apple SpeechTranscriber` = `speech`、`whisper.cpp <モデル名>` = `whisper`。確定版で動いたエンジンは、議事録の先頭（frontmatter）の `transcript_engine` に同じ表記で入る。

### リアルタイム要約が失敗した理由

要約が 1 度も出ないとき、または録音中の画面に「要約を更新できません」と出たとき（3 回続けて失敗したとき）は、理由が 1 行ずつ残っている。

```sh
log show --last 1h --predicate 'subsystem == "com.yutaokoshi.autonote" AND category == "ClaudeLiveSummarizer" AND process == "AutoNoteApp"'
```

**要約が 1 度も出ないとき**は、録音の最初の確認で止まっている。その録音のあいだ要約は止まったままで（画面には何も出ない）、次の録音でやり直す。

```text
live claude -p unavailable: claudeNotFound (the configured claude command is missing or not executable)
live claude -p unavailable: notLoggedIn (claude auth status: exit 0, loggedIn false)
```

- `claudeNotFound` は `claude` が見つからないとき。設定 › 一般 の「コマンド」（`claude` の場所）を直すか、「探す」を押す
- `notLoggedIn` はログインの確認（`claude auth status --json`）が通らなかったとき。`loggedIn false` ならターミナルで `claude` にログインする。`exit` が 0 以外、または `stderr:` が付いているときは、確認そのものが失敗している（`claude_env` に書いた設定フォルダや API キーの値を確かめる）

**「要約を更新できません」と出たとき**は、失敗のたびに次の形の行が出ている。

```text
live claude -p failed: failed (exit 1): There's an issue with the selected model (…). It may not exist or you may not have access to it. Run --model to pick a different model. …
```

- `failed:` の後ろが失敗の種類、`(exit N)` が `claude` の終了コード、その後ろが `claude` 自身のエラー文（1 行、200 文字まで）。会議の内容は出ない
- `***` は、`claude_env` に書いた値（8 文字以上）のどれかを伏せたもの。秘密でない値（モデル名やリージョン）も伏せるので、エラー文の前後から、どのキーの値かを `settings.json` と突き合わせる
- 上の例はモデル名が使えないとき。設定 › 一般 ›「リアルタイム要約」の「モデル」（`live_summary_model`。既定は `haiku`）を、その Mac の Claude Code で使える名前に直す
- `subtype=error_max_turns` は `claude` が 1 回のやり取りで答えを出し切れなかったとき、`notLoggedIn` は録音の途中でログインや API キーが通らなくなったとき（後ろの文で区別できる。その録音の要約はそこで止まる）、`timedOut` は 60 秒で終わらなかったとき
- `no error text (stdout … bytes, …; stderr … bytes)` は `claude` が何も言わずに終わったとき（理由は分からない。出力の大きさだけが出る）
- `live claude -p did not run: …` は、録音の途中で `claude` を起動できなくなったとき（設定 › 一般 の「コマンド」を確かめる）
- ここに無い行や、直し方が分からない行は、その 1 行をそのまま issue に貼る（会議の内容と `claude_env` の値は入っていない）
