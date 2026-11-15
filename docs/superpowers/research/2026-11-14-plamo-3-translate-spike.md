# PLaMo 3 Translate 組み込みの事前調査（スパイク）

文字起こしの後に端末内で翻訳する機能のため、Preferred Networks の PLaMo 3 Translate（2026-11-05 公開）を Swift アプリから動かせるか、速度・メモリ・訳の質を実測した。アプリのソースは変更していない。

## 結論

- **推論手段は llama.cpp（GGUF）を推奨する**。0.8B / 2B / 8B とも Homebrew の llama.cpp 1.0.0 でそのまま動いた。Command Line Tools だけの `swiftc` から、whisper.cpp と llama.cpp を**同じ ggml を共有して同一プロセスで**呼べることも確かめた（下の「Swift からの呼び出し」）。MLX は Python では動くが、Swift 側は PLaMo 3 のモデル実装もトークナイザーも無く、Metal シェーダのビルドに Xcode が要る。
- **既定モデルは 2B Q4_K_M（1.81 GB）**。0.8B より文脈を渡したときの訳の改善がはっきり大きく、M5 Pro では 1 発話 0.14〜0.17 秒。0.8B（0.57 GB）は Intel・メモリ 8 GB 機向けの軽量版、8B（5.28 GB）は 16 GB 以上の Apple Silicon 向けの高品質版として選べるようにする。
- **まず録音後にまとめて訳す**のがよい。速度の面では録音中の逐次訳も成り立つが（Whisper と同時でも 2B で中央値 0.24 秒）、リアルタイムの文字起こしは確定版で置き換わるので、訳しても捨てることになる。録音中に訳すのは、後から足す任意機能として扱う。
- 前後の発話（直前 3 組の原文と訳）を履歴として渡すと、文脈に依存する短い発話の誤訳が目に見えて減る。2B・8B で特に効く。

## 測定環境

- Apple M5 Pro、メモリ 64 GB、macOS 27.2、Xcode なし（Command Line Tools、Swift 6.4.2）
- llama.cpp 1.0.0（Homebrew、build 12359、commit b1b770d90、2026-11-13）。Homebrew の ggml 1.0.0 を共有ライブラリで使う
- whisper.cpp 1.9.5（Homebrew。上の ggml 1.0.0 にリンクされている）
- mlx 0.32.4 / mlx-lm 0.32.2 / transformers 5.23.0（Python 3.12、uv の venv）
- 生成は貪欲法（temperature 0）。速度はページキャッシュに載った状態（2 回目以降の読み込み）で測った

## 1. プロンプト形式

モデルカード（各サイズ共通）の要点。

- 入力は **PFML3** という専用形式で、特殊トークンで要素を区切る。チャットテンプレート（`chat_template.jinja`、GGUF には埋め込み済み）は PFML3 を組み立てるだけで、**アプリへの組み込みでは PFML3 を直接組み立てて Completions 系の API に渡すことが推奨されている**。
- 基本形（改行は読みやすさのためで、実際には入れない。先頭の `<|plamo:bos|>` は llama.cpp・mlx-lm・transformers が自動で付けるので書かない）:

  ```
  <|plamo:tag|>dataset<|plamo:msg|>translation
  <|plamo:tag|>input<|plamo:key|>lang<|plamo:val|>ja<|plamo:msg|>会議は来週の月曜日に変更されました。
  <|plamo:tag|>output<|plamo:key|>lang<|plamo:val|>en<|plamo:msg|>
  ```

  訳は最後の `<|plamo:msg|>` の直後に生成され、`<|plamo:tag|>` か `<|plamo:bos|>` を出して止まる。この 2 つを停止文字列にする。
- 言語: 出力側の `lang`（`target_lang`）は必須。入力側の `lang`（`source_lang`）は省略でき、省略すると自動判定。53 言語。
- **履歴**（前の原文と訳の組）: 訳し終えた `input`/`output` の組を文書の順に並べ、最後に今回の `input` と本文が空の `output` を置く。古い組から捨てる運用が推奨。
- **文脈**: `dataset` の直後に `<|plamo:tag|>context<|plamo:msg|>（場面の説明や周辺の文）`。
- **用語集**: 今回の `input` の直前に `<|plamo:tag|>glossary<|plamo:index|>原語<|plamo:item|>訳語…`（組を繰り返す）。
- **文体**: 日本語に訳すときだけ `output` に `<|plamo:key|>form<|plamo:val|>plain`（だ・である）か `polite`（です・ます）。
- 長さの上限: 学習時の最大は入力と出力の合計 32,768 トークン。
- 注意: GGUF のチャットテンプレートは 2026-11-08 に変更されている（`target_lang` 省略時の既定の変更）。PFML3 を自分で組み立てればテンプレートの変更の影響は受けないが、ファイルの差し替えはありうるので、取得するファイルは sha256 で固定する。

今回の計測で使った組み立て方（Python。Swift でも同じ文字列を作ればよい）:

```python
T, M, K, V = "<|plamo:tag|>", "<|plamo:msg|>", "<|plamo:key|>", "<|plamo:val|>"
def build(text, src, tgt, history=(), context=None, glossary=None):
    p = f"{T}dataset{M}translation"
    if context:
        p += f"{T}context{M}{context}"
    for s, t in history:
        p += f"{T}input{K}lang{V}{src}{M}{s}{T}output{K}lang{V}{tgt}{M}{t}"
    if glossary:
        p += f"{T}glossary" + "".join(f"<|plamo:index|>{g['source']}<|plamo:item|>{g['target']}" for g in glossary)
    return p + f"{T}input{K}lang{V}{src}{M}{text}{T}output{K}lang{V}{tgt}{M}"
```

## 2. 推論手段の候補と可否

| 手段 | 結果 | 要点 |
|---|---|---|
| llama.cpp CLI / サーバー（GGUF） | **成功** | Homebrew 1.0.0 で 0.8B・2B・8B が動作 |
| llama.cpp を Swift から同一プロセスで（whisper.cpp と ggml を共有） | **成功（試作）** | CLT の `swiftc` で、Whisper の文字起こしと PLaMo の翻訳を 1 プロセスで実行 |
| mlx-lm（Python） | **成功** | PFN 同梱の `modeling_plamo_mlx.py` を読み込む。llama.cpp より遅く、メモリも多い |
| mlx-swift / mlx-swift-lm | **不可** | CLT だけでは Metal シェーダをビルドできない。PLaMo 3 のモデル実装とトークナイザーも無い |
| その他（Ollama・LM Studio・ONNX・LiteRT など） | 試していない | 外部アプリが要るか非公式の変換なので候補から外した |

### 2.1 llama.cpp（GGUF）

- 対応状況: `plamo3` アーキテクチャは 2025-12（#17304）から入っている。ただし PLaMo 3 Translate を正しく動かすには、その後の 2 つの修正が要る:
  - #30045「PLaMo-3 tokenizer pre-segmentation」（2026-10-06 マージ）
  - #30206「ggml: support `truncate=false` for YaRN」（2026-11-05 マージ。**ggml 本体の変更**で、`ggml_rope_set_truncate()` の追加と `ggml_rope_yarn_corr_dims()` の削除を含む）

  Homebrew の 1.0.0（b1b770d90）は両方を含むことを GitHub の compare で確かめた。
- 試したコマンド:

  ```
  brew install llama.cpp                       # 1.0.0。ggml 1.0.0 も入る
  llama-server -m plamo-3-translate-2b-Q4_K_M.gguf -c 8192 --port 8765 -np 1 --no-webui
  # POST /completion {"prompt": <PFML3>, "n_predict": 256, "temperature": 0,
  #                   "stop": ["<|plamo:tag|>", "<|plamo:bos|>"], "cache_prompt": false}
  llama-bench -m ... -ngl 0 -t 4 -p 160 -n 32  # CPU のみの参考値
  ```

  結果: 成功。0.8B / 2B / 8B（いずれも PFN 公式の Q4_K_M）で 26 文 × 3 条件をすべて訳せた。
