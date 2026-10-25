# 計画 00 進捗

計画: `docs/superpowers/plans/2026-10-24-autonote-00-spikes-and-skeleton.md`
詳細台帳: `.superpowers/sdd/2026-10-24-autonote-00-spikes-and-skeleton/progress.md`（git 管理外）
ブランチ: Task 1 は `YutaOkoshi/autonote-plan00-spikes-skeleton` 上、Task 2 以降は `plan-00`

## 進め方の決定
- `git init` は不要（Orca worktree に既存リポジトリ）。worktree は増やさない
- 実装者は opus（general-purpose + sidekick-implementer の規律）。sidekick-implementer 定義の `isolation: worktree` を避けるため
- 順序: T1 → T2 → [T3 ∥ T5a] → [T4 ∥ T7] → T5b（ベンチ、CPU が暇なとき）→ T6 → T8（Apple Silicon、利用者に確認）→ T9 → 全体レビュー
- 結果表 `docs/superpowers/research/2026-10-24-spike-results.md` は各実装者が自分の節だけ書き、並列中は Lead がまとめてコミット

## 終わったタスク
- Task 1 骨組み（b2a5f3a、レビュー承認）
- Task 2 .app 組み立て・自己署名・TCC 持続確認（3e3b599 + 修正 09fbe18、レビュー承認）。TCC 許可は自己署名で再ビルド後も保たれた（項目 9 済）
- Task 3 process tap（85f1a7b, 4951e6b、レビュー承認）。許可あり受信 OK（48k/2ch/Float32）。許可なしの挙動は再現できず未確定（項目 3 済）
- Task 5 前半（ff601f4、レビュー承認）。whisper.cpp v1.9.5 ビルド・7 モデル取得・サンプル音声・XCFramework x86_64+arm64 確認（項目 8 済）

## 進行中
- Task 4 機材の列挙・抜き差し・VPIO（Spikes/DeviceProbe, MicHotSwap）: 利用者の機材操作が必要
- Task 7 `claude -p` 構造化出力（scripts/probe-claude.sh ほか）

## 利用者待ち
（なし）

## 次にやること
- Task 4 のビルドが終わったら Task 5 後半（whisper ベンチ、CPU ビルドのみ、`MODELS` 全部 + `--load`）を開始 → Task 6 → Task 8 確認 → Task 9 → 全体レビュー
- 計画 02 への申し送り: process tap の許可なし挙動は自己署名 .app 単体・再起動後に再確認。無音検知は最後のコールバックからの経過時間で判定し、無音区間を時間で埋める。TapCapture の IOProc はロック・確保・ディスク I/O を含みリアルタイム非安全なので写さずリングバッファにする。aggregate に出力デバイスを含めると入力付きヘッドセットで tap 以外のバッファが混ざる前提に注意。停止処理（DestroyIOProcID）はメインスレッドで同期的に呼ばない
