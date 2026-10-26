# AutoNote 計画 03: 機材検知と自動録音 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 入力デバイスの接続・切断を監視して機材を識別・登録し、要件書 §5.9 の 5 状態の録音器を純粋な状態機械として作り、登録機材の接続でカウントダウン → 録音、切断で猶予 → 停止までを計画 02 の `RecordingSession` を呼んで自動で回す。

**Architecture:** Core Audio の読み取り（`CoreAudioHardware`）と時間（`TimerScheduling`）と通知（`UserNotifier`）と録音（`RecordingControl`）をすべて protocol の向こうに置き、判断はすべて値型（`DeviceListDiff`、`WakeSuppression`、`DeviceRegistry` の一致判定、`RecorderStateMachine`）に集める。`DeviceMonitor`（actor）が入力デバイスの事象を `AsyncStream<DeviceEvent>` で流し、`AutoRecordCoordinator`（actor）が事象 → 登録照合 → 状態機械 → 効果の実行を 1 本の直列ループで行う。録音の開始・停止・一時停止・再開・ブックマーク・言語変更は手動操作も含めて必ず Coordinator を通す（状態機械と実際の録音がずれないようにするため）。CLI（`autonote dev`）と計画 06 が使う型・関数（Task 1〜9 の Produces）はすべて `public`。

**Tech Stack:** Swift 6 / Swift Testing / Core Audio（`AudioObjectAddPropertyListenerBlock`、`kAudioHardwarePropertyDevices`、`kAudioHardwarePropertyTranslateUIDToDevice`）/ AppKit（`NSWorkspace` のスリープ・復帰通知）/ IOKit（`IOPlatformUUID`）

**Spec:** `docs/superpowers/specs/2026-10-24-autonote-design.md`（中心: §4.1 手順 2、§4.4、§5.1、§5.9、§9.5、§11、付録 A）と `docs/superpowers/plans/2026-10-25-autonote-plans-overview.md`（共通契約）。根拠: `docs/superpowers/research/2026-10-24-spike-results.md` 項目 4・5・10、`docs/superpowers/research/2026-10-24-spike-raw/task-4-devices.jsonl`、`Spikes/Sources/DeviceProbe/main.swift`、`Spikes/Sources/MicHotSwap/main.swift`

ブランチ: `plan-03`（起点は `plan-02`）。

## Global Constraints

- 最低 OS: macOS 26.0。`Package.swift` の platforms は `.macOS("26.0")`、`swift-tools-version: 6.2`、`swiftLanguageModes: [.v6]`。ツールチェーンは Swift 6.3（計画 00 と同じ）
- `autonote` CLI や `AutoNoteApp` から使う `AutoNoteCore` の型・関数は `public` にする（同じパッケージでも別ターゲットからは見えない）
- Intel（x86_64）と Apple Silicon（arm64）の両方でビルド・動作すること。機種依存の分岐は実行時判定（`isAvailable` など）で行い、`#if arch` で機能を落とさない
- 署名: 自己署名証明書 `AutoNote Dev`、Bundle ID `com.yutaokoshi.autonote`。`scripts/build-app.sh` を使う。App Sandbox なし、Hardened Runtime なし
- 音声・文字起こし・議事録・個人の機材識別子（MAC アドレス）をリポジトリにコミットしない。テストのフィクスチャは架空の内容にする
- 音声はローカルから出ない。外部へ渡すのは `claude -p` への文字起こしテキストだけ（要件書 G9）
- 共有する型とプロトコルは本書 §3・§4 の名前と形を使う。変えるなら本書を先に直す
- 利用者の手が要る手順は「👤 利用者」と明記し、実装者はそこで止めて依頼する
- 各タスクは TDD（失敗するテスト → 実装 → 通過 → コミット）。ハードウェアが要る部分だけ手動確認手順を書く
- コミットメッセージは英語の Conventional Commits。タスクごとにコミット。push はしない
- 実装者はタスク完了前に `scripts/e2e-check.sh` を回し、結果を報告に含める

（上の「本書」は overview を指す。）

## Review Focus

要件書が暗に求めるが、表のセルをなぞるだけのテストでは素通りしやすい条件。各行のテストは担当タスクに入れてある。

1. 計画 02 の process tap が作る集約デバイス（と Zoom などの仮想デバイス）が「入力デバイスの追加」に見え、録音を始めるたびに登録通知が出る → 集約・仮想・`com.yutaokoshi.autonote.tap.` で始まる UID は機材として扱わない（Task 1 `aggregateAndVirtualAreNotCandidates`、Task 2 `aggregateAddedIsIgnored`）
2. Bluetooth の瞬断が猶予中に何度も起き、前の猶予のタイマーが後から発火して続いている録音を止める → 古い token のタイマーは無視（Task 5 `staleGraceTimerAfterFlapIsIgnored`）
3. `devices.json` が壊れている・出力フォルダが未マウント → 自動録音は写しで動き続け、壊れたファイルを黙って上書きしない（Task 4 `corruptFileIsBackedUpAndRegistryStartsEmpty`、`missingOutputFolderUsesMirror`）
4. Bluetooth の `ModelUID` は全機種 `0 0` なので、これを「型番一致」とみなすと別の Bluetooth 機材で録音が始まる → `0 0` は型番として使わない（Task 4 `bluetoothZeroModelUIDIsNeverAModelMatch`）
5. 録音中に初めて見る機材がつながり、登録通知で［はい］を押す → 登録だけして、新しい録音もカウントダウンも始めない（Task 9 `answerYesWhileRecordingRegistersOnly`）

---

## 前提（計画 01・02 に求める API。Lead が両計画と揃える）

計画 01・02 の草稿と、整合レビュー後の overview §3・§7・§8b に合わせた。以下の名前と形を前提にする。違っていたら本計画の該当タスクの Interfaces だけを直す（`RecordingSession` との差は Task 7 のアダプタ 1 ファイルで吸収する）。

計画 01（草稿の形）:
- 型 `DeviceRef`、`Language`、`MeetingID`（overview §3 のとおり）、`AppPaths(root:)`
- `Settings` の `countdownSeconds: Int`（既定 5、0〜30 に丸め済み）、`disconnectGraceSeconds: Int`（既定 30、5〜300 に丸め済み）、`defaultLanguage: Language`（既定 `.ja`）、`startOnModelMatch: Bool`（既定 false。機材ごとの上書きは本計画の `devices.json`）。`actor SettingsStore` の `func load() throws -> Settings`
- `actor PortableConfigStore` の `init(paths:outputFolder:)`、`func read(_ file: PortableFile) throws -> Data?`、`func write(_ file: PortableFile, _ data: Data) throws`、`PortableFile.devices`（`devices.json`）。出力フォルダが無いときは写しを読み書きする（要件書 §9.5）
- ライブラリターゲット `AutoNoteTestSupport`（本計画はここにフェイクを足す。`Package.swift` は触らない）
- E2E の共通補助 `AUTONOTE_CLI`（overview §7）
- `Sources/autonote/DevCommands.swift` の `enum DevCommands { static func run(_ args: [String]) async -> Int32 }`（本計画は `devices` と `auto-record` の 2 件を振り分けに足す）

計画 02（overview §3・§8b で確定した形）:
- `RecordingSession`（actor）の `start(_ configuration: Configuration) async throws -> MeetingID`（`Configuration(language:microphoneUID:device:)`。`microphoneUID` nil は既定入力）、`pause() async throws`、`resume() async throws`、`bookmark(note: String?) async throws -> Bookmark`、`setLanguage(_ language: Language) async throws`、`stop(reason: StopReason) async throws -> Manifest`（`StopReason` は `manual / deviceGone / diskFull / appTerminating`）
- 同じく `detachMicrophone() async throws`（マイクトラックは会議タイムラインに合わせて無音で埋まり、システム音は録り続ける。§11.5）と `attachMicrophone(deviceUID: String?) async throws`（失敗は throw。nil は既定入力）
- `func events() -> AsyncStream<RecordingEvent>`（呼ぶたびに新しい購読。overview §8b）に `.stopped(Manifest, StopReason)` が流れる（ディスク空き 500MB 未満の `.diskFull` など、録音器が自分で止まった場合を含む。§5.9）
- 1 分未満の停止を `tooShort` にする判断は計画 02 の `stop` が持つ（§5.9 補足 4）。本計画は `stop` を 1 回だけ呼ぶことを保証する
- process tap の集約デバイスは方式 aggregate で見え、UID は `com.yutaokoshi.autonote.tap.` で始まる（overview §3）
- 組み立て関数 `RecordingSession.live(paths:settings:clock:)`（overview §8b。Task 10 が使う）

## ファイル構成

新しいコードはすべて `Sources/AutoNoteCore/Devices/`（overview §2）、フェイクは `Sources/AutoNoteTestSupport/Devices/`、テストは `Tests/AutoNoteCoreTests/Devices/`、開発用サブコマンドは `Sources/autonote/DevAutoRecord.swift` と `DevDevices.swift`。判断を持つ値型（差分・復帰時の抑制・一致判定・状態機械）と、OS に触る薄い実装（Core Audio・NSWorkspace・IOKit）を別ファイルに分ける。各タスクの Files が正。

---

### Task 1: DeviceIdentity（識別子・方式・UID 種別の推定）

**Files:**
- Create: `Sources/AutoNoteCore/Devices/DeviceIdentity.swift`
- Test: `Tests/AutoNoteCoreTests/Devices/DeviceIdentityTests.swift`

**Interfaces:**
- Consumes: `DeviceRef`（計画 01）
- Produces:
  - `public struct RawAudioDevice: Equatable, Sendable { audioObjectID: UInt32; name: String?; deviceUID: String?; modelUID: String?; transport: DeviceTransport; inputChannels: Int; outputChannels: Int }` — Core Audio から読んだ値（方式だけ Task 2 の対応表で変換済み）。`AudioDeviceID` はここにだけ置き、保存しない（§11.1）
  - `public enum DeviceTransport: String, Codable, Sendable { case builtin, bluetooth, usb, aggregate, virtual, unknown }`（raw value は overview §3 の `DeviceRef.transport` の小文字の値。`import` は取り込み専用なのでここには無い）
  - `public enum UIDKind: String, Codable, Sendable { case individual, portBased, fixed, unknown }` — `DeviceUID` が個体（シリアル・MAC）を含むかの推定
  - `public struct DeviceIdentity: Codable, Hashable, Sendable { name: String; deviceUID: String; modelUID: String?; transport: DeviceTransport; inputChannels: Int; uidKind: UIDKind }`、`init?(raw: RawAudioDevice)`（`inputChannels == 0` か `deviceUID == nil` なら nil。名前が nil なら `deviceUID`）、`var isAutoRecordCandidate: Bool`、`var deviceRef: DeviceRef`（`transport.rawValue` を入れる）

- [ ] **Step 1: 失敗するテストを書く**

付録 A の 5 行を `RawAudioDevice` にしたフィクスチャ（Bluetooth の UID は架空の `00-11-22-33-44-55:input`、名前は `Fictional BT Headset`）で書く。

```swift
@Test func bluetoothInputIsIndividualCandidate() {
    let id = DeviceIdentity(raw: .fixtureBluetoothInput)!   // modelUID "0 0", transport .bluetooth, in 1
    #expect(id.transport == .bluetooth); #expect(id.uidKind == .individual); #expect(id.isAutoRecordCandidate)
    #expect(id.deviceRef == DeviceRef(name: "Fictional BT Headset", uid: "00-11-22-33-44-55:input", transport: "bluetooth"))
}
@Test func headphoneJackInputIsFixed()      // "BuiltInHeadphoneInputDevice", "Codec Input", .builtin → .fixed, 候補、deviceRef.transport == "builtin"
@Test func outputOnlyDeviceHasNoIdentity()  // "…:output", in 0 / out 2 → nil
@Test func aggregateAndVirtualAreNotCandidates()  // .aggregate / .virtual、UID が "com.yutaokoshi.autonote.tap.0D3A…" の .builtin も → false
@Test(arguments: [
    ("AppleUSBAudioEngine:Fictional Audio:Fictional USB Headset:ABC123XYZ:1", UIDKind.individual),
    ("AppleUSBAudioEngine:Fictional Audio:Fictional USB Headset:14200000:1", .portBased),
    ("AppleUSBAudioEngine:Fictional Audio:Fictional USB Headset::1", .portBased),
    ("FictionalVendorDriver_0042", .unknown),
]) func usbUIDKindEstimate(uid: String, expected: UIDKind)
@Test func deviceRefUsesLowercaseTransport()    // .usb → "usb"、.unknown → "unknown"
```

- [ ] **Step 2: 失敗を確認する**
Run: `swift test --filter DeviceIdentityTests` → Expected: FAIL（`DeviceIdentity` が無い）
- [ ] **Step 3: `DeviceIdentity.swift` を実装する**

UID 種別の推定（USB は機材が無く未測定なので仮。Task 10 の 👤 で USB があれば見直す）: `.bluetooth` → `.individual`（UID に MAC が入る。項目 4）。`.builtin` → `.fixed`。USB は `:` で分けて先頭が `AppleUSBAudioEngine` かつ 4 要素以上のとき、4 要素目が空、または 8 桁の 16 進で末尾 4 桁が `0000`（locationID の形）なら `.portBased`、それ以外の空でない値なら `.individual`。形が違えば `.unknown`。他の方式は `.unknown`。候補判定は「入力 1ch 以上、方式が aggregate / virtual でない、UID が `com.yutaokoshi.autonote.tap.` で始まらない」（overview §3。自分の process tap の集約デバイスを機材と誤認しない）。

- [ ] **Step 4: 通過を確認する**
Run: `swift test --filter DeviceIdentityTests` → Expected: PASS
- [ ] **Step 5: コミット**
```bash
git add Sources/AutoNoteCore/Devices/DeviceIdentity.swift Tests/AutoNoteCoreTests/Devices/DeviceIdentityTests.swift
git commit -m "feat(devices): add DeviceIdentity with transport and UID kind estimate"
```

---

### Task 2: DeviceListDiff と CoreAudioHardware

**Files:**
- Create: `Sources/AutoNoteCore/Devices/DeviceListDiff.swift`, `Sources/AutoNoteCore/Devices/CoreAudioHardware.swift`
- Create: `Sources/AutoNoteTestSupport/Devices/FakeAudioHardware.swift`
- Test: `Tests/AutoNoteCoreTests/Devices/DeviceListDiffTests.swift`

**Interfaces:**
- Consumes: `RawAudioDevice`, `DeviceIdentity`（Task 1）
- Produces:
  - `public struct DeviceListDiff: Sendable { public private(set) var known: [String: DeviceIdentity]; public init(); public mutating func update(with current: [RawAudioDevice]) -> (added: [DeviceIdentity], removed: [DeviceIdentity]) }` — キーは `deviceUID`。候補（`isAutoRecordCandidate`）だけを扱う。`removed` は消えた機材に問い合わせできないので `known` の値を返す（`DeviceProbe` と同じ）。順は removed → added、各々 `current` の並び
  - `public protocol AudioHardwareQuerying: Sendable { func snapshot() -> [RawAudioDevice]; func observeDeviceList(_ onChange: @Sendable @escaping () -> Void) throws -> any HardwareObservation }`、`public protocol HardwareObservation: Sendable { func cancel() }`
  - `public final class CoreAudioHardware: AudioHardwareQuerying`（`Sendable`。内部状態は専用 `DispatchQueue` の上だけで触る）、`public static func transport(coreAudio: UInt32?) -> DeviceTransport`
  - TestSupport: `public final class FakeAudioHardware: AudioHardwareQuerying` に `setDevices(_: [RawAudioDevice])`、`fireChange()`、`var observationCancelled: Bool`

- [ ] **Step 1: 失敗するテストを書く**

```swift
@Test func outputAppearingFirstIsNotAnEvent() {      // 出力だけ追加 → ([], [])。0.78 秒後に入力追加 → added == [headphoneIn]（付録 A の順）
@Test func inputRemovalCarriesCachedIdentity()      // 追加後に一覧から消す → removed[0].name == "Fictional BT Headset"
@Test func newAudioObjectIDWithSameUIDIsNoEvent()   // 同じ UID で audioObjectID が 149 → 161 に変わっただけ → ([], [])
@Test func aggregateAddedIsIgnored()                // Aggregate の入力 2ch が増えても ([], [])
@Test func removedComesBeforeAdded()                // 1 回の更新で A 消失・B 追加 → removed [A], added [B]
@Test(arguments: [(kAudioDeviceTransportTypeBuiltIn, DeviceTransport.builtin), (kAudioDeviceTransportTypeBluetooth, .bluetooth), (kAudioDeviceTransportTypeBluetoothLE, .bluetooth), (kAudioDeviceTransportTypeUSB, .usb), (kAudioDeviceTransportTypeAggregate, .aggregate), (kAudioDeviceTransportTypeAutoAggregate, .aggregate), (kAudioDeviceTransportTypeVirtual, .virtual), (kAudioDeviceTransportTypeHDMI, .unknown), (0x12345678, .unknown)])
func transportTable(code: UInt32, expected: DeviceTransport)   // CoreAudioHardware.transport(coreAudio:)。nil も .unknown
```

- [ ] **Step 2: 失敗を確認する**
Run: `swift test --filter DeviceListDiffTests` → Expected: FAIL（`DeviceListDiff` と `CoreAudioHardware.transport` が無い）
- [ ] **Step 3: `DeviceListDiff` を実装する**
- [ ] **Step 4: `CoreAudioHardware` を実装する**

読み取りは `DeviceProbe` の `allDevices` / `stringProp` / `uint32Prop` / `channelCount` を写す（`kAudioObjectPropertyName`、`kAudioDevicePropertyDeviceUID`、`kAudioDevicePropertyModelUID`、`kAudioDevicePropertyTransportType`、入力・出力スコープの `kAudioDevicePropertyStreamConfiguration` の ch 合計）。方式の対応表（`transport(coreAudio:)`。これ以外と nil は `.unknown`）:

| Core Audio の値 | `DeviceTransport` | 根拠 |
|---|---|---|
| `kAudioDeviceTransportTypeBuiltIn` | `.builtin` | 内蔵マイク・3.5mm（付録 A） |
| `kAudioDeviceTransportTypeBluetooth`、`kAudioDeviceTransportTypeBluetoothLE` | `.bluetooth` | Shokz（付録 A）。LE も同じ扱い |
| `kAudioDeviceTransportTypeUSB` | `.usb` | 未測定 |
| `kAudioDeviceTransportTypeAggregate`、`kAudioDeviceTransportTypeAutoAggregate` | `.aggregate` | 計画 02 の process tap |
| `kAudioDeviceTransportTypeVirtual` | `.virtual` | 会議アプリの仮想デバイス |

`observeDeviceList` は `kAudioHardwarePropertyDevices` に `AudioObjectAddPropertyListenerBlock` を専用キューで付け、ブロックは `onChange()` を呼ぶだけにする。`cancel()` は同じブロックとキューで `AudioObjectRemovePropertyListenerBlock`。ブロックは nonisolated なメソッドの中で作る（`main.swift` のトップレベルで作ると @MainActor 推論で SIGILL になった。計画 00 Task 3）。実機の値は Task 11 の E2E と Task 10 の 👤 で確かめる（ハードウェアを単体テストにしない）。

- [ ] **Step 5: 通過を確認する**
Run: `swift test --filter DeviceListDiffTests` → Expected: PASS
- [ ] **Step 6: コミット**
```bash
git add Sources/AutoNoteCore/Devices/DeviceListDiff.swift Sources/AutoNoteCore/Devices/CoreAudioHardware.swift Sources/AutoNoteTestSupport/Devices/FakeAudioHardware.swift Tests/AutoNoteCoreTests/Devices/DeviceListDiffTests.swift
git commit -m "feat(devices): diff input device lists and read them from Core Audio"
```

---

### Task 3: TimerScheduling・WakeSuppression・DeviceMonitor

