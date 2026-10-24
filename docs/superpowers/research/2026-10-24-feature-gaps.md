# AutoNote 要件ギャップ調査（2026-10-24）

調査方法: WebSearch / WebFetch。公式 README・公式ドキュメントを優先したが、商用製品は検索結果が第三者レビュー中心。信頼度は列「出典」で区別する。
- 【公式】= 公式 README/ドキュメントを直接取得。【二次】= レビュー・ベンダー紹介記事の要約（プラン区分や最新仕様は未確認）。
- 出典のない推測は「推測」と明記。

## 0. 調査済み一覧（21 製品）

| 製品 | 種別 | 確認度 | 出典 URL |
|---|---|---|---|
| Granola | 商用デスクトップ | 二次 | https://granola.ai/llms.txt / https://alternativeto.net/news/2025/10/granola-adds-recipes-for-context-aware-ai-prompts-and-custom-workflow-personalization |
| Krisp Meeting Notes | 商用デスクトップ | 二次（マーケ記事中心） | https://meetgeek.ai/comparison/krisp-vs-granola ほか |
| MacWhisper | 商用デスクトップ | 二次 | https://tidbits.com/watchlist/macwhisper-15-2/ / https://usevoicy.com/blog/macwhisper-review/ |
| Superwhisper | 商用デスクトップ | 公式ドキュメントが検索ヒット（本文は未精読） | https://superwhisper.com/docs/modes/meeting / https://superwhisper.com/documentation/meeting-notes |
| Notion AI Meeting Notes | 商用 | 公式ヘルプ検索ヒット＋二次 | https://www.notion.com/product/try-ai-meeting-notes / https://www.notion.com/zh-tw/help/ai-meeting-notes |
| tl;dv | 商用（bot） | 二次 | https://zapier.com/blog/tldv-features.md |
| Otter.ai | 商用（bot） | 二次 | https://www.toolsforhumans.ai/ai-tools/otter-ai |
| Fireflies.ai | 商用（bot） | 二次 | https://pipeline.zoominfo.com/sales/fireflies-ai-features |
| Fathom | 商用（bot） | 二次 | https://zapier.com/blog/fathom-features.md |
| Zoom AI Companion | プラットフォーム内蔵 | 二次（大学 IT ページ） | https://www.bu.edu/tech/services/cccs/collaboration/online/zoom/zoom-ai-companion |
| Teams Copilot / Intelligent Recap | プラットフォーム内蔵 | Microsoft Learn＋二次 | https://learn.microsoft.com/en-us/training/modules/introduction-teams-meetings-calling/5b-overview-copilot-teams-calling-meetings-devices |
| Google Meet Gemini メモ（日本語） | プラットフォーム内蔵 | 二次 | https://workspace.google.com/intl/ja/solutions/ai/ai-note-taking |
| LINE WORKS AiNote / CLOVA Note | 日本語商用 | ベンダー PR・公式ヘルプ | https://help.worksmobile.com/ja/use-guides/ainote/settings/automation/ / https://line-works.com/pr/20240306/ |
| Notta | 日本語商用 | 二次 | https://www.lifehacker.jp/article/2409-new-functions-notta/ / https://www.itreview.jp/products/notta/feature |
| Rimo Voice | 日本語商用 | 二次 | https://aismiley.co.jp/ai_news/ai-transcription-rimovoice-update/ |
| スマート書記 | 日本語商用 | 二次 | https://ascii.jp/elem/000/004/180/4180819/ |
| Hyprnote（現 Anarlog） | OSS | 【公式】README | https://github.com/fastrepl/hyprnote |
| Meetily | OSS | 【公式】README | https://github.com/Zackriya-Solutions/meeting-minutes |
| screenpipe | OSS | 【公式】README | https://github.com/mediar-ai/screenpipe |
| Vibe | OSS | 【公式】README | https://github.com/thewh1teagle/vibe |
| Buzz | OSS | 【公式】README | https://github.com/chidiwilliams/buzz |
| Whishper | OSS | 【公式】README | https://github.com/pluja/whishper |
| Amurex | OSS | 【公式】README | https://github.com/thepersonalaicompany/amurex |
| （参考）owengretzinger/meetingnotes, masconics/meeting-notes, meetcap, mraza007/minute | OSS | 検索ヒットのみ | https://github.com/owengretzinger/meetingnotes ほか |

注: 「kannyjyk/meetnote」は検索で存在を確認できなかった。代わりに上記の参考 OSS が同種（macOS・ローカル・system+mic）。Amurex は Meet/Teams 向け拡張で、AutoNote とは構造が違う（参考度低）。
注: 「クラッシュ復旧」「ディスク残量警告」「無音自動停止」は、今回取得した範囲では**どの製品でも明記を確認できなかった**（Meetily は「記載なし」と確認）。以下では「推測」扱い。

---
## 1. 録音・音声

