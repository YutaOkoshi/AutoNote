# AutoNote UI 初見操作性チェックリスト（一次資料ベース）

作成日: 2026-10-27 / 対象: macOS メニューバー常駐の会議録音・議事録アプリ

## 0. 出典と取得状況
- Apple HIG は SPA で WebFetch が空振りしたため、`developer.apple.com/tutorials/data/design/human-interface-guidelines/<page>.json`（HIG 本体と同内容の JSON）から本文を取得して確認した。以下の HIG 引用は全て本文確認済み（英語原文を要約、短い引用のみ）。
- 略号と URL
  - HIG-MB: https://developer.apple.com/design/human-interface-guidelines/the-menu-bar （Menu bar extras 節）
  - HIG-MENU: https://developer.apple.com/design/human-interface-guidelines/menus
  - HIG-ALERT: https://developer.apple.com/design/human-interface-guidelines/alerts
  - HIG-PRIV: https://developer.apple.com/design/human-interface-guidelines/privacy
  - HIG-ONB: https://developer.apple.com/design/human-interface-guidelines/onboarding
  - HIG-SET: https://developer.apple.com/design/human-interface-guidelines/settings
  - HIG-PROG: https://developer.apple.com/design/human-interface-guidelines/progress-indicators
  - HIG-NOTIF: https://developer.apple.com/design/human-interface-guidelines/notifications
  - HIG-LOAD: https://developer.apple.com/design/human-interface-guidelines/loading
  - HIG-TB: https://developer.apple.com/design/human-interface-guidelines/toolbars
  - HIG-SB: https://developer.apple.com/design/human-interface-guidelines/sidebars
  - HIG-COLOR: https://developer.apple.com/design/human-interface-guidelines/color
  - NN-H: https://www.nngroup.com/articles/ten-usability-heuristics/ （最終更新 2024-01-30）
  - NN-EMPTY: https://www.nngroup.com/articles/empty-state-interface-design/
  - NN-PD: https://www.nngroup.com/articles/progressive-disclosure/
  - NN-ONB: https://www.nngroup.com/articles/onboarding-tutorials/
  - NN-CLICK: https://www.nngroup.com/articles/clickable-elements/ （signifier / perceived affordance）
  - GRA-N: https://docs.granola.ai/help-center/taking-notes/notifications
  - GRA-T: https://docs.granola.ai/help-center/taking-notes/transcription
  - GRA-M: https://docs.granola.ai/help-center/troubleshooting/missing-notes
  - MW: https://macwhisper.helpscoutdocs.com/article/30-record-meetings
  - AH: https://rogueamoeba.com/support/manuals/audiohijack/?print=true
  - KR: https://whatsnew.krisp.ai/announcements/krisp-3-1-6-ai-meeting-assistant-improvements
- 未確認事項: Don Norman 本人の一次記述（jnd.org / 書籍）は直接取得できず、NN/g の記事経由（Norman の "perceived affordance → signifier" への言及）で代用。MacWhisper / Krisp / Granola のメニューバー UI の細部は公式ヘルプで確認できた範囲のみ。Audio Hijack・MacWhisper・Granola 公式製品ページは一部取得失敗（接続拒否・本文なし）のためヘルプ/マニュアルの検索結果の記述に基づく。

## 1. 競合アプリから読み取れる設計上の特徴（初見操作性に効くもの）
| アプリ | 特徴 | 出典 |
|---|---|---|
| Granola | メニューバー常駐はそれだけでは録音していない。録音開始はカレンダー通知の「ノートを開く」か、マイク使用検知時の「Take Notes」ボタン。通知は種別を帯の実線/破線で区別し、タイトルを "Huddle detected" / "Call detected" / "Meeting detected" と文脈に合わせる。他アプリ使用中は画面右にフローティングのライブ録音インジケータが出て、クリックでノートに戻る。録音されていない会議は復元不可とヘルプで明記 | GRA-N, GRA-T, GRA-M |
| MacWhisper | 会議検知時に "Meeting Detected" 通知＋Record ボタン、10 秒で自動消滅。検知対象アプリをドロップダウンで選択。必要権限（Screen Recording / Microphone）を機能説明に明記。ベータ機能にはベータと表示 | MW |
| Audio Hijack | 「セッション」という 1 つの単位（入力→処理→録音のブロック連結）で全てを説明。メニューバーのウィンドウから開始/停止と現在状態を確認。メニューバー表示は設定で ON/OFF（ユーザー主導）。録音先はデフォルト値あり（Music 内サブフォルダ） | AH |
| Krisp | macOS ネイティブのトップメニューにアップロード・更新確認・ヘルプを集約し、他の Mac アプリと同じ作法に寄せた。「録音しないアプリ」リスト（Do not transcribe）を設定に用意 | KR |

