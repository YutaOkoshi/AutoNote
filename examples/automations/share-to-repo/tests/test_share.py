import hashlib
import os
import shutil
import subprocess
import unittest

from helpers import (NO_TRANSCRIPT, NO_TRANSCRIPT_ID, SHARE, STANDARD, STANDARD_ID, TRANSCRIPT_ONLY,
                     TRANSCRIPT_ONLY_ID, SandboxTest, read, write)

MIN = "2026/2026-12-02_1000_サンプル商事 トライアル打合せ.md"
TR = "2026/文字起こし/2026-12-02_1000_サンプル商事 トライアル打合せ_文字起こし.md"
REC = "2026-12-02_1000_サンプル商事_トライアル打合せ.mp4"

SHARED_HEADER = ["autonote_id", "minutes_file", "transcript_file", "source_sha256", "source_path", "first_shared",
                 "kind", "customer", "recorded_by", "recording", "flags"]


def sha(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


class ShareTests(SandboxTest):
    def share_standard(self, *extra, now="2026-12-02T11:10:00+09:00"):
        return self.sb.share(self.sb.vault_file(STANDARD), "--kind", "customer", "--recording", REC, *extra, now=now)

    def test_first_share_writes_two_files_index_state_and_notice(self):
        before = sha(self.sb.vault_file(STANDARD))
        self.assertOk(self.share_standard())
        self.assertEqual(self.sb.remote_files(), sorted(["INDEX.md", "README.md", MIN, TR]))
        minutes = self.sb.remote_show(MIN)
        self.assertIn('customer: "サンプル商事"\n', minutes)  # taken from the recording name
        self.assertIn('recorded_by: "営業担当"\n', minutes)
        self.assertIn("source_recording_deleted: まだ\n", minutes)
        index = self.sb.remote_show("INDEX.md")
        self.assertIn("| 2026-12-02 | 10:00 | サンプル商事 | 顧客 | サンプル商事 トライアル打合せ |", index)
        self.assertIn("問い合わせ対応の試用を 12 月中旬から 2 週間行うことで合意した", index)
        self.assertIn("[議事録](<%s>)" % MIN, index)
        log = self.sb.git("log", "-1", "--format=%s", "main", cwd=self.sb.remote)
        self.assertEqual(log.strip(), "add: 2026-12-02 サンプル商事 トライアル打合せ")
        # state
        self.assertEqual(self.sb.state_file("shared.tsv").splitlines()[0].split("\t"), SHARED_HEADER)
        rows = self.sb.tsv("shared.tsv")
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["autonote_id"], STANDARD_ID)
        self.assertEqual(rows[0]["kind"], "customer")
        self.assertEqual(rows[0]["first_shared"], "2026-12-02")
        self.assertEqual(rows[0]["source_sha256"], before)
        self.assertEqual(rows[0]["source_path"], "2026/" + STANDARD)
        self.assertEqual(rows[0]["recording"], REC)
        # notice: title, date, deadline, no customer words
        msgs = self.sb.dry_messages()
        self.assertEqual(len(msgs), 1)
        self.assertIn("議事録が並びました: サンプル商事 トライアル打合せ（12/2 10:00・65 分）", msgs[0]["text"])
        self.assertIn("12/9 までに消してください", msgs[0]["text"])
        self.assertNotIn("三百件", msgs[0]["text"])
        self.assertNotIn("合意", msgs[0]["text"])
        # log, and the vault file is only read
        self.assertIn("share-2026-12.log", os.listdir(self.sb.logs))
        log_text = read(os.path.join(self.sb.logs, "share-2026-12.log"))
        self.assertIn(STANDARD_ID, log_text)
        self.assertNotIn("三百件", log_text)
        self.assertEqual(sha(self.sb.vault_file(STANDARD)), before)

    def test_link_uses_repo_web_url(self):
        self.sb.set_config(REPO_WEB_URL="https://example.invalid/owner/meetings")
        self.assertOk(self.share_standard())
        text = self.sb.dry_messages()[0]["text"]
        self.assertIn("https://example.invalid/owner/meetings/blob/main/2026/", text)
        self.assertIn("%E3%82%B5", text)  # the path is percent-encoded

    def test_transcript_only_and_no_transcript(self):
        self.assertOk(self.sb.share(self.sb.vault_file(TRANSCRIPT_ONLY)))
        self.assertIn("文字起こしだけ並びました", self.sb.dry_messages()[-1]["text"])
        self.assertOk(self.sb.share(self.sb.vault_file(NO_TRANSCRIPT)))
        files = self.sb.remote_files()
        self.assertIn("2026/2026-12-04_0930_社内定例.md", files)
        self.assertFalse(any("社内定例_文字起こし" in f for f in files))
        self.assertIn("transcript_file: なし", self.sb.remote_show("2026/2026-12-04_0930_社内定例.md"))
        rows = {r["autonote_id"]: r for r in self.sb.tsv("shared.tsv")}
        self.assertEqual(rows[NO_TRANSCRIPT_ID]["transcript_file"], "")
        self.assertEqual(rows[TRANSCRIPT_ONLY_ID]["kind"], "internal")
        self.assertEqual(rows[TRANSCRIPT_ONLY_ID]["recorded_by"], "オーナー")
        index = self.sb.remote_show("INDEX.md")
        self.assertIn("| 2026-12-04 | 09:30 | — | 社内 | 社内定例 | 来週の作業を確認した | ", index)
        # newest first
        self.assertLess(index.index("2026-12-04"), index.index("2026-12-03"))

    def test_reshare_with_new_title_replaces_files_and_keeps_kind_and_first_date(self):
        self.assertOk(self.share_standard())
        old = self.sb.vault_file(STANDARD)
        new = self.sb.vault_file("2026-12-02_1000_サンプル商事 試用の打合せ.md")
        text = read(old).replace("title: サンプル商事 トライアル打合せ", "title: サンプル商事 試用の打合せ")
        os.remove(old)
        write(new, text.replace("# サンプル商事 トライアル打合せ", "# サンプル商事 試用の打合せ"))
        self.assertOk(self.sb.share(new, now="2026-12-05T09:00:00+09:00"))
        files = self.sb.remote_files()
        self.assertNotIn(MIN, files)
        self.assertNotIn(TR, files)
        self.assertIn("2026/2026-12-02_1000_サンプル商事 試用の打合せ.md", files)
        self.assertIn("2026/文字起こし/2026-12-02_1000_サンプル商事 試用の打合せ_文字起こし.md", files)
        minutes = self.sb.remote_show("2026/2026-12-02_1000_サンプル商事 試用の打合せ.md")
        self.assertIn("kind: customer\n", minutes)
        self.assertNotIn("## ブックマーク", minutes)
        rows = self.sb.tsv("shared.tsv")
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["first_shared"], "2026-12-02")
        self.assertEqual(rows[0]["kind"], "customer")
        self.assertEqual(rows[0]["recording"], REC)
        self.assertIn("更新しました", self.sb.dry_messages()[-1]["text"])
        subject = self.sb.git("log", "-1", "--format=%s", "main", cwd=self.sb.remote).strip()
        self.assertEqual(subject, "update: 2026-12-02 サンプル商事 試用の打合せ")

    def test_upstream_commit_that_does_not_conflict_is_rebased(self):
        self.assertOk(self.share_standard())
        other = self.sb.other_clone()
        write(os.path.join(other, "メモ.md"), "別の人の追加\n")
        self.sb.git("add", "-A", cwd=other)
        self.sb.git("commit", "-q", "-m", "note", cwd=other)
        self.sb.git("push", "-q", "origin", "HEAD:main", cwd=other)
        path = self.sb.vault_file(STANDARD)
        write(path, read(path).replace("一緒に見る。", "一緒に見直す。"))
        self.assertOk(self.sb.share(path))
        self.assertIn("メモ.md", self.sb.remote_files())
        self.assertIn("一緒に見直す。", self.sb.remote_show(MIN))

    def test_upstream_edit_that_conflicts_resets_the_clone_and_writes_todo(self):
        self.assertOk(self.share_standard())
        other = self.sb.other_clone()
        p = os.path.join(other, MIN)
        write(p, read(p).replace("一緒に見る。", "画面で直した。"))
        self.sb.git("commit", "-q", "-am", "edit on the web", cwd=other)
        self.sb.git("push", "-q", "origin", "HEAD:main", cwd=other)
        head_before = self.sb.git("rev-parse", "HEAD").strip()
        path = self.sb.vault_file(STANDARD)
        write(path, read(path).replace("一緒に見る。", "AutoNote で直した。"))
        proc = self.sb.share(path)
        self.assertOk(proc, 1)
        self.assertIn("GitHub 側で直されています", self.sb.state_file("todo.md"))
        self.assertIn(MIN, self.sb.state_file("todo.md"))
        self.assertIn("画面で直した。", self.sb.remote_show(MIN))
        self.assertEqual(self.sb.git("status", "--porcelain").strip(), "")
        # C-F1: the clone is put on the fetched branch (nothing unpushed is left to block later runs)
        self.assertNotEqual(self.sb.git("rev-parse", "HEAD").strip(), head_before)
        self.assertEqual(self.sb.git("rev-parse", "HEAD").strip(), self.sb.git("rev-parse", "origin/main").strip())
        self.assertIn("GitHub 側で直されています", self.sb.dry_messages()[-1]["text"])
        self.assertEqual([r["autonote_id"] for r in self.sb.tsv("pending.tsv")], [STANDARD_ID])

    def test_meeting_that_conflicted_is_shared_again_from_autonote_on_the_next_retry(self):
        # What the README says under 失敗したとき: the next retry replaces the edit made upstream, and it stays in history.
        self.assertOk(self.share_standard())
        other = self.sb.other_clone()
        p = os.path.join(other, MIN)
        write(p, read(p).replace("一緒に見る。", "画面で直した。"))
        self.sb.git("commit", "-q", "-am", "edit on the web", cwd=other)
        self.sb.git("push", "-q", "origin", "HEAD:main", cwd=other)
        path = self.sb.vault_file(STANDARD)
        write(path, read(path).replace("一緒に見る。", "AutoNote で直した。"))
        self.assertOk(self.sb.share(path), 1)
        self.assertOk(self.sb.share("--retry-pending"))
        self.assertIn("AutoNote で直した。", self.sb.remote_show(MIN))
        self.assertNotIn("画面で直した。", self.sb.remote_show(MIN))
        self.assertEqual(self.sb.tsv("pending.tsv"), [])
        conflicts = [m for m in self.sb.dry_messages() if "GitHub 側で直されています" in m["text"]]
        self.assertEqual(len(conflicts), 1)  # the retry does not report the same conflict again
        subjects = self.sb.git("log", "--format=%s", "main", cwd=self.sb.remote)
        self.assertIn("edit on the web", subjects)

    def test_push_failure_goes_to_pending_and_retry_pushes(self):
        moved = self.sb.remote + ".away"
        os.rename(self.sb.remote, moved)
        proc = self.share_standard()
        self.assertOk(proc, 1)
        pending = self.sb.tsv("pending.tsv")
        self.assertEqual([r["autonote_id"] for r in pending], [STANDARD_ID])
        self.assertEqual(pending[0]["kind"], "customer")
        self.assertEqual(self.sb.dry_messages(), [])
        self.assertEqual(self.sb.tsv("shared.tsv"), [])
        os.rename(moved, self.sb.remote)
        self.assertOk(self.sb.share("--retry-pending"))
        self.assertIn(MIN, self.sb.remote_files())
        self.assertEqual(self.sb.tsv("pending.tsv"), [])
        self.assertEqual(self.sb.tsv("shared.tsv")[0]["kind"], "customer")
        self.assertIn("議事録が並びました", self.sb.dry_messages()[-1]["text"])

    def test_two_runs_at_once_keep_state_and_index_whole(self):
        procs = []
        for name in (STANDARD, NO_TRANSCRIPT, TRANSCRIPT_ONLY):
            env = dict(self.sb.env)
            procs.append(subprocess.Popen([SHARE, self.sb.vault_file(name)], env=env,
                                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True))
        for p in procs:
            out, err = p.communicate(timeout=120)
            self.assertEqual(p.returncode, 0, err)
        ids = sorted(r["autonote_id"] for r in self.sb.tsv("shared.tsv"))
        self.assertEqual(ids, sorted([STANDARD_ID, NO_TRANSCRIPT_ID, TRANSCRIPT_ONLY_ID]))
        index = self.sb.remote_show("INDEX.md")
        self.assertEqual(index.count("\n| 2026-12-0"), 3)
        self.assertFalse(os.path.exists(os.path.join(self.sb.state, "lock")))

    def test_unshare_removes_files_and_marks_row(self):
        self.assertOk(self.share_standard())
        self.assertOk(self.sb.share("--unshare", STANDARD_ID))
        self.assertEqual(self.sb.remote_files(), ["INDEX.md", "README.md"])
        self.assertNotIn("サンプル商事", self.sb.remote_show("INDEX.md"))
        self.assertIn("unshared", self.sb.tsv("shared.tsv")[0]["flags"])
        subject = self.sb.git("log", "-1", "--format=%s", "main", cwd=self.sb.remote).strip()
        self.assertEqual(subject, "remove: 2026-12-02 サンプル商事 トライアル打合せ")
        # Sharing it again brings it back and clears the mark.
        self.assertOk(self.sb.share(self.sb.vault_file(STANDARD)))
        self.assertIn(MIN, self.sb.remote_files())
        self.assertNotIn("unshared", self.sb.tsv("shared.tsv")[0]["flags"])

    def test_same_name_for_another_meeting_gets_suffix(self):
        self.assertOk(self.share_standard())
        twin = os.path.join(self.sb.vault, "old", STANDARD)
        write(twin, read(self.sb.vault_file(STANDARD)).replace(STANDARD_ID, "20261202-1000-ffff"))
        self.assertOk(self.sb.share(twin))
        files = self.sb.remote_files()
        self.assertIn("2026/2026-12-02_1000_サンプル商事 トライアル打合せ-2.md", files)
        self.assertIn("2026/文字起こし/2026-12-02_1000_サンプル商事 トライアル打合せ-2_文字起こし.md", files)
        self.assertIn(STANDARD_ID, self.sb.remote_show(MIN))
        # Re-sharing the first one keeps its own name.
        self.assertOk(self.sb.share(self.sb.vault_file(STANDARD)))
        self.assertIn(STANDARD_ID, self.sb.remote_show(MIN))

    def test_rebuild_index(self):
        self.assertOk(self.share_standard())
        other = self.sb.other_clone()
        write(os.path.join(other, "INDEX.md"), "壊れた一覧\n")
        self.sb.git("commit", "-q", "-am", "break index", cwd=other)
        self.sb.git("push", "-q", "origin", "HEAD:main", cwd=other)
        self.assertOk(self.sb.share("--rebuild-index"))
        self.assertIn("| 2026-12-02 | 10:00 |", self.sb.remote_show("INDEX.md"))

    def test_bad_input(self):
        self.assertOk(self.sb.share(os.path.join(self.sb.vault, "nope.md")), 1)
        no_id = os.path.join(self.sb.vault, "2026", "no-id.md")
        write(no_id, "---\ntitle: x\ndate: 2026-12-01\n---\n\n# x\n")
        self.assertOk(self.sb.share(no_id), 1)
        self.assertOk(self.sb.share(self.sb.vault_file(STANDARD), "--kind", "other"), 2)
        self.assertOk(self.sb.share(), 2)

    def test_unpushed_commit_that_conflicts_later_does_not_block_other_meetings(self):
        # C-F1: a push fails, then the same lines are edited upstream. The clone must not stay stuck.
        self.assertOk(self.share_standard())
        path = self.sb.vault_file(STANDARD)
        write(path, read(path).replace("一緒に見る。", "AutoNote で直した。"))
        moved = self.sb.remote + ".away"
        os.rename(self.sb.remote, moved)
        self.assertOk(self.sb.share(path), 1)
        os.rename(moved, self.sb.remote)
        other = self.sb.other_clone()
        p = os.path.join(other, MIN)
        write(p, read(p).replace("一緒に見る。", "画面で直した。"))
        self.sb.git("commit", "-q", "-am", "edit on the web", cwd=other)
        self.sb.git("push", "-q", "origin", "HEAD:main", cwd=other)
        self.assertOk(self.sb.share("--retry-pending"), 1)
        conflicts = [m for m in self.sb.dry_messages() if "GitHub 側で直されています" in m["text"]]
        self.assertEqual(len(conflicts), 1)  # C-F5: one notice per run
        self.assertEqual(self.sb.git("log", "--oneline", "origin/main..HEAD").strip(), "")
        # the dropped commit was made again from AutoNote's file (the edit upstream is replaced)
        self.assertIn("AutoNote で直した。", self.sb.remote_show(MIN))
        self.assertEqual(self.sb.tsv("pending.tsv"), [])
        self.assertOk(self.sb.share(self.sb.vault_file(NO_TRANSCRIPT)))
        self.assertIn("2026/2026-12-04_0930_社内定例.md", self.sb.remote_files())

    def test_commit_ignores_hooks_and_signing(self):
        # C-F3: a global pre-commit hook or commit.gpgsign must not break the script's own commits.
        hooks = os.path.join(self.sb.root, "hooks")
        write(os.path.join(hooks, "pre-commit"), "#!/bin/sh\nexit 1\n")
        os.chmod(os.path.join(hooks, "pre-commit"), 0o755)
        gc = self.sb.env["GIT_CONFIG_GLOBAL"]
        with open(gc, "a") as f:
            f.write("[core]\n\thooksPath = %s\n[commit]\n\tgpgsign = true\n" % hooks)
        self.assertOk(self.share_standard())
        self.assertIn(MIN, self.sb.remote_files())

    def test_missing_git_identity_stops_with_a_clear_message(self):
        gc = os.path.join(self.sb.root, "gitconfig-noid")
        write(gc, "[init]\n\tdefaultBranch = main\n")
        proc = self.sb.share(self.sb.vault_file(STANDARD), env={"GIT_CONFIG_GLOBAL": gc})
        self.assertOk(proc, 1)
        self.assertIn("user.name", proc.stdout)
        self.assertEqual(self.sb.git("status", "--porcelain").strip(), "")
        self.assertEqual([r["autonote_id"] for r in self.sb.tsv("pending.tsv")], [STANDARD_ID])
        self.assertOk(self.sb.share("--retry-pending"))
        self.assertIn(MIN, self.sb.remote_files())

    def test_git_failure_puts_back_what_this_run_wrote(self):
        # C-F3: after a git error the clone is clean again, so the next run is not "someone touched the clone".
        objects = os.path.join(self.sb.repo, ".git", "objects")
        subprocess.run(["chmod", "-R", "a-w", objects], check=True)
        try:
            proc = self.share_standard()
        finally:
            subprocess.run(["chmod", "-R", "u+w", objects], check=True)
        self.assertOk(proc, 1)
        self.assertNotIn("Traceback", proc.stderr)
        self.assertEqual(self.sb.git("status", "--porcelain").strip(), "")
        self.assertEqual([r["autonote_id"] for r in self.sb.tsv("pending.tsv")], [STANDARD_ID])
        self.assertOk(self.sb.share("--retry-pending"))
        self.assertIn(MIN, self.sb.remote_files())

    def test_unshare_of_a_meeting_that_was_never_pushed_settles(self):
        # C-F4
        moved = self.sb.remote + ".away"
        os.rename(self.sb.remote, moved)
        self.assertOk(self.share_standard(), 1)
        self.assertOk(self.sb.share("--unshare", STANDARD_ID), 1)
        os.rename(moved, self.sb.remote)
        self.assertOk(self.sb.share("--retry-pending"))
        self.assertEqual(self.sb.tsv("pending.tsv"), [])
        self.assertEqual(self.sb.remote_files(), ["INDEX.md", "README.md"])
        self.assertOk(self.sb.share("--retry-pending"))

    def test_lock_timeout_goes_to_pending(self):
        # C-F6
        lock = os.path.join(self.sb.state, "lock")
        os.makedirs(lock)
        write(os.path.join(lock, "owner"), "%d\tnow\n" % os.getpid())  # a live process holds it
        proc = self.sb.share(self.sb.vault_file(STANDARD), env={"SHARE_LOCK_TIMEOUT_SEC": "0.3"})
        self.assertOk(proc, 1)
        self.assertEqual([r["autonote_id"] for r in self.sb.tsv("pending.tsv")], [STANDARD_ID])
        shutil.rmtree(lock)
        self.assertOk(self.sb.share("--retry-pending"))
        self.assertIn(MIN, self.sb.remote_files())

    def test_recording_is_stored_as_a_file_name(self):
        # U-F1
        self.assertOk(self.sb.share(self.sb.vault_file(STANDARD), "--recording", "/Volumes/x/受け取り箱/" + REC))
        self.assertEqual(self.sb.tsv("shared.tsv")[0]["recording"], REC)

    def test_print_template_fills_in_the_days(self):
        # C-F7 / U-F6
        self.sb.set_config(RECORDING_KEEP_DAYS="14")
        proc = self.sb.share("--print-template", "README.md")
        self.assertOk(proc)
        self.assertIn("14 日", proc.stdout)
        self.assertNotIn("{{", proc.stdout)

    def test_index_template_is_used(self):
        self.assertOk(self.share_standard())
        index = self.sb.remote_show("INDEX.md")
        self.assertTrue(index.startswith("# 会議の一覧\n"))
        self.assertIn("まずここで絞り", index)


if __name__ == "__main__":
    unittest.main()