- **xcframework にして Swift から呼ぶ道**: 見通しは良い。ただし今の `tools/whisper.xcframework` をそのまま残して llama を足す形は避ける（下の「ggml の重複」）。
  - Homebrew は whisper.cpp 1.9.5 と llama.cpp 1.0.0 を、同じ `libggml` 1.0.0（`/opt/homebrew/opt/ggml/lib/libggml.1.dylib`）にリンクしてビルドしている（`otool -L` で確認）。つまり **whisper.cpp 1.9.5 は新しい ggml 1.0.0 でビルドでき、動く**。今回の同時実行の計測にもこの whisper-cli を使った。
  - AutoNote の `scripts/build-whisper-xcframework.sh` は whisper.cpp v1.9.5 同梱の ggml（2026-10-06 時点）を whisper.framework の dylib に静的に取り込んでいる。この ggml には上の YaRN の修正が無いので、**今の whisper.framework の ggml では PLaMo 3 Translate を正しく動かせない**。whisper.cpp master の ggml（2026-11-05 に同期）にもまだ入っていない（`ggml.h` を確認）。
- **ggml の重複の見通し**:
  - 案 A（推奨）: ggml を 1 つにまとめる。ggml（llama.cpp 側の新しいもの）を 1 回ビルドし、whisper.cpp を `WHISPER_USE_SYSTEM_GGML`、llama.cpp を `LLAMA_USE_SYSTEM_GGML` 相当で同じ ggml に向け、静的ライブラリを 1 つの framework（例: whisper と llama の両方のヘッダを持つ framework）にまとめる。Homebrew の構成と同じなので実績がある。Whisper の CER と速度は `scripts/bench-whisper.sh` で回帰を確かめる必要がある。
  - 案 B: whisper.framework と llama.framework を別々の dylib にし、それぞれに ggml を静的に取り込む。two-level namespace なのでシンボルの衝突自体は起きにくいが、ggml の Metal デバイスとバックエンド登録が 2 重になり、両方の module map が `ggml.h` を公開するので、同じ Swift モジュールから両方を import すると型の重複が起きうる。試していない。避けたい。
  - 案 C: `llama-server` を補助プロセスとしてアプリに同梱し、HTTP で呼ぶ。AutoNote はすでに `claude` を子プロセスで呼んでいるので構造は合う。リンクの問題は無くなるが、同梱バイナリの署名・公証、ポート管理、起動停止の面倒が増える。案 A がうまくいかない場合の退避先。
- xcframework を作るには今の whisper と同じく `xcodebuild` が要る（Xcode が要る）。リリースは GitHub Actions でビルドしているので、手元に Xcode が無くても配布には困らない。

### 2.2 Swift からの呼び出し（試作で確認）

Homebrew のヘッダとライブラリを使い、ブリッジングヘッダ（`whisper.h` と `llama.h`）で Swift から直接呼ぶ試作を CLT だけでビルドして動かした（リポジトリ外 `~/Library/Caches/autonote-plamo-spike/swift-probe/`）。

```
swiftc -O -import-objc-header bridge.h -I /opt/homebrew/include -L /opt/homebrew/lib \
  -lwhisper -lllama -lggml -lggml-base -Xlinker -rpath -Xlinker /opt/homebrew/lib main.swift -o probe
./probe ggml-large-v3-turbo.bin plamo-3-translate-2b-Q4_K_M.gguf ja30.f32
```

- 結果: 成功。large-v3-turbo の読み込み 0.41 秒、30 秒の音声の文字起こし 0.53 秒、続けて同じプロセスで PLaMo 2B を読み込み 0.97 秒、3 区間の和訳 0.71 秒。最大 RSS 4.05 GB、peak memory footprint 2.23 GB。
- 分かった注意点:
  - Homebrew の ggml はバックエンドを動的モジュールとして読み込む作りなので、最初に `ggml_backend_load_all()` を呼ばないと GPU も CPU も見つからず落ちる。AutoNote の xcframework のように静的に取り込むビルドなら不要。
  - 終了前に `llama_free` / `llama_model_free` / `whisper_free` を呼ばないと、終了時に `ggml-metal-device.m:1041: GGML_ASSERT([rsets->data count] == 0)` で abort する。アプリでは翻訳エンジンの破棄の順序を決めておく。
  - API は `llama_tokenize`（`parse_special=true` で PFML3 の特殊トークンを解釈）→ `llama_decode` → `llama_sampler_sample`（greedy）→ `llama_token_to_piece`。文ごとに `llama_memory_clear` で KV キャッシュを消した。