共通項: (1) 録音開始は明示操作に紐づく (2) 状態が常に見える (3) 検知→通知→1 クリックの短い導線 (4) 既定値で動き、設定は後回し。

## 2. チェックリスト（A〜J、全 61 項目）
判定欄は監査時に ✔ / ✘ / 要確認 を記入。「判定方法」は何を見るか（スクショ想定）。

### A. メニューバーアイコンとメニュー
| # | チェック項目 | 出典 | 判定方法 |
|---|---|---|---|
| A1 | メニューバーアイコンはシンボル/テンプレート画像（黒＋透明）で、ライト/ダーク両メニューバーと選択時の反転で読める | HIG-MB「Consider using a symbol… black and clear colors… dark and light menu bars, and when selected」 | ライト/ダーク/壁紙色違いの 3 通りのメニューバーを撮り、アイコンが消えない・色が崩れないか |
| A2 | アイコンの形状（色だけでなく）が 待機 / 録音中 / 処理中 / エラー で変わり、1 グリフで状態が分かる | NN-H #1 Visibility of System Status; HIG-COLOR「Avoid relying solely on color」 | 4 状態を並べて撮り、色を除いたグレースケールでも区別できるか |
| A3 | アイコンをクリックすると popover ではなくメニューが開く（機能が複雑すぎない限り） | HIG-MB「Display a menu — not a popover」 | クリック直後の表示形式。popover の場合は複雑さの正当性があるか |
| A4 | メニュー最上段が現在状態（例「待機中」「録音中 12:34」）の非操作行で、直下に最重要操作（録音開始/停止）がある | NN-H #1, #6 | メニュー全開のスクショ。1 行目で状態、2 行目で主操作が読めるか |
| A5 | 主操作ラベルが動詞句（「録音を開始」「録音を停止」）で、状態名（「録音」）だけの状態トグル表記になっていない | HIG-MENU「label…using a verb or verb phrase」「HDR On / HDR Off は動作か状態か不明」 | 録音中/待機中両方のメニューを比較し、ラベルが動作か状態か曖昧でないか |
| A6 | 使えない項目は消さずに薄表示（disabled）で、なぜ使えないかが他の行/ツールチップで分かる | HIG-MENU「Show people when a menu item is unavailable… dimmed」 | 録音中に押せない項目・Vault 未設定時の項目が dim か、非表示になっていないか |
| A7 | 追加入力が必要な項目だけに「…」が付く（付ければ必ずダイアログ/入力が出る） | HIG-MENU「Append an ellipsis…when the action requires more information」 | 「…」付き項目をクリックし、入力画面が出るか。付いていないのに確認が出る項目がないか |
| A8 | メニュー項目数が少なく（目安 10 前後以下）、区切り線で「録音」「会議一覧/開く」「設定」「終了」の塊に分かれる | NN-H #8 Aesthetic and Minimalist Design | メニュー全体のスクショ。項目数と区切りの論理 |
| A9 | 設定は標準の「設定…」(⌘,) で開き、「終了」も存在する。ショートカットは標準の意味と衝突しない | HIG-SET「Include a settings item…⌘,」; NN-H #4 Consistency and Standards | メニュー末尾の項目と、⌘, が動くか |
| A10 | メニューバーアイコンの表示/非表示をアプリが勝手に決めず、隠された場合の代替入口（Dock メニュー、主ウィンドウ等）がある | HIG-MB「Let people…decide」「Avoid relying on the presence of menu bar extras」「Dock menu」 | アイコンを隠した状態でアプリを再起動し、主要機能に到達できるか（Dock 右クリック等） |
| A11 | ツールチップ（ホバー）でアイコン/ボタンの意味が出る。アイコン単体ボタンにはラベルかツールチップがある | NN-CLICK「pair icons with text labels」; HIG-TB | ホバー時のスクショ。アイコンのみのボタンの有無 |

