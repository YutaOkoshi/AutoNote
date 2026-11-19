# 文字起こしと要約の評価

AutoNote の文字起こし（ライブ・確定版）と議事録要約の品質を、実在の会議音声で数字にする仕組み。2 つのビルドを同じ音声で回し、
**基準との差**で良くなったか悪くなったかを判断する（絶対値は正解の作りの癖で動くので、他製品との比較には使わない）。
設計は `docs/superpowers/specs/2026-11-19-evaluation-harness-design.md`。

- スクリプト: `scripts/eval/`（Python 3.9 の標準ライブラリのみ。ダウンロードしたファイルを読むので `python3 -I` で動かす）
- データ: `.eval-data/`（git 管理外。音声・正解の本文・実行結果はここだけに置く）
- 結果: `docs/eval/results/<日付>-<label>.json` と `.md`（集計値のみ）。基準は `docs/eval/baseline.json`
- CI には載せない（音声が大きく、要約は外部呼び出しになる）

## 前提

- `ffmpeg`（`brew install ffmpeg`）
- 比べるビルドの `autonote`（例: `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift build -c release --product autonote`。Xcode なしの回避策は `docs/development.md`）
- モデル: `~/Library/Application Support/AutoNote/models/ggml-large-v3-turbo-q5_0.bin`（`datasets.json` の `model`。`run.py --model-path` で変えられる）
- ディスク: 公開データ一式で約 1.5 GB

## 使い方

```sh
# 修正前（main）を回して基準にする
scripts/eval/eval.sh --autonote .build/release/autonote --label main --set-baseline
# 修正ブランチを回して基準と比べる（表の Δ 列が差）
scripts/eval/eval.sh --autonote ../other-worktree/.build/release/autonote --label fix
```

`eval.sh` は fetch（取得・検証・音声と正解の用意）→ run（文字起こし）→ score（採点）→ report（表）を順に回す。
取得済み・用意済み・実行済みのものは飛ばすので、途中で止まっても同じコマンドで続きから回る。1 つの label には
1 つのビルド（実行ファイルの SHA-256）の結果だけを入れる（別のビルドで続けようとすると止まる）。出力を書き終えた後に
autonote が 0 以外で終わった実行は、結果を使い、表に `⚠exit` を付ける。個別にも回せる:

| スクリプト | 役割 |
|---|---|
| `fetch.py [--datasets id,…] [--force-prepare]` | 取得（User-Agent は汎用名、要求の間は 3 秒以上）、SHA-256 の照合、ffmpeg で 16 kHz モノラル・先頭 20 分に、正解の変換 |
| `run.py --autonote <bin> --label <名前> [--engines …] [--langs …]` | `autonote dev transcribe` を確定版（whisper）とライブ（whisper-live）× 言語で 1 本ずつ順に回す（RTF を比べるため並列にしない。`--realtime` なし） |
| `score.py --label <名前> [--set-baseline]` | 採点して `docs/eval/results/` に書く |
| `report.py <result.json> [--base <json>|none]` | Markdown の表。既定の基準は `docs/eval/baseline.json` |
| `rtf.py --a <label>=<bin> --b <label>=<bin> [--rounds 3]` | 処理時間の比較。2 ビルドを交互に複数回回した中央値の比（1 回ずつの RTF は他の負荷で 2 倍近く揺れるので、速度の判断はこちらで） |
| `calibrate.py --autonote <bin>` | 一度だけ: 党首討論の正解の範囲（`calibration.json`）と合成の混在セットの区間（`mixed-spans.json`）を決める |
| `summary_eval.py --autonote <bin> --label <名前> [--allow-claude]` | 要約の評価（後述） |
| `local.py add/draft/import` | 手元の録音を加える（後述） |

単体テスト: `python3 -I -m unittest discover -s scripts/eval/tests`

## データセット（`scripts/eval/datasets.json`）

