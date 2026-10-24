# AutoNote 要件調査: Apple 公式情報（A〜F）

調査日: 2026-10-24 / 調査機: Intel x86_64, macOS 26.6.2（開発者の手元 Mac と同機種と推定）
凡例: **[公式]** Apple 一次情報 / **[SDK]** Xcode の SDK ヘッダ（Apple 一次）/ **[実測]** この Intel Mac で実行して確認 / **[二次]** 第三者・フォーラム / **[未確認]**

実測コードの置き場: `/private/tmp/claude-501/-Users-yuta-okoshi/fde3fd58-1d2c-4350-b7a6-c0d60d26a1e6/scratchpad/probe/`（speech: main.swift, dev: dev/main.swift, tap: tap/main.swift）

## 0. 先頭サマリ

### Intel Mac で使えない API
- **SpeechAnalyzer / SpeechTranscriber は、この Intel Mac（macOS 26.6.2）では使えない。[実測]** `SpeechTranscriber.isAvailable == false`、`supportedLocales` は 0 件。日本語も英語も不可。
  - Apple のドキュメントにも「デバイスが非対応なら `supportedLocales` は空」とある。[公式] ただし「Intel は非対応」という明文は見つからなかった。
  - Apple Silicon で動くかは**この機では未検証**。ただし API 上は動くはず（要実機検証）。
- 代替の **DictationTranscriber**（SpeechAnalyzer の枠組みで動く従来モデル）は Intel で 20 ロケール、日本語を含めて対応。[実測]
- **SFSpeechRecognizer** の on-device も Intel で日本語・英語とも `supportsOnDeviceRecognition == true`。[実測]
- Core Audio process tap は Intel で動く。**[実測]** 全システム音の tap の作成と破棄が成功（status 0）。音声の受信まではしていない。

### 権限まわりで要件に効く制約
1. **システム音声を録るなら、権限要求がマイクとは別に 1 つ増える。**
   - Core Audio tap: `NSAudioCaptureUsageDescription` が必須。初回に録音を開始した時点でシステム音声録音の許可ダイアログが出る。[公式]
   - ScreenCaptureKit: 画面収録の許可が必要。許可後はアプリの再起動が必要。[公式]
2. **マイクの権限は `NSMicrophoneUsageDescription` が必須。** キーが無いとアプリがシステムに強制終了される。[公式]
3. **録音中は macOS のインジケータが必ず出る（アプリ側で消せない）。**
   - マイクは橙の点、システム音声は紫の点。1 度に表示されるのは 1 つだけ。[公式]
   - Control Center を開くと、どのアプリが使っているかが分かる。
   - 画面収録の枠（Screen & System Audio Recording）は、画面と音声、または音声のみをアプリごとに許可できる。[公式]
4. **tap の権限状態を事前に問い合わせる公開 API は無い。** 開発者が Apple フォーラムで指摘している。[二次]
   - 「許可が未取得か拒否か」は、録音開始の失敗や無音で推測するしかない。
5. 「取り消す」ボタンは、通知の表示スタイルがバナーだと、ホバーしないとボタンが見えない場合がある。[二次]

### 推奨 API
| 用途 | 推奨 |
|---|---|
| システム音声 | **Core Audio process tap**（権限が軽く、映像不要、Intel 可） |
| マイク | **AVAudioEngine**（inputNode の tap） |
| 文字起こし | **Intel は DictationTranscriber または SFSpeechRecognizer（on-device）**。Apple Silicon なら SpeechTranscriber を使い、`isAvailable` で実行時に切り替える設計にする |
| デバイス監視 | Core Audio の property listener（`kAudioHardwarePropertyDevices`） |
| 常駐 | `MenuBarExtra` + `SMAppService.mainApp` |
| 通知 | `UNUserNotificationCenter` + `UNNotificationCategory` |

---

## A. システム音声（他アプリの音）の録音

### A-1. Core Audio process tap
**結論**
- 対応 OS は macOS 14.2 以降。[SDK] `AudioHardwareCreateProcessTap` は `API_AVAILABLE(macos(14.2))`。macOS 26 では当然使える。
  - Apple のドキュメントページには `CATapDescription` が macOS 12.0 と表示されるが、ヘッダの記述が正。[SDK] 実際の関数は 14.2。