| 機能 | 持っている製品 | 何のためにあるか | 私見 | 重さ |
|---|---|---|---|---|
| 会議アプリ/マイク使用の検知で録音開始を提案 | Notion（マイク使用プロセスを監視して通知）、MacWhisper Pro（会議自動検出）、Meetily PRO | 手動開始の押し忘れ防止 | **検討**。ドラフトの「登録機材の接続検知」は機材単位。Zoom 等が**マイクを掴んだ時**の検知は別軸で、内蔵マイク運用だと機材検知では拾えない。Notion の実装はマイク使用プロセスの有無（Notion 側説明）。Core Audio で同様に取れる可能性（推測） | 中 |
| 録音の一時停止/再開 | Fathom・Granola 等で一般的（推測。今回の出典では個別未確認） | 雑談・機微な話を残さない | **要**。個人用でも「ここは録らない」は頻出。同一ファイルに続けるか分割かだけ決める | 軽 |
| 無音が続いたら自動停止/確認 | 今回出典では確認できず（推測で他社にもある） | 停止し忘れ防止 | **検討**。ドラフトの停止は「機材切断」のみ。内蔵マイク・手動開始だと止め忘れが起きる。「N分無音で通知」程度が軽い | 軽 |
| 録音中の長時間上限・分割 | AiNote（1回6時間上限）、Notion（1日10時間/人） | 異常に長いセッションの暴走防止 | **検討**。上限というより「12時間付けっぱなし」の保険 | 軽 |
| 既存音声ファイルの取り込み（文字起こし・議事録化） | MacWhisper、Vibe、Buzz、Meetily（Import & Enhance）、Superwhisper | 他端末で録った音声・過去録音を処理 | **要**。エンジンと議事録パイプラインは既にあるので追加コストが小さい。iPhone ボイスメモ等の救済口になる | 軽 |
| ウォッチフォルダ（置くだけで自動処理） | MacWhisper Pro、Buzz | 上の取り込みの自動化 | **検討**。取り込みが入るなら CLI `autonote import` で足りる可能性（推測） | 軽〜中 |
| 録音失敗・クラッシュからの復旧（部分保存） | 今回出典では確認できず | 録音中のアプリ落ち・スリープ・電源断で全損しない | **要**（推測だが重要）。議事録アプリ最大の事故。チャンクごとに書き出し＋起動時に未完了セッションを検出して続き処理 | 中 |
| 録音中のスリープ/蓋閉じ対策 | 出典なし | ノート Mac で蓋を閉じると切れる | **検討**（推測）。電源アサーション取得が軽い | 軽 |
| ディスク残量警告 | 出典なし | 長時間録音で空き不足 | **検討**。30日自動削除があるので重要度は中。開始時チェックのみで足りる | 軽 |
| 音声デバイス切替への追従（会議中にイヤホン付け替え） | 出典なし | 録音が途切れない | **検討**（推測）。ドラフトの Bluetooth 瞬断猶予とセット | 中 |
| 特定アプリのシステム音除外 | screenpipe（bundle ID 指定、macOS 14.4+） | Spotify・通知音の混入防止 | **検討**。process tap は対象プロセス指定ができるはず（推測）。「会議アプリだけ録る」設計だと混入と相手以外の音が減り精度も上がる | 中 |
| ノイズ除去・エコー除去 | Krisp（通話中に適用）、Buzz（話者分離前の音声分離） | 認識精度向上 | **不要寄り**。スピーカー再生でマイクに相手の声が回り込むと「自分」の文字起こしに相手が混ざる。ヘッドホン前提か、回り込み重複除去が要るか**要確認**（二重文字起こしのリスク） | 重 |
| ダッキング・クリッピング防止 | Meetily | 小声と大声の混在でも拾う | **不要**（認識側の正規化で足りる。推測） | 軽 |

## 2. 文字起こし

