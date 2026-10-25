# Task 6 の生出力（AppleSpeechProbe、Intel x86_64 / macOS 26.6.2、2026-10-25）

計画 00 Task 6 の実装者レポートから、測定の生出力と実装者の所見の部分だけを抜き出したもの（E2E の出力と作業メモは除き、ほかは元の文言のまま）。結果表の項目 2・12 の根拠。パスは `<repo>/`（リポジトリ）と `$TMPDIR/` に置き換えた。参照テキスト `tools/samples/ja-5min.txt` は現在の `scripts/samples/ja-5min.txt` と同じ内容（md5 9c6948098a7d67e13c51dd71e992bb5d）。

## 短い確認（whisper ベンチと並走中。RTF は参考値）

- `--engine transcriber --locale ja-JP`: `SpeechTranscriber.isAvailable: false`、`supportedLocales: 0 件`。ただし `supportedLocale(equivalentTo: ja-JP)` は `ja_JP` を返す（空の一覧と矛盾。判定に使えない → `isAvailable` と `supportedLocales` で判定すべき）。DictationTranscriber は 20 ロケール、installedLocales = en_US, ja_JP。0.9 秒、exit 0。
- **資産取得（AssetInventory）**: 呼ぶ前の status はどちらも `supported`（installedLocales に載っていても）。`assetInstallationRequest` が非 nil で `downloadAndInstall()` 後 `installed`。
  - ja-JP: **0.16 秒**（既にディスクにあり、割り当てだけと推定）
  - en-US: **6.02 秒**（初回）
- **DictationTranscriber は音声認識の TCC 許可なしで動いた**（`SFSpeechRecognizer.requestAuthorization` を呼ばずに認識結果が返った。authorizationStatus は 0=未決定のまま）。
- **SFSpeechRecognizer は許可が要り、責任プロセスの Info.plist を見る**: 1 回目は Info.plist なしで SIGABRT（TCC: "must contain an NSSpeechRecognitionUsageDescription key"）。`__info_plist` を埋め込んでも、起動元（Orca.app）が責任プロセスなので同じく SIGABRT。sf のときだけ `responsibility_spawnattrs_setdisclaim`（非公開 API）で自分を責任プロセスとして起動し直すと落ちずにダイアログ待ちになった。→ 本体アプリで SF を使うなら AutoNote.app の Info.plist に `NSSpeechRecognitionUsageDescription` が必須。DictationTranscriber なら不要。
- dictation 短い確認（生出力は下）: ja 先頭 30 秒 RTF 0.677（経過 20.3 秒）、en-30s RTF 0.574・CER 0.0833（--no-punct 0.0528）。プロセス自身の CPU は 6% 程度（認識は別のシステムプロセスで走る）。結果は `.longDictation` だと 30 秒で確定 1 件。

### 生出力: dictation ja 先頭 30 秒
```
engine: dictation  locale: ja-JP  file: $TMPDIR/AppleSpeechProbe-trim-30s.wav  音声秒: 30.0  contextual: []
DictationTranscriber locale=ja_JP preset=.longDictation（transcriptionOptions=[Speech.DictationTranscriber.TranscriptionOption.punctuation] reportingOptions=[] attributeOptions=[] contentHints=0 件）
AssetInventory.status: supported
資産の取得を開始（AssetInstallationRequest）
資産の取得: 0.16 秒（progress 1/1）
AssetInventory.status（取得後）: installed
準備秒（ロケール・資産確認・初期化）: 0.34
結果の件数: 1（確定 1）
経過秒: 20.32
RTF: 0.677
文字数: 150  全文: $TMPDIR/AppleSpeechProbe-dictation-hyp.txt
先頭 200 文字: 目的と背景に、1困っている場面利用者の言葉をGoogleミートジェームズ面ハードルの打ち合わせ後に議事録をまとめるのが面倒会議中に10分前の会話を見返したい過去1ヵ月分の会議の文字起こしを蔵人に読み込ませ代理店に1つだけ完璧にするなら議事録青青と黒の連携のための保存形式と置き場所会議中の画面はその次
.build/debug/AppleSpeechProbe --engine dictation --file  --seconds 30  0.96s user 0.37s system 6% cpu 20.729 total
```