### 2.3 MLX

- mlx-lm（Python）:

  ```
  uv venv --python 3.12 venv && uv pip install mlx-lm mlx transformers numba
  # load(dir, trust_remote_code=True, tokenizer_config={"trust_remote_code": True})
  # stream_generate(model, tok, prompt=<PFML3>, max_tokens=256, sampler=make_sampler(temp=0))
  ```

  結果: 成功（0.8B・2B の PFN 公式 MLX-4bit）。ただし `config.json` の `model_file` で PFN 同梱の `modeling_plamo_mlx.py`（mlx-lm を改変。「Source-compatible PLaMo translation YaRN, normalization and window boundaries」）を読み込む作りで、mlx-lm 本体の `plamo3.py` ではない。トークナイザーも同梱の `tokenization_plamo.py`（`tokenizer.jsonl` の独自形式）を transformers の `trust_remote_code` で使う。
- mlx-swift: 最小のパッケージ（mlx-swift 0.33.0 の `MLX` に依存）を `swift build -c release` すると、`error: unable to spawn process 'metal' (No such file or directory)` / `CompileMetalFile ... steel_attention.metal failed` で失敗した。CLT には `metal` コンパイラが無い（`xcrun -f metal` も失敗）。Xcode があればビルドできる見込みだが、今の Mac では確かめられない。
- mlx-swift-lm（3.32.3、2026-09-30）の `Libraries/MLXLLM/Models` に PLaMo は無い。Swift で使うには `modeling_plamo_mlx.py` と PLaMo のトークナイザー（swift-transformers の tokenizers 形式ではない）を Swift に移植する必要がある。
- MLX は Apple Silicon 専用。AutoNote は Intel（x86_64）も支える（whisper.xcframework は x86_64 を含む）ので、MLX だけでは Intel 機で翻訳できない。
- 速度・メモリとも、この機械では llama.cpp の方が良かった（下の表）。

## 3. 実測

### 3.1 モデルのサイズ・ロード時間・メモリ

| 手段 | モデル | ファイル | ロード | 最大 RSS | peak memory footprint |
|---|---|---|---|---|---|
| llama.cpp | 0.8B Q4_K_M | 0.57 GB | 1.04 秒 | 0.92 GB | 0.29 GB |
| llama.cpp | 2B Q4_K_M | 1.81 GB | 1.24 秒 | 2.84 GB | 0.98 GB |
| llama.cpp | 8B Q4_K_M | 5.28 GB | 1.64 秒 | 6.61 GB | 1.28 GB |
| mlx-lm | 0.8B MLX-4bit | 0.98 GB | 3.36 秒（初回） | 1.30 GB | 1.69 GB（MLX のピーク 1.35 GB） |
| mlx-lm | 2B MLX-4bit | 2.41 GB | 1.49 秒 | 2.73 GB | 3.47 GB（MLX のピーク 3.06 GB） |

- ロード時間は `llama-server` の起動から `/health` が返るまで（MLX は `load()` の時間）。
- メモリは `/usr/bin/time -l` の値で、`llama-server` はコンテキスト 8,192 トークン。llama.cpp は GGUF を mmap するので、RSS にはファイルの内容（追い出せるページ）が入り、footprint は主に KV キャッシュと計算用バッファ。おおむね「ファイルサイズ + 0.3〜1.3 GB」が要ると見ればよい。
- 31B（ダウンロードしていない。公式の数値からの見積もり）: GGUF Q4_K_M 19.5 GB、MLX-4bit 18.7 GB。メモリ 32 GB 機では Whisper と同居させる余裕が無く、48 GB 以上が前提。生成速度はメモリ帯域で決まるので、8B（約 48 トークン/秒）の 8/31 として **M5 Pro で約 12 トークン/秒、1 発話 1.5〜2 秒**の見込み。会議の翻訳の既定には向かない。

### 3.2 翻訳速度

テスト文は自作の架空の会議（日→英 14 文、英→日 12 文。話し言葉・言い淀み・固有名詞・文脈に依存する短い発話を含む）。条件は 3 つ:

- 単独: 1 文だけを訳す（プロンプト約 30 トークン）
- 履歴: 直前 3 組の原文と（同じ条件でモデルが出した）訳を履歴として渡す（約 135〜150 トークン）
- 全部: 履歴 + 場面の説明（context）+ 用語集 1 語（約 165〜180 トークン）

1 文あたりの所要時間（HTTP 往復込み、中央値。括弧内は最大）と生成速度:

| 手段 | モデル | 単独 | 履歴 | 全部 | 生成 トークン/秒 |
|---|---|---|---|---|---|
| llama.cpp | 0.8B | 49〜52 ms（73） | 54〜57 ms（102） | 56〜57 ms（81） | 357 |
| llama.cpp | 2B | 135〜139 ms（205） | 158〜164 ms（233） | 164〜166 ms（224） | 133 |
| llama.cpp | 8B | 368〜388 ms（572） | 430〜467 ms（680） | 470〜511 ms（740） | 44〜48 |
| mlx-lm | 0.8B | 82〜83 ms（191） | 89〜93 ms（136） | 93〜97 ms（179） | 232 |
| mlx-lm | 2B | 188〜195 ms（289） | 222〜227 ms（313） | 226〜232 ms（318） | 97 |

（範囲は日→英と英→日の値）

- プロンプト処理は 2B で 2,000〜2,500 トークン/秒なので、履歴を 3 組渡しても 1 文あたり 30 ms ほど増えるだけ。
- 1 時間の会議（発話 600〜900 件と仮定）を録音後にまとめて訳すと、2B で 2〜3 分、8B で 6〜8 分、0.8B で 1 分弱。
- CPU のみ（`llama-bench -ngl 0 -t 4`、Metal を使わない参考値）: 0.8B はプロンプト 317 / 生成 144 トークン/秒、2B はプロンプト 76 / 生成 33 トークン/秒。Intel 機は測っていない。Intel の i7（4 コア）はこれよりさらに数倍遅いと見て、**2B で 1 文 2〜4 秒、0.8B で 1 秒前後**の見込み（未検証）。Intel 機は録音後にまとめて訳す、既定は 0.8B が現実的。

### 3.3 Whisper との同時実行

Homebrew の whisper-cli 1.9.5（large-v3-turbo、f16、Metal、既定のビーム探索）で、`say` で合成した日本語 296 秒（`scripts/samples/ja-5min.txt` の読み上げ）を文字起こしし、その間に llama-server で 26 文 × 3 条件の翻訳を途切れなく回し続けた（実際の会議よりずっと重い、最悪寄りの負荷）。

| 条件 | Whisper の所要時間 | 翻訳 1 文の中央値（p90） | 生成 トークン/秒 |
|---|---|---|---|
| Whisper のみ | 9.80 秒 / 8.74 秒（実時間比 約 0.03） | — | — |
| Whisper + 2B を連続 | 17.78 秒 / 15.79 秒（1.7〜1.9 倍） | 175 → **241 ms**（224 → 388） | 124 → 78 |
| Whisper + 0.8B を連続 | 12.12 秒 / 13.25 秒（1.3〜1.4 倍） | 61 → **91 ms**（90 → 158） | 330 → 213 |

- GPU を取り合うので互いに遅くなるが、どちらも実用の範囲に収まる。実際の会議では発話は 1 分に 10〜20 件程度で、2B でも翻訳が GPU を使うのは 1 分あたり数秒。Whisper の実時間比は 0.03 → 0.06 程度に下がるだけで、録音中の文字起こしが追いつかなくなる心配は M5 Pro では無い。
- 低い機種（M1 / 8 GB など）や Intel 機では測っていない。メモリは 2B（約 1.8 GB + 1 GB）と large-v3-turbo（約 1.6 GB）を合わせて 4〜5 GB なので、8 GB 機では 0.8B か録音後の翻訳にするのが安全。

### 3.4 訳の質

全 26 文 × 3 条件 × 各モデルの訳はリポジトリ外 `~/Library/Caches/autonote-plamo-spike/notes/compare-all.txt`（llama.cpp）と `compare-0.8b-2b.txt`（MLX の 2B を含む）にある。目立った違いが出た文だけ抜き出す（すべて llama.cpp の Q4_K_M）。