| 機能 | 持っている製品 | 何のためにあるか | 私見 | 重さ |
|---|---|---|---|---|
| 文字クリック→該当音声を再生 | Rimo Voice、スマート書記、Buzz（プレーヤー付ビューア）、Whishper、tl;dv、Otter | 誤認識を耳で確認して直す | **検討**。Markdown 出力が主なので再生UIをどこに置くか。frontmatter/タイムスタンプ（`[12:34]`）だけ残し、アプリ内の簡易プレーヤーに限る手もある | 中 |
| 文字起こしの手直しエディタ | Rimo、スマート書記、Whishper、Hyprnote | 固有名詞の誤りを後から直す | **検討**。ドラフトは議事録本文の編集可・辞書あり。**Markdown を直接編集で足りる**ので専用UIは不要寄り（推測） | 中 |
| 相手側の話者ラベル後付け/名前付け | Otter、Rimo（手動修正から自動設定）、MacWhisper、Superwhisper、Hyprnote | 誰の発言か明確にする | ドラフトは「相手の個別識別はしない」と明記 →「作らない」別枠へ（§末尾） | — |
| 用語登録の候補サジェスト（誤変換から辞書へ） | スマート書記（用語登録サジェスト） | 辞書の育成コスト削減 | **検討**。議事録生成時に Claude に「固有名詞らしい誤認識候補」を出させ、辞書へ追加提案する流れが安い（推測） | 軽〜中 |
| フィラー（えー、あのー）除去 | CLOVA Note（2024/3 追加）、Rimo | 読みやすさ | **要**（軽）。確定版後に regex か Claude 整形で十分。全文 Markdown を人が読むならほぼ必須 | 軽 |
| 言語自動判定（日英混在） | Notta（58言語）、Vibe、Whisper 系全般 | 英語会議の混在 | **検討**。日本語メイン・英語サブなので会議単位で言語指定できれば足りる。会議内の混在は whisper が弱い（推測） | 軽 |
| 原文と書き言葉化（話し言葉→書き言葉） | スマート書記（AIアシスト） | 読みやすい議事録 | **要**。議事録生成プロンプトに含めるだけ | 軽 |
| 確定版の再文字起こし（別モデル/別言語で再実行） | Meetily（Import & Enhance） | 精度やり直し | **検討**。ドラフトの「議事録再実行」と同様に文字起こし再実行の口が欲しい | 軽 |
| ライブ文字起こしを外部ファイルへ流す | Superwhisper（ユーザー要望のみ） | 他ツールからのリアルタイム参照 | **不要**（要望レベル） | — |

## 3. 議事録・AI

| 機能 | 持っている製品 | 何のためにあるか | 私見 | 重さ |
|---|---|---|---|---|
| 会議種別テンプレート切替（1on1/定例/商談） | Granola（29+）、Notta、AiNote（テンプレート要約、自動要約のテンプレート選択）、Meetily PRO | 種類ごとに欲しい構成が違う | **要**。ドラフトは「プロンプトは外部設定ファイル」止まり。**複数ファイル＋会議ごと/機材ごと/CLI引数で選択**にすれば低コスト | 軽 |
| 再生成・追加質問（1会議に対するチャット） | Granola、Hyprnote、Fireflies AskFred、Teams Copilot、Zoom | 要約の観点変更・深掘り | **不要寄り**。ドラフトは Claude Code に任せる方針と整合。ただし「別テンプレで再生成」は上の再実行で吸収 | 軽 |
| レシピ（保存済みプロンプトのワンタップ実行） | Granola Recipes | 後処理の定型化 | **不要**（Claude Code のスキル/コマンドで代替。推測） | — |
| 過去会議の文脈引き継ぎ（定例の前回内容を参照） | Granola（フォルダ横断）、tl;dv（複数会議）、Fireflies | 定例で前回との差分を要約 | ドラフトは横断質問を作らない。ただし**同名定例の前回議事録を生成時に渡す**は別物で、**検討**。タイトル/タグ一致の直近 1 件を入力に足すだけ | 中 |
| ToDo の担当者・期限抽出 | Fathom（クリップ付き）、AiNote（「次のステップ」）、Fireflies、Zoom | 誰が何をいつまで | **要**。Next Action に「担当/期限」フィールドを JSON スキーマに足すだけ。「自分」の担当は話者=マイクで判定可能 | 軽 |
| 発言の出典リンク（要約の各項目→文字起こしの該当行） | Notion（takeaway→transcript line）、Granola | 要約を検証できる | **要**。ハルシネーション対策。JSON に `source_timestamp` を持たせれば Markdown リンク化できる | 軽〜中 |
| 発言比率・話した時間などの統計 | Fireflies（talk-to-listen、monologue）、tl;dv（浅い） | 話しすぎ/聞きすぎ把握 | **検討**。マイク/システム音の2トラックなので**自分:相手の比率は計算だけで出せる**（推測）。frontmatter に1行で足せる | 軽 |
| 感情分析・トピック追跡・コーチング | Fireflies、tl;dv | 営業向け分析 | **不要**（私用議事録に合わない） | 重 |
| 自分の名前が呼ばれた箇所のマーカー | Teams（パーソナライズドマーカー）、Zoom（Was my name mentioned?） | 聞き逃し確認 | **検討**。文字起こし後に自分の名前を検索してタイムスタンプを frontmatter に出すだけ。ただし第二期の「質問拾い上げ」と近い | 軽 |
| 章・トピックのタイムライン | Teams（chapters）、Zoom | 長い会議のナビ | **検討**。「議題ごとの内容」と重複。各議題に開始時刻を付けるだけで足りる | 軽 |
| 要約の言語（日本語会議の英訳 / 逆） | Notta、Vibe、Whishper（翻訳） | 英語会議の日本語要約 | **要**（軽）。プロンプト指定で足りる。出力言語を設定に | 軽 |
| フォローアップメール下書き | Amurex、Fathom 等 | 会議後の連絡 | **不要**（私用）。必要なら Claude Code で | — |
| 機密を要約対象から除外（要約に出さない） | 出典なし（推測：ブックマークの逆機能） | 要約・保存に残さない部分 | §5 の一時停止と重複 | 中 |

