# 処理時間の比較: main と fix-foreign-script

- 日付: 2026-11-19、交互に 3 回ずつ、モデル: ggml-large-v3-turbo-q5_0.bin。比 = fix-foreign-script ÷ main（中央値どうし）

| ケース | main RTF（中央値・各回） | fix-foreign-script RTF（中央値・各回） | 比 |
|---|---|---|---|
| kantei-toron whisper/ja | 0.016（0.016, 0.017, 0.016） | 0.017（0.016, 0.018, 0.017） | 1.06 |
| kantei-toron whisper-live/ja | 0.043（0.042, 0.047, 0.043） | 0.043（0.043, 0.046, 0.043） | 1.00 |
| ami-IS1009c whisper/en | 0.014（0.014, 0.014, 0.014） | 0.014（0.014, 0.014, 0.014） | 1.00 |
| ami-IS1009c whisper-live/en | 0.033（0.036, 0.033, 0.033） | 0.034（0.035, 0.033, 0.034） | 1.03 |