| 原文 | 0.8B 単独 | 0.8B 全部 | 2B 単独 | 2B 全部 | 8B 単独 | 8B 全部 |
|---|---|---|---|---|---|---|
| We moved about sixty percent of the tenants over the weekend, and, uh, nothing major broke. | 入居者の6割くらいを入れ替えた（誤） | テナントの6割ほどを移行しました | 入居者の6割ほどを入れ替えた…大きな破損はなかった（誤） | テナントの約60%を移行しましたが、えー、特に大きな問題は起きませんでした | 入居者の6割くらいを入れ替えた（誤） | テナントの6割ほどを移行しましたが、えー、特に大きな問題は起きませんでした |
| Are we still on track to cut over the rest by the end of the month? | 残りを切り捨てる予定で（誤） | 残りの分を切り捨てる予定で（誤） | 残りをカットする計画は（不自然） | 残りをカットする計画は（不自然） | 残りも今月末までに切り上げる（誤） | 残りの移行も…今月末までに間に合う見込みでしょうか |
| It slipped twice already, right? | もう2回も滑ったんだよね？（誤） | もう2回も漏れてるんだよね？（誤） | もう2回も滑ったよね？（誤） | もう2回も滞ったんですよね？ | もう2回も滑ったよね？（誤） | もう2回もずれ込んでますよね？ |
| Put me down. I'll take it. | 下ろして。もらうよ。（誤） | 降ろして。もらうよ。（誤） | 降ろして。乗るよ。（誤） | 私を指名してください。引き受けます。 | 書いておいて。もらうよ。（半分） | 入れておいて。引き受けるよ。 |
| そっちはまだ、えー、決済代行のほうの返事待ちで。 | As for that, I'm still waiting for a response from the payment processor. | …waiting for a response on the payment processing side. | As for me, I'm still waiting…（誤） | As for those, we're still—uh—waiting to hear back from the payment processor. | We're still, uh, waiting for a response from the payment processor. | We're still, uh, waiting on a response from the payment processor. |
| 来週の水曜までに返事がなかったら、高橋さんから直接電話してもらえますか。 | …could you call me directly, Mr. Takahashi?（誤） | 同左（誤） | 同左（誤） | …could you have Mr. Takahashi call you directly? | …could you call me directly, Mr. Takahashi?（誤） | …could you call me directly, Takahashi-san?（誤） |
| じゃあ、それは私が持ちます。 | Then I'll take it. | In that case, I'll take it on. | I'll take that, then. | In that case, I'll take it. | Then I'll take that. | Then I'll cover that. |

所見:

- **言い淀み**（えーと、uh, um）は訳文にも「えー」「Um」として残る。議事録用には残らない方が読みやすい場面もあるので、必要なら訳す前に Whisper の出力から言い淀みを取るか、訳した後に取る。
- **固有名詞**（Kestrel・Atlas・Contoso・Priya・Postgres・SSO・CTO）はどのモデルでもほぼ正しく残った。用語集の効果は今回の文では確かめきれなかった（ケストレル → Kestrel は用語集なしでも Kestrel になった）が、表記を固定したい語に使える。「全部」では Priya → プリヤ とカタカナにされることがあった。
- **文脈に依存する短い発話**（Put me down. / It slipped twice / cut over）は、単独ではどのサイズでも誤訳が多い。**履歴を渡すと 2B・8B は正しくなる**が、0.8B は直らないものが残る（cut over → 切り捨てる）。「履歴」だけ（context なし）でも 0.8B・2B とも Put me down. I'll take it. → 「任せて。引き受けるよ。」になったので、効いているのは主に履歴。
- 「高橋さんから直接電話してもらえますか」は依頼の向きが曖昧な文で、2B の「全部」だけが「高橋さんに電話してもらう」と読めた。人間でも前後の文脈が要る文なので、ここは差の目安程度。
- 「全部」（context あり）にすると英→日の訳が **です・ます調に寄る**（単独・履歴ではくだけた口調）。会議の議事録用なら `form=polite` を明示して揃えるのがよい。
- GGUF と MLX の訳が文字列として完全に一致したのは、2B で 78 件中 52 件、0.8B で 33 件（履歴条件では前の訳の違いが後に伝わる）。違いの多くは語の選び方や句読点で、誤訳の有無が入れ替わったのは 2B では数件（例: 「そっちはまだ…」の単独で GGUF は As for me（誤）、MLX は I'm still waiting…over there）。量子化形式による質の差は小さい（公式の表でも 2B の Q4_K_M と MLX-4bit は BF16 との差が 0.01 未満）。
- 総合すると、**2B + 履歴 3 組**が速度と質のバランスが最もよい。8B は単独でも 2B より少し良く、履歴付きではさらに自然だが、2B + 履歴との差は「全部」条件ではわずか。0.8B は単独なら 2B とそれほど変わらないが、文脈の効きが弱い。