## 4. 保存・連携

| 機能 | 持っている製品 | 何のためにあるか | 私見 | 重さ |
|---|---|---|---|---|
| 外部送信（Slack/メール/Notion/CRM） | Fathom（CRM）、Fireflies、Notion、Amurex（メール） | 共有・転記 | **不要**（私用・ローカル重視）。CLI の `latest` があるので必要なら Claude Code から | — |
| Obsidian デイリーノートへのリンク挿入 | 出典なし（Obsidian プラグイン類は別途あり。screenpipe に Obsidian pipe） | 日々の記録から会議に辿れる | **検討**（推測で需要あり）。Vault を書き出し先にしているので、デイリーノートに `[[会議]]` を追記するのは近い。ただし Vault を勝手に書き換える点が重い | 中 |
| タグ自動付与 | frontmatter 初期値に「タグ」あり（ドラフト）。自動付与の方法は未記載 | 検索性 | **検討**。議事録生成の JSON に `tags` を足し、**既存タグ一覧を渡して語彙を揃える**のが効く（推測） | 軽 |
| エクスポート形式 txt / srt / vtt / json / docx / pdf | Vibe（SRT/VTT/TXT/HTML/PDF/JSON/DOCX）、Buzz、Whishper、MacWhisper | 字幕・他ツール受け渡し | **不要寄り**。Markdown 一本で十分。**生 JSON（タイムスタンプ付き）を同フォルダに残す**のは検討（再処理・再生成の入力になる） | 軽 |
| 音声ファイルの保存期間（自動削除） | ドラフトにあり | — | 既出（除外） | — |
| バックアップ | Hyprnote（任意の暗号化 CloudSync）、screenpipe（E2E 同期） | 端末故障対策 | **不要**（Vault 同期に任せる。推測）。ただし**音声だけ30日で消える**ので、文字起こし原文（JSON）は残す設計が要確認 | 軽 |
| ローカル DB（SQLite）による会議管理 | Hyprnote、screenpipe | 検索・一覧 | **不要**（ドラフトは Markdown 一本化で意図的） | — |
| REST API / HTTP API | Vibe、screenpipe | 他アプリ連携 | **不要**（CLI+UNIXソケットで代替済み） | — |
| MCP サーバー | Hyprnote、screenpipe、Krisp | AI クライアント連携 | ドラフトで「作らない」明記 → 別枠 | — |

## 5. 操作性

| 機能 | 持っている製品 | 何のためにあるか | 私見 | 重さ |
|---|---|---|---|---|
| グローバルショートカット（録音開始/停止） | Fathom（ハイライト用キー）、Buzz（キーボードショートカット）、Superwhisper 等（推測で一般的） | マウス不要で操作 | **要**。メニューバー常駐なので定番。CLI があるのでショートカット→CLI でも可 | 軽 |
| 録音中のブックマーク（「ここ重要」マーク） | Fathom（キー1つでハイライト）、tl;dv（自分のタイムスタンプ）、Granola（メモ紐付け） | 後で要約の重み付け・ジャンプ | **要**。ドラフトの「会議中メモ」は作らないが、**ワンキーでタイムスタンプだけ**は別物で軽い。生成時に「ブックマーク周辺を重視」と Claude に伝えられる | 軽 |
| 無通知での即時開始（メニューバー/ショートカット） | 一般的（推測） | 流れを止めない | ドラフトの「開始時の数秒通知（取り消し付き）」と衝突しないか確認 | 軽 |
| Spotlight / 検索 | screenpipe（FTS5）、Whishper、Buzz（ビューア内検索） | 過去会議を探す | **不要**（Vault の検索や Claude Code に委任） | — |
| ライブ要約・追いつき（Catch me up） | Zoom、Amurex（Late join recap）、Teams | 途中参加のキャッチアップ | ドラフトで「作らない」明記 → 別枠 | — |
| ウィジェット / Live Activity | iOS 系（今回出典なし） | — | **不要** | — |
| 処理中ステータス通知（議事録できた通知） | Notion 等（推測） | 完了に気づく | **要**（軽）。通知センター＋クリックで該当 Markdown を開く | 軽 |

## 6. プライバシー・法務

