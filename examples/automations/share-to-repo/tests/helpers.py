"""Test sandbox: temp HOME, a bare remote, a clone, a vault copied from fixtures, and a config.env.

Nothing here touches the real GitHub, Slack, autonote, osascript or op. Every run gets its own temp folder.
"""
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
FIXTURES = os.path.join(HERE, "fixtures")
GOLDEN = os.path.join(HERE, "golden")
SHARE = os.path.join(ROOT, "share-meeting.sh")
PATROL = os.path.join(ROOT, "daily-patrol.sh")

sys.path.insert(0, os.path.join(ROOT, "lib"))

STANDARD = "2026-12-02_1000_サンプル商事 トライアル打合せ.md"
TRANSCRIPT_ONLY = "2026-12-03_140000.md"
NO_TRANSCRIPT = "2026-12-04_0930_社内定例.md"
STANDARD_ID = "20261202-1000-3fa7"
TRANSCRIPT_ONLY_ID = "20261203-1400-77aa"
NO_TRANSCRIPT_ID = "20261204-0930-0b1c"


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


class Sandbox:
    def __init__(self, extra_config=None):
        self.root = tempfile.mkdtemp(prefix="share-to-repo-test-")
        self.home = os.path.join(self.root, "home")
        self.remote = os.path.join(self.root, "remote.git")
        self.repo = os.path.join(self.root, "repo")
        self.vault = os.path.join(self.root, "vault")
        self.state = os.path.join(self.root, "state")
        self.logs = os.path.join(self.root, "logs")
        self.config = os.path.join(self.root, "config.env")
        os.makedirs(self.home)
        gitconfig = os.path.join(self.root, "gitconfig")
        write(gitconfig, "[user]\n\tname = Test\n\temail = test@example.invalid\n"
                         "[init]\n\tdefaultBranch = main\n[commit]\n\tgpgsign = false\n")
        self.env = {
            "PATH": os.path.dirname(shutil.which("git") or "/usr/bin/git") + ":/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": self.home,
            "LANG": "en_US.UTF-8",
            "GIT_CONFIG_GLOBAL": gitconfig,
            "GIT_CONFIG_NOSYSTEM": "1",
            "SHARE_CONFIG": self.config,
            "SHARE_PYTHON": sys.executable,
        }
        shutil.copytree(os.path.join(FIXTURES, "vault"), self.vault)
        self.git("init", "-q", "--bare", self.remote, cwd=self.root)
        seed = os.path.join(self.root, "seed")
        self.git("clone", "-q", self.remote, seed, cwd=self.root)
        write(os.path.join(seed, "README.md"), "# 見本の置き場\n")
        self.git("add", "-A", cwd=seed)
        self.git("commit", "-q", "-m", "init", cwd=seed)
        self.git("push", "-q", "origin", "HEAD:main", cwd=seed)
        self.git("clone", "-q", self.remote, self.repo, cwd=self.root)
        config = {
            "SHARE_REPO_DIR": self.repo,
            "SHARE_STATE_DIR": self.state,
            "SHARE_LOG_DIR": self.logs,
            "VAULT_ROOT": self.vault,
            "DEFAULT_RECORDED_BY": "営業担当",
            "NOTIFY_MODE": "dry-run",
            "SHARE_LOCK_POLL_SEC": "0.1",
            "SHARE_LOCK_TIMEOUT_SEC": "30",
        }
        config.update(extra_config or {})
        self.write_config(config)

    def write_config(self, values):
        lines = ["# test config"] + ['%s="%s"' % (k, v) for k, v in values.items()]
        write(self.config, "\n".join(lines) + "\n")
        self.config_values = dict(values)

    def set_config(self, **values):
        merged = dict(self.config_values)
        merged.update(values)
        self.write_config(merged)

    def cleanup(self):
        shutil.rmtree(self.root, ignore_errors=True)

    def git(self, *args, cwd=None):
        env = dict(self.env)
        return subprocess.run(["git", "-c", "core.quotePath=false"] + list(args), cwd=cwd or self.repo,
                              env=env, check=True, capture_output=True, text=True).stdout

    def run(self, script, *args, env=None, now=None):
        e = dict(self.env)
        if now:
            e["SHARE_NOW"] = now
        e.update(env or {})
        return subprocess.run([script] + list(args), env=e, capture_output=True, text=True, timeout=120)

    def share(self, *args, **kw):
        return self.run(SHARE, *args, **kw)

    def patrol(self, *args, **kw):
        return self.run(PATROL, *args, **kw)

    def vault_file(self, name):
        return os.path.join(self.vault, "2026", name)

    def remote_files(self):
        out = self.git("ls-tree", "-r", "--name-only", "main", cwd=self.remote)
        return sorted(x for x in out.splitlines() if x)

    def remote_show(self, path):
        return self.git("show", "main:" + path, cwd=self.remote)

    def other_clone(self):
        path = os.path.join(self.root, "other")
        if not os.path.isdir(path):
            self.git("clone", "-q", self.remote, path, cwd=self.root)
        else:
            self.git("pull", "-q", "--rebase", cwd=path)
        return path

    def state_file(self, name):
        p = os.path.join(self.state, name)
        return read(p) if os.path.exists(p) else ""

    def tsv(self, name):
        text = self.state_file(name)
        lines = [l for l in text.splitlines() if l]
        if not lines:
            return []
        head = lines[0].split("\t")
        return [dict(zip(head, l.split("\t"))) for l in lines[1:]]

    def dry_messages(self):
        d = os.path.join(self.state, "outbox-dry")
        if not os.path.isdir(d):
            return []
        import json
        out = []
        names = sorted(os.listdir(d), key=lambda n: (os.stat(os.path.join(d, n)).st_mtime_ns, n))
        for n in names:
            with open(os.path.join(d, n), encoding="utf-8") as f:
                out.append(json.load(f))
        return out


class SandboxTest(unittest.TestCase):
    extra_config = None

    def setUp(self):
        self.sb = Sandbox(self.extra_config)

    def tearDown(self):
        if os.environ.get("KEEP_SANDBOX"):
            print("sandbox kept:", self.sb.root)
        else:
            self.sb.cleanup()

    def assertOk(self, proc, code=0):
        self.assertEqual(proc.returncode, code,
                         "exit %d\nstdout:\n%s\nstderr:\n%s" % (proc.returncode, proc.stdout, proc.stderr))
