# 録音中のレイアウトループによるクラッシュ（2026-11-01, branch feature/f3-layout-loop @ ae5363d）

問い: 2026-10-30 12:03:00、ライブ要約（`live_summary_enabled`）を有効にした直後の録音中にアプリが落ちた。何がレイアウトを止まらなくしたのか。

## 結論

- **ループしていたのは録音画面の文字起こし（`LiveTranscriptView` の ScrollView）。** 旧式スクロールバー（マウスを繋いだときの既定。幅を取る）が出ると行の幅が約 15pt 狭まり、折り返しが 1 行（16pt）増える。内容の高さが枠の高さを 1 行分またぐ位置にあると、「はみ出す → バーが出る → 1 行増える」「収まる → バーが消える → 1 行減る」が往復する。`defaultScrollAnchor(.bottom)` がはみ出すたびに下端へ offset を動かすので、1 回の `layoutIfNeeded` の中で往復が止まらず、AppKit のレイアウト回数の上限（10/30 の実機で 242）を超えて例外で落ちる
- **ライブ要約カードは原因ではない。** カードの出現・伸縮・開閉が文字起こしの枠の高さを動かし、境界に入る機会を増やす（ハーネスで開閉なし 1/6 → あり 3/6）。だから「ライブ要約を有効にした直後」に表に出た。会議の冒頭（12:00:02 開始、約 3 分後）は文字起こしが初めて画面を埋める頃でもある
- **修正: 文字起こしの行の幅を、スクロールバーの有無に依存させない。** ScrollView の外枠の幅から旧式スクロールバーの幅を常に差し引いた幅に行を固定する（`TranscriptLayout.rowWidth`、オーバーレイ型なら差し引き 0。マウスの抜き差しは `NSScroller.preferredScrollerStyleDidChangeNotification` で追従）。下端への追従・「最新へ」は変えていない。ハーネスで修正前 7/24 → 修正後 0/24（同じ考え方の初版を含めると 0/36）
- ライブ要約カードの ScrollView も同じ形（旧式バーで幅が変わる）だが、高さを `min(内容, 220)` にしているため、内容の高さを 1 語ずつ増やして 220pt を往復させる掃引でもループしなかった（ループ中にカードのコールバックは一度も回っていない）。今回は触っていない

## 10/30 のクラッシュの記録

- `EXC_BREAKPOINT`。落ちたスレッドは `+[NSApplication _crashOnException:]` ← `_NSViewLayout` ← `NSWindow layoutIfNeeded`。直前に `Marking window … as needing Layout Window … (limit: 242, count: 243)`、SwiftUI `NSHostingView.layout` → `ScrollActionDispatcher` の `requestImmediateUpdate` の繰り返し。アプリのフレームは無い
- クラッシュレポート（`AutoNoteApp-2026-10-30-120307.ips`）と 10/30 の unified log は、11/01 の調査時点で保持期間を過ぎて残っていない。上の記述は 10/30 の調査メモによる。10/30 の録音データも残っていない

## 再現の方法

### 合成データのハーネス（主な根拠）

`RecordingDetailView` と同じ組み方（NavigationSplitView の詳細に 操作行 / Divider / `LiveSummaryCard` / `LiveTranscriptView`。ae5363d のコードの写し）に、タイマーで行と要約を流す小さな SwiftUI アプリ。whisper も音声も使わない。リポジトリには入れていない（Lead の scratchpad の `reports/f3-layout-harness.tar.gz`）。

- 行: 0.25 秒ごとに部分結果を置き換え、4〜30 語で確定して次の行へ（`LiveFeed` と同じく毎回スナップショット全体を渡す）
- 要約: 起動 5 秒後にカードが現れ、3 秒ごとに決定事項・宿題が増減する。「n 秒前に更新」を毎秒更新
- 要素ごとに環境変数で外せる（`NO_SCROLLTO`、`NO_ANCHOR`、`NO_POSITION`、`EAGER`＝`VStack`、`NO_GEOM`、`FIXED_CARD`、`FIXED_WIDTH`＝修正）。`TOGGLE` でカードを開閉、`RESIZE` でウィンドウの大きさを変える、`SWEEP` でカードの高さを 1 語ずつ掃引
- 旧式スクロールバーは `-AppleShowScrollBars Always`、オーバーレイ型は `WhenScrolling` で起動時に強制する
- ループの検出: ランループ 1 回の中で文字起こしの `onScrollGeometryChange` が 1000 回呼ばれたら値を出して終了する。放っておくと AppKit が `NSGenericException` を投げて落ちる（再現した: `limit: 275, count: 279`。スタックは 10/30 と同じ `NSWindow layoutIfNeeded` → `_NSViewLayout` → `NSHostingView.layout` → SwiftUI の更新 → `setNeedsUpdateConstraints` → `-[NSWindow(NSDisplayCycle) _postWindowNeedsUpdateConstraints]`）。落ちる前に、1 回のレイアウトの中で数十秒〜数分メインスレッドが固まる

ループ中の値（ランループ 1 回の中の、文字起こしの offset と内容の高さ）:

```
o=0 h=282 | o=9 h=298 | o=0 h=282 | o=9 h=298 | …     （枠の高さ 289pt）
o=0 h=238 | o=11 h=270 | o=0 h=254 | o=0 h=238 | …
```

### 発生率（旧式スクロールバー、2 倍速、30 秒の実行を繰り返す。カード開閉 0.4 秒ごと）

