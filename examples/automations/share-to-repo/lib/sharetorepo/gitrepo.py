"""git in the script-only clone. Never force-pushes; never prompts (GIT_TERMINAL_PROMPT=0)."""
import os
import subprocess


class GitError(Exception):
    pass


class Repo:
    def __init__(self, path, remote, branch):
        self.path = path
        self.remote = remote
        self.branch = branch
        self.env = dict(os.environ)
        self.env.update({"GIT_TERMINAL_PROMPT": "0", "GIT_EDITOR": "true", "GIT_SEQUENCE_EDITOR": "true",
                         "GIT_MERGE_AUTOEDIT": "no"})

    def run(self, *args, check=True):
        p = subprocess.run(["git", "-c", "core.quotePath=false"] + list(args), cwd=self.path, env=self.env,
                           capture_output=True, text=True)
        if check and p.returncode != 0:
            raise GitError("git %s: %s" % (args[0], (p.stderr or p.stdout).strip()[:500]))
        return p

    def ok(self):
        return os.path.isdir(os.path.join(self.path, ".git")) or os.path.isfile(os.path.join(self.path, ".git"))

    def head(self):
        p = self.run("rev-parse", "--verify", "-q", "HEAD", check=False)
        return p.stdout.strip() if p.returncode == 0 else None

    def dirty(self):
        return self.run("status", "--porcelain").stdout.strip() != ""

    def add_all(self):
        self.run("add", "-A")

    def commit(self, message):
        """Commits everything staged. False when there is nothing to commit."""
        self.add_all()
        if self.run("diff", "--cached", "--quiet", check=False).returncode == 0:
            return False
        self.run("commit", "-q", "-m", message)
        return True

    def fetch(self):
        return self.run("fetch", "-q", self.remote, self.branch, check=False).returncode == 0

    def remote_ref(self):
        ref = "%s/%s" % (self.remote, self.branch)
        p = self.run("rev-parse", "--verify", "-q", "refs/remotes/" + ref, check=False)
        return ref if p.returncode == 0 else None

    def ahead(self):
        ref = self.remote_ref()
        if not self.head():
            return 0
        if not ref:
            return int(self.run("rev-list", "--count", "HEAD").stdout.strip() or "0")
        return int(self.run("rev-list", "--count", "%s..HEAD" % ref).stdout.strip() or "0")

    def rebase(self, on_index_conflict):
        """Rebases local commits onto the fetched branch (what `git pull --rebase` does).

        Conflicts only in INDEX.md are resolved by on_index_conflict() (it rewrites INDEX.md). Any other conflict
        aborts the rebase and returns the conflicting paths. Returns [] when done.
        """
        ref = self.remote_ref()
        if not ref or not self.head():
            if ref and not self.head():
                self.run("reset", "-q", "--hard", ref)
            return []
        if self.run("merge-base", "--is-ancestor", ref, "HEAD", check=False).returncode == 0:
            return []
        p = self.run("rebase", "-q", ref, check=False)
        for _ in range(100):
            if p.returncode == 0:
                return []
            files = [f for f in self.run("diff", "--name-only", "--diff-filter=U").stdout.splitlines() if f]
            if files and set(files) == {"INDEX.md"}:
                on_index_conflict()
                self.run("add", "INDEX.md")
                p = self.run("rebase", "--continue", check=False)
                continue
            self.run("rebase", "--abort", check=False)
            return files or ["(不明)"]
        self.run("rebase", "--abort", check=False)
        return ["(rebase が終わらない)"]

    def push(self):
        p = self.run("push", "-q", self.remote, "HEAD:%s" % self.branch, check=False)
        return p.returncode == 0, (p.stderr or "").strip()[:300]

    def reset_hard(self, sha):
        self.run("reset", "-q", "--hard", sha)