### 生出力: dictation en-30s（--contextual "AutoNote,Kubernetes"）
```
engine: dictation  locale: en-US  file: <repo>/tools/samples/en-30s.wav  音声秒: 30.2  contextual: ["AutoNote", "Kubernetes"]
DictationTranscriber locale=en_US preset=.longDictation（transcriptionOptions=[Speech.DictationTranscriber.TranscriptionOption.punctuation] reportingOptions=[] attributeOptions=[] contentHints=0 件）
AssetInventory.status: supported
資産の取得を開始（AssetInstallationRequest）
資産の取得: 6.02 秒（progress 1/1）
AssetInventory.status（取得後）: installed
準備秒（ロケール・資産確認・初期化）: 6.22
結果の件数: 1（確定 1）
経過秒: 17.35
RTF: 0.574
CER: 0.0833 (36/432)
CER（--no-punct）: 0.0528 (22/417)
文字数: 500  全文: $TMPDIR/AppleSpeechProbe-dictation-hyp.txt
先頭 200 文字: Good morning everyone thanks for joining today's weekly sink first the release schedule we agreed to ship the bed on Friday and Ken will send a bill to the testers on Thursday evening second the trans
```

### 生出力: sf ja 先頭 30 秒（許可ダイアログ待ち）
```
engine: sf  locale: ja-JP  file: $TMPDIR/AppleSpeechProbe-trim-30s.wav  音声秒: 30.0  contextual: []
SFSpeechRecognizer.authorizationStatus: 0（0=未決定 1=拒否 2=制限 3=許可）
音声認識の許可を要求する（ダイアログが出たら利用者の操作待ち）
```

## 本計測（CPU 空き）

- SF の先頭 30 秒の確認は許可後に完了（RTF 0.315）。出力 150 字は dictation と一字一句同じ（同じモデル）。
- 本計測（CPU 空き）: dictation RTF 0.307 / CER 0.3494（記号除く 0.3045）。SF RTF 0.302 / CER 0.8912（確定の本文のみ）。
- **SF の発見**: `shouldReportPartialResults = false` でも非確定のコールバックが 4 回、5 回目が isFinal。isFinal の bestTranscription は最後の約 1 分（277 字）だけ。最後の語の終わりは 295.3 秒なので音声は最後まで処理されている →「打ち切り」ではなく「約 1 分ごとの区切り」。SFCollector を区間ごとに記録して連結するよう直した（`[+秒] 区間:` 行で各区間の時刻範囲を出す）。
- **再ビルドで TCC の許可が未決定に戻った**（ad-hoc 署名の cdhash が変わるため）。連結版の SF 再計測は再び音声認識の許可ダイアログ待ち（👤）。dictation は許可不要なので影響なし。

### 生出力: dictation 5 分
```
engine: dictation  locale: ja-JP  file: <repo>/tools/samples/ja-5min.wav  音声秒: 295.4  contextual: []
DictationTranscriber locale=ja_JP preset=.longDictation（transcriptionOptions=[Speech.DictationTranscriber.TranscriptionOption.punctuation] reportingOptions=[] attributeOptions=[] contentHints=0 件）
AssetInventory.status: installed
資産の取得を開始（AssetInstallationRequest）
資産の取得: 0.02 秒（progress 1/1）
AssetInventory.status（取得後）: installed
準備秒（ロケール・資産確認・初期化）: 0.14
結果の件数: 5（確定 5）
経過秒: 90.72
RTF: 0.307
CER: 0.3494 (594/1700)
CER（--no-punct）: 0.3045 (475/1560)
文字数: 1476  全文: $TMPDIR/AppleSpeechProbe-dictation-hyp.txt
先頭 200 文字: 目的と背景に、1困っている場面利用者の言葉をGoogleミートジェームズ面ハードルの打ち合わせ後に議事録をまとめるのが面倒会議中に10分前の会話を見返したい過去1ヵ月分の会議の文字起こしを蔵人に読み込ませ代理店に1つだけ完璧にするなら議事録青青と黒の連携のための保存形式と置き場所会議中の画面はその次1.3成功の姿会議用のマイク機材をつなぐだけで録音が始まり外すと泊まりしばらく後Appleシリコンな
```

