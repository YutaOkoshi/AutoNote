# テストフィクスチャ

このディレクトリの内容はすべて架空である。実在の人物・会社・機材識別子（MAC アドレスなど）は含まない。
実際の音声・文字起こし・議事録をコミットしてはならない。会議の相手は架空の「ほしぞら食品」、新商品は架空の「ルミナ茶」。

## ファイル

| ファイル | 役割 |
| --- | --- |
| `README.md` | このファイル。`FixtureLibrary.defaultDirectory` が正しく解決されるかの目印も兼ねる。 |
| `dictionary.md` | 辞書。用語（ルミナ茶・ほしぞら食品）、置換（ルミナちゃ => ルミナ茶）、既定のフィラー 5 語。 |
| `meetings/20261024-1400-a1b2/manifest.json` | 会議 1（ライブ録音、一時停止 1 回、ブックマーク 2 件）のマニフェスト。 |
| `meetings/20261024-1400-a1b2/minutes.json` | 会議 1 の議事録出力（スキーマ v1: 要約・決定事項・議題・Next Action）。Next Action にパイプを含む。v1 の読み込みの回帰用なので v2 に書き換えない。 |
| `meetings/20261024-1400-a1b2/utterances/{mic,system}-{000,001}.json` | 会議 1 のトラック別の発話（時刻はファイル内の秒）。フィラー、置換、回り込み、短い相づち、一時停止後のオフセットを含む。 |
| `meetings/20261025-0930-c3d4/manifest.json` | 会議 2（取り込み、議事録なし、`transcript_only`）のマニフェスト。 |
| `meetings/20261025-0930-c3d4/utterances/import-000.json` | 会議 2 の発話（話者は不明になる）。 |
| `meetings/20261026-1000-e5f6/manifest.json` | 会議 3（ライブ録音、EC 受注連携の相談、ブックマーク 1 件）のマニフェスト。 |
| `meetings/20261026-1000-e5f6/minutes.json` | 会議 3 の議事録出力（スキーマ v2: 出席者・重要ポイント・質問・締め切り・フォローアップ・リスク・インサイト・構成図・優先度をすべて含む）。 |
| `meetings/20261026-1000-e5f6/utterances/{mic,system}-000.json` | 会議 3 のトラック別の発話。 |
| `expected/2026/2026-10-24_1400_ルミナ茶発売準備会議.md` | 会議 1 の期待出力（golden）。 |
| `expected/2026/2026-10-25_093015.md` | 会議 2 の期待出力（golden）。 |
| `expected/2026/2026-10-26_1000_ルミナ茶EC受注連携.md` | 会議 3 の期待出力（golden。v2 の全節）。 |
| `expected/_index.md` | 期待する `_index.md`（golden）。 |

## golden の更新

`expected/` は `FixtureRenderer.render(into:)` の出力を目で確かめてから置く。
`FixtureGoldenTests.goldenHasKeyLines` が主要な行を別に固定しているので、誤った出力ごと作り直さないこと。
