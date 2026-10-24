# AutoNote 調査: 文字起こしエンジンと Claude Code 非対話呼び出し

調査日 2026-10-24。「確認」= 一次情報で確認、「推測」= 根拠からの私見、「未確認」= 見つからず。

## A. whisper.cpp

### A1. Intel Mac のバックエンド
- 結論: Intel Mac では **CPU（AVX/AVX2）実行が現実解**。Metal・Core ML・ANEForge は Apple Silicon 向け。Intel Iris Plus での Metal 利用は **未確認**（README に Intel GPU の Metal 動作の記述なし。推測: 動いても速くない／不安定の可能性。要実機検証）。
- 根拠:
  - README「macOS (Intel and Arm) 対応」「Apple Silicon: ARM NEON, Accelerate, Metal, Core ML で最適化」「x86: AVX intrinsics」「Metal は Apple Silicon で推論を完全に GPU 実行」「Core ML / ANEForge は ANE 利用（Apple Silicon）」: https://github.com/ggml-org/whisper.cpp
  - OpenVINO（Intel CPU/GPU のエンコーダ高速化）は Linux/Windows 向けの別経路。macOS での利用は未確認。
- 不確かな点: Intel Mac + Metal（Iris Plus）の実測。Core ML が Intel Mac で動くか（ANE が無いので CPU/GPU にフォールバックするが利点は小さいと推測、未確認）。

### A2. モデル別速度（Intel クアッドコア）
- 結論: 実測値は Intel Mac のものが見つからず、**他の Intel CPU の `bench` エンコード時間（30 秒窓あたり）から推定**。
  | CPU | モデル | スレッド | エンコード時間 |
  |---|---|---|---|
  | i7-4790K 4C/8T | tiny.en / base.en | 4 | 0.81 s / 1.81 s |
  | i7-11800H 8C (WSL2, AVX2) | tiny / base / small / large | 4 | 0.73 / 1.83 / 6.0 / 38.5 s |
  | i5-1135G7 4C (Win) | medium | 8 | 24.9 s |
  | i5-8250U 4C (Win) | large | 8 | 61.5 s |
  - 窓長は 30 秒の想定（ページに明記なし）。上は **エンコーダのみ**。デコード時間が別途加わる。
- 推定（推測）: i7-1068NG7（Ice Lake 4C、AVX2/AVX512 あり）は 1135G7 と同世代。
  - tiny/base/small: エンコード実時間比 ≈ 0.03〜0.3 → **リアルタイム可**。small は余裕が薄く、デコード・同時の録音処理込みで 0.3〜0.5 程度と見る。
  - medium: エンコードだけで ≈ 0.8 → デコード込みで **1.0 前後〜超過。リアルタイムは不可**、会議後バッチなら可（RTF 約 1〜1.5 → 2 時間会議で 2〜3 時間）。
  - large-v3 / large-v3-turbo: エンコーダは large 同サイズなので **RTF 1.3〜2 超（バッチでも 2 時間会議が 3 時間以上）**。turbo はデコーダが軽いだけでエンコーダは同等 → 大差なし（推測）。量子化（q5_0/q8_0）での高速化・精度劣化の Intel 実測は **未確認**。
- 結論の目安: **リアルタイム用は small（q5_1/q8_0 検討）、base は保険。会議後の高精度版は medium または large-v3-turbo を「放置バッチ」で。**
- 根拠: whisper.cpp Issue #89 ベンチ集 https://github.com/ggml-org/whisper.cpp/issues/89
- 不確かな点: 1068NG7 での実測全般、スレッド数・発熱によるスロットリング（MacBook Pro 13 インチ想定、持続負荷で低下の恐れ）。**実装前に `whisper-bench` を実機で取る前提にすべき。**

### A3. 日本語精度と日英混在
- 結論: モデルが小さいほど日本語は急に悪化。OpenAI Whisper（PyTorch 版）の CER の参考値: CommonVoice8 日本語で large-v3 8.5 / medium 11.5 / small 15.1、より難しい ReazonSpeech で large-v3 14.9 / medium 33.2 / small 41.5（%）。→ **small は会議音声では誤りが目立ち「実用の下限」、清書用には medium 以上が望ましい**（推測を含む）。large-v3-turbo の日本語 CER は **未確認**。
  - 根拠: https://japanese-asr-readme.static.hf.space/ （whisper.cpp 版ではなく元モデルの値。量子化の影響は未確認）
- 日英混在: 言語を `ja` 固定にするとカタカナ化・英語欠落、`auto` だとセグメント単位で言語が揺れる。Whisper 公式にコードスイッチング専用機能はない（一般知識、一次情報の確認は未実施 → **未確認**）。対策案: 日本語固定 + initial prompt に英語語彙を混ぜる、会議後に Claude で補正。

