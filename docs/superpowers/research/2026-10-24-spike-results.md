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

- 結論: 未実施（Task 3）
- 測定値:
- 手順:
- 要件書への影響:

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

- 結論: 未実施（Task 5）
- 測定値:
- 手順:
- 要件書への影響:

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