**Files:**
- Create: `Sources/AutoNoteCore/Devices/TimerScheduling.swift`, `SleepWake.swift`, `WakeSuppression.swift`, `DeviceMonitor.swift`
- Create: `Sources/AutoNoteTestSupport/Devices/ManualTimerScheduler.swift`, `FakeSleepWake.swift`
- Test: `Tests/AutoNoteCoreTests/Devices/WakeSuppressionTests.swift`, `DeviceMonitorTests.swift`

**Interfaces:**
- Consumes: `AudioHardwareQuerying`, `DeviceListDiff`, `DeviceIdentity`（Task 1・2）
- Produces:
  - `public protocol TimerScheduling: Sendable { func schedule(after seconds: Double, _ action: @Sendable @escaping () async -> Void) -> any CancellableTimer }`、`public protocol CancellableTimer: Sendable { func cancel() }`、`extension TimerScheduling { func sleep(seconds: Double) async throws }`（キャンセルされたら `CancellationError` を投げる。計画 03 Task 3 のレビューで確定）、本番 `public struct TaskTimerScheduler: TimerScheduling`（`Task.sleep`）
  - TestSupport: `public final class ManualTimerScheduler: TimerScheduling` に `func advance(by seconds: Double) async`（期限の来た action を期限順に実行して待つ）と `var pendingCount: Int`
  - `public enum PowerEvent: Sendable { case willSleep, didWake }`、`public protocol SleepWakeObserving: Sendable { func events() -> AsyncStream<PowerEvent> }`、本番 `WorkspaceSleepWakeObserver`（`NSWorkspace.shared.notificationCenter` の `willSleepNotification` / `didWakeNotification`）。TestSupport: `FakeSleepWake.send(_:)`
  - `public struct WakeSuppression: Sendable { public init(); public mutating func didWake(present: Set<String>); public mutating func filter(added: [DeviceIdentity], removed: [DeviceIdentity]) -> (added: [DeviceIdentity], removed: [DeviceIdentity]); public mutating func endWindow(current: [DeviceIdentity]) -> [DeviceEvent]; public var inWindow: Bool }`
  - `public enum PresenceReason: String, Sendable { case launch, wake }`、`public enum DeviceEvent: Equatable, Sendable { case present(DeviceIdentity, PresenceReason); case added(DeviceIdentity); case removed(DeviceIdentity) }`
  - `public actor DeviceMonitor { public init(hardware: any AudioHardwareQuerying, power: any SleepWakeObserving, timer: any TimerScheduling, wakeWindowSeconds: Double = 10); public func events() throws -> AsyncStream<DeviceEvent>; public func connected() -> [DeviceIdentity]; public func stop() }`

- [ ] **Step 1: WakeSuppression の失敗するテストを書く**

窓の中の規則（§11.1。「復帰から 10 秒以内の再出現なら接続イベントとして扱わない」）: スリープ前からあった UID の removed は保留し、窓の中で戻れば removed も added も出さない。スリープ前に無かった UID の added はそのまま出す。窓の終わりに、保留した removed のうち戻らなかったものを `.removed`、その時点で接続中でスリープ前からあったものを `.present(_, .wake)` として返す。

```swift
@Test func reappearanceInsideWindowIsSwallowed() {
    var w = WakeSuppression(); w.didWake(present: [bt.deviceUID])
    #expect(w.filter(added: [], removed: [bt]) == ([], []))
    #expect(w.filter(added: [bt], removed: []) == ([], []))
    #expect(w.endWindow(current: [bt]) == [.present(bt, .wake)])
}
@Test func removalNotRecoveredIsEmittedAtWindowEnd()   // endWindow(current: []) == [.removed(bt)]
@Test func newDeviceInsideWindowIsAdded()              // スリープ前に無い jack → filter(added: [jack]) == ([jack], [])
@Test func outsideWindowPassesThrough()                // didWake 前と endWindow 後は入力をそのまま返す
```

- [ ] **Step 2: DeviceMonitor の失敗するテストを書く**

```swift
@Test func launchEmitsPresentForCandidatesOnly()   // 内蔵マイク・BT 入力・BT 出力・集約 → [.present(mic,.launch), .present(bt,.launch)]
@Test func addedAndRemovedAreStreamed()            // setDevices + fireChange → .added(jack)、続けて外す → .removed(jack)
@Test func reappearanceWithinWakeWindowIsNotAdded()  // willSleep → didWake → 3 秒後に BT 消失・再出現 → 事象なし。advance(by: 10) で .present(bt, .wake)
@Test func reappearanceAfterWakeWindowIsAdded()      // 2 秒後に消失、advance(10) で .removed(bt)、12 秒後に再出現で .added(bt)
@Test func stopCancelsHardwareObservation()          // stop() → hardware.observationCancelled、ストリーム終了
```

- [ ] **Step 3: 失敗を確認する**
Run: `swift test --filter "WakeSuppressionTests|DeviceMonitorTests"` → Expected: FAIL（型が無い）
- [ ] **Step 4: 実装する**

`DeviceMonitor` はリスナーのコールバックで `AsyncStream<Void>.Continuation.yield()` するだけにし、actor の中の 1 本のループが順に `snapshot()` → `DeviceListDiff.update` → `WakeSuppression.filter` を行う（コールバックごとに `Task` を作ると順序が崩れるため）。`willSleep` で接続中の UID 集合を控え、`didWake` でそれを `WakeSuppression.didWake` に渡して `timer.schedule(after: wakeWindowSeconds)` で `endWindow` を呼ぶ。起動時の `.present(_, .launch)` は `events()` を呼んだ直後に一度だけ流す。

- [ ] **Step 5: 通過を確認する**
Run: `swift test --filter "WakeSuppressionTests|DeviceMonitorTests"` → Expected: PASS
- [ ] **Step 6: コミット**
```bash
git add Sources/AutoNoteCore/Devices/{TimerScheduling,SleepWake,WakeSuppression,DeviceMonitor}.swift Sources/AutoNoteTestSupport/Devices/{ManualTimerScheduler,FakeSleepWake}.swift Tests/AutoNoteCoreTests/Devices/{WakeSuppressionTests,DeviceMonitorTests}.swift
git commit -m "feat(devices): stream input device events with wake suppression"
```

---

### Task 4: MacIdentity と DeviceRegistry（`_autonote/devices.json`）

**Files:**
- Create: `Sources/AutoNoteCore/Devices/MacIdentity.swift`, `DeviceRegistry.swift`
- Create: `Sources/AutoNoteTestSupport/Devices/InMemoryRegistryStorage.swift`, `FakeMacIdentity.swift`
- Test: `Tests/AutoNoteCoreTests/Devices/DeviceRegistryTests.swift`, `MacIdentityTests.swift`

**Interfaces:**
- Consumes: `DeviceIdentity`, `DeviceTransport`, `UIDKind`（Task 1）、`PortableConfigStore.read(_:)` / `write(_:_:)`・`PortableFile.devices`・`AppPaths`（計画 01 前提）
- Produces:
  - `public struct MacIdentity: Codable, Equatable, Sendable { id: String; name: String }`（`id` は `IOPlatformUUID`、`name` はコンピュータ名）、`public protocol MacIdentityProviding: Sendable { func current() -> MacIdentity }`、本番 `SystemMacIdentityProvider`
  - `public protocol DeviceRegistryStorage: Sendable { func load() async throws -> Data?; func save(_ data: Data) async throws; func backupCorrupt(_ data: Data) async throws }`、本番 `PortableDevicesStorage(store: PortableConfigStore, paths: AppPaths)`（読み書きは `PortableFile.devices`。壊れたファイルの退避先はアプリ領域の `devices.json.corrupt-<yyyyMMdd-HHmmss>`。計画 01 の `settings.json` と同じ流儀）
  - `public enum DeviceDisposition: String, Codable, Sendable { case registered, ignored }`
  - `public struct RegisteredDevice: Codable, Equatable, Identifiable, Sendable { id: String; name: String; transport: DeviceTransport; deviceUID: String; modelUID: String?; uidKind: UIDKind; disposition: DeviceDisposition; startOnModelMatch: Bool; registeredOn: MacIdentity; registeredAt: Date }`（§9.5 の「表示名・方式・識別子・登録した Mac」）
  - `public enum MatchRule: String, Sendable { case deviceUID, modelUIDAndName, name }`
  - `public enum RegistryMatch: Equatable, Sendable { case registered(entryID: String, rule: MatchRule); case ignored(entryID: String); case reRegistrationSuggested(entryID: String); case unknown }`
  - `public actor DeviceRegistry { init(storage: any DeviceRegistryStorage, mac: any MacIdentityProviding, now: @Sendable @escaping () -> Date = Date.init); func reload() async; func entries() -> [RegisteredDevice]; func match(_ device: DeviceIdentity) -> RegistryMatch; func register(_ device: DeviceIdentity, startOnModelMatchDefault: Bool = false) async throws -> RegisteredDevice; func ignore(_ device: DeviceIdentity) async throws; func remove(entryID: String) async throws; func setDisposition(entryID: String, _ d: DeviceDisposition) async throws; func setStartOnModelMatch(entryID: String, _ on: Bool) async throws }`

ファイル形式（snake_case、ISO 8601、`sortedKeys` と `prettyPrinted`）: `{"version": 1, "devices": [RegisteredDevice…]}`。

一致判定（§11.2。上から順に最初に当たったもの）:
1. `deviceUID` が完全一致する項目 → `disposition` に応じて `.registered(_, .deviceUID)` / `.ignored`（どの Mac で登録した項目でもよい）
2. 方式が `.usb` で `modelUID` が nil でも `0 0` でもなく、`modelUID` と名前が一致する `registered` の項目 → その項目の `registeredOn` が今の Mac なら、`startOnModelMatch` が真で `.registered(_, .modelUIDAndName)`、偽で `.unknown`。別の Mac なら `.reRegistrationSuggested`
3. 方式が `.bluetooth` で名前が一致する `registered` の Bluetooth 項目 → 2 と同じ扱いで規則は `.name`
4. それ以外 → `.unknown`

`register` で付ける `startOnModelMatch` は `startOnModelMatchDefault || uidKind == .portBased`（前者は `Settings.startOnModelMatch`、後者は §11.2「シリアルが含まれないと判定できた機材は既定でオン」）。同じ `deviceUID` の項目があれば新しく足さずにそれを `registered` に直す。

