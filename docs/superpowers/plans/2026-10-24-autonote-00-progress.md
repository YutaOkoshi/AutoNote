# 計画 00 進捗

計画: `docs/superpowers/plans/2026-10-24-autonote-00-spikes-and-skeleton.md`
詳細台帳: 削除済み（要点は本ファイルと結果表に移した）。測定の生データは `docs/superpowers/research/2026-10-24-spike-raw/`
ブランチ: Task 1 は `YutaOkoshi/autonote-plan00-spikes-skeleton` 上、Task 2 以降は `plan-00`

## 進め方の決定
- `git init` は不要（Orca worktree に既存リポジトリ）。worktree は増やさない
- 実装者は opus（general-purpose + sidekick-implementer の規律）。sidekick-implementer 定義の `isolation: worktree` を避けるため
- 順序: T1 → T2 → [T3 ∥ T5a] → [T4 ∥ T7] → T5b（ベンチ、CPU が暇なとき）→ T6 → T8（Apple Silicon、利用者に確認）→ T9 → 全体レビュー
- 結果表 `docs/superpowers/research/2026-10-24-spike-results.md` は各実装者が自分の節だけ書き、並列中は Lead がまとめてコミット

## 終わったタスク
- 最終レビュー（plan-00 ブランチ全体、a63c072..7d0d554）: With fixes → 本ラウンドで対応。Critical 1 件（項目 9 を「未確認」に下げた）、Important 5 件、Minor 10 件（M4 の Bundle ID・証明書名の一本化は計画 06 へ先送り）
- Task 9 要件書の既定値を事実で書き換える（dd7502b, 7d0d554、承認済み）
- Task 6 Apple Speech（5897d4e、レビュー承認）。Intel のリアルタイムは DictationTranscriber（RTF 0.31、CER 0.35、部分 0.5 秒遅れ・確定 5 秒）。SF は同じモデルと見られ（出力が一字一句同じ）60 秒区切り、許可も要るので予備価値なし。contextual は AnalysisContext 経由、造語には効かず（項目 2・12 Intel 側 済）
- Task 5 whisper ベンチ（ff601f4, eb85305、レビュー承認）。Intel 確定版 large-v3-turbo（RTF 0.68、CER 0.215）、whisper リアルタイム既定 small、Metal は Intel で不採用（項目 1・8 済）
- Task 4 機材の列挙・抜き差し・VPIO（169d4e8、レビュー承認）。項目 4 済（Shokz の BT UID は接続 3 回で安定、3.5mm は別デバイスとして added、USB 未測定）。項目 5・10 は利用者が後回し
- Task 7 `claude -p` 構造化出力（388f432、レビュー承認）。60/120 分・注入ありの 3 回とも成功、履歴なし、MCP なし（項目 6・11 済）
- E2E 動作確認スクリプト `scripts/e2e-check.sh`（4c63be4 + 修正 020014d、レビュー承認。利用者の追加指示。以後の全タスクが完了前に実行する）
- Task 1 骨組み（b2a5f3a、レビュー承認）
- Task 2 .app 組み立て・自己署名・TCC 持続確認（3e3b599 + 修正 09fbe18、レビュー承認）。自己署名の designated requirement が識別子と証明書ハッシュだけで決まることは確認。マイク許可の持続は、最終レビューで直接起動（責任プロセスが Terminal.app）を測っていた疑いが強いと分かり「未確認」に下げた（項目 9。計画 02 の TCC まとめ確認タスクで確認）
- Task 3 process tap（85f1a7b, 4951e6b、レビュー承認）。許可あり受信 OK（48k/2ch/Float32）。許可なしの挙動は再現できず未確定（項目 3 済）
- Task 5 前半（ff601f4、レビュー承認）。whisper.cpp v1.9.5 ビルド・7 モデル取得・サンプル音声・XCFramework x86_64+arm64 確認（項目 8 済）

## 進行中
（なし）

## 利用者待ち（後回し扱い。再開手順は結果表の該当項目に記載）
- Task 4 Step 4（Shokz を使ったマイク復帰、項目 10）と Step 5（VPIO の副作用、項目 5）
- Task 4 の USB 機材の識別子（項目 4 の USB 行）
- Task 8（Apple Silicon 機でのスパイク、項目 7・12 の Apple Silicon 側、項目 1 の Metal）。Task 8 の前に AppleSpeechProbe に `--engine transcriber --file/--live`（dictation と同じ経路）を追加する必要がある（今は「未実装」と出して exit 2）。あわせて Apple Silicon 機で `DeviceProbe` を回し、3.5mm の見え方と Bluetooth UID が別の Mac でも同じかを確認する（Task 9 で判明した追加確認）

## 次にやること
- （任意）項目 9 の再測定 → 計画 01（中核モデルと保存形式）を書く

## 計画 02 への申し送り
- process tap の許可なし挙動は自己署名 .app 単体・再起動後に再確認。無音検知は最後のコールバックからの経過時間で判定し、無音区間を時間で埋める。TapCapture の IOProc はロック・確保・ディスク I/O を含みリアルタイム非安全なので写さずリングバッファにする。aggregate に出力デバイスを含めると入力付きヘッドセットで tap 以外のバッファが混ざる前提に注意。停止処理（DestroyIOProcID）はメインスレッドで同期的に呼ばない
- IOProc が無音時に呼ばれない件は内蔵スピーカー・Intel のみの観測。BT 出力と Apple Silicon で再確認
- 最初のタスクとして TCC まとめ確認を置く。すべて `open` 起動で確認する（実行ファイルの直接起動は責任プロセスが起動元になるので使わない。判定は TCC.db の行で行う。手順は結果表の項目 9）:
  1. システム音声録音の許可の持続（再ビルド後）
  2. システム音声録音の許可なしの挙動
  3. DictationTranscriber が音声認識の許可なしで動くこと（AutoNote.app 単体）
  4. マイク許可の持続（再ビルド後。項目 9 を先に任意で再測定していれば省ける）

## 計画 04 への申し送り
- 発話単位の区切り: DictationTranscriber（`.progressiveLongDictation`）は約 70 秒の連続発話を確定 1 件にまとめた。沈黙での確定、`finalize(through:)`、`.frequentFinalization` のどれで区切るかを決める（結果表の項目 2、要件書 §6.3）
- DictationTranscriber の許可の再確認は計画 02 の TCC まとめ確認タスクに入れた（上記）
