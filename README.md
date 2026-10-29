# AutoNote

macOS のメニューバーに常駐して会議を録音し、手元で文字起こしして、Claude Code で議事録を作るアプリ。オンライン会議のあとに議事録をまとめる手間を減らしたい人と、過去の会議を Claude に読ませたい人のためのもの。

## 何ができるか

- メニューバーの波形アイコン、ショートカット（⌃⌥R）、CLI のどれからでも録音を始められる
- 自分のマイクと Mac のシステム音声（Zoom・Google Meet・Teams・Slack ハドルの相手の声）を別々のトラックで同時に録る
- 文字起こしは Mac の中で行う。録音中は Apple の音声認識（SpeechTranscriber / DictationTranscriber）でリアルタイムに流し、止めたあとに whisper.cpp で精度の高い確定版を作る（whisper のモデルを取得していないときは、確定版も Apple の音声認識で作る）
- 確定版の文字起こしから、手元の Claude Code（`claude -p`）が 3 行要約・決定事項・議題・Next Action を持つ議事録を作る
- 録音中にリアルタイム要約を出せる（設定でオンにしたとき）
- 議事録は 1 会議 1 ファイルの Markdown で、Obsidian などの Vault のフォルダに保存する。Claude Code がフォルダを読んで「先月決まったこと」に答えられる形にしてある
- 登録した会議用のマイク機材をつなぐと録音が始まり、外すと止まる
- CLI（`autonote start` / `stop` / `latest` など）と、議事録ができたときに自分のコマンドを走らせる Automations を持つ

## プライバシー

- 音声はこの Mac から出ない。録音・文字起こしはすべてローカルで行う
- 外に渡るのは、議事録（とリアルタイム要約）を作るために Claude Code（`claude -p`）へ渡す文字起こしのテキストだけ
- 根拠: [要件書](docs/superpowers/specs/2026-10-24-autonote-design.md) のゴール G9

## 動作環境

- macOS 26.0 以降
- Apple Silicon と Intel の両方で動く（配布物はユニバーサル）。Intel では確定版の文字起こしに会議の長さと同程度かそれ以上の時間がかかる
- 議事録を作るには Claude Code の CLI（ターミナルで `claude` が動き、ログイン済み）が要る。無くても録音と文字起こしはできる

## インストール

1. [GitHub Releases](https://github.com/YutaOkoshi/AutoNote/releases) から `AutoNote-<version>-macos-universal.zip` を取り、展開した `AutoNote.app` を `/Applications` に置く
2. 配布物は Developer ID 署名・公証をしていない。一度開こうとして拒否されたら、システム設定 › プライバシーとセキュリティ の下にある「このまま開く」を押す。または次を実行する

   ```sh
   xattr -d com.apple.quarantine /Applications/AutoNote.app
   ```

最初の録音まで:

1. Claude Code を入れ、ターミナルで `claude` を一度起動してログインする
2. AutoNote を起動し、メインウィンドウ下部の準備カード（保存先・文字起こしモデル・Claude Code）を確かめる。保存先の既定は `~/Documents/AutoNote`
3. メニューバーの波形アイコンから「録音開始」を選び、終わったら停止する。少し待つと保存先に議事録ができる

画面つきの手順は [利用者ガイド](docs/guide/getting-started.md) にある。

## ドキュメント

| 文書 | 内容 |
|---|---|
| [利用者ガイド](docs/guide/getting-started.md) | 起動から最初の議事録ができるまでと、うまくいかないときの対処を画面つきで説明する |
| [利用者リファレンス](docs/guide/reference.md) | CLI のコマンド、Automations、ショートカット、通知、ログイン時起動 |
| [開発者ガイド](docs/development.md) | ビルド・テスト・E2E、リポジトリ構成、開発の約束事、CI とリリース |
| [要件書](docs/superpowers/specs/2026-10-24-autonote-design.md) | 目的、ゴールと非ゴール、録音・文字起こし・議事録・保存形式の設計全体 |
| [初回起動から議事録が開くまで](docs/superpowers/specs/2026-10-27-first-run-to-minutes-design.md) | 準備カード、空状態、失敗の説明など初回体験の設計 |
| [停止後の文字起こしを窓で流す](docs/superpowers/specs/2026-10-28-windowed-batch-transcription-design.md) | 長時間録音でもメモリを抑える確定版文字起こしの設計 |
| [録音中のリアルタイム要約](docs/superpowers/specs/2026-10-28-live-summary-design.md) | 録音中に要約を更新する機能の設計 |

調査記録（`docs/superpowers/research/`）:

| 文書 | 内容 |
|---|---|
| [Apple API 調査](docs/superpowers/research/2026-10-24-apple-apis.md) | 音声認識・process tap・権限など Apple の API を Intel Mac で確かめた記録 |
| [スパイク結果](docs/superpowers/research/2026-10-24-spike-results.md) | 実装前に実機で確かめた 12 項目の結果と、要件書への反映 |
| [文字起こしエンジンと Claude Code](docs/superpowers/research/2026-10-24-transcription-and-claude-code.md) | whisper.cpp と Apple Speech の比較、`claude -p` の非対話呼び出し |
| [長時間録音のメモリ監査](docs/superpowers/research/2026-10-27-memory-audit-long-recordings.md) | 2〜3 時間の録音でメモリが増える箇所の測定と結論 |
| [UX 監査](docs/superpowers/research/2026-10-27-ux-audit/README.md) | 説明なしで初見操作できるかを 61 項目とゼロコンテキスト操作テストで見た結果 |
| [参考アプリ](docs/superpowers/research/2026-10-24-reference-apps.md) | 同種の Swift 製メニューバーアプリ 3 本の作りの調査 |
| [機能ギャップ](docs/superpowers/research/2026-10-24-feature-gaps.md) | 21 製品の機能比較と、自作する価値がある部分 |