- 全システム音を録るには `CATapDescription(stereoGlobalTapButExcludeProcesses: [])` を使う。[SDK] 除外プロセスを指定すれば、自分のアプリの音を除ける。mono 版もある。
- 特定アプリだけを録るには `stereoMixdownOfProcesses:`（または mono 版）にプロセスの AudioObjectID を渡す。[SDK]
  - PID から AudioObjectID への変換は `kAudioHardwarePropertyTranslatePIDToProcessObject`。[SDK]
  - プロセス一覧は `kAudioHardwarePropertyProcessObjectList`。[SDK]
  - macOS 26 で `bundleIDs` プロパティと `isProcessRestoreEnabled` が追加された。[SDK] 後者は、アプリが終了して再起動しても bundle ID で tap に再登録される。会議アプリを指名する用途に向く。
- 手順は次のとおり。[公式]
  1. `AudioHardwareCreateProcessTap` で tap を作る。
  2. `AudioHardwareCreateAggregateDevice` で aggregate device を作る。
  3. `kAudioAggregateDevicePropertyTapList` に tap の UID を設定する。
  4. IO proc で音声を受け取る。
- `muteBehavior` は `.unmuted`（既定）/ `.muted` / `.mutedWhenTapped`。[SDK] 録音中に他アプリの音をスピーカーから消すことも可能。AutoNote では通常 `.unmuted`。
- 権限: Info.plist に `NSAudioCaptureUsageDescription`（macOS 14.2 以降）。初回に aggregate device の録音を始める時点で許可ダイアログが出る。[公式]
- Intel: ヘッダに arch 制限は無い。[SDK] この機で tap の作成が成功した。[実測]

**根拠**
- https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps
- https://developer.apple.com/documentation/bundleresources/information-property-list/nsaudiocaptureusagedescription
- SDK ヘッダ: `CoreAudio.framework/Headers/CATapDescription.h`, `AudioHardwareTapping.h`, `AudioHardware.h`

**不確かな点**
- 許可ダイアログが出る正確なタイミングと、拒否時のエラー形式は、この機で未検証。（今回の実測は tap の作成のみで、録音の開始までは行っていない。）
- 許可状態を取得する公開 API は無い。[二次] https://developer.apple.com/forums/thread/718279
- 設定画面の "System Audio Recording Only" という文言は Apple のサポート記事に見つからなかった。[未確認] サポート記事では「Screen & System Audio Recording」の枠で、画面と音声、または音声のみを許可できる、という書き方。
- ブラウザや Electron は音声を子プロセス（ヘルパー）から出す。特定アプリを指名すると取り逃す恐れがある。[二次] 会議アプリごとの指名よりも、全体 tap（自アプリ除外）の方が確実。

### A-2. ScreenCaptureKit の音声キャプチャ
**結論**
- `SCStreamConfiguration.capturesAudio = true` で音声を取れる。[公式] macOS 13 以降。
- 映像なしの音声のみの公式な手段は無い。`.screen` 出力を付けないとログに "stream output NOT found" が出てフレームが落ちる、という報告がある。[二次] 回避策は、極端に低いフレームレートにして映像を捨てる方法。
- 画面収録の許可が必要で、許可後はアプリの再起動が必要。[公式]
- `captureMicrophone`（マイクも同時取得）は macOS 15 以降。[公式]
- 音声のみにしても、権限は画面収録のまま。[二次] 1 件の第三者記事ベース。

**根拠**
- https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos
- https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/capturesaudio
- https://developer.apple.com/videos/play/wwdc2022-10156
- https://developer.apple.com/forums/thread/718279

**不確かな点**
- macOS 26 で音声のみの画面収録権限の扱いが変わったかは確認できなかった。[未確認]
- ScreenCaptureKit の Intel 上での動作は未検証。（API 自体は macOS 12.3 以降で Intel 向けにも提供されてきた。）

### A-3. どちらを推奨するか
**結論: Core Audio process tap を推奨。**
- 理由 1: 権限が「システム音声録音」のみで、画面を見られる権限を要求しない。[公式] 個人利用でも、ユーザーが許可しやすい。
- 理由 2: 映像が不要なのに画面収録の仕組みを使うのは不自然で、フレームを捨てるための回避策が要る。[二次]
- 理由 3: 全システム音または指定アプリを選べ、自アプリを除外できる。[SDK]
- 理由 4: macOS 26 で `bundleIDs` と process restore が追加され、会議アプリの指名に向く。[SDK]
- ScreenCaptureKit を選ぶのは、画面収録の許可が既に得られている場合や、将来、映像も録りたい場合。