## 4. ライセンス（PLaMo コミュニティライセンス、2026-11-09 改定版）

モデルの重みは PLaMo Community License（本文は各モデルの `LICENSE/ja`、https://plamo.preferredai.jp/info/plamo-community-license-ja ）。AutoNote のコード（MIT）とは別に、モデルを使う利用者に適用される。

- **個人・非商用（学術を含む）**: 無料、事前登録不要。
- **商用**: 「商業目的」には **利用者の組織内部での利用も含まれる**（第 1 条 (10)）。つまり AutoNote の利用者が会社の会議で使う場合は商用にあたり、利用者側で次が要る:
  - 直近事業年度の売上・収入が 10 億円以下: PFN の登録フォーム（https://forms.gle/mTL8tBLrMYXKNZD56 ）に**事前登録**すれば無料（第 3 条 (3)）。
  - 10 億円超: PFN と別途の契約が要る。
- **再配布**（第 4 条）: 本モデルや派生モデルを第三者に提供する場合は、ライセンスのコピーの提供、「Built with PLaMo」の表示、派生モデル名に「PLaMo」を含めることが要る。**AutoNote がモデルを同梱せず、利用者が Hugging Face から取得する形**なら、AutoNote が本モデルを提供することにはならないと読めるが、取得の前に利用者がライセンスに同意する手順を置き、アプリの UI か README に「Built with PLaMo」を書いておくのが安全。量子化した GGUF を自分で作って配る（派生モデルの提供）のは避け、PFN 公式のファイルをそのまま取得させる。
- **生成物（訳文）**（第 5 条）: 翻訳モデルは「変換モデル」にあたり、訳文は PLaMo の生成物だと明示せずに公表してよい。ただし書籍・論文などの長文の公表物の全部や主要部分にする場合は、PLaMo を翻訳に使った旨を奥付などに書く。訳文を使ってモデルを学習すると派生モデルになる。
- その他: 法律・医療・金融・人物評価などの重要な決定で生成物を唯一の根拠にしない（第 7 条 (2)）。PFN は契約を変更できる（第 12 条）。準拠法は日本法。
- llama.cpp・ggml・mlx・mlx-lm は MIT。PFN の `modeling_plamo_mlx.py` は mlx-lm（MIT）の改変を含む。

アプリに入れるなら、モデルのダウンロード画面に「PLaMo Community License への同意」「業務で使う場合は PFN への事前登録が必要（売上 10 億円以下は無料）」「Built with PLaMo」を出すのが最低限。

## 5. 推奨