### B. 録音開始・状態表示・停止（コア導線）
| # | チェック項目 | 出典 | 判定方法 |
|---|---|---|---|
| B1 | 録音開始の導線がメニュー 1 クリック（＋任意の検知通知）で到達でき、所要クリック数が 2 以下 | NN-H #7; Granola/MacWhisper の「検知→通知→1 クリック」 | 初期状態からの操作ステップ数を数える |
| B2 | 録音中であることが「アイコンの変化」＋「メニュー内の経過時間」＋（任意で）ウィンドウ/フローティング表示の複数手段で分かる | NN-H #1; Granola のフローティングインジケータ（GRA-T） | 録音中の各画面のスクショ。アイコンだけに依存していないか |
| B3 | 「アプリが起動している」と「録音している」が区別でき、起動しただけで録音が始まる誤解を生まない表示がある | GRA-M「Having Granola open or running in your menu bar does not mean it is recording」 | 待機状態のメニュー/ウィンドウに「録音していません」が明示されているか |
| B4 | 録音停止は開始と同じ場所・同じ操作で行え、停止後に何が起きるか（保存/処理の開始）が即座に表示される | NN-H #3 User Control and Freedom, #1 | 録音中メニューの停止項目位置と、停止直後の表示 |
| B5 | 録音停止時に確認アラートを出さない（可逆・通常操作のため）。誤停止は後から救える（例: 続きの録音/破棄の取り消し） | HIG-ALERT「Avoid displaying alerts for common, undoable actions」 | 停止操作後に不要なダイアログが出ないか |
| B6 | 検知通知（会議検知）は文脈に合う見出し、主ボタン 1 つ、自動で消える、のいずれもが満たされる。録音を勝手に始めない | GRA-N, MW（10 秒で自動消滅）; HIG-NOTIF「Avoid…multiple notifications for the same thing」 | 通知のスクショ。見出し・ボタン・消滅時間・再通知の有無 |
| B7 | 録音中に他アプリ前面でも状態が分かる手段がある（メニューバーの変化／フローティング／macOS のマイク使用インジケータ） | GRA-T; NN-H #1 | 他アプリを前面にしたスクショでアプリの録音状態が読めるか |

### C. 権限リクエスト（マイク/画面収録/通知）
| # | チェック項目 | 出典 | 判定方法 |
|---|---|---|---|
| C1 | 権限は、その機能が必要になった時点（初回の録音開始時など）で要求する。起動直後に一括要求しない（必須機能で理由が明白な場合を除く） | HIG-PRIV「Request permission only when your app clearly needs access」「Avoid requesting permission at launch unless…required」 | 初回起動から最初のシステムダイアログが出るまでの操作を記録 |
| C2 | purpose string は具体的な 1 文（何のために録音するか）。「より良い体験のため」型の曖昧文でない | HIG-PRIV「Microphone access is needed for a better experience.」が悪例 | システムダイアログのスクショで文言を読む |
| C3 | 事前説明画面を出す場合、ボタンは 1 つでシステムダイアログを開くことが明白（「許可」と書かない、キャンセルを置かない） | HIG-PRIV「Include only one button…」「Don't include additional actions」 | 事前説明画面のボタン数とラベル |
| C4 | 権限拒否後に、何ができなくなったかと復旧手順（システム設定の該当パネルを開くボタン）が画面内にある | NN-H #9 Recover from Errors; HIG-SET「provide a button that opens it directly」 | 権限を拒否した状態で録音開始し、エラー表示の文言とボタンを確認 |
| C5 | 必要な権限の一覧と現在の許可状態（許可済/未許可）が設定内で一目で分かる | NN-H #1, #6 | 設定画面の権限セクションのスクショ |