---

## B. マイク録音

**結論**
- **AVAudioEngine** の `inputNode` に tap を付けて PCM を受け取る。[公式] macOS 10.10 以降。
- **AVCaptureSession** でも取れるが、音声のみの用途では AVAudioEngine が簡素。[公式の位置づけ] 用途の使い分けを明示した記述は見つからなかった。
- 権限: Info.plist に `NSMicrophoneUsageDescription`。キーが無いと、権限要求時または入力デバイス使用時にシステムがアプリを終了させる。[公式]
- 状態確認は `AVCaptureDevice.authorizationStatus(for: .audio)`、要求は `requestAccess(for: .audio)`。[公式] 状態は `notDetermined / authorized / denied / restricted`。
- `tccutil reset Microphone` でダイアログを再表示できる。開発時に便利。[公式]
- 入力デバイスが変わる（Bluetooth ヘッドセット接続など）と、`AVAudioEngineConfigurationChangeNotification` が飛ぶ。[公式] エンジンの再構成が必要。
- App Sandbox を使う場合は `com.apple.security.device.audio-input` entitlement が必要（Hardened Runtime 前提）。[公式] 個人配布で Sandbox を使わないなら不要。

**根拠**
- https://developer.apple.com/documentation/bundleresources/requesting-authorization-for-media-capture-on-macos
- https://developer.apple.com/documentation/avfaudio/avaudioengine
- https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.audio-input

**不確かな点**
- Bluetooth ヘッドセットのマイクを使うと、出力が高品質プロファイル（A2DP）から通話用（HFP）に切り替わり、音質が落ちることがある。[未確認 / 一般知識] Apple の一次情報は見つからなかった。
- 入力デバイスを AVAudioEngine で特定の物に固定する手順の公式解説は未確認。（Core Audio で `kAudioOutputUnitProperty_CurrentDevice` を設定する方法が一般的。）

---

## C. 音声機器の接続検知と識別

### C-1. デバイス一覧の変更通知
**結論**
- `AudioObjectAddPropertyListenerBlock` を `kAudioObjectSystemObject` に付け、`kAudioHardwarePropertyDevices` を監視する。[SDK] このプロパティは「現在システムで使える全デバイスの AudioObjectID 配列」。接続・取り外しのたびに通知される。
- 既定入力・出力の変化は `kAudioHardwarePropertyDefaultInputDevice` / `DefaultOutputDevice` で監視する。[SDK]
- 取り外し直前は `kAudioDevicePropertyDeviceIsAlive` が 0 になる。[SDK] 列挙時に生存確認を入れないとクラッシュした、という報告がある。[二次]

**根拠**
- SDK ヘッダ: `AudioHardware.h`, `AudioHardwareBase.h`
- https://forum.juce.com/t/bug-coreaudiointernal-can-miss-device-property-changes/56849 [二次]

**不確かな点**
- 通知の発火タイミング（接続の何ミリ秒後か）は未検証。

### C-2. デバイスの識別に使えるプロパティ
**結論**

| プロパティ | 内容 | 要件上の扱い |
|---|---|---|
| `kAudioDevicePropertyDeviceUID` | 再起動後も不変の識別子。個体固有の情報や CPU 固有の情報を含み得る。[SDK] | **同一個体の識別**に使う。マシン間では使い回せない。[SDK] |
| `kAudioDevicePropertyModelUID` | 同一メーカーの同一モデルなら、どのマシンでも同じ値になる。[SDK] | **機種の識別**に使う。 |
| `kAudioDevicePropertyTransportType` | 接続方式（FourCC）。[SDK] | 接続方式の分類に使う。 |
| `kAudioObjectPropertyName` | 表示名 | 表示用。識別には使わない。 |