| 機能 | 持っている製品 | 何のためにあるか | 私見 | 重さ |
|---|---|---|---|---|
| 録音同意の確認/注意表示 | Notion（「全員が同意した」ことを開始時に確認）、Zoom・Gemini（参加者へ通知表示） | 法令・規約・倫理 | **要**（私用でも）。**相手に聞こえない録音**（process tap）なので、初回のみ「録音には相手の同意が要る」旨の確認と、会議冒頭で言う定型文のコピー機能くらいは軽い。相手通知の自動送信は不可能/不要 | 軽 |
| 特定アプリ・ウィンドウの除外 | screenpipe | 銀行・パスワードを録らない | 音声のみなので上記「特定アプリのシステム音除外」と同じ（§1） | 中 |
| 暗号化（保存時） | screenpipe（任意）、Hyprnote（CloudSync 暗号化） | 紛失・盗難 | **不要寄り**。FileVault 前提でよい（推測）。ただし音声は平文で残る旨を設定画面に明記 | 軽 |
| PII/センシティブ語マスク | screenpipe（PII 除去） | 要約・外部 AI へ出す前に伏せる | **検討**。Claude Code に渡すのは**外部送信**でもある（ローカル完結の前提と矛盾）。**「Claude に送る」ことの明示と、送信前の固有名詞置換**の方針を決める価値あり | 中 |
| テレメトリ無効 | screenpipe（既定ON、設定で切替） | 外部送信の透明性 | **要**（自作なので既定でテレメトリ無し。仕様に一言） | 軽 |
| 保持期間・手動削除 | Zoom（365日でごみ箱）、AiNote | 残さない | ドラフトで音声 30 日自動削除あり。**会議単位の即時削除**（音声・文字起こし）は **要**（軽） | 軽 |
| 会議アプリ側への自動通知 | Zoom/Gemini（参加者に表示）。サードパーティの bot なし方式（Granola/Notion/Krisp）は相手に出ない | — | AutoNote も相手に出ない。**要確認事項**として上記同意表示で扱う | — |

## 7. その他（前提：Intel/Apple Silicon 両対応・個人用・Claude Code 連携）

| 機能 | 持っている製品 | 何のためにあるか | 私見 | 重さ |
|---|---|---|---|---|
| 確定版文字起こしの進捗表示・キュー（長時間バッチ） | Vibe/Buzz（進捗）、MacWhisper（キュー） | Intel の medium 処理は時間がかかる | **要**。Intel の確定版は会議後バッチなので、複数会議の**キューと進捗、スリープ中断からの再開**が必要 | 中 |
| 処理失敗時の再実行（文字起こし/要約の個別） | ドラフトに議事録の再実行あり | — | 文字起こし側も同様に（§2 の再文字起こし） | 軽 |
| Claude Code 実行の安全策（タイムアウト・コスト/Limit 配慮・失敗リトライ） | 出典なし（推測） | `claude -p` は 5時間枠 Limit を消費。長い会議だと上限や遅延 | **要**。ユーザーの Limit 管理を考えると、**文字起こしが長い時の分割要約、失敗時の後回しキュー、同時実行の制限**が必要。ドラフト「使えないときは後で再実行」の一部 | 中 |
| 要約入力のサイズ上限（2〜3時間会議） | 出典なし（推測） | トークン超過 | **要**（推測）。長い会議は map-reduce 的に章ごと要約→統合 | 中 |
| ローカル LLM フォールバック（Ollama 等） | Hyprnote、Meetily、Vibe | 完全ローカル/オフライン | **検討**。ドラフトは「API キー方式の口」止まり。ローカル完結重視なら将来拡張の口に。今は不要 | 中 |
| 自動アップデート | Vibe | 配布更新 | **検討**。個人用・複数 Mac。Sparkle 等は署名・notarization 要（推測）。当面は手動配布で足りる | 中 |
| 複数 Mac 間の設定共有 | ドラフト済み（書き出し先フォルダ内） | — | 既出（除外） | — |
| macOS 権限の状態確認画面（マイク/システム音/通知） | Notion 等（推測） | 権限切れで無音録音になる事故を防ぐ | **要**。ドラフトに「無音録音の検知」がない。**開始直後に音が来ているか検査し、来ていなければ警告**が事故防止で効く（推測） | 軽 |
| ログイン時自動起動 | ドラフト済み | — | 既出（除外） | — |

---
## 8. 「作らないと決めたが、他ツールでは重要扱い」一覧

| ドラフトの「作らない」 | 他ツールの扱い | 一言 |
|---|---|---|
| カレンダー連携（予定ベースの自動録音・リマインド） | Notion（Calendar から開始）、Otter（OtterPilot は予定に参加）、Hyprnote（カレンダー plugin）、Meetily（計画中） | 商用では最頻出の入口。ただし会議名・参加者名の取得源でもあり、**タイトルを Claude が付ける方針と相補**。後から追加しやすいよう `meeting.source` を残す程度で十分（推測） |
| 会議中メモ（時刻ひも付け） | Granola の中核（手書きメモ＋文字起こしを AI が統合）、Hyprnote（編集可能ノート） | Granola の差別化点。AutoNote では**ワンキーのブックマーク**（§5）で近い価値を軽く得られる |
| 途中経過要約・追いつき | Zoom（Catch me up）、Amurex（Late join recap）、Teams | 他人向け会議の途中参加が主用途で、**私用の自分が主催/参加し続ける会議では優先度低**（推測） |
| 週次レポート・過去会議への横断質問 | Fireflies AskFred、tl;dv（複数会議・定期レポート）、Granola（フォルダ横断）、screenpipe（検索・MCP） | 商用では売りだが、Claude Code が Markdown を読める前提なら重複。**frontmatter とタグを正しく残すことだけが前提条件** |
| 相手側の複数話者の個別識別 | Otter・Rimo・スマート書記・MacWhisper（最大8人）・Hyprnote・Vibe・Buzz・Meetily（PRO 予定）・screenpipe | ほぼ全製品が持つ標準機能。ローカル（Apple Silicon）なら可能になったが、Intel では重い（推測）。**後から入れる前提で話者ラベルを `相手` 固定にせず `相手1…` に拡張できる出力形式**にしておくと将来が楽 |
| MCP サーバー | Hyprnote、screenpipe、Krisp が提供 | CLI で足りる判断は妥当（推測） |

## 9. AutoNote の前提で特に効く上位 10 件

1. **録音のクラッシュ復旧**（チャンク保存＋起動時に未完了を検出）— 議事録アプリ最大の事故。出典で明記した製品は確認できず＝推測だが重要。軽〜中
2. **録音開始直後の無音検知（権限切れ・デバイス違い）**— 気づかず全会議が無音になる事故を防ぐ（推測）。軽
3. **既存音声ファイルの取り込み**（MacWhisper/Vibe/Buzz/Meetily が標準）— 既存パイプラインの再利用で安い。軽
4. **ワンキーのブックマーク＋グローバルショートカット**（Fathom/tl;dv）— 「会議中メモ」を作らない代わりの最小代替。軽
5. **会議テンプレートの切替**（Granola/Notta/AiNote）— プロンプトファイルを複数持ち、会議ごとに選ぶだけ。軽
6. **要約の出典リンク（各項目→文字起こしの時刻）**（Notion）— Claude の要約の検証に必須。軽〜中
7. **ToDo の担当・期限抽出＋自分の担当を判定**（Fathom/AiNote）— JSON スキーマにフィールドを足すだけ。軽
8. **録音の一時停止／会議単位の即時削除／同意の初回確認**（Notion の同意確認、Zoom/Gemini の通知）— 私用でも事故・倫理の保険。軽
9. **Intel 向けバッチのキューと進捗＋Claude Code 失敗時の後回しキュー（長時間会議の分割要約）**— 前提（Intel 両対応・claude -p・Limit 管理）に直撃。中
10. **フィラー除去・用語登録サジェスト**（CLOVA Note/Rimo/スマート書記）— 日本語メイン前提で読みやすさに直結。軽

次点: 会議アプリによるマイク使用検知での開始提案（Notion/MacWhisper）、特定アプリのシステム音除外（screenpipe）、同名定例の前回議事録を入力に足す、エコー回り込み時の「自分」二重文字起こし対策。

## 10. 未確認事項（追加調査候補）
- Granola / Superwhisper / Notion / Krisp の公式ドキュメント精読（今回は検索要約と README 止まり）
- 各製品の録音一時停止・クラッシュ復旧・無音停止の有無（出典で確認できず）
- 商用製品のプラン区分（Pro 限定機能など）は二次情報で未検証

---
# 11. 無料プランでの実現可否（追加調査 2026-10-24）

方法: 公式の料金ページ・公式ドキュメント・公式 README を WebFetch で直接取得（二次情報は使っていない）。
凡例: **無料** = 公式に無料プラン/OSS で使えると記載 / **有料** = 有料プラン限定と記載 / **なし** = 公式ドキュメントに該当機能が見当たらず、機能自体が無いと思われる（断定ではない）/ **未確認** = 取得したページに記載なし・プラン区分が読み取れない。
注意: 料金ページは機能比較表がテキスト化で欠落しやすく、「未確認」が多い。**ここで「無料」と書いたものは公式に根拠がある**、それ以外は無料で使えるとは言えない。

## 11-1. 7 機能 × 製品