### D. 初回起動・オンボーディング
| # | チェック項目 | 出典 | 判定方法 |
|---|---|---|---|
| D1 | 説明なしで最初の操作が分かる。必須の事前フローは短く、スキップ可能（任意） | HIG-ONB「fast, fun, and optional」; NN-ONB（チュートリアルは飛ばされ・忘れられる） | 初回起動から最初の録音完了まで、説明を読まずに到達できるか実機で試行 |
| D2 | 必須のセットアップ（例: Vault の保存先、API キー）は最小限で、既定値ですぐ使える。任意設定は後回し | HIG-ONB「Postpone nonessential setup…reasonable default settings」; HIG-SET | 初回に求められる入力項目数。既定値で録音まで進めるか |
| D3 | 初回に画面が空にならず「次にすること」が 1 つ明示される（メニューバー常駐アプリで、アイコンの場所が分からない状態を作らない） | NN-EMPTY; HIG-MB | 初回起動直後のスクショ。メニューバーのどこを見るかが示されているか |
| D4 | 手順の説明より、文脈に応じたヒント（その場で見えるラベル/ツールチップ/空状態）に説明を置く。標準的記号（歯車=設定）は説明しない | NN-ONB「pull revelation」「skip the obvious」; HIG-ONB「context-specific tips」 | オンボ画面の文字量と、各画面内のヒントの有無 |
| D5 | 同意/規約/ライセンスの説明がオンボーディングを妨げない位置にある。録音に関する同意（相手への告知）の注意は録音開始の文脈で出る | HIG-ONB「Avoid displaying licensing details」 | 初回フローで規約画面が主導線を邪魔していないか |
| D6 | オンボーディングを後から見直せる入口（ヘルプ/設定内）がある。スキップしたものを再提示し続けない | HIG-ONB「make it easy to find later」 | 設定/ヘルプ項目のスクショ |

### E. 空状態・一覧（会議リスト）
| # | チェック項目 | 出典 | 判定方法 |
|---|---|---|---|
| E1 | 会議が 0 件の画面は空白でなく、何が表示される場所かと、埋める方法（録音開始ボタン）を示す | NN-EMPTY「Tell the user what could be displayed, and how to populate」「Provide direct pathways」 | 初期データ 0 件でのスクショ |
| E2 | 読込中/処理中の空表示を「項目なし」と誤認させない（ローディング表示と区別） | NN-EMPTY「Show accurate status while loading」; HIG-LOAD「Show something as soon as possible」 | 起動直後・処理中の一覧スクショ |
| E3 | 一覧の各行で、状態（録音済/文字起こし中/議事録作成済/失敗）が文字またはアイコン＋文字で分かる。色だけに依存しない | HIG-COLOR; NN-H #1 | 状態違いの行を並べたスクショ（グレースケール化して確認） |
| E4 | 失敗した行には、原因と「再実行」などの次の操作が同じ行にある | NN-H #9「plain language, precise problem, suggest a fix」 | 失敗行のスクショ。エラーコードのみの表示でないか |
| E5 | 一覧の主要操作（開く、再実行、削除）が見える位置にある。ホバー/右クリックでのみ出る操作は他にも導線がある | NN-H #6 Recognition rather than recall; NN-CLICK | 操作が隠れていないか。ホバー前後のスクショ |
| E6 | 行のクリックで詳細が開く（クリック可能に見える、非クリック要素とボタンを混同しない） | NN-CLICK「Non-clickable items…should not be styled like buttons」 | ホバー時のカーソル/ハイライト、見出しがボタン風になっていないか |