- [ ] **Step 1: 失敗するテストを書く**

```swift
@Test func exactInputUIDMatches()                     // register(bt) → match(bt) == .registered(id, .deviceUID)
@Test func ignoredDeviceMatchesIgnored()              // ignore(jack) → .ignored
@Test func usbSameModelOtherUnitFollowsSetting()      // USB A を登録 → 別 UID・同 modelUID・同名 B: 既定（individual）は .unknown、setStartOnModelMatch(true) で .registered(_, .modelUIDAndName)
@Test func portBasedUSBDefaultsToModelMatchOn()       // uidKind .portBased を register → true。individual は false、startOnModelMatchDefault: true なら true
@Test func bluetoothZeroModelUIDIsNeverAModelMatch()  // BT「Headset X」(0 0) を登録し startOnModelMatch true → 名前の違う BT「Headset Y」(0 0) は .unknown、同名で UID 違いは .registered(_, .name)
@Test func otherMacNameMatchSuggestsReRegistration()  // registeredOn が別 Mac の BT 項目に名前だけ一致 → .reRegistrationSuggested
@Test func fileRoundTripsWithSnakeCaseKeys()          // 保存した JSON に "device_uid" "registered_on" "start_on_model_match" があり、別インスタンスで読み直して entries が同じ
@Test func missingFileMeansEmptyRegistry()
@Test func corruptFileIsBackedUpAndRegistryStartsEmpty() // load が "{not json" → entries 空、backupCorrupt に元のバイト列（本番実装ではアプリ領域に `devices.json.corrupt-` で始まるファイル）、次の register で正しい JSON が save される
@Test func missingOutputFolderUsesMirror()            // PortableConfigStore(paths: 一時 AppPaths, outputFolder: 存在しないフォルダ) で register → 写しに devices.json があり match が効く
@Test func systemMacIdentityIsStable()                // SystemMacIdentityProvider().current() を 2 回呼んで同じ、id が空でない（MacIdentityTests）
```

- [ ] **Step 2: 失敗を確認する**
Run: `swift test --filter "DeviceRegistryTests|MacIdentityTests"` → Expected: FAIL（型が無い）
- [ ] **Step 3: `MacIdentity.swift` と `DeviceRegistry.swift` を実装する**

`IOPlatformUUID` は `IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))` の `kIOPlatformUUIDKey`、名前は `Host.current().localizedName`（取れなければ `"Mac"`）。

- [ ] **Step 4: 通過を確認する**
Run: `swift test --filter "DeviceRegistryTests|MacIdentityTests"` → Expected: PASS
- [ ] **Step 5: コミット**
```bash
git add Sources/AutoNoteCore/Devices/{MacIdentity,DeviceRegistry}.swift Sources/AutoNoteTestSupport/Devices/{InMemoryRegistryStorage,FakeMacIdentity}.swift Tests/AutoNoteCoreTests/Devices/{DeviceRegistryTests,MacIdentityTests}.swift
git commit -m "feat(devices): add device registry stored in _autonote/devices.json"
```

---

### Task 5: RecorderStateMachine（§5.9 の全セル）

**Files:**
- Create: `Sources/AutoNoteCore/Devices/RecorderStateMachine.swift`
- Test: `Tests/AutoNoteCoreTests/Devices/RecorderStateMachineTests.swift`, `Tests/AutoNoteCoreTests/Devices/RecorderTransitionTable.swift`

**Interfaces:**
- Consumes: `DeviceIdentity`（Task 1）
- Produces:
  - `public enum RecorderState: String, Sendable { case idle, countdown, recording, paused, grace }`（overview §3 の形）
  - `public enum RecordingTrigger: String, Sendable { case auto, manual }`、`public enum MicrophoneChoice: Equatable, Sendable { case device(DeviceIdentity), systemDefault }`
  - `public struct AutoRecordConfig: Equatable, Sendable { countdownSeconds: Int; graceSeconds: Int; language: Language; startOnModelMatch: Bool; init(countdownSeconds:graceSeconds:language:startOnModelMatch:) }` — 初期化で countdown を 0〜30（§11.4）、grace を 5〜300（overview §3 の `disconnectGraceSeconds` と同じ）に丸める
  - `public enum RecorderEvent: Equatable, Sendable { case deviceConnected(DeviceIdentity, autoStartEntryID: String?); case deviceDisconnected(DeviceIdentity); case timerFired(token: Int); case cancelCountdown; case manualStart; case manualStop; case pause; case resume; case startForConnectedDevice(DeviceIdentity, entryID: String); case sessionEnded }`（`autoStartEntryID` は登録照合が `.registered` のときの項目 ID。それ以外は nil）
  - `public enum RecorderEffect: Equatable, Sendable { case postCountdownNotice(DeviceIdentity, seconds: Int); case dismissCountdownNotice; case scheduleTimer(seconds: Int, token: Int); case cancelTimer; case startRecording(MicrophoneChoice, RecordingTrigger); case stopRecording; case pauseRecording; case resumeRecording; case suspendMicrophone; case reattachMicrophone(DeviceIdentity); case showGraceBanner(seconds: Int); case clearGraceBanner }`
  - `public struct RecorderStateMachine: Sendable { public init(config: AutoRecordConfig); public var config: AutoRecordConfig; public private(set) var state: RecorderState; public private(set) var trigger: RecordingTrigger?; public private(set) var origin: DeviceIdentity?; public private(set) var originEntryID: String?; public private(set) var pendingTimerToken: Int?; public var needsQuitConfirmation: Bool; public mutating func apply(_ event: RecorderEvent) -> (RecorderState, [RecorderEffect]) }`

規則: token は 1 から振り、`scheduleTimer` のたびに 1 増やす。`timerFired` は `pendingTimerToken` と同じ値のときだけ効く。猶予中の「同じ機材が復帰」は、接続した機材の `deviceUID` が `origin` と同じか、`autoStartEntryID` が `originEntryID` と同じとき（USB をポートを変えて差し直した場合を含む）。切断は `deviceUID` が `origin` と同じときだけ起点機材の切断とみなす。

- [ ] **Step 1: 遷移表をテストデータとして書く**

`RecorderTransitionTable.swift` に、8 つの構成 × 14 列 = 112 セルを `[Cell]` として書く。下の表に無いセルはすべて「状態も起点も変わらず効果は空」として生成する。構成の作り方（既定の config: カウントダウン 5、猶予 30）:

| 構成 | 作り方 | state / trigger / origin |
|---|---|---|
| I | 新規 | idle / nil / nil |
| CD | I に c1 | countdown / nil / A |
| RA | CD に c6（token 1） | recording / auto / A |
| RM | I に c9 | recording / manual / nil |
| PA | RA に c11 | paused / auto / A |
| PM | RM に c11 | paused / manual / nil |
| GR | RA に c4 | grace / auto / A（録音中から） |
| GP | PA に c4 | grace / auto / A（一時停止中から） |

列: c1 `deviceConnected(A, "eA")`、c2 `deviceConnected(B, "eB")`（別の登録機材）、c3 `deviceConnected(U, nil)`（未登録）、c4 `deviceDisconnected(A)`、c5 `deviceDisconnected(B)`、c6 `timerFired(保留中の token。保留が無い構成では最後に発行した token、未発行なら 1)`、c7 `timerFired(99)`、c8 `cancelCountdown`、c9 `manualStart`、c10 `manualStop`、c11 `pause`、c12 `resume`、c13 `startForConnectedDevice(A, "eA")`、c14 `sessionEnded`。

効果の略記: N(x,s) = `postCountdownNotice(x, seconds: s)`、D = `dismissCountdownNotice`、T(s,k) = `scheduleTimer(seconds: s, token: k)`、X = `cancelTimer`、S(A,auto) = `startRecording(.device(A), .auto)`、S(既定,manual) = `startRecording(.systemDefault, .manual)`、P / R / Q = pause / resume / stopRecording、M- = `suspendMicrophone`、M+(A) = `reattachMicrophone(A)`、G(s) = `showGraceBanner(seconds: s)`、g = `clearGraceBanner`。効果は書いた順のまま比べる。

| 構成 | 変化するセル（列 → 次の構成: 効果）。ここに無い列は「変化なし・効果なし」 | 要件書の根拠 |
|---|---|---|
| I | c1 → CD: N(A,5), T(5,1) ／ c2 → CD（origin B）: N(B,5), T(5,1) ／ c9 → RM: S(既定,manual) ／ c13 → RA: S(A,auto) | 待機の行、§11.1 起動時の［開始］ |
| CD | c4 → I: X, D ／ c6 → RA: D, S(A,auto) ／ c8 → I: X, D ／ c9 → RM: X, D, S(既定,manual) | カウントダウンの行。c2 は補足 2（最初の 1 台） |
| RA | c4 → GR: M-, T(30,2), G(30) ／ c10 → I: Q ／ c11 → PA: P ／ c14 → I: なし | 録音中の行。c2 は補足 1、c9 は §11.4-4 |
| RM | c10 → I: Q ／ c11 → PM: P ／ c14 → I: なし | c4 が無いのは §4.4（手動は切断で止めない） |
| PA | c4 → GP: M-, T(30,2), G(30) ／ c10 → I: Q ／ c12 → RA: R ／ c14 → I: なし | 一時停止中の行 |
| PM | c10 → I: Q ／ c12 → RM: R ／ c14 → I: なし | |
| GR | c1 → RA: X, g, M+(A) ／ c6 → I: g, Q ／ c10 → I: X, g, Q ／ c14 → I: X, g | 猶予中の行。c8 が無いのは「取り消すは出さない」 |
| GP | c1 → RA: X, g, M+(A), R ／ c6 → I: g, Q ／ c10 → I: X, g, Q ／ c14 → I: X, g | 一時停止中の「再開時は機材復帰を待つ」 |

