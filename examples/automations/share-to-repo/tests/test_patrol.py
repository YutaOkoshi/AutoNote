import json
import os
import shutil
import subprocess
import unittest

from helpers import STANDARD, STANDARD_ID, NO_TRANSCRIPT, SandboxTest, read, write

MIN = "2026/2026-12-02_1000_サンプル商事 トライアル打合せ.md"
REC = "2026-12-02_1000_サンプル商事_トライアル打合せ.mp4"
DAY0 = "2026-12-02T11:00:00+09:00"


class PatrolTests(SandboxTest):
    def share_customer(self):
        self.assertOk(self.sb.share(self.sb.vault_file(STANDARD), "--kind", "customer", "--recording", REC, now=DAY0))

    def texts(self):
        return [m["text"] for m in self.sb.dry_messages()]

    def test_reshares_when_vault_file_changes(self):
        self.share_customer()
        self.assertOk(self.sb.patrol(now="2026-12-03T09:00:00+09:00"))
        self.assertEqual(len(self.sb.dry_messages()), 1)  # nothing changed, nothing sent
        path = self.sb.vault_file(STANDARD)
        write(path, read(path).replace("一緒に見る。", "画面の編集で直した。"))
        self.assertOk(self.sb.patrol(now="2026-12-03T09:00:00+09:00"))
        self.assertIn("画面の編集で直した。", self.sb.remote_show(MIN))
        self.assertIn("kind: customer", self.sb.remote_show(MIN))
        self.assertIn("更新しました", self.texts()[-1])

    def test_reshare_finds_renamed_vault_file_by_id(self):
        self.share_customer()
        old = self.sb.vault_file(STANDARD)
        new = self.sb.vault_file("2026-12-02_1000_改題.md")
        write(new, read(old).replace("title: サンプル商事 トライアル打合せ", "title: 改題"))
        os.remove(old)
        self.assertOk(self.sb.patrol(now="2026-12-03T09:00:00+09:00"))
        self.assertIn("2026/2026-12-02_1000_改題.md", self.sb.remote_files())
        self.assertNotIn(MIN, self.sb.remote_files())

    def test_patrol_retries_pending(self):
        moved = self.sb.remote + ".away"
        os.rename(self.sb.remote, moved)
        self.assertOk(self.sb.share(self.sb.vault_file(STANDARD), now=DAY0), 1)
        os.rename(moved, self.sb.remote)
        self.assertOk(self.sb.patrol(now="2026-12-03T09:00:00+09:00"))
        self.assertIn(MIN, self.sb.remote_files())
        self.assertEqual(self.sb.tsv("pending.tsv"), [])

    def test_without_inbox_asks_once_after_seven_days(self):
        self.share_customer()
        self.assertOk(self.sb.share(self.sb.vault_file(NO_TRANSCRIPT), now=DAY0))  # no recording: never asked
        self.assertOk(self.sb.patrol(now="2026-12-08T09:00:00+09:00"))
        self.assertFalse(any("録画は消しましたか" in t for t in self.texts()))
        self.assertOk(self.sb.patrol(now="2026-12-09T09:00:00+09:00"))
        asked = [t for t in self.texts() if "録画は消しましたか" in t]
        self.assertEqual(len(asked), 1)
        self.assertIn(REC, asked[0])
        self.assertIn("--recording-deleted %s" % STANDARD_ID, asked[0])  # C-F7 / U-F2 (round 3): ready to paste
        self.assertNotIn("<autonote_id>", asked[0])
        self.assertOk(self.sb.patrol(now="2026-12-10T09:00:00+09:00"))
        self.assertEqual(len([t for t in self.texts() if "録画は消しましたか" in t]), 1)

    def test_with_inbox_reminds_at_7_and_21_days_and_marks_deleted(self):
        inbox = os.path.join(self.sb.root, "inbox")
        write(os.path.join(inbox, REC), "video")
        write(os.path.join(inbox, "2026-11-01_0900_見本食堂_初回.mp4"), "video")  # never shared
        write(os.path.join(inbox, ".hidden"), "x")
        write(os.path.join(inbox, "置き方のメモ.txt"), "録画以外")  # not a recording: never reminded
        self.sb.set_config(INBOX_DIR=inbox)
        self.assertOk(self.sb.patrol(now="2026-11-20T09:00:00+09:00"))  # first sight of the unshared one
        self.share_customer()
        self.assertOk(self.sb.patrol(now="2026-12-08T09:00:00+09:00"))
        self.assertFalse(any(REC in t for t in self.texts() if "受け取り箱" in t and "消して" in t))
        self.assertOk(self.sb.patrol(now="2026-12-09T09:00:00+09:00"))  # the deadline day (shared + 7)
        seven = [t for t in self.texts() if REC in t and "7 日" in t]
        self.assertEqual(len(seven), 1)
        self.assertIn("共有から 7 日", seven[0])
        # the unshared one was first seen on 11-20: already 7 days, and 21 days on 12-11
        self.assertTrue(any("見本食堂" in t and "まだ共有していない録画" in t for t in self.texts()))
        self.assertFalse(any("見本食堂" in t and "消してください" in t for t in self.texts()))
        self.assertOk(self.sb.patrol(now="2026-12-11T09:00:00+09:00"))
        self.assertTrue(any("見本食堂" in t and "21 日" in t for t in self.texts()))
        self.assertFalse(any("置き方のメモ" in t for t in self.texts()))
        self.assertIn("見本食堂", self.sb.state_file("todo.md"))
        self.assertOk(self.sb.patrol(now="2026-12-23T09:00:00+09:00"))
        self.assertEqual(len([t for t in self.texts() if REC in t and "21 日" in t]), 1)
        self.assertEqual(len([t for t in self.texts() if REC in t and "7 日" in t]), 1)
        os.remove(os.path.join(inbox, REC))
        self.assertOk(self.sb.patrol(now="2026-12-25T09:00:00+09:00"))
        self.assertIn("source_recording_deleted: はい\n", self.sb.remote_show(MIN))
        self.assertIn("recording_deleted", self.sb.tsv("shared.tsv")[0]["flags"])
        # a later re-share keeps はい
        path = self.sb.vault_file(STANDARD)
        write(path, read(path).replace("一緒に見る。", "一緒に見直す。"))
        self.assertOk(self.sb.share(path, now="2026-12-26T09:00:00+09:00"))
        self.assertIn("source_recording_deleted: はい\n", self.sb.remote_show(MIN))

    def inbox_with(self, *names):
        inbox = os.path.join(self.sb.root, "inbox")
        os.makedirs(inbox, exist_ok=True)
        for n in names:
            write(os.path.join(inbox, n), "video")
        self.sb.set_config(INBOX_DIR=inbox)
        return inbox

    def test_unshared_recording_tells_the_owner_and_the_deadline_reminder_comes_after_sharing(self):
        # C-F9 (round 2): nobody is told to delete a recording that has not been shared yet.
        self.inbox_with(REC)
        self.assertOk(self.sb.patrol(now="2026-11-24T09:00:00+09:00"))
        self.assertOk(self.sb.patrol(now="2026-12-01T09:00:00+09:00"))
        unshared = [t for t in self.texts() if "まだ共有していない録画" in t]
        self.assertEqual(len(unshared), 1)
        self.assertIn(REC, unshared[0])
        self.assertIn("まだ共有していない録画", self.sb.state_file("todo.md"))
        self.assertFalse(any("消してください" in t for t in self.texts()))
        self.share_customer()  # 12-02: the days now count from the share
        self.assertOk(self.sb.patrol(now="2026-12-08T09:00:00+09:00"))
        self.assertFalse(any("共有から" in t for t in self.texts()))
        self.assertOk(self.sb.patrol(now="2026-12-10T09:00:00+09:00"))  # the Mac was off on the due day
        due = [t for t in self.texts() if REC in t and "消してください" in t and "共有から" in t]
        self.assertEqual(len(due), 1)
        self.assertIn("共有から 8 日", due[0])  # C-F14: the real number of days
        self.assertOk(self.sb.patrol(now="2026-12-11T09:00:00+09:00"))
        self.assertEqual(len([t for t in self.texts() if REC in t and "共有から" in t]), 1)

    def test_mov_in_the_inbox_is_counted_even_though_the_guide_does_not_list_it(self):
        # C-F6 (round 2)
        mov = "2026-11-20_0900_見本食堂_画面収録.mov"
        self.inbox_with(mov)
        self.assertOk(self.sb.patrol(now="2026-11-24T09:00:00+09:00"))
        self.assertOk(self.sb.patrol(now="2026-12-01T09:00:00+09:00"))
        self.assertTrue(any(mov in t for t in self.texts()))

    def test_recording_deleted_right_after_sharing_is_marked_deleted(self):
        # C-F4 / U-F3 (round 2): seen in the inbox at share time counts as seen.
        inbox = self.inbox_with(REC, "2026-11-30_1500_見本食堂_定例.mp4")
        self.share_customer()
        self.assertEqual([r["recording"] for r in self.sb.tsv("inbox-seen.tsv")], [REC])
        os.remove(os.path.join(inbox, REC))
        self.assertOk(self.sb.patrol(now="2026-12-03T09:00:00+09:00"))
        self.assertIn("source_recording_deleted: はい\n", self.sb.remote_show(MIN))
        self.assertFalse(any("見当たらない" in t for t in self.texts()))

    def test_deleted_flag_without_the_line_in_the_repository_is_written_again(self):
        # C-F13 (round 2): the flag is the truth; a commit dropped by a conflict is made again.
        self.share_customer()
        p = os.path.join(self.sb.state, "shared.tsv")
        write(p, read(p).replace("notified_minutes,notified_new", "notified_minutes,notified_new,recording_deleted"))
        self.assertIn("recording_deleted", self.sb.tsv("shared.tsv")[0]["flags"])
        self.assertIn("source_recording_deleted: まだ\n", self.sb.remote_show(MIN))
        self.assertOk(self.sb.patrol(now="2026-12-03T09:00:00+09:00"))
        self.assertIn("source_recording_deleted: はい\n", self.sb.remote_show(MIN))

    def test_failed_autonote_list_ends_with_1(self):
        # C-F12 (round 2)
        self.share_customer()
        self.sb.set_config(AUTONOTE_CLI="/usr/bin/false")
        self.assertOk(self.sb.patrol(now="2026-12-03T09:00:00+09:00"), 1)
        self.assertIn("autonote list", self.sb.state_file("todo.md"))  # C-F1 (round 3)
        self.assertEqual(len([t for t in self.texts() if "見回りで失敗" in t]), 1)

    def test_push_failure_in_the_patrol_reaches_the_owner(self):
        # U-F2 (round 2): one todo line (not repeated) and at most one notice a day.
        self.share_customer()
        path = self.sb.vault_file(STANDARD)
        write(path, read(path).replace("一緒に見る。", "直した。"))
        os.rename(self.sb.remote, self.sb.remote + ".away")
        self.assertOk(self.sb.patrol(now="2026-12-03T09:00:00+09:00"), 1)
        self.assertEqual(self.sb.state_file("todo.md").count("置き場に送れていません"), 1)
        self.assertEqual(len([t for t in self.texts() if "見回りで失敗" in t]), 1)
        self.assertOk(self.sb.patrol(now="2026-12-03T15:00:00+09:00"), 1)  # same day: no second notice
        self.assertEqual(len([t for t in self.texts() if "見回りで失敗" in t]), 1)
        self.assertOk(self.sb.patrol(now="2026-12-04T09:00:00+09:00"), 1)
        self.assertEqual(len([t for t in self.texts() if "見回りで失敗" in t]), 2)
        self.assertEqual(self.sb.state_file("todo.md").count("置き場に送れていません"), 1)

    def test_recording_not_synced_yet_is_not_marked_deleted(self):
        # C-F2: the recording has not reached the synced folder when the patrol runs.
        inbox = self.inbox_with("2026-11-30_1500_見本食堂_定例.mp4")
        self.share_customer()
        self.assertOk(self.sb.patrol(now="2026-12-02T12:00:00+09:00"))
        self.assertIn("source_recording_deleted: まだ\n", self.sb.remote_show(MIN))
        self.assertNotIn("recording_deleted", self.sb.tsv("shared.tsv")[0]["flags"])
        missing = [t for t in self.texts() if "見当たらない" in t]
        self.assertEqual(len(missing), 1)
        self.assertIn(REC, missing[0])
        self.assertOk(self.sb.patrol(now="2026-12-03T12:00:00+09:00"))
        self.assertEqual(len([t for t in self.texts() if "見当たらない" in t]), 1)
        # it arrives, is seen, then is deleted: now it counts
        write(os.path.join(inbox, REC), "video")
        self.assertOk(self.sb.patrol(now="2026-12-04T12:00:00+09:00"))
        self.assertIn("source_recording_deleted: まだ\n", self.sb.remote_show(MIN))
        os.remove(os.path.join(inbox, REC))
        self.assertOk(self.sb.patrol(now="2026-12-05T12:00:00+09:00"))
        self.assertIn("source_recording_deleted: はい\n", self.sb.remote_show(MIN))

    def test_misspelt_recording_name_is_never_marked_deleted(self):
        self.inbox_with(REC)
        typo = REC.replace("打合せ", "打ち合わせ")
        proc = self.sb.share(self.sb.vault_file(STANDARD), "--kind", "customer", "--recording", typo, now=DAY0)
        self.assertOk(proc)
        self.assertIn("受け取り箱にありません", proc.stdout)
        for day in ("2026-12-03", "2026-12-04"):
            self.assertOk(self.sb.patrol(now=day + "T12:00:00+09:00"))
        self.assertIn("source_recording_deleted: まだ\n", self.sb.remote_show(MIN))
        self.assertEqual(len([t for t in self.texts() if "見当たらない" in t and typo in t]), 1)

    def test_empty_inbox_skips_the_deleted_check(self):
        inbox = self.inbox_with(REC)
        self.share_customer()
        self.assertOk(self.sb.patrol(now="2026-12-02T12:00:00+09:00"))  # seen
        os.remove(os.path.join(inbox, REC))  # the sync app shows an empty folder for a day
        self.assertOk(self.sb.patrol(now="2026-12-03T12:00:00+09:00"))
        self.assertIn("source_recording_deleted: まだ\n", self.sb.remote_show(MIN))

    def test_full_path_and_unicode_form_of_recording_match_the_inbox(self):
        # U-F1: a path dragged from Finder, and a decomposed (NFD) name from the synced folder.
        import unicodedata
        name = "2026-12-02_1000_サンプル商事_ガイド打合せ.mp4"  # ガ/ド decompose under NFD
        inbox = self.inbox_with(unicodedata.normalize("NFD", name))
        self.assertOk(self.sb.share(self.sb.vault_file(STANDARD), "--kind", "customer",
                                    "--recording", os.path.join(inbox, name), now=DAY0))
        row = self.sb.tsv("shared.tsv")[0]
        self.assertEqual(row["recording"], name)
        self.assertOk(self.sb.patrol(now="2026-12-03T12:00:00+09:00"))
        self.assertIn("source_recording_deleted: まだ\n", self.sb.remote_show(MIN))
        self.assertFalse(any("見当たらない" in t for t in self.texts()))

    def test_share_warns_when_recording_is_not_in_inbox(self):
        self.inbox_with(REC)
        proc = self.sb.share(self.sb.vault_file(STANDARD), "--recording", "2026-12-02_1000_別_名前.mp4", now=DAY0)
        self.assertOk(proc)
        self.assertIn("受け取り箱にありません", proc.stdout)

    def test_unreadable_vault_is_reported_and_other_steps_still_run(self):
        # launchd without the Documents permission: listing the vault fails with "Operation not permitted".
        self.share_customer()
        moved = self.sb.remote + ".away"
        os.rename(self.sb.remote, moved)
        path = self.sb.vault_file(NO_TRANSCRIPT)
        self.assertOk(self.sb.share(path, now=DAY0), 1)  # leaves a commit and a pending row
        os.rename(moved, self.sb.remote)
        os.chmod(self.sb.vault, 0)
        try:
            proc = self.sb.patrol(now="2026-12-03T09:00:00+09:00")
        finally:
            os.chmod(self.sb.vault, 0o755)
        self.assertOk(proc, 1)
        self.assertNotIn("Traceback", proc.stderr)
        self.assertIn("会議ファイルのフォルダ（VAULT_ROOT）を読めません", self.sb.state_file("todo.md"))
        self.assertEqual(len([t for t in self.texts() if "VAULT_ROOT" in t or "会議ファイルのフォルダ" in t]), 1)
        # the commit left by the failed push still went out
        self.assertIn("2026/2026-12-04_0930_社内定例.md", self.sb.remote_files())

    def todo_lines(self, word):
        return [l for l in self.sb.state_file("todo.md").splitlines() if word in l]

    def test_git_failure_in_the_patrol_reaches_the_owner(self):
        # C-F1 (round 3): it used to be one line in launchd's log and nothing else
        self.share_customer()
        path = self.sb.vault_file(STANDARD)
        write(path, read(path).replace("一緒に見る。", "直した。"))
        objects = os.path.join(self.sb.repo, ".git", "objects")
        subprocess.run(["chmod", "-R", "a-w", objects], check=True)
        try:
            first = self.sb.patrol(now="2026-12-03T09:00:00+09:00")
            second = self.sb.patrol(now="2026-12-04T09:00:00+09:00")
        finally:
            subprocess.run(["chmod", "-R", "u+w", objects], check=True)
        self.assertOk(first, 1)
        self.assertOk(second, 1)
        self.assertEqual(len(self.todo_lines("git ")), 1)  # the same line is not written twice
        self.assertEqual(len([t for t in self.texts() if "見回りで失敗" in t]), 2)  # one a day

    def test_lock_that_cannot_be_taken_in_the_patrol_reaches_the_owner(self):
        # C-F1 (round 3)
        self.share_customer()
        lock = os.path.join(self.sb.state, "lock")
        os.makedirs(lock)
        write(os.path.join(lock, "owner"), "%d\tnow\n" % os.getpid())  # a live process holds it
        proc = self.sb.patrol(now="2026-12-03T09:00:00+09:00", env={"SHARE_LOCK_TIMEOUT_SEC": "0.3"})
        self.assertOk(proc, 1)
        self.assertEqual(len(self.todo_lines("ロック")), 1)
        self.assertEqual(len([t for t in self.texts() if "見回りで失敗" in t]), 1)
        shutil.rmtree(lock)
        self.assertOk(self.sb.patrol(now="2026-12-04T09:00:00+09:00"))

    def test_pending_meeting_whose_vault_file_is_gone_gets_its_row_once_it_is_pushed(self):
        # C-F2 (round 3): the commit left in the clone went out, but shared.tsv never heard of the meeting
        moved = self.sb.remote + ".away"
        os.rename(self.sb.remote, moved)
        self.assertOk(self.sb.share(self.sb.vault_file(STANDARD), "--kind", "customer", "--recording", REC,
                                    now=DAY0), 1)
        os.remove(self.sb.vault_file(STANDARD))
        os.rename(moved, self.sb.remote)
        self.assertOk(self.sb.patrol(now="2026-12-03T09:00:00+09:00"))
        self.assertIn(MIN, self.sb.remote_files())
        rows = self.sb.tsv("shared.tsv")
        self.assertEqual([(r["autonote_id"], r["minutes_file"], r["kind"], r["customer"], r["recorded_by"],
                           r["recording"], r["first_shared"]) for r in rows],
                         [(STANDARD_ID, MIN, "customer", "サンプル商事", "営業担当", REC, "2026-12-02")])
        self.assertTrue(rows[0]["transcript_file"].endswith("_文字起こし.md"))
        self.assertEqual(self.sb.tsv("pending.tsv"), [])
        self.assertEqual(len(self.todo_lines("会議ファイルが見つかりません")), 1)
        self.assertIn(STANDARD_ID, self.todo_lines("会議ファイルが見つかりません")[0])
        arrived = [t for t in self.texts() if "議事録が並びました" in t]
        self.assertEqual(len(arrived), 1)
        self.assertIn("12/9 までに消してください", arrived[0])
        self.assertOk(self.sb.patrol(now="2026-12-04T09:00:00+09:00"))
        self.assertEqual(len(self.todo_lines("会議ファイルが見つかりません")), 1)
        self.assertEqual(len([t for t in self.texts() if "議事録が並びました" in t]), 1)
        self.assertOk(self.sb.patrol(now="2026-12-09T09:00:00+09:00"))  # and the recording is followed up
        self.assertTrue(any("録画は消しましたか" in t for t in self.texts()))

    def test_pending_meeting_with_no_vault_file_and_no_commit_is_reported(self):
        # C-F1 / C-F2 (round 3)
        lock = os.path.join(self.sb.state, "lock")
        os.makedirs(lock)
        write(os.path.join(lock, "owner"), "%d\tnow\n" % os.getpid())
        self.assertOk(self.sb.share(self.sb.vault_file(STANDARD), env={"SHARE_LOCK_TIMEOUT_SEC": "0.3"}), 1)
        shutil.rmtree(lock)
        os.remove(self.sb.vault_file(STANDARD))
        self.assertOk(self.sb.patrol(now="2026-12-03T09:00:00+09:00"), 1)
        self.assertEqual(len(self.todo_lines("会議ファイルが見つかりません")), 1)
        self.assertIn(STANDARD_ID, self.todo_lines("会議ファイルが見つかりません")[0])
        self.assertEqual(len([t for t in self.texts() if "見回りで失敗" in t]), 1)
        self.assertEqual([r["autonote_id"] for r in self.sb.tsv("pending.tsv")], [STANDARD_ID])
        self.assertEqual(self.sb.tsv("shared.tsv"), [])
        self.assertOk(self.sb.share("--unshare", STANDARD_ID))  # the way out that the message names
        self.assertEqual(self.sb.tsv("pending.tsv"), [])
        self.assertOk(self.sb.patrol(now="2026-12-04T09:00:00+09:00"))

    def test_reshare_finds_a_vault_file_moved_into_nested_folders(self):
        # C-F5 (round 3): AutoNote walks the whole vault, so people file meetings into folders in Obsidian
        self.share_customer()
        old = self.sb.vault_file(STANDARD)
        new = os.path.join(self.sb.vault, "顧客", "サンプル商事", STANDARD)
        write(new, read(old).replace("一緒に見る。", "フォルダを動かした後に直した。"))
        os.remove(old)
        write(os.path.join(self.sb.vault, "_autonote", "控え", STANDARD), read(new).replace("動かした後", "読まれない"))
        write(os.path.join(self.sb.vault, ".trash", STANDARD), read(new).replace("動かした後", "読まれない"))
        self.assertOk(self.sb.patrol(now="2026-12-03T09:00:00+09:00"))
        self.assertIn("フォルダを動かした後に直した。", self.sb.remote_show(MIN))
        self.assertEqual(self.sb.state_file("todo.md"), "")

    def test_shared_meeting_whose_vault_file_is_gone_is_written_to_todo_once(self):
        # C-F5 (round 3): it used to be skipped without a word
        self.share_customer()
        os.remove(self.sb.vault_file(STANDARD))
        self.assertOk(self.sb.patrol(now="2026-12-03T09:00:00+09:00"))
        lines = self.todo_lines("会議ファイルが見つかりません")
        self.assertEqual(len(lines), 1)
        self.assertIn(STANDARD_ID, lines[0])
        self.assertEqual(len([t for t in self.texts() if "会議ファイルが見つかりません" in t]), 1)
        os.remove(os.path.join(self.sb.state, "todo.md"))  # the owner dealt with it
        self.assertOk(self.sb.patrol(now="2026-12-04T09:00:00+09:00"))
        self.assertEqual(self.todo_lines("会議ファイルが見つかりません"), [])
        self.assertEqual(len([t for t in self.texts() if "会議ファイルが見つかりません" in t]), 1)
        self.assertIn(MIN, self.sb.remote_files())  # never removed automatically

    def test_missing_vault_folder_is_one_problem_not_one_line_per_meeting(self):
        # round 3, with C-F5: an unmounted disk must not report every shared meeting as gone
        self.share_customer()
        self.assertOk(self.sb.share(self.sb.vault_file(NO_TRANSCRIPT), now=DAY0))
        os.rename(self.sb.vault, self.sb.vault + ".away")
        self.assertOk(self.sb.patrol(now="2026-12-03T09:00:00+09:00"), 1)
        self.assertEqual(len(self.todo_lines("VAULT_ROOT")), 1)
        self.assertEqual(self.todo_lines("会議ファイルが見つかりません"), [])

    def test_undo_of_a_deleted_mark_set_by_the_patrol_stays_undone(self):
        # C-F4 (round 3): renaming the file in the inbox looks like "seen, then gone"
        inbox = self.inbox_with(REC, "2026-12-20_0900_別の録画.mp4")
        self.share_customer()
        os.remove(os.path.join(inbox, REC))
        self.assertOk(self.sb.patrol(now="2026-12-03T09:00:00+09:00"))
        self.assertIn("source_recording_deleted: はい\n", self.sb.remote_show(MIN))
        self.assertOk(self.sb.share("--recording-deleted", STANDARD_ID, "--undo", now="2026-12-03T10:00:00+09:00"))
        self.assertIn("source_recording_deleted: まだ\n", self.sb.remote_show(MIN))
        self.assertOk(self.sb.patrol(now="2026-12-04T09:00:00+09:00"))
        self.assertIn("source_recording_deleted: まだ\n", self.sb.remote_show(MIN))
        self.assertNotIn("recording_deleted", self.sb.tsv("shared.tsv")[0]["flags"])

    def fake_cli(self, ids):
        path = os.path.join(self.sb.root, "fake-autonote")
        rows = [{"id": i, "title": "x", "startedAt": "2026-12-02T01:00:00Z", "state": "minutes_generated"} for i in ids]
        write(path, "#!/bin/sh\n[ \"$1 $2\" = \"list --json\" ] || exit 2\ncat <<'EOF'\n%s\nEOF\n" % json.dumps(rows))
        os.chmod(path, 0o755)
        return path

    def test_reports_shared_meeting_missing_from_autonote(self):
        self.share_customer()
        self.sb.set_config(AUTONOTE_CLI=self.fake_cli([STANDARD_ID]))
        self.assertOk(self.sb.patrol(now="2026-12-03T09:00:00+09:00"))
        self.assertFalse(any("AutoNote に無い" in t for t in self.texts()))
        self.sb.set_config(AUTONOTE_CLI=self.fake_cli(["20990101-0000-0000"]))
        self.assertOk(self.sb.patrol(now="2026-12-04T09:00:00+09:00"))
        missing = [t for t in self.texts() if "AutoNote に無い" in t]
        self.assertEqual(len(missing), 1)
        self.assertIn(STANDARD_ID, missing[0])
        self.assertIn(STANDARD_ID, self.sb.state_file("todo.md"))
        self.assertOk(self.sb.patrol(now="2026-12-05T09:00:00+09:00"))
        self.assertEqual(len([t for t in self.texts() if "AutoNote に無い" in t]), 1)
        self.assertIn(MIN, self.sb.remote_files())  # never removed automatically


if __name__ == "__main__":
    unittest.main()