### F. 設定ウィンドウ
| # | チェック項目 | 出典 | 判定方法 |
|---|---|---|---|
| F1 | 設定は ⌘, で開き、ツールバーのタブ（ペイン）で分類、常に表示され選択中が分かる。タイトルは現在のペイン名 | HIG-SET「noncustomizable toolbar…indicates the active toolbar button」「Update the window's title」 | 各ペインのスクショ。ウィンドウタイトルとタブの選択状態 |
| F2 | 設定項目が少なく、既定値が多数のユーザーに最適。変更が即時反映で、保存ボタンが要らない | HIG-SET「Minimize the number of settings」「Aim to provide default settings」 | 設定項目数（ペインあたり目安 7 以下）と保存ボタンの有無 |
| F3 | 設定ラベルが内部用語でなく利用者の言葉（「Vault」「ASR」「ジョブ」の説明なき使用がない） | NN-H #2 Match with the real world | 全ラベルを読み、専門用語に補足があるか |
| F4 | 上級項目は折りたたみ/別ペインで、2 段階までに収まる | NN-PD「Limit disclosure to two levels」 | 詳細設定への到達階層数 |
| F5 | 保存先（Vault 等）は現在値のフルパスまたは選択済みフォルダ名と「変更…」ボタンが並び、検証結果（書き込み可否）が表示される | NN-H #1, #5 | 保存先設定のスクショ |
| F6 | 自動化（automation）の ON/OFF とその意味が 1 行説明で分かり、何が自動実行されるかを事前に確認できる | NN-H #5 Error Prevention, #1 | 自動化設定の文言と、実行結果の確認先 |

### G. 破壊的操作・確認ダイアログ
| # | チェック項目 | 出典 | 判定方法 |
|---|---|---|---|
| G1 | 取り消し不能な削除/上書きのみ確認アラートを出し、取り消せる操作には出さない | HIG-ALERT「Avoid displaying alerts for common, undoable actions」「uncommon destructive action that they can't undo → display an alert」 | 削除/再生成の操作で確認有無を一覧化。undo が効く操作に確認がないか |
| G2 | アラートのタイトルが状況を具体的に述べる（「エラー」「Error 3042」でない）。本文は必要な場合のみ | HIG-ALERT「Avoid…like 'Error'」 | ダイアログのスクショで文言を読む |
| G3 | ボタンは動詞（「削除」「録音を破棄」）で、確認系の「OK/はい/いいえ」を使わない。キャンセルは「キャンセル」 | HIG-ALERT「Avoid using OK as the default button title unless purely informational」「Always use Cancel」 | ボタンラベルの全数チェック |
| G4 | 破壊的ボタンは危険スタイルで、既定ボタン（Return）は安全な選択（キャンセル）。Esc/⌘. でキャンセルできる | HIG-ALERT「destructive style」「you don't want to make a Cancel button the default」 | ダイアログのスクショ（赤文字/既定ボタンの枠）と Esc の動作 |
| G5 | アプリ起動時にアラートを出さない（問題はキャッシュ表示＋非モーダルのインジケータで知らせる） | HIG-ALERT「Avoid showing an alert when your app starts」 | 起動直後の表示。エラー状態で起動して確認 |
| G6 | 情報のみのお知らせにアラートを使わない（文脈内インジケータにする）。同じ警告の繰り返しに「今後表示しない」がある | HIG-ALERT「Avoid using an alert merely to provide information」「suppression」 | 全アラート一覧を洗い出し、通知で済むものを抽出 |