### ① 既存音声ファイルの取り込み（インポート文字起こし）
| 製品 | 判定 | 根拠 |
|---|---|---|
| Otter | **無料（強い制限）** | Basic: 取り込み文字起こし 300分/月、ただしファイル取り込みは**生涯 3 回**。1会話 30 分まで。Pro は月 10 回 — https://otter.ai/pricing |
| Notta | **無料（制限あり）** | Free: ファイルアップロード 50 件/月、120分/月。表に「1会話 3 分まで」とあり実質かなり狭い（表の読み取り不確実） — https://www.notta.ai/en/pricing |
| LINE WORKS AiNote | **無料** | 録音ファイルのアップロードは全プランで可、フリーは 1 回 60 分、対応形式 m4a/mp3/aac/amr/wav — https://line-works.com/ainote/column/ainote-price/ （検索結果の要約）。フリー詳細ページには記載なし — https://line-works.com/ainote/free-solo/ |
| Meetily（Community） | **無料** | 「Import & Enhance」（Beta）が Community 側 — https://github.com/Zackriya-Solutions/meeting-minutes |
| Anarlog（旧 Hyprnote） | **無料（ローカル+自前キー）** | 音声と SRT/VTT からノート作成可と docs に記載。無料枠はローカル+BYO キー — https://docs.anarlog.so/ / https://anarlog.so/pricing |
| Vibe | **無料（OSS）** | 音声/動画・複数ファイルのバッチ・YouTube 等。ライセンス表記は README で未確認 — https://github.com/thewh1teagle/vibe |
| Buzz | **無料（OSS）** | ファイル/YouTube 文字起こし、ウォッチフォルダ — https://github.com/chidiwilliams/buzz |
| MacWhisper | 未確認 | 取り込み形式・バッチは公式に記載、**Free/Pro 区分はページに無い**。無料€0/Pro €64 買い切りは確認 — https://macwhisper.com |
| Superwhisper | **有料** | 「File transcription: Free=No / Pro=Yes」 — https://superwhisper.com |
| tl;dv / Fathom / Granola | 未確認 | 公式の料金/ドキュメントに取り込み記載なし（Fathom は「どのプランにも記載なし」） |

### ② 録音中のワンキー・ブックマーク（グローバルショートカット）
| 製品 | 判定 | 根拠 |
|---|---|---|
| Fathom | 未確認（ハイライト機能自体は無料） | Free に「自分の会議のクリップ/ハイライト」あり。**キーボードショートカットでの付与は公式料金ページに記載なし**（以前の二次情報のみ）— https://www.fathom.ai/pricing |
| tl;dv | 未確認 | 自分のタイムスタンプ機能は二次情報のみ。Free は「多くの AI 機能に限定アクセス」とだけ記載 — https://zapier.com/blog/tldv-features.md |
| AiNote | 未確認（機能は存在） | ヘルプ目次に「ブックマーク」「メモ」「ハイライト」の項目あり。プラン区分は不明 — https://help.worksmobile.com/ja/use-guides/ainote/ |
| Buzz | 無料（ただしアプリ内ショートカットのみ） | README に「Keyboard shortcuts」。録音中ブックマークではない |
| Meetily / Anarlog / Vibe / Granola / Otter / Notta | なし or 未確認 | 公式 README・ドキュメントに記載なし |
→ **無料で「録音中ブックマーク」と確認できた例は無し**（機能の存在自体は Fathom・AiNote にあるが、無料の可否は一次情報で確認できず）。

### ③ 会議種類ごとのテンプレート切替
| 製品 | 判定 | 根拠 |
|---|---|---|
| Granola | **無料** | Basic（$0）に「カスタマイズ可能なノートテンプレート」。履歴は 30 日 — https://www.granola.ai/pricing |
| Otter | **無料（上限あり）** | 標準テンプレ+カスタム AI テンプレート 5 個まで（Pro 15 / Business 30）— https://otter.ai/pricing |
| Notta | **無料（上限あり）** | Free: カスタムテンプレート 5 個、AI 要約は月 10 回 — https://www.notta.ai/en/pricing |
| Anarlog | **無料** | docs に「テンプレート、指示、言語、辞書で要約をカスタマイズ」— https://docs.anarlog.so/ |
| Meetingnotes（owengretzinger） | **無料（OSS）** | 「Different note templates」実装済み、自前 API キー前提 — https://github.com/owengretzinger/meetingnotes |
| Fathom | **有料** | 15+ テンプレートは有料、Free は高度な要約テンプレートなし — https://www.fathom.ai/pricing |
| Meetily | **有料（PRO）** | Custom Summary Templates は PRO — https://github.com/Zackriya-Solutions/meeting-minutes |
| Zoom（ZoomMate） | **有料** | Basic は要約が主催 3 会議/月まで、カスタム要約テンプレートは有料 — https://www.zoom.com/en/products/ai-assistant/ |
| AiNote | 未確認 | テンプレート要約はあるが、フリーでは AI 要約自体が使えない可能性が高い（FAQ は「有償版で回数制限付き」）— https://line-works.com/ainote/free-solo/ |

### ④ 要約の各項目 → 文字起こし該当時刻へのリンク（出典リンク）
| 製品 | 判定 | 根拠 |
|---|---|---|
| Notion | 未確認（機能は存在） | 各要点から文字起こしの該当行へリンク（Notion ヘルプ/二次情報）。無料プラン可否は未確認 — https://www.notion.com/zh-tw/help/ai-meeting-notes |
| Granola | 未確認 | API ドキュメントの文字起こし項目は speaker と text のみで**タイムスタンプ無し** — https://docs.granola.ai/ |
| 上記以外 | 未確認 | 今回の公式ページに記載なし |
→ 無料で確認できた例は無し。ただし**これは他サービスに頼る機能ではなく、AutoNote 側の JSON スキーマ（`source_timestamp`）で自作する性質**。