- transport type の定数。[SDK] BuiltIn `bltn` / USB `usb ` / Bluetooth `blue` / BluetoothLE `blea` / HDMI `hdmi` / DisplayPort `dprt` / AirPlay `airp` / Thunderbolt `thun` / Aggregate `grup` / Virtual `virt` / ContinuityCapture（Wired `ccwd` / Wireless `ccwl`）ほか。
- **USB の場合**: Apple のエンジニアが次の形式を回答している。[公式フォーラム回答]
  - `DeviceUID` = `AppleUSBAudioEngine:<メーカー名>:<製品名>:<シリアル番号 または locationID>:<interfaces>`
  - `ModelUID` = `<BoxName>::0x<VID>:0x<PID>`（VID と PID は 16bit の16進）
  - つまり **ModelUID から VID/PID、DeviceUID からシリアルまたは locationID を取れる**。IOKit に降りなくても足りる可能性が高い。
  - 注意: macOS 26 で USB Audio のクラスドライバがユーザー空間に移り、`AppleUSBAudioEngine` などの IOService は作られなくなった。昔の「UID で IORegistry を引く」方法は動かない。[公式フォーラム回答]
  - IOKit で突き合わせる場合は、`IOUSBHostDevice` を VID/PID で探し、`iSerialNumber` または `locationID` を DeviceUID の該当部分と比べる。Apple の推奨手順は「まず Core Audio の通知でデバイスの出現を受け、その後 `IOUSBHostDevice` を探す」。（ドライバとの競合を避けるため。）
  - 同一製品を 2 本挿した場合の区別は、シリアルを持たない機種では locationID（挿すポート）依存になる。つまり**ポートを変えると別個体に見える**。
- **Bluetooth の場合**: Apple の一次情報は見つからなかった。[未確認]
  - 一般には UID が MAC アドレス由来の文字列（`XX-XX-XX-XX-XX-XX:input` など）になると言われる。[未確認 / 一般知識] 要実機確認。
  - アドレスの取得は、UID の解析、または IOBluetooth の `IOBluetoothDevice` との照合になる。（IOBluetooth の詳細は今回未調査。）
- **この Mac の実測** [実測]（内蔵デバイスのみ接続されていた状態）:
  - 内蔵マイク: UID `BuiltInMicrophoneDevice` / ModelUID `Digital Mic` / transport `bltn` / data source `imic`
  - 内蔵スピーカー: UID `BuiltInSpeakerDevice` / ModelUID `Speaker` / transport `bltn` / data source `ispk`
  - 外部ディスプレイ（DisplayPort）: transport `dprt`

**根拠**
- SDK ヘッダ: `AudioHardwareBase.h`（UID, ModelUID, TransportType の説明）
- https://developer.apple.com/forums/thread/801522（Apple エンジニアの回答）

**不確かな点**
- 上記の USB 形式は 1 件のフォーラム回答にあり、**文字列の細部（区切り、数値が10進か16進か、シリアルか locationID かの見分け方）は未確認**。実機で USB マイクを挿して検証が必要。
- ModelUID 全体が常にこの形式かは未確認。（Cobalt の実装は ModelUID の末尾が `VID:PID` 形式かを見ている。[二次]）
- Bluetooth アドレスの取得方法は未確認。

### C-3. 3.5mm ジャックへの接続の見え方
**結論**
- 内蔵出力は 1 つのデバイス（`BuiltInSpeakerDevice`）で、**ジャックに挿すと別デバイスではなく data source が切り替わる**と考えられる。[二次 / 一般知識] 内蔵スピーカーの data source が `ispk` であることは実測した。ヘッドホン時の値は未観測。
- 関連プロパティ。[SDK]
  - `kAudioDevicePropertyDataSource`（現在選択中のソース ID）
  - `kAudioDevicePropertyDataSources`（利用可能なソース一覧）
  - `kAudioDevicePropertyDataSourceNameForIDCFString`（ID から名前への変換）
  - `kAudioDevicePropertyJackIsConnected`（ジャックに何か挿さっているか）
- `kAudioDevicePropertyDataSource` の変化を監視すれば検知できる。ただし通知は他の変化でも飛ぶので、自前で絞り込む必要がある。[二次] https://forum.juce.com/t/is-there-any-notification-when-headphones-are-unplugged/25572
- 一部のデバイスで data sources が常に空になる、という報告がある（Catalina）。[二次] エラー時の処理が必要。
- **入力側のジャック（3.5mm マイク入力）は Intel MacBook Pro では 1 個のコネクタが入出力兼用（4極）**で、挿すと内蔵マイクの data source が変わる可能性がある。[未確認]

**根拠**
- SDK ヘッダ: `AudioHardware.h`
- https://forum.juce.com/t/is-there-any-notification-when-headphones-are-unplugged/25572 [二次]