```swift
@Test func tableHasEveryCell() { #expect(RecorderTransitionTable.cells.count == 112) }
@Test(arguments: RecorderTransitionTable.cells)
func transition(_ cell: RecorderTransitionTable.Cell) {
    var m = RecorderTransitionTable.machine(in: cell.from)
    let (state, effects) = m.apply(RecorderTransitionTable.event(cell.column, for: m))
    #expect(state == cell.to.state); #expect(m.trigger == cell.to.trigger); #expect(m.origin == cell.to.origin)
    #expect(effects == cell.effects)
}
```

- [ ] **Step 2: 表の外の規則のテストを書く**

```swift
@Test func zeroCountdownStartsImmediately()        // countdown 0: I に c1 → recording/auto、効果 [S(A,auto)]（通知もタイマーも無し）
@Test func configIsClamped()                       // countdown 45→30, -1→0。grace 0→5, 1000→300
@Test func staleGraceTimerAfterFlapIsIgnored()     // RA → c4（token 2）→ c1 → c4（token 3）→ timerFired(2) は変化なし → timerFired(3) で idle と Q
@Test func graceReturnByEntryIDCountsAsSameDevice() // GR に deviceConnected(A の UID 違い, "eA") → RA、M+ は新しい identity
@Test func twoDevicesAtOnceCountDownOnlyFirst()    // I に c1 と c2 を続けて → N は A の 1 回だけ、origin == A（補足 2）
@Test func needsQuitConfirmationWhileRecordingPausedOrGrace() // RA/RM/PA/PM/GR/GP で true、I と CD で false（補足 3）
@Test func usesConfiguredSecondsInEffects()        // countdown 10・grace 45 で N(A,10)/T(10,1)、T(45,2)/G(45)
```

- [ ] **Step 3: 失敗を確認する**
Run: `swift test --filter RecorderStateMachineTests` → Expected: FAIL（`RecorderStateMachine` が無い）
- [ ] **Step 4: `RecorderStateMachine.swift` を実装する**

構成ごとに `switch (state, event)` で書き、表に無い組はすべて `(state, [])` を返す既定の枝にまとめる。

- [ ] **Step 5: 通過を確認する**
Run: `swift test --filter RecorderStateMachineTests` → Expected: PASS（112 セル＋7 件）
- [ ] **Step 6: コミット**
```bash
git add Sources/AutoNoteCore/Devices/RecorderStateMachine.swift Tests/AutoNoteCoreTests/Devices/RecorderStateMachineTests.swift Tests/AutoNoteCoreTests/Devices/RecorderTransitionTable.swift
git commit -m "feat(devices): add recorder state machine covering every transition"
```

---

### Task 6: 通知の種類（UserNotice・UserNotifier）と文言・RecorderSnapshot

**Files:**
- Create: `Sources/AutoNoteCore/Devices/UserNotice.swift`, `Sources/AutoNoteCore/Devices/RecorderSnapshot.swift`
- Create: `Sources/AutoNoteTestSupport/Devices/FakeUserNotifier.swift`
- Test: `Tests/AutoNoteCoreTests/Devices/UserNoticeTests.swift`

**Interfaces:**
- Consumes: `DeviceRef`, `MeetingID`, `Track`, `Language`（計画 01）、`RecorderState`（Task 5）
- Produces（overview §3 の case とメソッドを一字一句そのまま。全計画分をここで宣言する。すべて `public`、`Equatable, Sendable`）:
  - `public enum UserNotice` の case: `deviceConnectedCountdown(DeviceRef, seconds: Int)`、`deviceSeenFirstTime(DeviceRef)`、`deviceAlreadyConnected(DeviceRef)`、`deviceGoneGrace(DeviceRef, seconds: Int)`、`silence(Track)`、`diskLow(availableBytes: Int64)`、`recordingTooShort(MeetingID)`、`interruptedRecordingFound(MeetingID)`、`minutesGenerated(MeetingID, title: String)`、`transcriptOnly(MeetingID)`、`claudeNotLoggedIn(MeetingID)`、`overwriteConfirmation(MeetingID)`、`outputFolderMissing`、`automationFailed(name: String, MeetingID)`。`public var id: String { get }`
  - `public enum RegisterAnswer { case yes, no, never }`
  - `public enum UserNoticeAction` の case: `cancelCountdown`、`startNow(DeviceRef)`、`registerDevice(DeviceRef, answer: RegisterAnswer)`、`openMeeting(MeetingID)`、`retry(MeetingID)`、`resolveOverwrite(MeetingID, overwrite: Bool)`、`transcribeTooShort(MeetingID)`、`discardTooShort(MeetingID)`、`recoverInterrupted(MeetingID)`、`discardInterrupted(MeetingID)`、`openPrivacySettings`
  - `public protocol UserNotifier: Sendable { func post(_ notice: UserNotice) async; func withdraw(id: String) async }`（実装は計画 06。通知に音は付けない）
  - `public enum DeviceNoticeCopy { public static func body(for notice: UserNotice) -> String?; public static func actions(for notice: UserNotice) -> [(title: String, action: UserNoticeAction)]; public static func isSticky(_ notice: UserNotice) -> Bool }` — 機材の 4 case の文言（他の case は nil / 空。文言は投げる側の計画と計画 06 が持つ）
  - `public enum Banner { public static func grace(seconds: Int) -> String; public static let micFallback: String; public static let startFailed: String }`
  - `public struct RecorderSnapshot: Equatable, Sendable { public var state: RecorderState; public var meetingID: MeetingID?; public var startedAt: Date?; public var deviceName: String?; public var deadline: Date? /* カウントダウン・猶予の満了 */; public var isManual: Bool; public var language: Language; public var banner: String?; public var canCancelCountdown: Bool { get } }`、`public static func idle(language: Language) -> RecorderSnapshot`
  - TestSupport: `public final class FakeUserNotifier: UserNotifier`（`posted: [UserNotice]`、`withdrawn: [String]`）

`id` の値（同じ事象は同じ id。取り下げに使う）: `device.countdown`、`device.first.<uid>`、`device.connected.<uid>`、`device.grace`、`silence.<track>`、`disk.low`、`meeting.tooShort.<id>`、`meeting.interrupted.<id>`、`meeting.minutes.<id>`、`meeting.transcriptOnly.<id>`、`meeting.claudeLogin.<id>`、`meeting.overwrite.<id>`、`output.missing`、`automation.<name>.<id>`。

機材の文言（要件書の固定文言。○○ は `DeviceRef.name`、間に空白を入れない）:

| case | 本文 | ボタン | 残り方 | 根拠 |
|---|---|---|---|---|
| `deviceConnectedCountdown(d, seconds: s)` | `○○が接続されました。s 秒後に録音を始めます` | 取り消す → `.cancelCountdown` | 通常 | §4.1-2、§11.4 |
| `deviceSeenFirstTime(d)` | `○○が接続されました。この機材で自動録音しますか？` | はい / いいえ / 今後聞かない → `.registerDevice(d, answer: .yes / .no / .never)` | 通常 | §11.3 |
| `deviceAlreadyConnected(d)` | `○○が接続されています。録音を始めますか？` | 開始 → `.startNow(d)` | 押すまで残る | §11.1 |
| `deviceGoneGrace(d, seconds: s)` | `機材が外れました。s 秒後に停止` | なし（取り消すは出さない。overview §8b） | 通常 | §11.5 |

画面の帯（`RecorderSnapshot.banner`）: `Banner.grace(seconds: 30)` == `機材が外れました。30 秒後に停止`（§11.5）。`micFallback` == `機材に戻せなかったため、Mac の既定入力で録音を続けています`、`startFailed` == `録音を開始できませんでした。マイクの許可と機材を確認してください`（この 2 つは本計画の判断。§11.5「ウィンドウに知らせる」）。

- [ ] **Step 1: 失敗するテストを書く**

```swift
@Test func countdownCopy() {
    let n = UserNotice.deviceConnectedCountdown(btRef, seconds: 5)
    #expect(DeviceNoticeCopy.body(for: n) == "Fictional BT Headsetが接続されました。5 秒後に録音を始めます")
    #expect(DeviceNoticeCopy.actions(for: n).map(\.title) == ["取り消す"]); #expect(n.id == "device.countdown")
}
@Test func firstSeenCopyAndActions()  // 本文の表どおり、actions の action が .registerDevice(btRef, answer: .yes/.no/.never)、id "device.first.00-11-22-33-44-55:input"
@Test func alreadyConnectedIsSticky() // 本文の表どおり、[.startNow(btRef)]、isSticky == true。他の case は false
@Test func graceCopyHasNoActions()    // "機材が外れました。30 秒後に停止"、actions 空
@Test func nonDeviceNoticesHaveNoCopyHere()  // .outputFolderMissing など機材以外の 10 case は body nil・actions 空、id は上の表どおり（全 14 case を arguments で回す）
@Test func bannersCopy()              // Banner.grace(seconds: 30)、micFallback、startFailed が上の文字列
@Test func canCancelOnlyInCountdown() // RecorderSnapshot の state .countdown だけ true（猶予中は取り消さない §5.9）
```

- [ ] **Step 2: 失敗を確認する**
Run: `swift test --filter UserNoticeTests` → Expected: FAIL（`UserNotice` が無い）
- [ ] **Step 3: `UserNotice.swift`、`RecorderSnapshot.swift`、`FakeUserNotifier` を実装する**
- [ ] **Step 4: 通過を確認する**
Run: `swift test --filter UserNoticeTests` → Expected: PASS
- [ ] **Step 5: コミット**
```bash
git add Sources/AutoNoteCore/Devices/UserNotice.swift Sources/AutoNoteCore/Devices/RecorderSnapshot.swift Sources/AutoNoteTestSupport/Devices/FakeUserNotifier.swift Tests/AutoNoteCoreTests/Devices/UserNoticeTests.swift
git commit -m "feat(devices): declare UserNotice for all plans with device copy and snapshot"
```

---

### Task 7: RecordingControl と MicrophoneReattacher（マイク組み直しの仮の方式）

**Files:**
- Create: `Sources/AutoNoteCore/Devices/RecordingControl.swift`
- Create: `Sources/AutoNoteTestSupport/Devices/FakeRecordingControl.swift`
- Test: `Tests/AutoNoteCoreTests/Devices/MicrophoneReattacherTests.swift`（アダプタの 2 件も同じファイル）

