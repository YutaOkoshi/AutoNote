# 要約の評価: main-e1de04c

- 日付: 2026-11-20、採点モデル: claude-sonnet-5-5（claude-sonnet-5-5）、プロンプト: match=judge-1,faith=judge-2
- 突き合わせ: AMI の decisions / actions と MinutesOutput の decisions / next_actions。再現率 = 正解のうち対応がついた割合、適合率 = 生成のうち正解のどれかに対応した割合
- 忠実性: 要約・決定事項・次のアクション・要点の各項目を、正解の書き起こしに照らして supported / partial / unsupported で判定。スコア = (supported + 0.5 × partial) ÷ 項目数

| データ | 入力 | 決定 再現率 | 決定 適合率 | アクション 再現率 | アクション 適合率 | 忠実性 | 項目 (S/P/U) |
|---|---|---|---|---|---|---|---|
| ami-ES2008a | reference | 83% (5/6) | 50% (2/4) | 100% (5/5) | 57% (4/7) | 98% | 23 (22/1/0) |
| ami-ES2008a | reference-me-other | 0% (0/6) | 0% (0/2) | 100% (5/5) | 62% (5/8) | 100% | 23 (23/0/0) |