| id | 内容 | 正解 | ライセンス・出典 |
|---|---|---|---|
| `ami-ES2008a` / `ami-IS1009c` / `ami-TS3003c` | AMI Meeting Corpus の英語の会議（設計の初回・中間・後半、4 人）。Mix-Headset | 語単位の人手の書き起こし（時刻つき）、人手の要約 | CC BY 4.0。AMI Meeting Corpus（University of Edinburgh / AMI Consortium） |
| `kantei-toron` | 党首討論 2010-04-21（国家基本政策委員会合同審査会） | 国会会議録（整文済み・時刻なし）。`calibration.json` の範囲で採点 | 動画: 首相官邸、Wikimedia Commons、CC BY 3.0（Commons ではライセンス審査が未了）。会議録: 国立国会図書館 国会会議録検索システム（発言者に著作権が残る。評価の解析にだけ使い、本文を再配布しない） |
| `kantei-us` | 日米共同記者会見 2017-02-10。日本語と英語が交互に出る | 冒頭のトランプ大統領の発言（0〜240 秒）の英語のみ（米国政府の記録） | 動画: 首相官邸、Wikimedia Commons、CC BY 3.0。記録: govinfo.gov DCPD-201700110（public domain） |
| `mixed-synth` | 合成の日英混在: AMI TS3003c の後半と党首討論の後半から、正解がよく合う区間（英 12〜30 秒・日 15〜35 秒）を 8 組、0.6 秒の無音を挟んで交互につないだもの（区間ごとに音量を揃える） | 区間の正解をつないだもの | 上の 2 つに同じ |
| `rwcp-sp01` | RWCP-SP01 会議音声データベース（無効。利用者が申請中） | — | 研究用・再配布不可。届いたら宣言を足す |

注意:
- 党首討論の正解は**整文済み**の会議録なので、誤り率は「整文の差 + 認識の誤り」の合計になる（会長の呼び出しの声は記録になく、挿入として数えられる）。差で見る。
- 合成の混在セットの日本語区間の切れ目は、確定版の発話の時刻から決めた（境界の数語がずれることがある。区間内の CER が 15% 以下のものだけ使う）。語の途中の切り替えは再現できない。
- 日米会見の英語の冒頭は原稿の読み上げで、公開動画なのでモデルが学習で見ている可能性がある。英語の一般的な精度ではなく、`--lang ja` で英語が残るかを見るのに使う。
- `datasets.json` の sha256 が空のものは、取得時の値を表示する（確かめて書き込む）。API の応答（会議録・govinfo）は `sha256_may_change` で、違っても警告だけ。

## 指標（`score.py`、正規化の版 `norm-1`）

正規化（`scripts/eval/textnorm.py`）は参照と出力の両方に同じ規則を当てる: NFKC、小文字化、漢数字と「3万5000」の算用数字化、
数字の桁区切りの除去、フィラー（えー・えーと・あのー・うーん / um・uh・hmm・mm-hmm など）の除去、句読点・記号の除去。
規則を変えたら `NORM_VERSION` を上げる（版が基準と違うと表に警告が出る）。

| 列 | 意味 |
|---|---|
| er | 正規化後の誤り率（主指標）。英語は WER、日本語は CER、混在は MER（英語は語・日本語は 1 文字を 1 単位）。日米会見は冒頭 240 秒の英語の WER |
| raw | 素の値（NFKC だけ。句読点・大文字小文字も数える） |
| en WER / ja CER | 混在のとき、英語の語だけ・日本語の文字だけを取り出して比べた値 |
| en 残存 | 正解の英語の語のうち、出力に英語の語として現れた割合（語の多重集合の重なり。順序は見ない） |
| 想定外 | 日本語の文字・ラテン文字以外の文字種（キリル・ハングル・デーヴァナーガリーなど）を含む確定発話の数 / 確定発話の数 |
| 反復 | 繰り返しの幻覚らしい確定発話の数（2〜12 文字の単位が 3 回以上、2 語以上の句が 3 回以上、1 語が 4 回以上続く、同じ発話が 3 回以上続く） |
| 最長脱落 | 整列で連続して落ちた正解の単位数の最長（まとまった聞き漏らし） |
| RTF | 処理時間 ÷ 音声長（モデルの読み込みを除く）。RTF 比 = この結果 ÷ 基準 |

Δ は「この結果 − 基準」（ポイント）。誤り率が 1 ポイント以上悪化した行に ▲ を付ける。時刻のない正解は
`calibration.json` の範囲（どのビルドでも同じ）で採点する。範囲が無いときは出力に最も合う区間に合わせる（表に `locate` と出る）。

## 要約の評価（`summary_eval.py`）

```sh
python3 -I scripts/eval/summary_eval.py --autonote .build/release/autonote --label main --datasets ami-ES2008a --allow-claude
```