**Interfaces:**
- Consumes: `RecordingSession`・`StopReason`・`RecordingEvent`（計画 02 前提）、`TimerScheduling`（Task 3）、`DeviceRef`, `Language`, `MeetingID`
- Produces:
  - `public protocol RecordingControl: Sendable { func start(device: DeviceRef?, language: Language, manual: Bool) async throws -> MeetingID; func stop(reason: StopReason) async; func pause() async; func resume() async; func bookmark(note: String?) async throws -> Bookmark; func setLanguage(_ language: Language) async; func detachMicrophone() async; func attachMicrophone(uid: String?) async throws; func selfStops() -> AsyncStream<Void> }`
  - `public actor RecordingSessionControl: RecordingControl { public init(session: RecordingSession) }` — 計画 02 への薄い委譲。`start` は `Configuration(language:, microphoneUID: device?.uid, device: device)`。`bookmark` はそのまま投げる。`stop`・`pause`・`resume`・`setLanguage`・`detachMicrophone` の throw は `os.Logger` に残して握る。`selfStops()` は `session.events()` を購読し、`.stopped` のうち自分が `stop` を呼んでいないものだけを流す
  - `public enum ReattachOutcome: Equatable, Sendable { case device(attempts: Int), fallbackToDefault, failed }`
  - `public struct MicrophoneReattacher: Sendable { init(control: any RecordingControl, timer: any TimerScheduling, retryInterval: Double = 0.5, maxAttempts: Int = 20); func reattach(uid: String) async -> ReattachOutcome }`
  - TestSupport: `FakeRecordingControl`（`starts: [(DeviceRef?, Language, Bool)]`、`stopReasons: [StopReason]`、`stopCount`、`pauseCount`、`resumeCount`、`bookmarks: [String?]`、`languages: [Language]`、`detachCount`、`attachCalls: [String?]`、`failAttach(uid:times:)`、`failDefaultAttach`、`failStart`、`emitSelfStop()`）

組み直しの方式は**仮**（スパイク項目 10 は未実施）: `MicHotSwap` と同じく、戻った直後は入力ストリームが未準備のことがあるので `attachMicrophone(uid:)` を 0.5 秒おきに最大 20 回試す。全部失敗したら `attachMicrophone(uid: nil)`（Mac の既定入力。§11.5）。それも失敗したら `.failed`（マイクトラックは無音のまま録音は続く）。値は Task 10 の 👤 の結果で見直す。

- [ ] **Step 1: 失敗するテストを書く**

```swift
@Test func succeedsAfterRetries()       // failAttach(uid: A, times: 3) → 0.5 秒ずつ advance → .device(attempts: 4)、attachCalls == [A, A, A, A]
@Test func fallsBackToDefaultAfter20()  // times: 20 → .fallbackToDefault、attachCalls.last == nil、A は 20 回
@Test func reportsFailedWhenDefaultFails()  // times: 20 + failDefaultAttach → .failed
@Test func doesNotWaitBeforeFirstAttempt()  // advance せずに 1 回目の attach が呼ばれる
@Test func adapterReportsOnlyUnrequestedStops() async // 計画 02 の FakeAudioSourceFactory で RecordingSession を作り RecordingSessionControl で包む: stop(reason: .manual) では selfStops() に流れない。ディスク不足の .stopped(_, .diskFull) では 1 件流れる
@Test func adapterPassesMicrophoneUID() async     // start(device: A.deviceRef, …) → Configuration.microphoneUID == A.deviceRef.uid、device == A.deviceRef。start(device: nil) → 両方 nil
@Test func adapterForwardsBookmarkAndLanguage() async // bookmark(note: "x") が RecordingSession の Bookmark を返す、setLanguage(.en) 後の manifest の language == .en
```

- [ ] **Step 2: 失敗を確認する**
Run: `swift test --filter MicrophoneReattacherTests` → Expected: FAIL
- [ ] **Step 3: `RecordingControl.swift` と `FakeRecordingControl` を実装する**
- [ ] **Step 4: 通過を確認する**
Run: `swift test --filter MicrophoneReattacherTests` → Expected: PASS
- [ ] **Step 5: コミット**
```bash
git add Sources/AutoNoteCore/Devices/RecordingControl.swift Sources/AutoNoteTestSupport/Devices/FakeRecordingControl.swift Tests/AutoNoteCoreTests/Devices/MicrophoneReattacherTests.swift
git commit -m "feat(devices): bridge RecordingSession and retry microphone reattach"
```

---

### Task 8: AutoRecordCoordinator — 自動開始・猶予・手動操作

**Files:**
- Create: `Sources/AutoNoteCore/Devices/AutoRecordCoordinator.swift`
- Test: `Tests/AutoNoteCoreTests/Devices/AutoRecordCoordinatorTests.swift`

**Interfaces:**
- Consumes: `DeviceMonitor`, `DeviceEvent`（Task 3）、`DeviceRegistry`, `RegistryMatch`（Task 4）、`RecorderStateMachine` 一式（Task 5）、`UserNotifier`, `UserNotice`, `UserNoticeAction`, `RecorderSnapshot`, `Banner`（Task 6）、`RecordingControl`, `MicrophoneReattacher`（Task 7）、`Settings`, `Bookmark`（計画 01）
- Produces（すべて `public`。計画 06 の `RecorderPort` はこの名前に合わせる）:
  - `public actor AutoRecordCoordinator { public init(monitor: DeviceMonitor, registry: DeviceRegistry, recorder: any RecordingControl, notifier: any UserNotifier, timer: any TimerScheduling, config: @Sendable @escaping () async -> AutoRecordConfig, now: @Sendable @escaping () -> Date = Date.init) }`
  - `public func run() async`（`monitor.events()` と `recorder.selfStops()` を読み、終わるまで戻らない）、`public func handle(_ event: DeviceEvent) async`（`run` の中身。テストはこれを直接呼ぶ）
  - 操作（計画 06 のメニュー・CLI・ショートカットが呼ぶ）: `public func manualStart(language: Language?) async throws`（開始の失敗をそのまま投げる）、`public func stop() async`、`public func pause() async`、`public func resume() async`、`public func cancelCountdown() async`、`public func bookmark(note: String?) async throws -> Bookmark`（録音中・一時停止中・猶予中だけ。それ以外は `AutoRecordError.notRecording`）、`public func setLanguage(_ language: Language) async`、`public func handle(_ action: UserNoticeAction) async`（通知のボタン。Task 9）
  - `public enum AutoRecordError: Error, Equatable, Sendable { case notRecording }`
  - `public func current() -> RecorderSnapshot`、`public func snapshots() -> AsyncStream<RecorderSnapshot>`（呼ぶたびに新しい購読。最初に現在値を 1 件流す）
  - `public static func config(from settings: Settings) -> AutoRecordConfig`（`countdownSeconds`、`disconnectGraceSeconds`、`defaultLanguage`、`startOnModelMatch`）

効果の実行: `postCountdownNotice(A, s)` → `post(.deviceConnectedCountdown(A.deviceRef, seconds: s))`、`dismissCountdownNotice` → `withdraw(id: "device.countdown")`、`scheduleTimer` → `timer.schedule` で `apply(.timerFired(token:))`、`startRecording(.device(A), .auto)` → `recorder.start(device: A.deviceRef, language: 言語, manual: false)`、`.systemDefault, .manual` → `start(device: nil, language: 引数か言語, manual: true)`。返った `MeetingID` と `now()` を snapshot の `meetingID`・`startedAt` に入れる。自動開始が投げたら `apply(.sessionEnded)` と `banner = Banner.startFailed`（`manualStart` は同じ後始末をしてから投げ直す）。`suspendMicrophone` → `detachMicrophone()`、`reattachMicrophone(A)` → `MicrophoneReattacher.reattach(uid:)`、結果が `.device` 以外なら `banner = Banner.micFallback`。`showGraceBanner(s)` → `banner = Banner.grace(seconds: s)`、`deadline = now + s`、`post(.deviceGoneGrace(origin.deviceRef, seconds: s))`。`clearGraceBanner` → banner と deadline を消し `withdraw(id: "device.grace")`。`stopRecording` → 猶予満了（猶予中の `timerFired`）なら `stop(reason: .deviceGone)`、それ以外は `.manual`。`selfStops()` の 1 件 → `apply(.sessionEnded)`。各 `apply` の前に `machine.config = await config()`。

言語: `setLanguage` は録音中・一時停止中・猶予中なら `recorder.setLanguage` に渡し、待機中・カウントダウン中なら次の録音の言語として持つ（停止で設定の既定に戻す）。`snapshot.language` は常に今の値。

- [ ] **Step 1: 失敗するテストを書く（全部フェイク。登録済み A の registry を用意する）**

