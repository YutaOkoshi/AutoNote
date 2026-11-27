import os
import subprocess
import tempfile
import unittest

import helpers  # noqa: F401  (puts lib/ on sys.path)
from sharetorepo import gitrepo
from sharetorepo.config import parse_env_file


class ConfigFileTests(unittest.TestCase):
    def parse(self, text):
        with tempfile.NamedTemporaryFile("w", suffix=".env", delete=False, encoding="utf-8") as f:
            f.write(text)
        try:
            return parse_env_file(f.name)
        finally:
            os.remove(f.name)

    def test_comment_after_a_quoted_value_is_dropped(self):
        # C-F8 / U-F5 (round 2): the quotes used to stay in the value
        v = self.parse('A="http://127.0.0.1:9/hook"   # 直接渡す場合\n'
                       "B='single'  # note\n"
                       'C="a # b"\n'
                       'D="say \\"hi\\"" # c\n'
                       "E=plain   # note\n"
                       'F="7"#x\n'
                       'G="$A/x"  # uses A\n')
        self.assertEqual(v["A"], "http://127.0.0.1:9/hook")
        self.assertEqual(v["B"], "single")
        self.assertEqual(v["C"], "a # b")
        self.assertEqual(v["D"], 'say "hi"')
        self.assertEqual(v["E"], "plain")
        self.assertEqual(v["F"], "7")
        self.assertEqual(v["G"], "http://127.0.0.1:9/hook/x")

    def test_example_file_parses_to_plain_values(self):
        example = os.path.join(helpers.ROOT, "config.env.example")
        for key, value in parse_env_file(example).items():
            self.assertFalse(value.startswith('"') or value.endswith('"'), "%s=%r" % (key, value))
            self.assertNotIn("#", value, key)
        text = helpers.read(example)
        self.assertIn("OP_CMD=", text)
        for line in text.splitlines():  # no comment after a value, commented-out examples included
            body = line.lstrip("# ")
            if "=" in body and body.split("=", 1)[0].isupper():
                self.assertNotRegex(body, r'"\s+#', line)


class LaunchdTemplateTests(unittest.TestCase):
    def test_both_plists_are_valid_after_the_readme_substitution(self):
        # C-F18 / U-F6 (round 2): the shell form and the app form
        if not os.path.exists("/usr/bin/plutil"):
            self.skipTest("plutil is macOS only")
        d = os.path.join(helpers.ROOT, "launchd")
        plists = sorted(n for n in os.listdir(d) if n.endswith(".plist"))
        self.assertEqual(len(plists), 2)
        for name in plists:
            text = helpers.read(os.path.join(d, name))
            text = text.replace("__LABEL__", "local.share-to-repo.daily-patrol")
            text = text.replace("__SHARE_HOME__", "/Users/someone/Library/Application Support/AutoNoteShare")
            self.assertNotIn("__", text, name)
            with tempfile.NamedTemporaryFile("w", suffix=".plist", delete=False, encoding="utf-8") as f:
                f.write(text)
            try:
                subprocess.run(["/usr/bin/plutil", "-lint", f.name], check=True, capture_output=True)
            finally:
                os.remove(f.name)

    def test_app_builder_is_a_valid_shell_script(self):
        script = os.path.join(helpers.ROOT, "launchd", "make-patrol-app.sh")
        subprocess.run(["/bin/sh", "-n", script], check=True)
        self.assertTrue(os.access(script, os.X_OK))


class GitTimeoutTests(unittest.TestCase):
    def test_fetch_and_push_that_hang_count_as_offline(self):
        # C-F17 (round 2)
        repo = gitrepo.Repo("/nonexistent", "origin", "main")
        real = subprocess.run
        seen = []

        def fake(argv, **kw):
            seen.append((argv, kw.get("timeout")))
            raise subprocess.TimeoutExpired(argv, kw.get("timeout") or 0)

        gitrepo.subprocess.run = fake
        try:
            self.assertFalse(repo.fetch())
            ok, why = repo.push()
            self.assertFalse(ok)
            self.assertIn("時間切れ", why)
        finally:
            gitrepo.subprocess.run = real
        self.assertTrue(all(t for _, t in seen), seen)


if __name__ == "__main__":
    unittest.main()