**不確かな点**
- ヘッドホン接続時の data source の FourCC 値は未観測（`hdpn` と言われるが確認できず）。**3.5mm を挿して、入力・出力それぞれの data source と `JackIsConnected` を記録する実機検証が必要**。
- Apple Silicon の MacBook でも同じ見え方かは未確認。

### C-4. Bluetooth が一瞬切れて再接続するときの挙動
**結論: 未確認。**
- 同一個体が再接続したときに UID が同じかは、Apple の一次情報も第三者情報も見つからなかった。
- 実装上の注意として、再接続のときに `kAudioDevicePropertyDeviceHasChanged` が飛ぶ、という報告がある。[二次] https://forum.juce.com/t/big-sur-audio-playback-freezes-in-desktop-applications-when-disconnecting-headphones/46230
- 切断時は `DeviceIsAlive` が 0 になり、`kAudioHardwarePropertyDevices` の一覧から消えるはず。[SDK からの推測]
- **要件に「一瞬の切断では別機器扱いにしない（デバウンス）」を入れる場合は、実機で AirPods などを切断・再接続して UID・ModelUID・通知の順序を記録して決めるべき。**

---

## D. オンデバイス音声認識

### D-1. SpeechAnalyzer / SpeechTranscriber（macOS 26）
**結論**
- macOS 26.0 以降。[公式]
- **日本語対応: ロケール一覧は `SpeechTranscriber.supportedLocales` で実行時に取る。** Apple のページは言語を列挙していない。[公式] 第三者記事では日本語を含むとされる。[二次]
  - **ただしこの Intel Mac では `supportedLocales` が空（0 件）で `isAvailable == false`。日本語も使えない。[実測]**
  - 公式ドキュメント: 「デバイスが非対応なら `supportedLocales` は空」。[公式]
- **Intel で動くか: この機（macOS 26.6.2）では動かない。[実測]** Apple の明文は見つからず（WWDC25 では "certain hardware requirements"）。第三者の OSS（Yap）も Apple Silicon 専用と述べている。[二次]
- リアルタイム対応: **可。** `.volatileResults`（暫定結果、後で置き換わる）と final（確定結果）の 2 種類を返す。`result.isFinal` で区別。[公式 WWDC25-277]
  - 音声は `AsyncStream<AnalyzerInput>` に流し込む。`AnalyzerInputConverter` で形式変換。[公式]
  - 形式は `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)` で取得。[公式]
- タイムスタンプ: `attributeOptions: [.audioTimeRange]` で、各語に `CMTimeRange` が付く。サンプル単位の精度。[公式 WWDC25-277]
- 話者情報（話者分離）: **SpeechTranscriber には無い。** WWDC25 セッションにも言及が無い。[公式 / 言及なし → 無いと判断、断定はしない]
- モデルのダウンロード: `AssetInventory.assetInstallationRequest(supporting:)` → `downloadAndInstall()`。`progress` で進捗表示可。[公式] アセットは Apple のサーバから落ち、システムが管理・自動更新し、他アプリと共有する。アプリのサイズやメモリには影響しない。[公式]
  - アプリが予約できるロケール数には上限がある（`maximumReservedLocales`）。[公式]
  - 同時に走らせる分析数にも上限があり、超えると `insufficientResources`。[公式]
- 長時間の音声: 上限の記述は見つからなかった。[未確認] SFSpeechRecognizer のような 1 分制限の記述は SpeechAnalyzer には無い。

**根拠**
- https://developer.apple.com/documentation/speech/speechanalyzer
- https://developer.apple.com/documentation/speech/speechtranscriber
- https://developer.apple.com/documentation/speech/speechtranscriber/supportedlocales
- https://developer.apple.com/documentation/speech/assetinventory
- https://developer.apple.com/videos/play/wwdc2025/277/
- 実測: probe/main.swift

**不確かな点**
- Apple Silicon で日本語がサポートされるかは、この機では検証できない。
- Apple が Intel を非対応と明記した文書は見つからなかった。

