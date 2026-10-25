# 計画 00 スパイク結果

[計画 00](../plans/2026-10-24-autonote-00-spikes-and-skeleton.md) で実機確認した結果を、[要件書 §19](../specs/2026-10-24-autonote-design.md#19-実装前に実機で確かめること) の 12 項目ごとにまとめる。

## 要件書に反映した変更

Task 9 で記入。

## 項目 1: Intel 機で `whisper-bench` を回し、base / small / medium / large-v3-turbo（量子化版を含む）の実時間比を測る

- 結論: 未実施（Task 5）
- 測定値:
- 手順:
- 要件書への影響:

## 項目 2: Intel 機で DictationTranscriber の日本語リアルタイム認識の遅延と精度を、whisper small と比べる

- 結論: 未実施（Task 6）
- 測定値:
- 手順:
- 要件書への影響:

## 項目 3: Intel 機で process tap から実際に音声データが届くこと（作成・破棄は確認済み）

- 結論: 届く（許可あり）。Intel x86_64 / macOS 26.6.2 で全システム音の tap から Float32 の PCM を受信し WAV に書けた。**「許可なし時の挙動」は本スパイクでは再現できなかった**。(a) Orca で許可をオフにして同じプロセス系統から実行 → 音が届いた（tccd は拒否を記録）。(b) 許可状態が未確認の Terminal.app から実行 → ダイアログなしで音が届いた。自己署名 `.app` 単体で、再起動後に再確認する（計画 02 の最初のタスク）。
- 測定値:
  - 受信フォーマット: 48000 Hz / 2ch / Float32 / interleaved / lpcm（`kAudioTapPropertyFormat`）。出力デバイスは内蔵スピーカー（UID `BuiltInSpeakerDevice`）。
  - 許可あり、`afplay Submarine.aiff` ループ中に 5 秒: callbacks=461、frames=236032（4.92 s）、rms=-31.72 dBFS。出力 WAV を読み直しても rms=-31.72 dBFS、peak=-8.90 dBFS、長さ 4.92 s。
  - 許可あり、音を何も鳴らさず 3 秒: callbacks=0、frames=0。6 秒中 3 秒目から鳴らすと frames=136192（2.84 s）。**音を出すプロセスが無い間は IOProc が呼ばれない**（ゼロのサンプルが届くのではない）。
  - 許可ダイアログ未応答の間: 作成〜開始〜停止の全 API が status 0、callbacks=0。`AudioDeviceDestroyIOProcID` が約 3 分ブロックしてから戻った（coreaudiod への mach_msg 待ち）。
  - 許可なし（利用者が Orca の「システムオーディオ録音のみ」をオフ。TCC.db の `com.stablyai.orca` は auth_value=0）:
    - 1 回目（Submarine ループ中 5 秒）: ERROR 行なし、全 API が status 0、callbacks=463、frames=237056（4.94 s）、rms=-31.74 dBFS、peak=-8.90 dBFS。所要 7 秒、ブロックなし。WAV にも許可ありと同じ音が入っていた。
    - 2 回目（6 秒中 3 秒目に Glass.aiff）: callbacks=273、frames=139776（2.91 s）、rms=-34.01 dBFS。所要 6 秒。
    - その時刻の tccd は `kTCCServiceAudioCapture` に `authValue=0`（拒否）を返し、coreaudiod は `HALS_IOContext.cpp:1491 Client is not granted access to the tap.` をエラーで出していた。それでも IOProc に音声が届いた。
    - つまりこの環境（未署名の CLI、責任プロセスが Orca.app）では拒否が受信を止めなかった。拒否が効かない理由は未特定（Orca を再起動していないことや、未署名バイナリであることが影響している可能性がある）。
  - Terminal.app から実行（利用者、Orca の許可をオンに戻した後）: 許可ダイアログは出ず、全 API が ok、callbacks=460、frames=235520（4.91 s）、rms=-31.71 dBFS。Terminal.app に以前から許可が付いていたかは未確認（TCC.db が読めなかった）。
  - 以上から、許可なし時の挙動（エラーになるか、無音になるか、届いてしまうか）は**未確定**。
- 手順（`Spikes/Sources/TapCapture/main.swift` 冒頭コメントに同じ内容）:
  1. `CATapDescription(stereoGlobalTapButExcludeProcesses: [])`、`isPrivate = true`、`muteBehavior = .unmuted`
  2. `AudioHardwareCreateProcessTap(desc, &tapID)`、tap の UID は `desc.uuid.uuidString`
  3. `kAudioTapPropertyFormat` を読む → `AVAudioFormat(streamDescription:)`
  4. 既定出力デバイス（`kAudioHardwarePropertyDefaultSystemOutputDevice`）の `kAudioDevicePropertyDeviceUID`
  5. `AudioHardwareCreateAggregateDevice`: Name / UID（新規 UUID）/ `IsPrivate`=true / `IsStacked`=false / `TapAutoStart`=true / `MainSubDevice`=出力 UID / `SubDeviceList`=[[`kAudioSubDeviceUIDKey`: 出力 UID]] / `TapList`=[[`kAudioSubTapUIDKey`: tap UID, `kAudioSubTapDriftCompensationKey`: true]]
  6. `AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, queue, block)` → `AudioDeviceStart`（初回はここで許可ダイアログ）
  7. 停止: `AudioDeviceStop` → `AudioDeviceDestroyIOProcID` → `AudioHardwareDestroyAggregateDevice` → `AudioHardwareDestroyProcessTap`
  - 実装上の注意: Swift 6 で IOProc ブロックを MainActor 文脈（main.swift のトップレベル）で書くと IO スレッドで SIGILL（実行時の隔離チェック）。nonisolated な関数で作る。`AVAudioFile` は `close()` しないと WAV が確定しない。
  - TCC の許可は起動元アプリ（ターミナル相当。今回は Orca.app = `com.stablyai.orca`）に対して求められる。
- 要件書への影響:
  - §5.7「システム音の無音検知 60 秒」は、サンプルの RMS ではなく「最後に IOProc が呼ばれてからの経過時間」でも判定する必要がある。相手が黙っている・会議アプリが音を出していないだけでも callbacks が止まる。
  - 許可なしは API エラーからも検知できない前提で設計する（status はすべて 0 だった）。「許可なし→無音になる」とも決めつけない。UI は「60 秒コールバックなし → 許可または音源を確認するよう案内」に留める。
  - 許可なし時の挙動は、計画 02 の最初のタスクで自己署名 `.app`（`AutoNote Dev`）単体、再起動後に再確認する。
  - 初回の許可ダイアログに応答していない間は、全 API が成功したまま何も届かず、停止時に `AudioDeviceDestroyIOProcID` が数分ブロックする。計画 02 では停止処理をメインスレッドで同期的に呼ばない。
  - 録音ファイルの時間軸: 無音区間はコールバック自体が来ないので、受信フレームをそのまま連結するとマイク側とずれる。計画 02 で AudioTimeStamp（`mHostTime`/`mSampleTime`）による穴埋めが要る。

## 項目 4: 利用者が実際に使う機材を一つずつつなぎ、`DeviceUID` `ModelUID` `TransportType` 名前を記録する。Bluetooth は切断・再接続で UID が変わらないか、3.5mm は入力ソースの値がどう変わるかを見る

- 結論: 未実施（Task 4）
- 測定値:
- 手順:
- 要件書への影響:

## 項目 5: `AVAudioEngine` のボイスプロセッシングを有効にしたまま process tap と同時に録音できるか、エコー除去が効くか

- 結論: 未実施（Task 4）
- 測定値:
- 手順:
- 要件書への影響:

## 項目 6: `claude -p --output-format json --json-schema` に 1 時間分の文字起こしを流し、`structured_output` が期待どおり返ること

- 結論: 未実施（Task 7）
- 測定値:
- 手順:
- 要件書への影響:

## 項目 7: Apple Silicon 機で SpeechTranscriber の日本語が使えること（`supportedLocales`）

- 結論: 未実施（Task 8）
- 測定値:
- 手順:
- 要件書への影響:

## 項目 8: whisper.cpp の公式 XCFramework に x86_64 スライスが含まれるか

- 結論: 含まれる。macOS スライスは `macos-arm64_x86_64` で `x86_64 arm64` の両方を持つので、計画 04 は XCFramework を使える。ただし最新リリースタグ `v1.9.5`（2026-10-06）には zip が添付されておらず、同じコミット（`d1be6fd`）から作られたビルド番号付きプレリリース `b5454` の `whisper-b5454-xcframework.zip` で確認した。
- 測定値:
  - `v1.9.5` のリリースの添付ファイルは 0 件（GitHub API `releases/tags/v1.9.5` の `assets` が空）。`whisper-v1.9.5-xcframework.zip` の URL は 404。`v1.9.4`・`v1.9.3` も添付なしで、`v` タグに zip がある最新は `v1.9.2`。zip は `bNNNN` 形式のプレリリース側に付いている（`v1.9.5` と `b5454` はどちらも `d1be6fde11ac6e0407606b4e42fe72d34add8037` を指す）。
  - `whisper-b5454-xcframework.zip`: 65,816,082 バイト、SHA-256 `e57f8c48933000acabc13bb913fbe82805d483a2deff692cc6738836bd92393b`。展開すると `build-apple/whisper.xcframework/` の下に `macos-arm64_x86_64`、`ios-arm64`、`ios-arm64_x86_64-simulator`、`tvos-arm64`、`tvos-arm64_x86_64-simulator`、`xros-arm64`、`xros-arm64_x86_64-simulator`。
  - `lipo -info macos-arm64_x86_64/whisper.framework/whisper` → `Architectures in the fat file: ... are: x86_64 arm64`。`Info.plist` の `SupportedArchitectures` も `arm64`, `x86_64`。
  - x86_64 スライスの `LC_BUILD_VERSION` は `minos 13.3`、`sdk 26.5`。リンク先は Foundation・Metal・Accelerate・CoreML・libc++。
- 手順: `curl -sSLf -o tools/xcframework-b5454/whisper-b5454-xcframework.zip https://github.com/ggml-org/whisper.cpp/releases/download/b5454/whisper-b5454-xcframework.zip` → `unzip -q -o ... -d tools/xcframework-b5454/extracted` → `lipo -info tools/xcframework-b5454/extracted/build-apple/whisper.xcframework/macos-*/whisper.framework/whisper`。リリースの添付有無は `curl -s https://api.github.com/repos/ggml-org/whisper.cpp/releases?per_page=15` で確認。
- 要件書への影響: 計画 04 は XCFramework（`bNNNN` プレリリースの zip。`v` タグ版には zip が無いことがある）を使う前提でよい。x86_64 スライスの速度がソースビルド（`tools/whisper.cpp/build`）と同等かは未測定で、項目 1 のベンチは手元のソースビルドで取る。

## 項目 9: 自己署名証明書で署名し直したビルドで、マイクとシステム音声の TCC 許可が保たれるか

- 結論: 自己署名（`AutoNote Dev`、Bundle ID 固定）で再ビルド後もマイク許可は保たれた。システム音声録音（`NSAudioCaptureUsageDescription`）の許可は未確認で、Task 3 で見る。
- 測定値: 1 回目の起動で `マイク許可の状態: notDetermined` → ダイアログで許可 → `マイク許可の要求結果: authorized`。`CFBundleVersion` を `1` → `2` にして `scripts/build-app.sh` で再ビルド・再起動すると、ダイアログは出ず `マイク許可の状態: authorized`。署名は `Identifier=com.yutaokoshi.autonote` / `Authority=AutoNote Dev` / `TeamIdentifier=not set`。designated requirement は `identifier "com.yutaokoshi.autonote" and certificate leaf = H"c7f68fcb3afa065151260b113948ac6485837825"` で、cdhash などビルドごとに変わる値を含まない。
- 手順: `scripts/make-dev-cert.sh` で自己署名のコード署名証明書 `AutoNote Dev` を作り、ログインキーチェーンに入れてコード署名用に信頼する → `scripts/build-app.sh` で `build/AutoNote.app` を組み立てて `codesign --force --sign "AutoNote Dev" --identifier com.yutaokoshi.autonote --timestamp=none` で署名 → `open build/AutoNote.app` でメニュー「マイク許可を確認」→ 許可 → 終了 → `Resources/Info.plist` の `CFBundleVersion` を `2` にして再ビルド → 再起動して「マイク許可を確認」。
- 要件書への影響: §3.4 を「確認済み」に変える（Task 9）。

## 項目 10: 録音中にマイク機材を抜き、戻したときに `AVAudioEngine` を組み直して同じ録音を続けられるか（第 11.5 節）

- 結論: 未実施（Task 4）
- 測定値:
- 手順:
- 要件書への影響:

## 項目 11: `claude -p` で会話履歴を残さない方法（オプションの有無）と、`--strict-mcp-config` で MCP が読み込まれないこと

- 結論: `--no-session-persistence` と `--strict-mcp-config` は claude 2.1.310 の `claude -p --help` に存在することを確認済み（前の実装者のレポート参照）。効果は Task 7 で確認。
- 測定値: `claude -p --help` に `--no-session-persistence  Disable session persistence - sessions ...` と `--strict-mcp-config  Only use MCP servers from --mcp-config, ...` の行がある（claude 2.1.310）。
- 手順: `claude -p --help | grep -E "no-session-persistence|strict-mcp-config"`
- 要件書への影響: オプションの存在のみ確認。要件書の変更要否は Task 7 で効果を確かめてから判断する。

## 項目 12: SpeechTranscriber に contextual strings 相当の機能があるか

- 結論: 未実施（Task 6 と 8）
- 測定値:
- 手順:
- 要件書への影響:
