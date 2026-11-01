# 2026-10-30 12:00 の録音停止の調査（2026-11-01）

2026-10-30 12:00:00 に、利用者が何も押していないのに録音が止まり、1.6 秒後に新しい録音が始まった。開始・停止の理由が unified log に残っていなかったため、原因は分かっていない。開始・停止の理由をログに残す版（Spec F4 §5）を作り、その版で §5.2 の候補 1〜3 を確かめた。

## 結論

| 候補 | 結果 | 根拠 |
|---|---|---|
| 1(a) 録音中に `final_model` を変える | 再現しなかった | 保存のあとも録音が続いた。キューの作り直し・ホットキーの登録し直しは走ったが、状態遷移は起きなかった（下のログ A） |
| 1(b) 録音中に `live_summary_enabled` を false → true にする | 再現しなかった | 同上（ログ B）。10/30 と同じ「約 9 秒おきの 2 回の保存」でも止まらなかった（ログ C） |
| 2 ショートカットの誤作動 | 経路はある（試せなかった） | ⌃⌥R は Carbon の `RegisterEventHotKey` で全アプリ共通に受け取るので、他のアプリやキー割り当てツールが同じ組み合わせを送れば録音はトグルする。2 回届けば「停止 → 開始」になる。実験時は画面がロック中で、キー入力を送れなかった |
| 3 ヘッドセットのボタン・Bluetooth のプロファイル切り替え | ボタン: 経路なし。プロファイル切り替え: すぐ止める経路はない | 下の「候補 2・3 のコード読み」 |

再現したものはないので、コードは直していない（推測では直さない）。ログを入れた版を使い続け、次に起きたら `log show` で原因を特定する（読み方は `docs/development.md` の「録音の開始・停止の理由をログで読む」）。

## 実験の方法

- ビルド: `feature/f4-recording-logs` の WIP（`3068648`）に、実験用の一時フック（下記）を足した debug ビルド。フックはコミットしていない
- データ領域: `AUTONOTE_DATA_DIR=/tmp/an-f4`。`live_engine: dictation`（Apple）、`final_engine: whisper`、`final_model: base`、`live_summary_enabled: false`、`launch_at_login: true`。録音は CLI（`autonote start/stop`）で行い、既定の入力で 30〜55 秒録った（1 分未満なので後処理は走らない）。利用者の実機アプリ（別プロセス）は止めていない
- 設定画面の操作の代わり: 実験したとき Mac は画面ロック中で（`ioreg` の `CGSSessionScreenIsLocked=Yes`）、osascript でも computer-use でも設定ウィンドウを操作できなかった。そこで一時フックを使った。環境変数 `AUTONOTE_EXPERIMENT_SETTINGS=1` のときだけ、SIGUSR1 で `<データ領域>/experiment-step` を読み、タブの「保存」と同じ処理を呼ぶ。具体的には `SettingsSaving.save(env) { … }` で、変えるのは 1 項目だけ、ほかの項目はそのタブが保存するもの全部を今の値のまま書く。そこから先は設定画面の保存と同じ経路（`settings.change` → `AppEnvironment.settingsSaved` → `AppWiring.settingsChanged`、ホットキーの登録し直し、ログイン項目の調整）を通る。文字起こしタブについては、タブを開いたときの読み込み（`models.installed()`、`catalog.entries`）も先に呼んだ
- 観察: `log show --predicate 'subsystem == "com.yutaokoshi.autonote" AND processID == <実験アプリ>'`（`notice` 以上が残ることの確認も兼ねる）

### この方法で確かめていないこと

- 設定ウィンドウの表示・タブの切り替え・コントロールの操作そのもの（SwiftUI の画面の動き）
- ログイン項目の登録（`SMAppService.mainApp.register()`）。`AUTONOTE_DATA_DIR` を設定した起動では、ルール X22 によりログイン項目を触らない（ログは `login item leftAlone`）。10/30 の 11:59:40 と 11:59:49 にあった `smd` への接続はこれにあたる。実機アプリが `/Applications` 以外から動いていると状態が `notFound` になり、保存のたびに `register()` が呼ばれうる（`LoginItem.needsReconciling`）。ただし登録はプロセスの中の録音を止めない。10/30 の停止と開始は同じ PID の中で起きている（調査メモの `HALC_ProxyIOContext ... ending the transport` → `AVAudioEngine stop`）ので、この経路が原因とは考えにくい

## ログ（抜粋、実験アプリ PID 48398）

A. 1(a) `final_model` を base → small に変更:

```
16:10:01.215 [devices] idle -> recording on manualStart (origin: cli)
16:10:01.829 [RecordingSession] 20261101-1610-3867: recording started (mic: default input, -; failed tracks: none)
16:10:02.260 [LiveTranscriptionWiring] 20261101-1610-3867: live transcript started (on recording started)
16:10:11.889 [AppDelegate] EXPERIMENT settings save: final_model
16:10:11.893 [AppWiring] settings saved: changed [final_model]; queue rebuild: yes
16:10:11.895 [AppEnvironment] queue inputs changed: output folder synced, stages re-registered, device list reloaded
16:10:11.898 [HotKeyCenter] hotkey toggleRecording registered as ctrl+option+r
16:10:11.898 [AppEnvironment] settings save applied: hot keys re-registered (3), login item leftAlone
16:10:32.092 [SocketServer] ipc stop from pid 50658
16:10:32.092 [devices] recording -> idle on manualStop (origin: cli, stop: manual, meeting: 20261101-1610-3867)
16:10:32.154 [RecordingSession] 20261101-1610-3867: recording stopped (reason: manual, 30.9 s, status: too_short, saved: yes)
```

保存（16:10:11）から CLI で止める（16:10:32）までの 20 秒間、状態遷移はない。

B. 1(b) `live_summary_enabled` を false → true:

```
16:10:57.672 [devices] idle -> recording on manualStart (origin: cli)
16:11:08.489 [AppWiring] settings saved: changed [live_summary_enabled]; queue rebuild: no
16:11:08.498 [AppEnvironment] settings save applied: hot keys re-registered (3), login item leftAlone
16:11:28.665 [devices] recording -> idle on manualStop (origin: cli, stop: manual, meeting: 20261101-1610-412f)
```

C. 10/30 と同じ並び（録音開始 → 16 秒後に `final_model` → 9 秒後に `live_summary_enabled` false → true → 30 秒待つ）:

```
16:11:55.978 [devices] idle -> recording on manualStart (origin: cli)
16:12:11.975 [AppWiring] settings saved: changed [final_model]; queue rebuild: yes
16:12:20.990 [AppWiring] settings saved: changed [live_summary_enabled]; queue rebuild: no
16:12:51.127 [devices] recording -> idle on manualStop (origin: cli, stop: manual, meeting: 20261101-1611-8773)
```

## 候補 2・3 のコード読み

- 録音を止める経路は次の 3 種類しかない（`Tests/AutoNoteCoreTests/Devices/RecordingControlOriginTests.swift` の冒頭に全経路の表）
  - 人の操作: ショートカット・メニュー・ウィンドウ・通知・CLI
  - 機材: 起点機材が外れてから grace（既定 30 秒）が満了する
  - 録音器自身: ディスク不足など
- 設定の保存から録音の停止につながる呼び出しはない
- ショートカット: `HotKeyCenter` は Carbon の `RegisterEventHotKey` で ⌃⌥R などを登録し、`kEventHotKeyPressed` を受けると `AppModel.toggleRecording` を呼ぶ。この仕組みはどのアプリが前面でも動き、受けたイベントが本物のキー入力か、合成されたものかを区別しない
  - 別の経路: メニューバーのメニュー項目「録音開始」「停止」「一時停止」にも同じキーが割り当てられている（`MenuBarContent.swift`、`.keyboardShortcut`）。メニューを開いているあいだは、こちらでも反応しうる
  - 10/30 の調査メモには「ショートカットは押されてもログが残らない」とある。しかし `hotkey pressed: …` は 2026-10-27 のコミット `56af969` から `notice` で出ている。10/30 のビルドにこの行が入っていて、かつ当時の unified log に subsystem の行が残っていたのなら、ショートカット経由ではなかったことになる
  - 確かめられなかった理由: 11/01 の時点で 10/30 のログはかなり消えており、調査メモが引用した PID 94028 の行も、`com.yutaokoshi.autonote` の行も取り出せなかった
  - 今の版で見分けられること: ショートカットなら `hotkey pressed: toggleRecording` と `origin: hotkey` が並ぶ。メニューのキー割り当てなら `origin: menu` が出て、`hotkey pressed` は出ない
- ヘッドセットのボタン: `MPRemoteCommandCenter`（MediaPlayer）、メディアキー（`NX_KEYTYPE_*`、`NSEvent` の systemDefined）、`IOHID`、`CGEventTap`、グローバルなイベントモニタは、どれもアプリのコードに無い（`grep` で確認）。アプリがヘッドセットのボタンを受け取る経路はない
- Bluetooth のプロファイル切り替え: アプリが見ているのは Core Audio の機材一覧の変化（`CoreAudioHardware` が system object の機材一覧に listener を付けている）だけである
  - 入力が消えると `DeviceMonitor` が removed として流す。起点機材なら grace に入るだけで、すぐには止めない。起点以外なら何もしない
  - `AVAudioEngine` の構成変更（`AVAudioEngineConfigurationChange`）は購読していない。マイクが黙っても録音は続く（止まらない）
  - 1.6 秒で止まって始まる動きは、この経路では起きない
  - 今の版では、機材の追加・削除が UID つきで出る（`DeviceMonitor` と `devices`。起点機材かどうかも出る）

## 次に起きたとき

`log show --start '<日時>' --predicate 'subsystem == "com.yutaokoshi.autonote"'` で、停止の行の `origin` を見る。

| `origin` | 原因 |
|---|---|
| `hotkey` | ショートカット（直前に `hotkey pressed` も出る） |
| `menu` / `window` | 画面の操作 |
| `cli` | 直前の `ipc stop from pid N` の PID が送り主 |
| `graceExpired` / `diskFull` / `sessionEnded` | 機材・ディスク・録音器 |
| どの行も無い | 今回押さえていない経路がある（その場合は `RecordingSession` の `recording stopping` の行から辿る） |
