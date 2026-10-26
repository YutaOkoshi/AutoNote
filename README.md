# AutoNote

macOS（26.0 以降）のメニューバーで会議を録音し、文字起こしと議事録を作るアプリ。

- 要件書: [docs/superpowers/specs/2026-10-24-autonote-design.md](docs/superpowers/specs/2026-10-24-autonote-design.md)
- 計画 00: [docs/superpowers/plans/2026-10-24-autonote-00-spikes-and-skeleton.md](docs/superpowers/plans/2026-10-24-autonote-00-spikes-and-skeleton.md)

テスト: `swift test`
アプリ（.app）のビルド: `scripts/build-app.sh`
動作確認（E2E）: `scripts/e2e-check.sh`（速い確認だけなら `--quick`）

初回の注意:
- whisper.cpp の XCFramework（`tools/whisper.xcframework`）はリポジトリに含めず、手元でソースからビルドする。初回は `scripts/build-whisper-xcframework.sh` を実行する（数分かかる。`tools/whisper.cpp` が無ければ v1.9.5 を clone する。既存の `tools/whisper.cpp` が commit `d1be6fd`（= v1.9.5）でなければエラーで止まる）。公式の zip は x86_64 スライスが AVX2 なしで Intel では約 7 倍遅いため使わない。`scripts/build-app.sh` と `scripts/e2e-check.sh` は成果物が無ければこのスクリプトを先に呼ぶ。`tools/` は git の管理外
- 初回の `scripts/build-app.sh` は自己署名のコード署名証明書 `AutoNote Dev` を作ってログインキーチェーンに入れるので、管理者認証のダイアログが出る
- whisper.cpp のベンチ用スクリプト（`scripts/setup-whisper.sh`、`scripts/make-sample-audio.sh`、`scripts/bench-whisper.sh`。取得物は `tools/` に置き、コミットしない）と、XCFramework を手元でビルドする `scripts/build-whisper-xcframework.sh` がある。文字起こしの開発用コマンドは `autonote dev engines` / `autonote dev transcribe`（計画 00 のスパイク `Spikes/` は計画 04 で削除した）
- `scripts/e2e-check.sh --quick` はビルドし直さず、前回ビルドした `build/AutoNote.app` をそのまま確かめる