```swift
@Test func registeredConnectStartsAfterCountdown() async {
    await c.handle(.added(A))
    #expect(notifier.posted == [.deviceConnectedCountdown(A.deviceRef, seconds: 5)])
    await timer.advance(by: 4.9); #expect(recorder.starts.isEmpty)
    await timer.advance(by: 0.1)
    #expect(recorder.starts.count == 1 && recorder.starts[0].0 == A.deviceRef && recorder.starts[0].2 == false)
    #expect(notifier.withdrawn.contains("device.countdown")); #expect(await c.current().state == .recording)
}
@Test func cancelCountdownPreventsStart()             // cancelCountdown → advance(5) → starts 空、state idle
@Test func originDisconnectStopsAfterGrace()          // 録音中に .removed(A) → detachCount 1、banner "機材が外れました。30 秒後に停止"、posted に .deviceGoneGrace(A.deviceRef, seconds: 30) → advance(29.9) で stopCount 0 → advance(0.1) で 1・stopReasons == [.deviceGone]、banner nil、withdrawn に "device.grace"
@Test func graceReturnReattachesSameDevice()          // 猶予中に .added(A) → attachCalls == [A.deviceUID]、state recording、stopCount 0
@Test func reattachFallbackShowsBanner()              // failAttach(A, 20) → 復帰後 advance(10) → attachCalls.last == nil、banner == Banner.micFallback
@Test func manualStartUsesDefaultInputAndIgnoresDisconnect() // manualStart(.en) → starts[0] == (nil, .en, true)、snapshot.isManual。.removed(A) で状態は recording のまま
@Test func manualStartFailureThrows()                 // failStart → manualStart が投げる、state idle、banner == Banner.startFailed
@Test func autoStartFailureShowsBanner()              // failStart で自動開始 → state idle、banner == Banner.startFailed
@Test func autoStartUsesConfiguredLanguage()          // config.language .en → 自動開始の language == .en
@Test func pauseResumeStopRouteToRecorder()           // pause/resume/stop がそれぞれ 1 回ずつ届く、stopReasons == [.manual]
@Test func bookmarkOnlyWhileRecording()               // 待機中は AutoRecordError.notRecording、録音中・猶予中は recorder.bookmarks == ["x"]
@Test func setLanguageWhileRecordingAndIdle()         // 録音中 setLanguage(.en) → languages == [.en]・snapshot.language .en。待機中 setLanguage(.auto) → 次の自動開始の language == .auto、停止後は .ja に戻る
@Test func selfStopReturnsToIdleWithoutStopCall()     // emitSelfStop → state idle、stopCount 0（§5.9 補足 5 のディスク不足停止）
@Test func quickUnplugCallsStopOnce()                 // 開始 10 秒後に .removed(A) → advance(30) → stopCount == 1（補足 4 の判定は計画 02 側）
@Test func secondRegisteredDeviceIgnoredWhileRecording() // 録音中に登録済み B の .added → posted に countdown が増えない、starts 1 件のまま
@Test func snapshotsStreamEachTransition()            // snapshots() に idle → countdown（deadline = now+5、deviceName A）→ recording（meetingID あり）の 3 件
```

- [ ] **Step 2: 失敗を確認する**
Run: `swift test --filter AutoRecordCoordinatorTests` → Expected: FAIL
- [ ] **Step 3: `AutoRecordCoordinator.swift` を実装する**

`.added` は `await registry.reload()` → `registry.match` を引き、`.registered(entryID, _)` なら `deviceConnected(d, autoStartEntryID: entryID)`、それ以外は `deviceConnected(d, autoStartEntryID: nil)` を状態機械に渡す（猶予中の復帰判定に使うため未登録でも渡す）。登録通知と `handle(_ action:)` は Task 9（この Task では空の実装）。`.removed` は `deviceDisconnected`。`os.Logger`（サブシステム `com.yutaokoshi.autonote`、カテゴリ `devices`）に状態遷移を 1 行ずつ残す。

- [ ] **Step 4: 通過を確認する**
Run: `swift test --filter AutoRecordCoordinatorTests` → Expected: PASS
- [ ] **Step 5: コミット**
```bash
git add Sources/AutoNoteCore/Devices/AutoRecordCoordinator.swift Tests/AutoNoteCoreTests/Devices/AutoRecordCoordinatorTests.swift
git commit -m "feat(devices): coordinate countdown, recording and disconnect grace"
```

---

### Task 9: AutoRecordCoordinator — 登録通知と起動時・復帰時の接続（`handle(_ action:)`）

**Files:**
- Modify: `Sources/AutoNoteCore/Devices/AutoRecordCoordinator.swift`
- Test: `Tests/AutoNoteCoreTests/Devices/AutoRecordRegistrationTests.swift`

**Interfaces:**
- Consumes: Task 8 の `AutoRecordCoordinator`、`DeviceRegistry.register` / `ignore`（Task 4）、`UserNotice.deviceSeenFirstTime` / `deviceAlreadyConnected`、`UserNoticeAction`、`RegisterAnswer`（Task 6）
- Produces: Task 8 の `public func handle(_ action: UserNoticeAction) async` の中身。扱うのは `.cancelCountdown`、`.startNow(DeviceRef)`、`.registerDevice(DeviceRef, answer:)` の 3 つ。他の case は何もしない（計画 06 が自分で処理する）。`DeviceRef.uid` から `monitor.connected()` の `DeviceIdentity` を引く

規則:
- `.added` で照合が `.unknown` か `.reRegistrationSuggested` → `post(.deviceSeenFirstTime(d.deviceRef))`（状態に関係なく出す。`.ignored` は何もしない）。§11.3
- `.registerDevice(ref, .yes)` → `registry.register(d, startOnModelMatchDefault: config.startOnModelMatch)`。機材がまだ接続中なら `deviceConnected(d, autoStartEntryID: 新しい項目 ID)` を状態機械に渡す（待機中ならカウントダウンが始まり、それ以外は表の規則どおり無視される）。`.no` → 何も保存しない（次の接続でまた聞く）。`.never` → `registry.ignore`。いずれも `withdraw(id: "device.first.<uid>")`
- `.present(_, .launch)` と `.present(_, .wake)` で照合が `.registered` かつ待機中 → `post(.deviceAlreadyConnected(d.deviceRef))`。自動開始はしない（§11.1）。未登録の `.present` には何も出さない（起動のたびに内蔵マイクを聞かないため）
- `.startNow(ref)` → 機材がまだ接続中なら `startForConnectedDevice(d, entryID:)`（カウントダウンなしで自動開始扱い。切断で猶予に入る）。接続中でなければ何もしない
- `.cancelCountdown` → Task 8 の `cancelCountdown()` と同じ
- `deviceAlreadyConnected` の通知は、その機材の `.removed` と、状態が待機を離れたときに `withdraw(id: "device.connected.<uid>")`

- [ ] **Step 1: 失敗するテストを書く**

```swift
@Test func firstSeenAddedAsksRegistration()        // 未登録 U の .added → posted.last == .deviceSeenFirstTime(U.deviceRef)、countdown なし
@Test func answerYesRegistersAndStartsCountdown()  // handle(.registerDevice(U.deviceRef, answer: .yes)) → entries に U（registeredOn == fake Mac、registered）、posted に .deviceConnectedCountdown(U.deviceRef, seconds: 5)
@Test func answerYesWhileRecordingRegistersOnly()  // 録音中に U を yes → 登録される、countdown なし、starts 1 件のまま
@Test func answerNoAsksAgainNextConnection()       // .no → entries 空、.removed(U) → .added(U) で deviceSeenFirstTime が 2 回目
@Test func answerNeverIgnoresSilently()            // .never → match == .ignored、次の .added(U) で posted が増えない
@Test func launchPresentPostsAlreadyConnected()    // 登録済み A の .present(A, .launch) → posted == [.deviceAlreadyConnected(A.deviceRef)]、starts 空、timer.pendingCount 0
@Test func unregisteredPresentPostsNothing()       // 内蔵マイクの .present(_, .launch) → posted 空
@Test func wakePresentPostsAlreadyConnected()      // .present(A, .wake) → 同上
@Test func startNowRecordsAutoWithoutCountdown()   // handle(.startNow(A.deviceRef)) → starts[0] == (A.deviceRef, ja, false)。.removed(A) で state grace
@Test func startNowForDisconnectedDeviceDoesNothing() // 接続中でない ref → starts 空
@Test func cancelCountdownActionCancels()          // カウントダウン中に handle(.cancelCountdown) → idle
@Test func unrelatedActionsAreIgnored()            // handle(.openMeeting(id)) → 状態・posted・starts とも変化なし
@Test func alreadyConnectedWithdrawnOnRemoval()    // .present(A, .launch) → .removed(A) → withdrawn に "device.connected.<A の uid>"
@Test func alreadyConnectedWithdrawnWhenRecordingStarts() // .present(A) → manualStart → withdrawn に同じ id
@Test func otherMacDeviceAsksReRegistration()      // 別 Mac で登録した BT と名前だけ一致 → deviceSeenFirstTime、yes で今の Mac の項目が増える
```

- [ ] **Step 2: 失敗を確認する**
Run: `swift test --filter AutoRecordRegistrationTests` → Expected: FAIL
- [ ] **Step 3: Coordinator に登録・接続中通知・`handle(_ action:)` を足す**
- [ ] **Step 4: Task 8 と合わせて通過を確認する**
Run: `swift test --filter "AutoRecordCoordinatorTests|AutoRecordRegistrationTests"` → Expected: PASS
- [ ] **Step 5: コミット**
```bash
git add Sources/AutoNoteCore/Devices/AutoRecordCoordinator.swift Tests/AutoNoteCoreTests/Devices/AutoRecordRegistrationTests.swift
git commit -m "feat(devices): ask to register new devices and handle notice actions"
```

---

### Task 10: `autonote dev auto-record` と 👤 実機確認（後回し可）

Step 1〜3（ハーネスの実装とコミット）は今やる。Step 4〜7 の 👤（Shokz・3.5mm・USB はあれば）は利用者の都合で後回しにしてよく、Task 11 はそれを待たない。

**Files:**
- Create: `Sources/autonote/DevAutoRecord.swift`
- Modify: `Sources/autonote/DevCommands.swift`（`DevCommands.run` の振り分けに `auto-record` を足す）
- Modify（👤 の結果）: `docs/superpowers/research/2026-10-24-spike-results.md` 項目 10（と USB があれば項目 4）

**Interfaces:**
- Consumes: Task 2〜9 の本番実装（`CoreAudioHardware`、`WorkspaceSleepWakeObserver`、`TaskTimerScheduler`、`DeviceMonitor`、`DeviceRegistry` + `PortableDevicesStorage`、`SystemMacIdentityProvider`、`AutoRecordCoordinator`）、計画 02 の `RecordingSession.live(paths:settings:clock:)`（`clock` は 02 の既定）と `RecordingSessionControl`（Task 7）
- Produces: `autonote dev auto-record --vault <dir> --data <dir> [--countdown N] [--grace N] [--lang ja|en|auto]`。標準出力に 1 行 1 JSON（`{"kind":"status",…}`、`{"kind":"notice","id":…,"body":…,"actions":[…]}`（`UserNotice.id` と `DeviceNoticeCopy`）、`{"kind":"withdraw","id":…}`、`{"kind":"device","event":"present|added|removed",…}`。device 行のキーは Task 11 の `dev devices` と同じ）。標準入力の 1 行コマンド `yes|no|never <uid>`（→ `handle(.registerDevice(ref, answer:))`）、`start <uid>`（→ `handle(.startNow(ref))`）、`cancel`、`manual`、`pause`、`resume`、`bookmark [メモ]`、`lang ja|en|auto`、`stop`、`quit`（`quit` は録音中なら停止してから終わる）。`status` 行は `RecorderSnapshot` を snake_case にしたもの。通知は `UserNotifier` の実装 `ConsoleUserNotifier`（このファイル内）が JSON を出す