- 入力は 2 通り: `reference`（AMI の正解の書き起こし。要約だけの力）と `final`（AutoNote の確定版、whisper・`--lang en`・会議の全長。通しの力）。
- 要約は `autonote dev summarize --fake <transcript.json> --claude --minutes-out <path>`（アプリと同じ Claude 呼び出しと議事録スキーマ）。
- 採点は `claude -p --output-format json --json-schema …`（アプリと同じ固定の引数。道具なし・MCP なし・1 ターン）。採点モデルの既定は `claude-sonnet-5-5`（`--judge-model`）。
  - 突き合わせ: AMI の decisions / actions の各項目に、`MinutesOutput` の decisions / next_actions のどれが対応するかを判定させ、再現率と適合率を出す。
  - 忠実性: 要約・決定事項・次のアクション・要点の各項目が、**正解の書き起こし**に照らして supported / partial / unsupported のどれかを判定させる。スコア = (supported + 0.5 × partial) ÷ 項目数。
- 要約のキャッシュの鍵は「書き起こし + autonote の SHA-256」なので、ビルドを変えると要約は作り直す（採点は要約の中身が同じなら再利用）。
- **Claude を呼ぶのは `--allow-claude` を付けたときだけ**。要約と採点は入力のハッシュで `.eval-data/cache/` にキャッシュし、同じ入力では呼び直さない（`--allow-claude` なしでキャッシュが無ければ止まる）。プロンプトを変えたら `PROMPT_VERSION` を上げる。
- 結果: `docs/eval/results/<日付>-summary-<label>.json` と `.md`。採点モデル（実際に使われた ID）、プロンプトの版、議事録スキーマの版、トークン量を記録する。
- 1 会議で、要約 1 回 + 採点 2 回（入力 2 通りで計 6 回）。採点の入力は正解の書き起こし全文なので、20 分の会議で 1 回あたり約 1 万トークン。

## 手元の録音（共有できない会議）

音声・下書き・正解はすべて `.eval-data/private/`、宣言は git 管理外の `scripts/eval/datasets.local.json` に置く。

```sh
# 1. 宣言する（日英混在なら --langs ja,en）
python3 -I scripts/eval/local.py add --id work-0001 --audio ~/Desktop/meeting.m4a --langs ja,en
# 2. 確定版で下書きを書き出す → .eval-data/private/work-0001/draft.txt
python3 -I scripts/eval/local.py draft --id work-0001 --autonote .build/release/autonote
# 3. draft.txt を聞きながら直す（[HH:MM:SS] と # の行は取り込まれない。聞き取りにくい箇所も聞こえたとおりに書く）
# 4. 正解として取り込む → .eval-data/private/work-0001/reference.json
python3 -I scripts/eval/local.py import --id work-0001
# 5. 採点する（結果は .eval-data/results/ に出る。集計値だけだが、共有するかは自分で決める）
scripts/eval/eval.sh --autonote .build/release/autonote --label main --datasets local
```

`datasets.local.json` の書式（`local.py add` が書く）:

```json
{
  "version": 1,
  "sources": {"local-work-0001": {"path": "/abs/path/meeting.m4a", "sha256": "…", "license": "private（共有しない）"}},
  "datasets": [{"id": "work-0001", "kind": "local", "title": "…", "audio": "local-work-0001",
                "reference": "private/work-0001/reference.json", "max_seconds": 1200, "unit": "word",
                "languages": ["ja", "en"], "langs": ["ja", "auto"]}]
}
```

- 下書きは確定版の出力なので、直さずに取り込むと確定版に有利になる（誤り率 0 に近づく）。直した量がそのまま評価の質になる。
- 手元の録音は `--set-baseline` の対象にしない（公開データだけを基準にする）。
- 共有するときは結果の `.json` / `.md` だけを渡す（本文・音声は渡さない）。

## 結果の置き場所

```
.eval-data/
  ami/ kantei/ kantei-us/     取得したそのままのファイル
  prepared/<id>/audio.wav     16 kHz モノラル・先頭 20 分
  prepared/<id>/ref.json      正解（本文）
  runs/<label>/<id>/<engine>-<lang>.jsonl   autonote dev transcribe の出力
  cache/summaries/ cache/judge/             要約と採点のキャッシュ
  private/                    手元の録音
docs/eval/results/            集計値（コミットする）
docs/eval/baseline.json       基準
```
