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

## 進行中
- Task 3 process tap スパイク（Spikes/TapCapture）
- Task 5 前半（whisper.cpp 取得・ビルド・サンプル音声・XCFramework 確認。ベンチ実行は後半で）

## 利用者待ち
（なし）

## 次にやること
- Task 3 Step 3（許可なし確認）と Task 5 後半（ベンチ）→ Task 4 ∥ Task 7 → Task 6 → Task 8 確認 → Task 9