### A4. ストリーミングと Swift 連携
- 結論:
  - 公式 `stream` / `whisper-stream` はマイク入力を SDL2 で取り、`--step`（既定 3000ms）、`--length`（既定 10000ms）、`--keep`（200ms）のスライディング窓で再推論。`--step 500 --length 5000` 例あり。`-kc` でコンテキスト保持（既定オフ）。窓ごとに再推論するため CPU 負荷が高く、Intel では **small でも窓を長めに（step 3〜5 秒）** が現実的（推測）。
  - VAD: Silero-VAD 対応（`--vad`、`--vad-threshold`、`--vad-min-silence-duration-ms` 等、`download-vad-model.sh`）。無音スキップで負荷と幻覚（無音時の誤出力）を減らせる。
  - Swift: **XCFramework 公式配布**（iOS/visionOS/tvOS/macOS、SPM の binaryTarget 例あり）。リポジトリに `examples/whisper.swiftui`, `whisper.objc`。サードパーティの SwiftWhisper は存在するが今回は詳細未確認。
  - 設計案（推測）: アプリ側で AVAudioEngine/ScreenCaptureKit 録音 → 16kHz mono PCM → 自前で VAD 区切り → whisper.cpp を数秒チャンクで呼ぶ。stream サンプルの SDL2 依存は避けられる。
- 根拠: https://github.com/ggml-org/whisper.cpp ; https://github.com/ggml-org/whisper.cpp/discussions/166（stream 初出と引数）
- 不確かな点: XCFramework が Intel(x86_64) スライスを含むか **未確認**（最新リリースの中身を要確認。含まない場合は自前ビルド）。SwiftWhisper の保守状況。

### A5. 固有名詞対策（initial prompt）
- 結論: `--prompt`（API では `initial_prompt`）に人名・社名・製品名を並べると、それらの綴りへ寄せる効果がある、というのが一般的な知見。上限は Whisper の仕様上、プロンプトに使えるのは **約 224 トークン（n_ctx の半分）** で超過分は切り捨て（一般知識。今回の一次情報では確認できず **未確認**）。日本語は 1 文字 1〜2 トークン消費のため、辞書語は **100〜150 語程度が目安**（推測）。
- 不確かな点: 効果は確実ではなく、長いプロンプトは幻覚・繰り返しを誘発することがある。会議後に Claude で用語集を使って補正する二段構えが堅実。

### A6. 単語タイムスタンプ・話者分離
- 結論: 単語単位は `-ml 1`（`--max-len 1`）、実験的。話者分離は **tinydiarize（`-tdrz`、`small.en-tdrz` など）で、話者交代点 `[SPEAKER_TURN]` を出すのみ**。対応モデルは英語のみ想定で **日本語は実質不可**（モデル名から推測、日本語対応版は未確認）。話者の同定（誰が話したか）は不可。
- 代替案（推測）: マイク（自分）とシステム音声（相手）を別チャンネルで録音し、チャンネルで「自分/相手」を区別するのが安価で確実。
- 根拠: https://github.com/ggml-org/whisper.cpp

## B. 代替エンジン
- 結論:
  - **WhisperKit は Apple Silicon 専用**（Intel 非対応）。MacWhisper ヘルプ: M シリーズのみ。Homebrew の whisperkit-cli は arm64 のみ。
    - https://macwhisper.helpscoutdocs.com/article/29-switching-to-a-whisperkit-model ; https://formulae.brew.sh/formula/whisperkit-cli
  - **MLX Whisper**: MLX は Apple Silicon 向けフレームワーク。Intel での動作は **未確認**（推測: 不可）。
  - Intel Mac での現実的な代替: whisper.cpp 以外では faster-whisper（CTranslate2、CPU/int8）が候補だが、今回 Intel Mac 上の実測・対応状況は **未確認**。Apple の SpeechAnalyzer / SFSpeechRecognizer（macOS 26 のオンデバイス音声認識）も候補だが、Intel 対応と日本語精度は **未調査**。
- 設計への示唆: 将来 Apple Silicon 対応を見据え、エンジンを抽象化（プロトコル）して whisper.cpp（Intel/共通）と WhisperKit（Apple Silicon）を差し替え可能にするのが妥当（推測）。

## C. Claude Code 非対話呼び出し

### C1. `claude -p` の使い方（確認済み）
- 結論:
  - stdin で渡せる: `cat file | claude -p "指示"`。
  - 出力: `--output-format text|json|stream-json`。json は `result`, `session_id`, `total_cost_usd` 等を含む。stream-json は `--verbose`（+ `--include-partial-messages`）併用。
  - システムプロンプト: `--system-prompt`（全置換）/ `--append-system-prompt`（追記）/ 各 `-file` 版。
  - `--model`（sonnet/opus/haiku/フルネーム）、`--max-turns`（print 専用、超過で異常終了）、`--fallback-model`、`--max-budget-usd`、`--no-session-persistence`（セッション保存なし）。
  - ツール: `--tools ""` で全ビルトインツール無効、`--allowedTools`（承認不要化）、`--disallowedTools`（`"*"` で全ツール除去）。
  - 作業ディレクトリ: 呼び出しプロセスの cwd（`Process.currentDirectoryURL` で指定）。追加ディレクトリは `--add-dir`。
  - `--bare`: hooks/skills/MCP/CLAUDE.md/自動メモリを読まず高速・再現性高。**ただし OAuth/キーチェーンを読まず ANTHROPIC_API_KEY が必須** → サブスク認証では使えない。サブスクで使うなら `--bare` なしで `--setting-sources` や `--strict-mcp-config` 等で絞る（推測）。
  - 終了コード: 成功 0、失敗は非 0。未認証等の実行時エラーは **stdout に結果として出る**（stderr ではない）点に注意。SIGTERM は 143。