### H. 進捗・処理中表示・通知
| # | チェック項目 | 出典 | 判定方法 |
|---|---|---|---|
| H1 | 文字起こし/議事録生成の進捗が見える（可能なら determinate、不可ならスピナー＋「何をしているか」の簡潔な説明）。「処理中…」「Loading」だけにしない | HIG-PROG「use determinate when possible」「Avoid vague terms like loading」 | 処理中の画面スクショ。段階名（文字起こし→要約→Vault 書込）が出ているか |
| H2 | 進捗が止まって見えない（動き続ける）。停滞時は理由と取れる行動を示す | HIG-PROG「Keep progress indicators moving…If a process stalls…provide feedback」 | 長時間処理時の画面（アニメーション有無、経過時間表示） |
| H3 | 長時間処理は中断/キャンセル可能で、失うものがある場合はその旨を確認する | HIG-PROG「let people halt processing」「Let people know when halting has a negative consequence」 | 処理中メニュー/ウィンドウにキャンセル項目があるか |
| H4 | 完了/失敗の通知は短く具体的で、同じ内容を繰り返さず、機密（会議内容）を載せない。エラーはアラート/インライン、通知ではない | HIG-NOTIF「concise, informative」「Use an alert — not a notification — to display an error」「Avoid sensitive info」 | 通知のスクショ。議事録本文が表示されないか。エラー通知の有無 |
| H5 | 通知のアクションは有用なもの 1〜2 個（例: 「議事録を開く」）。「アプリを開く」だけのボタンを置かない | HIG-NOTIF「Avoid providing an action that merely opens your app」 | 通知アクションの一覧 |
| H6 | 処理結果の出力先（Vault 内のどこに保存されたか）に 1 クリックで到達できる | NN-H #1, #7 | 完了後の画面にパス/「Finder で表示」「開く」があるか |

### I. エラー・復旧
| # | チェック項目 | 出典 | 判定方法 |
|---|---|---|---|
| I1 | エラー文は平易な言葉、問題の特定、解決策の提示の 3 点を満たす（内部例外メッセージをそのまま出さない） | NN-H #9 | 代表的な失敗（APIキー不正、Vault 書込失敗、ネットワーク断）を発生させ、文言を採取 |
| I2 | 一時的失敗の再実行ボタンがあり、再実行しても重複や上書きが起きない | NN-H #3, #5 | 再実行後の結果（重複ファイルがないか）と、ボタンの位置 |
| I3 | 前提未設定（Vault 未設定、APIキー未設定、権限なし）のとき、機能を隠さず「何を設定すれば使えるか」とそこへのリンクを表示する | NN-H #6, #9; HIG-MENU（dimmed で存在を示す） | 未設定状態で主要画面を巡回し、行き止まりがないか |

### J. 一貫性・アクセシビリティ・全般
| # | チェック項目 | 出典 | 判定方法 |
|---|---|---|---|
| J1 | 同じ概念に同じ語を使う（「会議/ミーティング/セッション」「議事録/ノート/minutes」が混在しない）。言語は日本語UI内で統一 | NN-H #4 Consistency and Standards | 全画面の用語を抜き出して表記ゆれを集計 |
| J2 | 色だけで状態/重要度を区別しない。アイコンには文字か形の差を併用 | HIG-COLOR「Avoid relying solely on color」 | 画面をグレースケール化して比較 |
| J3 | 標準コントロール（ボタン、トグル、メニュー、ファイル選択）を使い、ボタンに見える要素は押せ、押せる要素はボタンに見える | NN-CLICK; NN-H #4 | 全画面のスクショで、フラットすぎてクリック可能性が不明な要素を抽出 |
| J4 | ヘルプなしで主要タスク（録音→停止→議事録を開く）を完了でき、ヘルプが必要な場合も検索不要で短く、タスク単位 | NN-H #10 Help and Documentation | 未経験者（または説明を渡さない状態の自分）が主要 3 タスクを完遂する時間と迷った箇所 |
| J5 | ダーク/ライト、フォントサイズ変更、ウィンドウ縮小で崩れない（文字切れ・重なりなし） | HIG-COLOR; NN-H #4 | ダーク/ライトの両方で全画面を撮り、切れ・コントラストを確認 |

## 3. 使い方（推奨）
1. 画面ごとに撮影（初期/空/録音中/処理中/失敗/権限拒否/設定の各ペイン/ダーク）。
2. 各項目で ✔/✘/要確認。✘ は画面名・再現手順・推奨修正を併記。
3. 重大度の目安: コア導線（A4, A5, B2〜B4, C1, C4, D1, H1）の ✘ は P1、その他は P2〜P3。
4. 最終判定「説明文なしで初見操作できるか」は J4 の実測で裏取りする（チェック項目の総和ではなく、タスク完遂率を優先）。
