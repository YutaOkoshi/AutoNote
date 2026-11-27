import os
import shutil
import subprocess
import tempfile
import unittest

from helpers import GOLDEN, STANDARD, STANDARD_ID, NO_TRANSCRIPT, SandboxTest, read, write
from sharetorepo import mdhtml

DAY0 = "2026-12-02T11:00:00+09:00"
REC = "2026-12-02_1000_サンプル商事_トライアル打合せ.mp4"
NAME = "2026-12-02_1000_サンプル商事 トライアル打合せ"


def mirror_files(root):
    out = []
    for d, _, files in os.walk(root):
        for n in files:
            out.append(os.path.relpath(os.path.join(d, n), root))
    return sorted(out)


class MarkdownToHtmlTests(unittest.TestCase):
    def test_golden(self):
        src = read(os.path.join(GOLDEN, "mdhtml-input.md"))
        self.assertEqual(mdhtml.to_html(src, title="見本"), read(os.path.join(GOLDEN, "mdhtml-output.html")))

    def test_golden_docx_mode(self):
        # textutil's docx writer drops <table> and hanging indents, so the docx mode writes rows and items as paragraphs.
        src = read(os.path.join(GOLDEN, "mdhtml-input.md"))
        html = mdhtml.to_html(src, title="見本", mode="docx")
        self.assertEqual(html, read(os.path.join(GOLDEN, "mdhtml-output-docx.html")))
        self.assertNotIn("<table", html)
        self.assertNotIn("<li>", html)

    def test_inline(self):
        self.assertEqual(mdhtml.inline("**太字** と *斜体* と `a<b>` と [リンク](https://example.invalid/?a=1&b=2)"),
                         '<b>太字</b> と <i>斜体</i> と <code>a&lt;b&gt;</code> と '
                         '<a href="https://example.invalid/?a=1&amp;b=2">リンク</a>')
        self.assertEqual(mdhtml.inline("2026-12-02_1000_相手_用件"), "2026-12-02_1000_相手_用件")
        self.assertEqual(mdhtml.inline("[[別のノート]]"), "[[別のノート]]")

    def test_table_cell_pipe(self):
        html = mdhtml.to_html("| a | b |\n|---|---|\n| x\\|y | z |\n")
        self.assertIn("<td>x|y</td>", html)