- 根拠: https://code.claude.com/docs/en/headless ; https://code.claude.com/docs/en/cli-reference

### C2. 長い文字起こしの渡し方
- 結論: **パイプ stdin は 10MB 上限**（超過はエラー終了）。日本語 2 時間分（数万〜10 万文字弱、UTF-8 で数百 KB）は上限内。コンテキスト窓（トークン）の上限はモデル依存で今回 **未確認**。数万文字は通常収まるが、超長時間は分割要約（map-reduce）を設計に入れる。
- stdin vs ファイル Read 比較（推測）: stdin はツール不要（`--tools ""` で安全・高速・1 ターン）。ファイル参照は Read ツールが必要で、ツール許可とターン数が増え、巨大ファイルは分割読みになる。**議事録生成は stdin 渡し + ツール無効が最適。** 10MB 超のみファイル渡し。

### C3. GUI アプリから呼ぶときの注意
- PATH: GUI アプリ/launchd は対話シェルの PATH を継承しない。`claude` はネイティブバイナリ（`~/.local/bin/claude` 等）の **絶対パスを設定で持たせる**か、`zsh -lc` 経由で起動（推測。インストール先は環境依存）。
- 認証: `claude auth status` が JSON を返し、未ログインは終了コード 1。`authMethod` は none/claude.ai/oauth_token 等。起動前チェックに使える。ログインは対話操作が必要なので、アプリ側は「ターミナルで `claude` を実行してログイン」と案内する。`claude setup-token` で長期 OAuth トークン（要サブスク）を発行でき CI・スクリプト向け（環境変数名は **未確認**: 一般に `CLAUDE_CODE_OAUTH_TOKEN`）。
- 未認証時: `claude -p` は非 0 終了し、エラーが結果として stdout に出る（上記 C1）。
- 同時実行: 公式に明示の制限記述は **未確認**。`--no-session-persistence` でセッション競合を避け、アプリ側で直列化（キュー）するのが安全（推測）。サブスクの利用上限（5 時間枠）にも注意。
- 追加: `-p` は cwd のプロジェクト設定（hooks・.mcp.json）を信頼ダイアログなしで実行するため、**空のディレクトリを cwd に指定**するのが安全（公式記述あり）。

### C4. 構造化出力
- 結論: **あり**。`--output-format json --json-schema '<schema>'` で、検証済みの結果が応答 JSON の `structured_output` に入る。議事録を「要約 / 決定事項 / ToDo / 議題別」等のフィールドで確実に分けて受け取れる。スキーマ不正はエラー終了。有効な構造化出力が得られない場合（拒否等）は `structured_output` が欠落するので、**存在チェック必須**。`format` キーワードは注釈扱いで検証されない。
- 根拠: https://code.claude.com/docs/en/headless#get-structured-output

### C5. 利用規約・プラン上の注意
- 結論: 公式（legal-and-compliance）の記述:
  - OAuth 認証は Free/Pro/Max/Team/Enterprise の購入者本人が Claude Code 等のネイティブアプリで通常利用するためのもの。
  - 製品・サービスを作る開発者（Agent SDK 利用者含む）は **API キー認証**を使うこと。第三者に Claude.ai ログインを提供したり、Pro/Max の認証情報で他人のリクエストを中継することは禁止。認証情報の収集・保管・仲介も禁止。
  - Pro/Max の上限は「Claude Code と Agent SDK の通常の個人利用」を前提。
  - エンドユーザー自身が改変なしの Claude Code バイナリに自分のサブスクでサインインすることは妨げられない。
  - https://code.claude.com/docs/en/legal-and-compliance
- 解釈（推測）: **開発者本人が自分の Mac で自分のサブスクの正規 `claude` バイナリを `claude -p` で呼ぶ個人用途は許容範囲**と読めるが、明示的に「許可」と書いた一文は見つからず、グレー。配布アプリにする、OAuth トークンをアプリが保管する、他人に使わせる場合は **API キー方式が必須**。報道（2026-02 の規約明確化、1 次ではない）: https://gigazine.net/gsc_news/en/20260220-anthropic-third-party-block
- 不確かな点: 「サブスク利用で `claude -p`/Agent SDK が別枠クレジット計量になる」という二次情報は **未確認**（要 Anthropic 公式で再確認）。要件書には「認証は claude CLI 側に任せる（アプリは認証情報を触らない）」「将来の API キー切替を可能にする」を入れるのが安全。