### 生出力: sf 5 分（連結前。確定の本文のみ）
```
engine: sf  locale: ja-JP  file: <repo>/tools/samples/ja-5min.wav  音声秒: 295.4  contextual: []
SFSpeechRecognizer.authorizationStatus: 3（0=未決定 1=拒否 2=制限 3=許可）
SFSpeechRecognizer isAvailable=true supportsOnDeviceRecognition=true
[+89.1] 確定: セグメント 127 個、最後の語の終わり 295.3 秒
コールバック回数: 5（確定後の追加: 0）
経過秒: 89.14
RTF: 0.302
CER: 0.8912 (1515/1700)
CER（--no-punct）: 0.8853 (1381/1560)
文字数: 277  全文: $TMPDIR/AppleSpeechProbe-sf-hyp.txt
先頭 200 文字: 愛とみなすもの録音したつもりで部員がいるだけが残る電源切れ機材違い音声ファイルがボルトに入りオブシリアンの時を重くするAppleシリコンでしか動かない4008文字起こし全文が利用者の意図しない形でグラウンドに送られる会議以外の場面で勝手に録音が始まる前程度1103.1環境項目内容開発利用喜一MacBook Pro 2020インテル強アイ7から1068エヌジー74582、3ギガヘルツ32 GBインテ
```

### 生出力: sf 先頭 30 秒（許可後）
```
engine: sf  locale: ja-JP  file: $TMPDIR/AppleSpeechProbe-trim-30s.wav  音声秒: 30.0  contextual: []
SFSpeechRecognizer.authorizationStatus: 0（0=未決定 1=拒否 2=制限 3=許可）
音声認識の許可を要求する（ダイアログが出たら利用者の操作待ち）
SFSpeechRecognizer.authorizationStatus（要求後）: 3
SFSpeechRecognizer isAvailable=true supportsOnDeviceRecognition=true
[+9.4] 確定: セグメント 70 個、最後の語の終わり 29.8 秒
コールバック回数: 1（確定後の追加: 0）
経過秒: 9.45
RTF: 0.315
文字数: 150  全文: $TMPDIR/AppleSpeechProbe-sf-hyp.txt
先頭 200 文字: 目的と背景に、1困っている場面利用者の言葉をGoogleミートジェームズ面ハードルの打ち合わせ後に議事録をまとめるのが面倒会議中に10分前の会話を見返したい過去1ヵ月分の会議の文字起こしを蔵人に読み込ませ代理店に1つだけ完璧にするなら議事録青青と黒の連携のための保存形式と置き場所会議中の画面はその次
```

## SF 連結版の再計測

- 区間はちょうど 60 秒ごと（5 区間）。連結版の CER 0.3494 / 0.3045 は dictation と同値で、`cmp` で全文が完全一致（同じモデル）。RTF 0.342。結果表の SF 行と注記を差し替えた。

```
engine: sf  locale: ja-JP  file: <repo>/tools/samples/ja-5min.wav  音声秒: 295.4  contextual: []
SFSpeechRecognizer.authorizationStatus: 0（0=未決定 1=拒否 2=制限 3=許可）
音声認識の許可を要求する（ダイアログが出たら利用者の操作待ち）
SFSpeechRecognizer.authorizationStatus（要求後）: 3
SFSpeechRecognizer isAvailable=true supportsOnDeviceRecognition=true
[+20.6] 区間: セグメント 144 個、0.0〜59.8 秒、310 文字
[+39.1] 区間: セグメント 143 個、60.0〜120.0 秒、304 文字
[+57.0] 区間: セグメント 139 個、120.0〜180.0 秒、301 文字
[+81.0] 区間: セグメント 132 個、180.0〜239.6 秒、284 文字
[+100.9] 確定: セグメント 127 個、240.0〜295.3 秒、277 文字
区間数: 5（確定の bestTranscription 単体は 277 文字）
コールバック回数: 5（確定後の追加: 0）
経過秒: 100.90
RTF: 0.342
CER: 0.3494 (594/1700)
CER（--no-punct）: 0.3045 (475/1560)
文字数: 1476  全文: $TMPDIR/AppleSpeechProbe-sf-hyp.txt
先頭 200 文字: 目的と背景に、1困っている場面利用者の言葉をGoogleミートジェームズ面ハードルの打ち合わせ後に議事録をまとめるのが面倒会議中に10分前の会話を見返したい過去1ヵ月分の会議の文字起こしを蔵人に読み込ませ代理店に1つだけ完璧にするなら議事録青青と黒の連携のための保存形式と置き場所会議中の画面はその次1.3成功の姿会議用のマイク機材をつなぐだけで録音が始まり外すと泊まりしばらく後Appleシリコンな
```