class MirrorTests(SandboxTest):
    def setUp(self):
        super().setUp()
        self.mirror = os.path.join(self.sb.root, "sync", "会議の記録")
        self.fake_docx = os.path.join(self.sb.root, "fake-docx")
        # The fake converter copies the HTML so the tests can read what would go into the docx.
        write(self.fake_docx, '#!/bin/sh\ncp "$1" "$2"\n')
        os.chmod(self.fake_docx, 0o755)

    def enable(self, **extra):
        cfg = dict(MIRROR_DIR=self.mirror, DOCX_CMD=self.fake_docx)
        cfg.update(extra)
        self.sb.set_config(**cfg)

    def share_customer(self, now=DAY0):
        self.assertOk(self.sb.share(self.sb.vault_file(STANDARD), "--kind", "customer", "--recording", REC, now=now))

    def test_nothing_without_mirror_dir(self):
        self.share_customer()
        self.assertFalse(os.path.exists(os.path.join(self.sb.root, "sync")))

    def test_four_kinds_of_files(self):
        self.enable()
        self.share_customer()
        self.assertEqual(mirror_files(self.mirror), sorted([
            "はじめに.docx", "会議の一覧.docx",
            "議事録/2026/%s.docx" % NAME,
            "文字起こし/2026/%s_文字起こし.docx" % NAME,
        ]))
        minutes = read(os.path.join(self.mirror, "議事録/2026/%s.docx" % NAME))
        self.assertNotIn("autonote_id", minutes)  # no frontmatter
        self.assertIn("2026-12-02 10:00〜11:05（65 分）", minutes)
        self.assertIn("相手先: サンプル商事", minutes)
        self.assertIn("（→ 00:07:08）", minutes)
        self.assertIn("「文字起こし」フォルダ", minutes)
        self.assertNotIn(".md", minutes)
        self.assertNotIn("GitHub", minutes)
        index = read(os.path.join(self.mirror, "会議の一覧.docx"))
        self.assertIn("<b>議事録</b>: %s" % NAME, index)
        self.assertNotIn("<a ", index)
        readme = read(os.path.join(self.mirror, "はじめに.docx"))
        for word in ("GitHub", "git", ".md", "docx", "Markdown"):
            self.assertNotIn(word, readme)
        transcript = read(os.path.join(self.mirror, "文字起こし/2026/%s_文字起こし.docx" % NAME))
        self.assertIn("[00:07:08]", transcript)
        self.assertNotIn("^t00-07-08", transcript)
        # Nothing half-written is left in the synced folder, and the vault and push are untouched.
        self.assertFalse(any(n.startswith(".") for n in mirror_files(self.mirror)))

    def test_md_and_both_formats(self):
        self.enable(MIRROR_FORMAT="docx,md")
        self.share_customer()
        files = mirror_files(self.mirror)
        self.assertIn("議事録/2026/%s.md" % NAME, files)
        self.assertIn("議事録/2026/%s.docx" % NAME, files)
        self.assertIn("はじめに.md", files)
        md = read(os.path.join(self.mirror, "議事録/2026/%s.md" % NAME))
        self.assertTrue(md.startswith("# サンプル商事 トライアル打合せ\n"))
        self.assertNotIn("---\ntitle", md)

    def test_readme_gets_the_configured_days(self):
        # C-F7 / U-F6: the reader's guide shows RECORDING_KEEP_DAYS and the file types, like the repository README
        self.enable(MIRROR_FORMAT="md", RECORDING_KEEP_DAYS="14")
        self.share_customer()
        readme = read(os.path.join(self.mirror, "はじめに.md"))
        self.assertIn("14 日", readme)
        self.assertNotIn("7 日", readme)
        self.assertNotIn("{{", readme)
        self.assertIn("mp4", readme)

    def test_title_change_replaces_old_copy(self):
        self.enable()
        self.share_customer()
        write(os.path.join(self.mirror, "読む人のメモ.txt"), "置いたもの")
        old = self.sb.vault_file(STANDARD)
        new = self.sb.vault_file("2026-12-02_1000_改題.md")
        write(new, read(old).replace("title: サンプル商事 トライアル打合せ", "title: 改題"))
        os.remove(old)
        self.assertOk(self.sb.share(new))
        files = mirror_files(self.mirror)
        self.assertIn("議事録/2026/2026-12-02_1000_改題.docx", files)
        self.assertNotIn("議事録/2026/%s.docx" % NAME, files)
        self.assertNotIn("文字起こし/2026/%s_文字起こし.docx" % NAME, files)
        self.assertIn("読む人のメモ.txt", files)  # what the reader put there stays

    def test_unshare_removes_copy(self):
        self.enable()
        self.share_customer()
        self.assertOk(self.sb.share("--unshare", STANDARD_ID))
        self.assertEqual(mirror_files(self.mirror), ["はじめに.docx", "会議の一覧.docx"])
        self.assertNotIn(NAME, read(os.path.join(self.mirror, "会議の一覧.docx")))

    def test_mirror_failure_keeps_share_ok_and_patrol_rebuilds(self):
        self.enable(DOCX_CMD="/usr/bin/false")
        proc = self.sb.share(self.sb.vault_file(STANDARD), now=DAY0)
        self.assertOk(proc)
        self.assertIn("2026/%s.md" % NAME, self.sb.remote_files())
        self.assertIn("読む人向けの写し", self.sb.state_file("todo.md"))
        self.assertFalse(os.path.exists(os.path.join(self.mirror, "議事録")))
        self.assertOk(self.sb.patrol(now="2026-12-03T08:00:00+09:00"), 1)  # C-F12 (round 2): still failing → 1
        self.enable()
        self.assertOk(self.sb.patrol(now="2026-12-03T09:00:00+09:00"))
        self.assertIn("議事録/2026/%s.docx" % NAME, mirror_files(self.mirror))

    def test_rebuild_mirror(self):
        self.share_customer()
        self.assertOk(self.sb.share(self.sb.vault_file(NO_TRANSCRIPT)))
        self.enable()
        self.assertOk(self.sb.share("--rebuild-mirror"))
        self.assertEqual(mirror_files(self.mirror), sorted([
            "はじめに.docx", "会議の一覧.docx",
            "議事録/2026/%s.docx" % NAME,
            "文字起こし/2026/%s_文字起こし.docx" % NAME,
            "議事録/2026/2026-12-04_0930_社内定例.docx",
        ]))

    def test_notice_uses_mirror_web_url_over_repo(self):
        self.enable(MIRROR_WEB_URL="https://drive.example.invalid/folder/abc",
                    REPO_WEB_URL="https://example.invalid/owner/meetings")
        self.share_customer()
        text = self.sb.dry_messages()[-1]["text"]
        self.assertIn("https://drive.example.invalid/folder/abc", text)
        self.assertNotIn("example.invalid/owner", text)
        self.assertIn("議事録/2026/%s" % NAME, text)


@unittest.skipUnless(os.path.exists("/usr/bin/textutil"), "textutil is macOS only")
class RealTextutilTests(unittest.TestCase):
    def test_one_real_conversion(self):
        d = tempfile.mkdtemp()
        try:
            html = os.path.join(d, "a.html")
            write(html, mdhtml.to_html("# 見出し\n\n| a | b |\n|---|---|\n| 日本語 | 表 |\n", title="t"))
            out = os.path.join(d, "a.docx")
            from sharetorepo import mirror
            mirror.convert_docx(None, html, out)
            with open(out, "rb") as f:
                self.assertEqual(f.read(2), b"PK")
        finally:
            shutil.rmtree(d, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