### D-1b. DictationTranscriber（Intel の代替）
**結論**
- macOS 26 以降。[公式] 「システムのディクテーションや、on-device 設定の SFSpeechRecognizer と同じモデルを使う」「古いデバイスでも動く」。
- **この Intel Mac では 20 ロケール対応、日本語を含む。[実測]**
- SpeechAnalyzer の枠組み（入力は AsyncSequence、結果も AsyncSequence、`.volatileResults`、`.audioTimeRange` など）で使える。[公式]
- Siri やキーボードのディクテーションを有効にしなくても使える（SFSpeechRecognizer と違う点）。[公式 WWDC25-277]
- `contextualStrings`（語彙バイアス）、`SFSpeechLanguageModel`（独自語彙）、`ContentHint.farField`（遠距離音声向け）が使える。[公式] 会議の遠距離マイクに有利。
- ネットワーク経由でのみ対応するロケールは非対応。[公式]

**根拠**
- https://developer.apple.com/documentation/speech/dictationtranscriber

**不確かな点**
- 精度、長時間連続使用での挙動、1 分制限の有無は未検証。

### D-2. SFSpeechRecognizer
**結論**
- macOS 10.15 以降。[公式]
- on-device 日本語: **この Intel Mac で `supportsOnDeviceRecognition == true`（ja-JP, en-US）。[実測]**
- 設定は `SFSpeechAudioBufferRecognitionRequest.requiresOnDeviceRecognition = true`。[公式]
- 制約: ドキュメントに "Plan for a one-minute limit on audio duration"（1 分で打ち切り）とある。[公式] ただしこの記述は、ネットワーク型を前提にした古い文言。on-device でも同じ制限が適用されるかは**ドキュメントからは判断できない**。[未確認]
  - 1 分を超える会議では、タスクを自動で張り直す設計が必要になる可能性が高い。
- 1 つの recognizer は 1 言語のみ。[公式]
- 認証: `SFSpeechRecognizer.requestAuthorization`。音声認識の権限が別途必要（Info.plist に `NSSpeechRecognitionUsageDescription`）。[公式 / 一般知識]（今回このキーのページは未取得。）
- 一部の言語はネットワークが必要。`isAvailable` で確認する。[公式]

**根拠**
- https://developer.apple.com/documentation/speech/sfspeechrecognizer
- https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest

**不確かな点**
- on-device の 1 分制限の有無。実機で 5 分以上の音声を流して検証するのが確実。
- `NSSpeechRecognitionUsageDescription` の公式ページ未取得。

### D-3. 日英混在
**結論: 未確認（Apple の公式な対応は見つからなかった）。**
- SFSpeechRecognizer は 1 recognizer = 1 言語。[公式]
- SpeechTranscriber / DictationTranscriber は `locale` を 1 つ指定する作り。[公式] ただし `selectedLocales` が配列である点に含みがある。[公式] 複数ロケールを同時に扱えるかは書かれておらず、**未確認**。
- 現実的な方針: 日本語ロケールで認識させ、英単語は `contextualStrings` で補う。または、言語ごとに別の transcriber を並走させる。いずれも精度は未検証。

---

## E. 常駐アプリ関連

**結論**
- **メニューバー常駐**: SwiftUI の `MenuBarExtra`（macOS 13 以降）。[公式]
  - スタイルは `.menu`（既定）と `.window`（ポップオーバー風）。
  - `isInserted: Binding<Bool>` でメニューバー表示を切り替えられる。ユーザーがメニューバーから外すと false になる。
  - メニューバーのみのアプリは、ユーザーが項目を外すと**自動で終了する**。[公式]
  - Dock に出さないなら、Info.plist の `LSUIElement = true`。[公式]
- **ログイン時自動起動**: `SMAppService.mainApp.register()`（macOS 13 以降）。[公式]
  - 状態は `status`（`.enabled / .requiresApproval / .notRegistered / .notFound`）。
  - 「ユーザーの承認の下で起動する」とあり、システム設定の「ログイン項目」で承認が必要になる場合がある。`openSystemSettingsLoginItems()` で設定画面を開ける。[公式]
- **録音インジケータ**: [公式]
  - マイク使用中は橙の点、システム音声録音中は紫の点、カメラは緑の点。メニューバーの Control Center アイコンの横に出る。
  - **1 度に表示されるのは 1 つだけ。** マイクと同時にシステム音声を録ると、どちらの点が出るかは優先順位次第。（今回未確認）
  - Control Center を開くと、どのアプリがマイク・システム音声を使っているかが見える。
  - アプリ側でインジケータを消す手段は無い。
  - Control Center には「マイクを使用中または最近使用した」状態が出る。
