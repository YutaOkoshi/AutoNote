# AutoNote

会議を録音し、端末内で文字起こしして `claude -p` で議事録にする macOS のメニューバーアプリ（Swift 6.2、macOS 26 以降）。
設計は `docs/superpowers/specs/`（全体は `2026-10-24-autonote-design.md`）、開発の手順と約束事は `docs/development.md`、利用者向けは `docs/guide/`。

## コマンド

- テスト: `swift test`（時間依存のテストが負荷で落ちたら `swift test --no-parallel` で 1 回だけ再実行）
- .app のビルド: `scripts/build-app.sh [debug|release]` → `build/AutoNote.app`（初回は `scripts/build-whisper-xcframework.sh` を自動で呼ぶ）
- 動作確認: `scripts/e2e-check.sh`（`--quick` で時間のかかる項目を飛ばす）。タスクを完了とする前に必ず回す
- Xcode の無い arm64 Mac では SDKROOT とプラグインのパスの回避策が要る（メモリ `reference-arm64-mac-build-env`）

## 完了の定義と確認なしで進めてよい範囲

ユーザーが「実装して」と言ったら、次の 1〜8 までが 1 つの作業で、全部を確認なしで進めてよい。途中で「マージしますか」「入れ替えますか」と聞かない（ユーザーが「まだ実装しないで」「マージしないで」と言ったときはそれに従う）。

1. 実装（TDD）→ `swift test` → `scripts/e2e-check.sh`
2. 利用者に見える変更なら、同じ PR で版を上げる（機能は minor、修正だけなら patch）。3 か所をそろえる: `Resources/Info.plist` の `CFBundleShortVersionString` と `CFBundleVersion`（+1）、`Sources/AutoNoteCore/AutoNoteVersion.swift`。docs・eval だけの変更は版を上げない
3. ブランチを push して PR を作る（コミットは英語の Conventional Commits）
4. 文脈なしレビュー（グローバル CLAUDE.md の既定）の指摘を直し、CI（`.github/workflows/ci.yml`）が緑になったら `gh pr merge <番号> --merge`
5. main に入ると `release.yml` がタグ `v<版>` と GitHub Release（`AutoNote-<版>-macos-universal.zip`、「AutoNote Dev」で署名）を作る。`gh run watch <id> --exit-status --interval 30` で待ち、時間切れのテストで落ちたら `gh run rerun <id> --failed`
6. /Applications を入れ替える（v0.7.0 で行った手順）:
   - `gh release download v<版> --dir <scratchpad>/dl` → `ditto -x -k <zip> <scratchpad>/x` → `codesign --verify --deep --strict` と、`codesign -d -r-` の designated requirement が今の /Applications の版と同じことを確かめる
   - `/Applications/AutoNote.app/Contents/MacOS/autonote status --json` で `status.queue` が空、`status.recorder.state` が `idle` になるまで待つ（録音中・後処理中は終了させない。待つのであって、聞くのではない）
   - `osascript -e 'tell application id "com.yutaokoshi.autonote" to quit'` → プロセスが消えたのを `pgrep -f AutoNote.app/Contents/MacOS/AutoNoteApp` で確かめる
   - `mv /Applications/AutoNote.app ~/Backups/AutoNote/AutoNote-<旧版>-before-<新版>.app` → `ditto <scratchpad>/x/AutoNote.app /Applications/AutoNote.app` → `xattr -dr com.apple.quarantine /Applications/AutoNote.app`
   - `codesign --verify --deep --strict` → `open -g /Applications/AutoNote.app` → `autonote --version` と `status --json` で新しい版が動いていることを確かめる
7. 古い版を片付ける: `~/Backups/AutoNote/` には直前の版を 1 つだけ残し、それより古いものは `~/.Trash/` へ移す（`rm` しない）。マージ済みのローカルブランチは `git branch -d`、自分が作った worktree と scratchpad の取得物も片付ける
8. 報告: 版・PR と Release の URL・入れ替えの確認結果に、グローバル CLAUDE.md の区切りの報告の 4 項目を添える

Release が作られない（CI が直せない形で落ちる）ときだけ、`scripts/build-app.sh release` の手元ビルドで 6 を行い、その旨を報告する。
アプリには自動アップデート（24 時間ごと）もあるが、完了の定義では待たずに 6 で入れ替える。

## 止まるところ（実行せず、理由と選択肢を添えて聞く）

- ユーザーのデータの削除・上書き: データ領域 `~/Library/Application Support/AutoNote`（録音・文字起こし・`settings.json`）と保存先 `~/Documents/AutoNote`（議事録）。試すときは `AUTONOTE_DATA_DIR` で別の場所を使う
- 署名の証明書「AutoNote Dev」の作り直し・削除（`scripts/make-dev-cert.sh` で作り直すと、マイク・システム音声の許可を取り直すことになる。2026-11-14 に発生。v0.7.0 以降は自動アップデートが信頼する唯一の鍵でもある）
- login キーチェーンやその検索リストの変更、`scripts/signing.sh export-to-1password` / `import-login`、1Password の鍵の項目・GitHub Environment `release` の Secrets の変更
- `tccutil reset` など macOS の許可を消す操作（2026-11-16、許可の入れ直しを利用者に頼むことになった）
- 公開済みのタグ・Release の削除や作り直し（利用者の Mac の自動アップデートが参照している）、force push
- 利用者の録音・議事録をリポジトリや外部に出すこと（eval に使ってよいが共有はできない、と言われている）

## 毎回の作業に効く規則

- 区切りごとに小さくコミットする。途中経過の push は要らず、PR を作るときに push する
- GUI や許可まわりの確認も osascript・`sqlite3 -readonly` の TCC.db・計測で自動化する。利用者に頼むのは初回の許可ダイアログと、別の機材が要るときだけ
- `op`（1Password CLI）は承認のダイアログが出るので、呼ぶ回数を最小にし、呼ぶ直前に知らせる。サインインの確認は `op whoami` ではなく `op vault list`
- 音声はローカルから出さない。外部に渡すのは `claude -p` への文字起こしテキストだけ
