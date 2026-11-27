import json
import os
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
        self.assertTrue(any("見本食堂" in t and "置いてから 7 日" in t for t in self.texts()))
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
