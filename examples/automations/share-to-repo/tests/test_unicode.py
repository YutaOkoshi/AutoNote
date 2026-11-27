"""File names with dakuten: AutoNote's vault files are NFD on disk, git's tree names are NFC (C-F1 / C-F2, round 2)."""
import os
import re
import shutil
import unicodedata
import unittest
import urllib.parse

from helpers import NO_TRANSCRIPT, STANDARD, SandboxTest, read, write


def nfc(s):
    return unicodedata.normalize("NFC", s)


def nfd(s):
    return unicodedata.normalize("NFD", s)


STEM = nfc("2026-12-02_1000_サンプル商事 トライアル打合せ")
MIN = "2026/%s.md" % STEM
TR = "2026/文字起こし/%s_文字起こし.md" % STEM
DAY0 = "2026-12-02T12:00:00+09:00"


class UnicodeNameTests(SandboxTest):
    def setUp(self):
        super().setUp()
        self.vault_path = self.sb.nfd_vault_file(STANDARD)
        listed = [n for n in os.listdir(os.path.dirname(self.vault_path)) if n.startswith("2026-12-02")][0]
        self.assertEqual(listed, nfd(STANDARD))  # the name on disk really is NFD
        self.assertNotEqual(nfd(STANDARD), nfc(STANDARD))

    def share(self, *extra, now=DAY0):
        return self.sb.share(self.vault_path, "--kind", "customer", *extra, now=now)

    def meeting_files(self):
        return [f for f in self.sb.remote_files() if "2026-12-02_1000" in f]

    def edit_vault(self, mark):
        write(self.vault_path, read(self.vault_path).replace("## 決定事項", "## 決定事項\n- %s" % mark, 1))

    def index_rows(self):
        return [l for l in self.sb.remote_show("INDEX.md").splitlines() if l.startswith("| 2026-12-02")]

    def edit_upstream(self, old, new):
        other = self.sb.other_clone()
        p = os.path.join(other, MIN)
        write(p, read(p).replace(old, new, 1))
        self.sb.git("commit", "-q", "-am", "edit on the web", cwd=other)
        self.sb.git("push", "-q", "origin", "HEAD:main", cwd=other)

    def assertBothThere(self):
        self.assertEqual(self.meeting_files(), sorted([MIN, TR]))
        self.assertEqual(len(self.index_rows()), 1)

    def test_names_links_and_state_match_the_tree_byte_for_byte(self):
        self.sb.set_config(REPO_WEB_URL="https://example.invalid/owner/repo")
        self.assertOk(self.share())
        files = self.sb.remote_files()
        self.assertIn(MIN, files)
        self.assertIn(TR, files)
        index = self.sb.remote_show("INDEX.md")
        targets = re.findall(r"\]\(<([^>]+)>\)", index)
        self.assertEqual(len(targets), 2)
        for t in targets:
            self.assertIn(t, files)
        minutes = self.sb.remote_show(MIN)
        self.assertIn('transcript_file: "文字起こし/%s_文字起こし.md"\n' % STEM, minutes)
        self.assertIn("`文字起こし/%s_文字起こし.md`" % STEM, minutes)
        transcript = self.sb.remote_show(TR)
        self.assertIn('minutes_file: "../%s.md"\n' % STEM, transcript)
        row = self.sb.tsv("shared.tsv")[0]
        self.assertEqual(row["minutes_file"], MIN)
        self.assertEqual(row["transcript_file"], TR)
        self.assertIn(urllib.parse.quote(MIN), self.sb.dry_messages()[-1]["text"])

    def test_reshare_after_git_rewrote_the_file_keeps_both_files(self):
        # B: edited on the web, pulled in by another share (git writes the file again), then re-shared.
        self.assertOk(self.share())
        self.edit_upstream("## アクション", "## アクション\n（画面で 1 行足した）")
        self.assertOk(self.sb.share(self.sb.vault_file(NO_TRANSCRIPT), now="2026-12-04T12:00:00+09:00"))
        self.edit_vault("追記した決定")
        self.assertOk(self.sb.patrol(now="2026-12-06T09:00:00+09:00"))
        self.assertBothThere()
        self.assertIn("追記した決定", self.sb.remote_show(MIN))

    def test_reshare_after_a_fresh_clone_keeps_both_files(self):
        # C: the clone was made again (a new Mac); its names on disk are NFC.
        self.assertOk(self.share())
        shutil.rmtree(self.sb.repo)
        self.sb.git("clone", "-q", self.sb.remote, self.sb.repo, cwd=self.sb.root)
        self.edit_vault("追記した決定")
        self.assertOk(self.sb.patrol(now="2026-12-06T09:00:00+09:00"))
        self.assertBothThere()

    def test_retry_after_a_conflict_keeps_both_files(self):
        # D
        self.assertOk(self.share())
        self.edit_upstream("## 決定事項", "## 決定事項\n- 画面で足した決定")
        self.edit_vault("AutoNote で足した決定")
        self.assertOk(self.share(now="2026-12-03T12:00:00+09:00"), 1)
        self.assertOk(self.sb.share("--retry-pending", now="2026-12-03T13:00:00+09:00"))
        self.assertBothThere()
        self.assertIn("AutoNote で足した決定", self.sb.remote_show(MIN))

    def test_same_file_given_in_the_other_unicode_form_keeps_both_files(self):
        nfc_path = os.path.join(os.path.dirname(self.vault_path), nfc(STANDARD))
        if not os.path.exists(nfc_path):
            self.skipTest("this file system tells NFC and NFD names apart")
        self.assertOk(self.sb.share(nfc_path, "--kind", "customer", now=DAY0))
        self.edit_vault("追記した決定")
        self.assertOk(self.share(now="2026-12-03T12:00:00+09:00"))
        self.assertBothThere()

    def test_clone_without_precomposeunicode_gets_nfc_names_too(self):
        self.sb.git("config", "core.precomposeunicode", "false")
        self.assertOk(self.share())
        self.edit_vault("追記した決定")
        self.assertOk(self.share(now="2026-12-03T12:00:00+09:00"))
        self.assertBothThere()

    def test_files_left_in_nfd_by_an_older_version_are_renamed_not_removed(self):
        self.assertOk(self.share())
        year = os.path.join(self.sb.repo, "2026")
        os.rename(os.path.join(year, STEM + ".md"), os.path.join(year, nfd(STEM) + ".md"))
        self.assertIn(nfd(STEM) + ".md", os.listdir(year))
        self.edit_vault("追記した決定")
        self.assertOk(self.share(now="2026-12-03T12:00:00+09:00"))
        self.assertBothThere()
        self.assertIn(STEM + ".md", os.listdir(year))
        self.assertEqual(self.sb.git("status", "--porcelain").strip(), "")

    def test_reader_copy_recorded_under_nfd_names_is_not_removed(self):
        mirror = os.path.join(self.sb.root, "sync")
        self.sb.set_config(MIRROR_DIR=mirror, MIRROR_FORMAT="md")
        self.assertOk(self.share())
        copy = os.path.join(mirror, "議事録", "2026", STEM + ".md")
        self.assertTrue(os.path.exists(copy))
        manifest = os.path.join(self.sb.state, "mirror-files.tsv")
        write(manifest, nfd(read(manifest)))  # what a version that kept NFD names left behind
        self.assertOk(self.sb.patrol(now="2026-12-03T09:00:00+09:00"))
        self.assertTrue(os.path.exists(copy))
        self.assertIn(STEM + ".md", os.listdir(os.path.dirname(copy)))
        self.assertEqual(read(manifest), nfc(read(manifest)))


if __name__ == "__main__":
    unittest.main()