- [ ] **Step 1: `DevAutoRecord.swift` を実装する**

実行ターゲットはテストから import できないので、このタスクの自動確認は Step 2 の起動確認と Task 11 の E2E に任せる（Global Constraints の「ハードウェアが要る部分だけ手動確認」）。既定は `--countdown 5 --grace 30 --lang ja`。`--vault` を `PortableConfigStore` の出力フォルダ、`--data` を `AppPaths(root:)` にする（利用者の Vault とアプリ領域を汚さない）。録音器は `RecordingSessionControl(session: RecordingSession.live(paths:settings:clock:))`、`Settings` は既定値に引数の 3 項目を上書きしたもの。

- [ ] **Step 2: 起動と終了を確かめる**
Run: `swift build && mkdir -p /tmp/an-dev/vault /tmp/an-dev/data && printf 'quit\n' | .build/debug/autonote dev auto-record --vault /tmp/an-dev/vault --data /tmp/an-dev/data` → Expected: 1 行目が `{"kind":"status","state":"idle",…}`、接続中の候補ごとに `{"kind":"device","event":"present",…}`、exit 0
- [ ] **Step 3: ハーネスをコミット**
```bash
git add Sources/autonote/DevAutoRecord.swift Sources/autonote/DevCommands.swift
git commit -m "feat(cli): add dev auto-record harness"
```

- [ ] **Step 4: 👤 利用者 — Shokz で一周する（後回し可）**

TCC の責任プロセスは起動元の端末になる（ここで見るのは機材の挙動なので構わない。端末にマイクとシステム音声録音の許可が要る）。実装者は次を起動し、利用者に操作を依頼する: `.build/debug/autonote dev auto-record --vault /tmp/an-dev/vault --data /tmp/an-dev/data | tee /tmp/an-dev/shokz.log`。ブラウザで音の出る動画を流しておく。

1. Shokz の電源を入れる → `notice` の `device.first.…` が出る → `yes <uid>` → `device.countdown` の通知 → 5 秒後に `state":"recording"`
2. 10 秒話す → Shokz の電源を切る → `state":"grace"`、banner と `device.grace` の通知「機材が外れました。30 秒後に停止」
3. 10 秒以内に電源を入れ直す → `state":"recording"`。再接続までの秒数と、attach の試行回数（ログ）を記録する
4. 10 秒話す → 電源を切る → 30 秒待つ → `state":"idle"`
5. `--data` の WAV を聞く: マイクトラックに切断前と復帰後の声が続き、猶予中は無音、システム音トラックは途切れない
6. 電源を入れて `notice` の `device.countdown` → `cancel` → `idle` のまま 10 秒（取り消し）
7. Shokz をつないだまま `quit` して起動し直す → `device.connected.…` の通知だけが出てカウントダウンしない → `start <uid>` で録音 → `stop`
8. （任意）Shokz をつないだまま Mac を 1 分スリープ → 復帰 → カウントダウンが出ず、約 10 秒後に `device.connected.…` が出る

Expected: 1〜7 がすべて期待どおり（8 は任意）。`resume failed` 相当のログ（attach 失敗）や `micFallback` の banner が出たら回数と状況を記録する

- [ ] **Step 5: 👤 利用者 — 3.5mm で一周する（後回し可）**

Step 4 の 1〜5 を 3.5mm イヤホン（マイク付き）の抜き差しで行う。`device.first.…` の uid が `BuiltInHeadphoneInputDevice` であること、マイクの無いイヤホンでも `外部マイク` が現れるかも見る（あれば。付録 A の未確認点）。

- [ ] **Step 6: 👤 利用者 — USB（機材があれば。後回し可）**

`dev auto-record` を起動したまま USB 機材を差し、`{"kind":"device","event":"added",…}` の行を記録する（シリアルは伏せ字にする）。`uid_kind` が実物と合うか（シリアルの有無）、別のポートに差して `device_uid` が変わるか、変わったときに ［はい］で登録した項目の型番一致（`start_on_model_match`）でカウントダウンが始まるかを見る。

- [ ] **Step 7: 結果を記録してコミット（👤 を済ませたとき）**

結果表の項目 10 の「結論」「測定値」を Step 4・5 で埋める（MAC は下 3 オクテットを `xx-xx-xx` に伏せる）。USB を測ったら項目 4 の USB 行を足す。組み直しが安定しない（20 回で戻らない、声が欠ける）場合は、Task 7 の値と §11.5 の方式を見直す必要があるので Lead に報告して止める。
```bash
git add docs/superpowers/research/2026-10-24-spike-results.md
git commit -m "docs: record auto-record hardware results (spike item 10)"
```

---

### Task 11: `autonote dev devices` と E2E 更新、全 PASS、コミット

**Files:**
- Create: `Sources/autonote/DevDevices.swift`
- Modify: `Sources/autonote/DevCommands.swift`（振り分けに `devices` を足す）
- Modify: `scripts/e2e-check.sh`（確認項目 2 件と `CHECKS` 配列）

**Interfaces:**
- Consumes: `CoreAudioHardware`, `DeviceIdentity`, `DeviceMonitor`（Task 1〜3）
- Produces: `autonote dev devices [--watch]`。既定は接続中の入力デバイス（候補でないものも含む）を 1 行 1 JSON（キー: `name`, `device_uid`, `model_uid`, `transport`, `input_channels`, `uid_kind`, `candidate`）で出して exit 0。`--watch` は同じ行に `"event":"present"` を付けて出した後、`added` / `removed`（`"at"` 付き ISO 8601）を流し続け、SIGINT で exit 0

- [ ] **Step 1: E2E の項目を先に足す（失敗する確認）**

`check_dev_devices`: `CURRENT="03.1 dev devices が接続中の入力を 1 行以上の JSON で出す"`。CLI は共通補助の `AUTONOTE_CLI`（overview §7）。実行できなければ SKIP。`run_timeout 10 "${AUTONOTE_CLI}" dev devices` が exit 0、1 行以上、全行が JSON として読めて `device_uid` を持つこと（`python3 -I` で確認。項目 14 と同じ書き方）。入力デバイスが 1 台も無い Mac（`system_profiler SPAudioDataType` に `Input Channels` が無い）では SKIP。
`check_dev_devices_watch`: `CURRENT="03.2 dev devices --watch が present を流し SIGINT で exit 0"`。CLI は同じく `AUTONOTE_CLI`。項目 14（`check_device_probe`）と同じ手順で起動 → `"event":"present"` を最大 5 秒待つ → SIGINT → 3 秒以内に exit 0。
両方を `CHECKS` の末尾に足す。

Run: `swift build && scripts/e2e-check.sh --quick` → Expected: 03.1・03.2 が FAIL（`dev devices` が未実装で `DevCommands` が usage を出して 2）
- [ ] **Step 2: `DevDevices.swift` を実装する**

既定は `CoreAudioHardware().snapshot()` を `DeviceIdentity(raw:)` で変換して出すだけ。`--watch` は `DeviceMonitor` の `events()` を回す（`present` には候補だけが出るが、一覧表示は候補外も出す違いがある。`--watch` は事象の確認用なので `DeviceMonitor` のとおりでよい）。JSON は `JSONEncoder`（snake_case、`sortedKeys`、`withoutEscapingSlashes`）。

- [ ] **Step 3: 単体で確かめる**
Run: `swift build && .build/debug/autonote dev devices` → Expected: 内蔵マイクの行（`"device_uid":"BuiltInMicrophoneDevice"`、`"transport":"builtin"`、`"candidate":true`、`"uid_kind":"fixed"`）を含み exit 0
- [ ] **Step 4: 全体を通す**
Run: `swift test && scripts/build-app.sh && scripts/e2e-check.sh` → Expected: `swift test` が全 PASS。E2E は FAIL 0（機材・GUI に依存する項目の SKIP は可）。03.1・03.2 が PASS
- [ ] **Step 5: コミット**
```bash
git add Sources/autonote/DevDevices.swift Sources/autonote/DevCommands.swift scripts/e2e-check.sh
git commit -m "feat(cli): add dev devices command and e2e checks"
```

---

## Self-Review の記録

- 対応: §4.1-2・§11.4 → Task 5・6・8、§4.4・§5.1 → Task 5・8、§5.9 表 → Task 5（112 セル）、補足 1〜3 → Task 5、補足 4・5 → Task 8（判断は計画 02）、§9.5 → Task 4・9、§11.1 → Task 2・3・9、§11.2 → Task 1・4、§11.3 → Task 9、§11.5 → Task 5・6・7・8・10、付録 A → Task 1・2。設定画面の機材タブ・終了確認・注意書き・通知の表示は計画 06（`DeviceRegistry`、`DeviceMonitor.connected()`、`needsQuitConfirmation`、`DeviceNoticeCopy`、`RecorderSnapshot` を使う）
- 共通契約との一致: `UserNotice`（14 case）・`UserNoticeAction`（11 case）・`RegisterAnswer`・`UserNotifier.post / withdraw` は overview §3 の字面どおり。`DeviceRef.transport` は小文字、aggregate の接頭辞は `com.yutaokoshi.autonote.tap.`、grace の丸めは 5〜300、`events()` は関数、組み立ては `RecordingSession.live(paths:settings:clock:)`、E2E は 03.1・03.2 と `AUTONOTE_CLI`
- 型の名前（`deviceUID`、`RegistryMatch.registered(entryID:rule:)`、`deviceConnected(_:autoStartEntryID:)`、`RecordingControl` の 9 メンバー、`schedule(after:_:)`、Coordinator の `current / snapshots / manualStart / stop / pause / resume / bookmark / setLanguage / cancelCountdown / handle`）は全タスクで同じ。Review Focus の 5 件は Task 1・2・4・5・9 にテストがある