| 条件 | ループ |
|---|---|
| 修正前（基準） | 6/18 |
| 修正前、開閉なし | 1/6 |
| 修正前、開閉 + 大きさ変更 + カード掃引 | 1/6 |
| オーバーレイ型スクロールバー | 0/12（+ 長時間 0/2） |
| `defaultScrollAnchor` を外す | 0/18 |
| `onChange` の `scrollTo` を外す | 1/18 |
| `scrollPosition` ごと外す | 2/6 |
| `LazyVStack` → `VStack` | 0/6 |
| 文字起こしの `onScrollGeometryChange` を外す | 0/6 |
| 文字起こしに `.scrollIndicators(.visible)` | 2/6 |
| カードの高さを固定 | 5/6 |
| **修正後（行の幅を固定）** | **0/18** |
| **修正後、開閉 + 大きさ変更 + カード掃引** | **0/6** |
| 修正後（同じ考え方の初版） | 0/12 |

修正前の基準（約 1/3）で 18 回続けてループしない確率は約 0.07%。

### 実機

`build/AutoNote.app` を `AUTONOTE_DATA_DIR=/tmp/an-f3`、`-AppleShowScrollBars Always`（旧式スクロールバー）で起動した。ライブ文字起こしは Apple（`dictation`）、確定版は whisper `base`、ライブ要約は偽の `claude`（`claude_path` に、`claude auth status --json` と `claude -p --output-format json` の出力を真似て、決定事項・宿題を 1〜14 件で増減させるシェルスクリプトを指定。実物の claude は呼んでいない）で 10〜20 秒ごと。録音は CLI（`autonote start` / `stop`）で始め、`say -v Kyoko` で日本語の会議文を読み上げ続けた。ウィンドウ（900×572）は毎回画面上にあることを `CGWindowListCopyWindowInfo` で確かめた。`log stream` でこのアプリの `needing Layout` / `NSGenericException` を監視した。

- **修正前の版では、実機では再現しなかった。** 2 分の録音を 14 回（うち 8 回は毎回アプリを起動し直し、何も選択していない＝録音画面が出ている状態で開始）、計 約 28 分。警告 0、クラッシュ 0。ハーネスでもカード開閉なしの発生率は 1/6 程度で、実機には 0.4 秒ごとの開閉も 2 倍速の更新も無いので、もっと低いと考える
- 注意: 録音を止めると止めた会議が選択される（`AppModel.showStoppedBand`）。続けて録音すると、ウィンドウには録音画面ではなく前の会議の処理中画面（`ProcessingDetailView`、`LiveTranscriptView(follows: false)`）が出る。10/30 の 12:00 の停止の後もこの状態だった可能性がある。ハーネスで `follows: false`（上端アンカー）も試し、旧式スクロールバーでループした（1/12）。修正は `LiveTranscriptView` に入れたので、録音・処理中・議事録なし・完了の各画面の文字起こしに効く（修正後 `follows: false` で 0/12）

## 修正

- `Sources/AutoNoteCore/Presentation/TranscriptLayout.swift`: `rowWidth(outerWidth:scrollerWidth:legacyScroller:)`。外枠の幅 − 旧式バーの幅（オーバーレイ型は 0）。未計測（0 以下）は nil、負にしない。テスト `Tests/AutoNoteCoreTests/Presentation/TranscriptLayoutTests.swift`
- `Sources/AutoNoteApp/MainWindow/LiveTranscriptView.swift`: ScrollView の外枠の幅を `onGeometryChange` で測り（外枠は内容に依存しないので一方向）、`LazyVStack` に `.frame(width: rowWidth)` を与える。旧式かどうかは `@State` に持ち、`preferredScrollerStyleDidChangeNotification` で更新する
- 見た目の変化: 旧式バーが出ていないとき、文字起こしの右端に約 15pt の余白ができる（バーが出ても文字が動かない）

### 選ばなかった案

- `defaultScrollAnchor` を外す（0/18）: 下端に張り付く追従の仕組みを作り直すことになる
- `LazyVStack` → `VStack`（0/6）: 1 時間の会議（千行超）で、0.25 秒ごとの部分結果の更新のたびに全行を測り直す。4 コア Intel では重い
- `.scrollIndicators(.never)`: バーが無くなり、マウス利用者が位置を見失う。`.visible` はループを止めない（2/6）
- `onChange` の `scrollTo` を外す: ループは止まらない（1/18）

## 確認

- `swift test`（並列）: 1030 件中 1029 件通過。落ちた `ProcessTapSourceTests.stopAfterTimedOutStartReturnsPromptly` は時間依存で、`--no-parallel --filter ProcessTapSourceTests` で 14 件すべて通過（今回の変更と無関係）。新しい `TranscriptLayoutTests` 4 件通過
- 修正版の実機で 30 分録音（上と同じ条件、旧式スクロールバー、ライブ要約 10 秒ごと、読み上げ 180 回 → ライブの発話 180 件）: クラッシュなし、`needing Layout` 警告 0
- `scripts/e2e-check.sh`: 36 passed / 2 failed / 5 skipped。失敗の 7b・07.3 は、メニューバーを osascript でプロセス名から読む項目が、利用者の稼働中の AutoNoteApp と取り違えるもの（既知の環境要因。今回の変更と無関係）
- 利用者が後で行う確認: マウスを繋いだ状態（旧式スクロールバー）で、ライブ要約を有効にして 30 分の会議を録音する。文字起こしの右端に約 15pt の余白があること、スクロールバーが出ても文字が折り返し直さないこと

## 関連

- 録音はクラッシュしても `CrashRecovery` で残り、次の起動時に「前回の録音が途中で終わっています。文字起こしと議事録を作りますか？」と聞かれる。録音は自動では再開しない（`docs/guide/reference.md`「アプリが異常終了したとき」）
- 当初の仮説（`onChange` → `scrollTo` の連鎖、`LazyVStack` の推定高さ）は、どちらも主因ではなかった