### ⑤ Next Action の担当者・期限の抽出
| 製品 | 判定 | 根拠 |
|---|---|---|
| Fathom | **無料（限定）/ 有料（フル）** | 「AI action items」は Free が Limited use、有料で全面。**担当者・期限のフィールドが取れるかは記載なし** — https://www.fathom.ai/pricing |
| AiNote | **有料** | AI 要約の「次のステップ」は有償プラン（フリー不可の可能性が高い）— https://line-works.com/ainote/free-solo/ |
| Zoom | **無料（3 会議/月）** | 要約に Next steps あり。担当・期限は記載なし — https://www.zoom.com/en/products/ai-assistant/ |
| Otter | 未確認 | Takeaways でアクション項目の割当とあるがプラン区分が読めない — https://otter.ai/pricing |
→ 担当・期限まで構造化して無料で出せると確認できた製品は無し。Claude に出させる（スキーマ指定）のが現実的。

### ⑥ 録音の一時停止
| 製品 | 判定 | 根拠 |
|---|---|---|
| Superwhisper | 未確認 | 会議モードの docs に一時停止の記載なし（停止前の確認プロンプトのみ）— https://superwhisper.com/docs/modes/meeting |
| Meetily / Anarlog / Vibe / Granola / Fathom / Notta / Otter | 未確認 | 取得した公式ページに記載なし |
→ **無料で一時停止できると公式に確認できた例は無し**（機能が無いのか、ページに書いていないだけかは不明）。

### ⑦ フィラー除去
| 製品 | 判定 | 根拠 |
|---|---|---|
| CLOVA Note（現 AiNote） | 機能あり、プラン未確認 | 2024/3 追加（ベンダー PR）。AiNote フリー詳細ページに記載なし — https://line-works.com/pr/20240306/ / https://line-works.com/ainote/free-solo/ |
| Rimo Voice | 機能あり、プラン未確認 | 二次情報のみ。今回は公式料金を取れていない |
| 他（OSS 含む） | なし/未確認 | Vibe / Buzz / Meetily / Anarlog の README に記載なし |
→ 無料で確認できた例は無し。**LLM（Claude）整形か正規表現で自作する方が早い領域**。

## 11-2. 基本機能が無料で揃うか

AutoNote の基本機能（マイク+システム音の同時録音・日本語リアルタイム文字起こし・AI 議事録・Markdown 書き出し・ローカル処理）を**公式情報で全部満たすと確認できた無料サービスは無かった**。近いのは次の 3 つ。
- **Meetily Community**: マイク+システム音の同時録音、Whisper/Parakeet のローカルリアルタイム、Ollama・Claude 等で要約（無料）。ただし Markdown 等の高度なエクスポートとテンプレは PRO。日本語・Intel は README で未確認 — https://github.com/Zackriya-Solutions/meeting-minutes
- **Anarlog（旧 Hyprnote）**: オンデバイス文字起こし、Markdown エクスポート、Ollama 等のローカル LLM も可、無料枠はローカル+自前キー。日本語リアルタイム品質・Intel は README で未確認 — https://github.com/fastrepl/hyprnote
- **Superwhisper**: 機能ページは「会議録音は無料（Mac のみ）」だが、会議モード docs は「Meetings は Pro 機能」と記載が**食い違う**。オフラインモデルは Apple Silicon 向けで Intel はクラウド推奨 — https://superwhisper.com / https://superwhisper.com/docs/modes/meeting
いずれも **Claude Code（`claude -p`）連携・1 会議 1 Markdown の Vault 出力・機材接続での自動開始・Intel 両対応**は満たさない（または未確認）。「自作する価値」は、無料サービスの不足ではなくこの連携部分にある、が私見。

## 11-3. 補足（無料枠の実測値）
- Otter Basic: 300分/月、1会話 30 分、履歴 25 件、辞書 5 語、書き出し mp3/txt のみ
- Notta Free: 120分/月、AI 要約 10 回/月、アップロード 50 件/月
- Granola Basic: 履歴 30 日、会議数の上限は記載なし
- AiNote Free: 300分/月・1回 60分、保管 1 年、AI 要約と Web 会議録音は不可（フリー詳細ページでは AI 要約欄が空欄）
- Zoom ZoomMate 無料枠: 要約は主催 3 会議/月、40 分まで
- Gemini メモ: 対象の Workspace エディション/Google AI プラン限定、日本語対応、参加者に通知表示（管理者設定で同意取得も可）— https://support.google.com/meet/answer/14754931?hl=ja
- tl;dv: 公式料金ページは価格のみで機能比較が取れず、Free の中身は未確認（https://tldv.io/app/pricing/）
