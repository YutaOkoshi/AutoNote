"""git in the script-only clone. Never force-pushes; never prompts (GIT_TERMINAL_PROMPT=0).

Every call runs with hooks and commit signing off: a global pre-commit hook or commit.gpgsign is the user's setting
for their own work, and must not make the script's commits fail half way.
"""
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

    PREFIX = ["git", "-c", "core.quotePath=false", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false",
              "-c", "tag.gpgsign=false"]

    def run(self, *args, check=True):
        p = subprocess.run(self.PREFIX + list(args), cwd=self.path, env=self.env, capture_output=True, text=True)
        if check and p.returncode != 0:
            detail = (p.stderr or "").strip() or (p.stdout or "").strip() or "(出力なし)"
            raise GitError("git %s が失敗しました（終了コード %d）: %s" % (args[0], p.returncode, detail[:500]))
        return p

    def identity_missing(self):
        """Names of the missing settings among user.name / user.email (environment variables count too)."""
        missing = []
        for key, envs in (("user.name", ("GIT_AUTHOR_NAME", "GIT_COMMITTER_NAME")),
                          ("user.email", ("GIT_AUTHOR_EMAIL", "GIT_COMMITTER_EMAIL"))):
            if all(self.env.get(e) for e in envs):
                continue
            if not self.run("config", key, check=False).stdout.strip():
                missing.append(key)
        return missing

    def put_back(self, sha):
        """Undoes what a failed run left: an unfinished rebase, commits after sha, and files it wrote."""
        git_dir = os.path.join(self.path, ".git")
        if os.path.isdir(os.path.join(git_dir, "rebase-merge")) or os.path.isdir(os.path.join(git_dir, "rebase-apply")):
            self.run("rebase", "--abort", check=False)
        if sha:
            self.run("reset", "-q", "--hard", sha, check=False)
        else:
            self.run("read-tree", "--empty", check=False)
        self.run("clean", "-fdq", check=False)

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

    def drop_unpushed(self):
        """Throws away every commit not on the fetched branch (they are made again from AutoNote's files)."""
        ref = self.remote_ref()
        if ref:
            self.run("reset", "-q", "--hard", ref)
            self.run("clean", "-fdq", check=False)
