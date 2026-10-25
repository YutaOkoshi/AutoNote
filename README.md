# AutoNote

macOS（26.0 以降）のメニューバーで会議を録音し、文字起こしと議事録を作るアプリ。

- 要件書: [docs/superpowers/specs/2026-10-24-autonote-design.md](docs/superpowers/specs/2026-10-24-autonote-design.md)
- 計画 00: [docs/superpowers/plans/2026-10-24-autonote-00-spikes-and-skeleton.md](docs/superpowers/plans/2026-10-24-autonote-00-spikes-and-skeleton.md)

テスト: `swift test`
アプリ（.app）のビルド: `scripts/build-app.sh`
動作確認（E2E）: `scripts/e2e-check.sh`（速い確認だけなら `--quick`）

初回の注意:
- 初回の `scripts/build-app.sh` は自己署名のコード署名証明書 `AutoNote Dev` を作ってログインキーチェーンに入れるので、管理者認証のダイアログが出る
- `Spikes/`（計画 00 の使い捨てスパイク。`swift build --package-path Spikes`）と whisper.cpp のスクリプト（`scripts/setup-whisper.sh`、`scripts/make-sample-audio.sh`、`scripts/bench-whisper.sh`。取得物は `tools/` に置き、コミットしない）がある
- `scripts/e2e-check.sh --quick` はビルドし直さず、前回ビルドした `build/AutoNote.app` をそのまま確かめる