- **App Sandbox との相性**:
  - process tap のサンドボックス対応について、Apple の公式文書は見つからなかった。[未確認]
  - 開発者フォーラムに「サンドボックス内で `com.apple.security.device.audio-input` で動く。マイク用の利用目的文字列は不要」という報告が 1 件ある。[二次] https://developer.apple.com/forums/thread/848578 （検索結果の要約ベースで、**本文は未読**）
  - `NSAudioCaptureUsageDescription` がサンドボックス下で必要かは未確認。
  - **配布が App Store 外・個人利用なら、Sandbox を使わず Hardened Runtime + Developer ID（または ad-hoc 署名）が最も単純。** これは設計判断であり、Apple の推奨ではない。
- 参考: アプリに署名を付けないと、TCC の許可が再ビルドのたびにリセットされることがある。[未確認 / 一般知識] 安定した署名 ID を使うことを推奨したい。

**根拠**
- https://developer.apple.com/documentation/swiftui/menubarextra
- https://developer.apple.com/documentation/servicemanagement/smappservice
- https://support.apple.com/guide/mac-help/mchlp1446/mac （プライバシーインジケータ）
- https://support.apple.com/guide/mac-help/control-access-screen-system-audio-recording-mchld6aa7d23/mac
- https://support.apple.com/guide/mac-help/control-access-to-the-microphone-on-mac-mchla1b1e1fe/mac

**不確かな点**
- 画面収録の枠にシステム音声のみを許可した場合の設定画面での表示は未確認。
- 署名方式と TCC の許可保持の関係は未検証。

---

## F. ユーザー通知に「取り消す」ボタンを付ける

**結論**
- 手順。[公式]
  1. `UNNotificationAction(identifier:title:options:)` でボタンを定義する（例: id `"CANCEL"`, title `"取り消す"`）。
  2. `UNNotificationCategory(identifier:actions:intentIdentifiers:options:)` に束ね、アプリ起動時に `UNUserNotificationCenter.current().setNotificationCategories([...])` で登録する。
  3. 通知の `UNMutableNotificationContent.categoryIdentifier` に同じカテゴリ ID を設定して送る。
  4. `UNUserNotificationCenterDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:)` で `response.actionIdentifier` を見て処理する。最後に `completionHandler()` を必ず呼ぶ。
- アクション ID はアプリ全体で一意にする。[公式]
- 破壊的な操作は `.destructive` オプション。[公式] 「取り消す」には向く。
- アプリが前面に出る必要がある場合は `.foreground`。（今回このオプションの個別ページは未取得。）
- 通知の許可 (`requestAuthorization`) が前提。[公式 / 一般知識]
- **macOS の表示スタイル**: バナーは数秒で消え、**ホバーしないとボタンが見えない**場合がある。アラートは操作するまで残り、ボタンが常に見える。[二次] どちらにするかは**ユーザーがシステム設定で選ぶ**。アプリからの指定は難しい。[二次 / 古い情報]
  - 要件への含意: 「取り消す」を一定時間内に押してもらう設計なら、バナーのままでは見落とされる可能性がある。メニューバーの項目や `MenuBarExtra` 内にも同じ取り消しを置くべき。
- 通知を押したときの動作はアプリがバックグラウンドで起動して処理される。[公式]

**根拠**
- https://developer.apple.com/documentation/usernotifications/declaring-your-actionable-notification-types
- https://developer.apple.com/documentation/usernotifications/unnotificationaction
- https://developer.apple.com/forums/thread/8064 [二次]

**不確かな点**
- 現行 macOS 26 でバナー時のボタン表示がどうなるかは未検証。
- 通知スタイル（バナー/アラート）を取得する API（`UNNotificationSettings.alertStyle`）の挙動は今回未調査。

---

## 付録: 実機検証が必要な項目（要件の確定前に）
1. 3.5mm ジャックの抜き差しで、内蔵デバイスの data source / `JackIsConnected` がどう変わるか（入力・出力）。
2. USB マイクを挿したときの DeviceUID / ModelUID の実際の文字列（シリアルあり・なしの両方）。
3. Bluetooth 機器（AirPods など）の UID 形式と、切断・再接続での UID・通知の変化。
4. Core Audio tap の録音開始時の許可ダイアログと拒否時の挙動。
5. SFSpeechRecognizer / DictationTranscriber の on-device で 5 分以上の連続認識ができるか。
6. Apple Silicon Mac で `SpeechTranscriber.isAvailable` と日本語・日英混在の挙動。