1. **既定モデル**: 2B Q4_K_M（1.81 GB）。選択肢として 0.8B Q4_K_M（0.57 GB、Intel 機・8 GB 機の既定）と 8B Q4_K_M（5.28 GB、16 GB 以上の Apple Silicon 向けの高品質版）を置く。31B は対象外。根拠: 3.2〜3.4 節。2B は履歴付きで 0.8B より明らかに良く、8B との差は小さい。速度は M5 Pro で 1 発話 0.16 秒前後、Whisper と同時でも 0.24 秒。
2. **推論手段**: llama.cpp を同一プロセスで使う。whisper.cpp と llama.cpp を**同じ ggml（PLaMo の YaRN の修正を含む 2026-11-05 以降のもの）でビルドし直し**、1 つの xcframework にまとめる（2.1 節の案 A）。Homebrew が同じ構成で動いていること、CLT の Swift から両方を呼べることは確かめた。うまくいかない場合は `llama-server` を補助プロセスとして同梱する案 C に退く。MLX は Swift 側の対応が無く、Intel でも動かないので採らない。
3. **いつ訳すか**: 録音後に確定版の文字起こしをまとめて訳す（1 時間の会議で 2B なら 2〜3 分）。各発話に直前 3 組の原文と訳を履歴として付け、日本語に訳すときは `form=polite` を指定する。用語集の元には、文字起こしに渡している認識のヒント（Whisper の `initial_prompt`、Apple の `contextualStrings`）の語が使えるかもしれない（訳語は別に要る）。録音中の逐次訳は速度の面では可能だが、リアルタイムの文字起こしは確定版で置き換わるので、まずは入れない。入れるなら Apple Silicon 限定の任意機能にする。
4. **大まかな工数**（実装 1 人、合計 1.5〜2.5 週間）:
   - ggml を共有する xcframework の作り直しと CI（release.yml）の更新、Whisper の CER・速度の回帰確認: 2〜4 日（**最大の危険点**）
   - Swift の翻訳エンジン（PFML3 の組み立て、履歴の窓、停止文字列、取り消し、破棄の順序）とテスト: 2〜3 日
   - モデルの一覧とダウンロード（`WhisperModel` と同じ sha256 固定の仕組みを流用）、ライセンス同意の表示: 1〜2 日
   - 訳文の保存・表示・書き出しの UI: 2〜4 日
5. **危険点**:
   - ggml の版: PLaMo 3 Translate は 2026-11-05 以降の ggml が要る。whisper.cpp の公式リリース（v1.9.5）はまだそれより古い ggml を同梱しているので、whisper.cpp を自前で新しい ggml に向けてビルドする必要がある。その後の ggml の API 変更（今回も `ggml_rope_yarn_corr_dims` が消えた）で whisper.cpp がビルドできなくなる可能性がある。
   - Metal の後始末: コンテキストを解放しないと終了時に abort する（2.2 節）。アプリの終了やモデル切り替えの経路で確実に解放する。
   - GGUF ファイルの更新: PFN は公開 3 日後にチャットテンプレートを変えて GGUF を差し替えている。sha256 と Hugging Face のリビジョンで固定する。
   - Intel 機は未測定。CPU のみで 2B は 1 文数秒の見込みで、録音後にまとめて訳しても 1 時間の会議に 30 分以上かかりうる（0.8B なら 15 分前後の見込み）。Intel では 0.8B を既定にし、実機で測ってから決める。
   - 言い淀みや Whisper の幻覚（無音区間の決まり文句など）もそのまま訳される。訳す前に除く処理が要るかもしれない。
   - ライセンス: 業務利用は利用者側の事前登録が要る。利用者に伝わる表示を用意しないと、利用者が知らずに違反する形になる。

## 付録: 置き場所

リポジトリ外 `~/Library/Caches/autonote-plamo-spike/`（合計 約 11 GB）:

- `models/pfnet/`: 0.8B・2B・8B の GGUF Q4_K_M、0.8B・2B の MLX-4bit（計 約 10.3 GB）
- `venv/`（533 MB）: mlx-lm の Python 環境
- `scripts/`: PFML3 の組み立て（`pfml.py`）、計測（`bench_llama.py`・`bench_mlx.py`・`run_llama.sh`・`concurrent.sh`）、集計（`summarize.py`・`compare.py`・`conc_summary.py`）、テスト文（`sentences.json`）
- `results/`: 各訳と計測値の JSONL
- `notes/`: モデルカード・ライセンス本文・サーバーのログ・訳の比較表
- `swift-probe/`: Swift から whisper と llama を呼んだ試作
- `mlxswift-probe/`（139 MB）: mlx-swift のビルドを試したパッケージ
- `audio/`: `say` で合成した日本語のサンプル音声

ほかに Homebrew で `llama.cpp` 1.0.0、`ggml` 1.0.0、`whisper.cpp` 1.9.5 を入れた（`brew uninstall llama.cpp whisper.cpp ggml` で消せる）。
