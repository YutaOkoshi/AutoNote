# 要約の評価: main-e1de04c

- 日付: 2026-11-20、採点モデル: claude-sonnet-5-5（claude-sonnet-5-5）、プロンプト: match=judge-1,faith=judge-2,faith_open=judge-2-generic
- 突き合わせ: AMI の decisions / actions と MinutesOutput の decisions / next_actions。再現率 = 正解のうち対応がついた割合、適合率 = 生成のうち正解のどれかに対応した割合
- 忠実性: 要約・決定事項・次のアクション・要点の各項目を、正解の書き起こしに照らして supported / partial / unsupported で判定。スコア = (supported + 0.5 × partial) ÷ 項目数

| データ | 入力 | 決定 再現率 | 決定 適合率 | アクション 再現率 | アクション 適合率 | 忠実性 | 項目 (S/P/U) |
|---|---|---|---|---|---|---|---|
| kaiken-kishida | reference | – | –（生成 5 件） | – | –（生成 7 件） | 100% | 25 (25/0/0) |
| kaiken-kishida | final | – | –（生成 8 件） | – | –（生成 8 件） | 100% | 28 (28/0/0) |
| ingcrowd-09 | reference | – | –（生成 0 件） | – | –（生成 0 件） | 97% | 15 (14/1/0) |
| ingcrowd-09 | final | – | –（生成 0 件） | – | –（生成 0 件） | 93% | 14 (12/2/0) |

