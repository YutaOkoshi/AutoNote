"""git in the script-only clone. Never force-pushes; never prompts (GIT_TERMINAL_PROMPT=0).

Every call runs with hooks and commit signing off: a global pre-commit hook or commit.gpgsign is the user's setting
for their own work, and must not make the script's commits fail half way.

The script owns INDEX.md and the year folders (2026/…) and nothing else. It commits only those, puts only those
back after a run that died, and leaves untracked files elsewhere (.DS_Store, a note) alone.
"""
import os
import re
import subprocess

OWN_RE = re.compile(r"^(?:INDEX\.md$|\d{4}/)")


class GitError(Exception):
    pass


def is_own(path):
    return bool(OWN_RE.match(path))


def scrub(text):
    """Hides credentials written into a remote URL (https://user:token@host/…) before a message is shown or kept."""
    return re.sub(r"://[^/@\s]+@", "://***@", text or "")


def _first_line(text):
    lines = [l.strip() for l in scrub(text).splitlines() if l.strip()]
    return lines[0][:200] if lines else ""


class Repo:
    def __init__(self, path, remote, branch, net_timeout=120):
        self.path = path
        self.remote = remote
        self.branch = branch
        self.net_timeout = net_timeout  # fetch / push / ls-remote: a stalled connection must not hold the lock
        self.last_error = ""
        self.env = dict(os.environ)
        self.env.update({"GIT_TERMINAL_PROMPT": "0", "GIT_EDITOR": "true", "GIT_SEQUENCE_EDITOR": "true",
                         "GIT_MERGE_AUTOEDIT": "no", "GIT_LITERAL_PATHSPECS": "1"})

    PREFIX = ["git", "-c", "core.quotePath=false", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false",
              "-c", "tag.gpgsign=false"]

    def run(self, *args, check=True, timeout=None):
        """Runs git. With a timeout, a command that does not finish returns None (or raises when check is on)."""
        try:
            p = subprocess.run(self.PREFIX + list(args), cwd=self.path, env=self.env, capture_output=True, text=True,
                               timeout=timeout)
        except subprocess.TimeoutExpired:
            if check:
                raise GitError("git %s が %d 秒たっても終わりません" % (args[0], timeout))
            return None
        if check and p.returncode != 0:
            detail = scrub((p.stderr or "").strip() or (p.stdout or "").strip()) or "(出力なし)"
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

    def ok(self):
        return os.path.isdir(os.path.join(self.path, ".git")) or os.path.isfile(os.path.join(self.path, ".git"))

    def head(self):
        p = self.run("rev-parse", "--verify", "-q", "HEAD", check=False)
        return p.stdout.strip() if p.returncode == 0 else None

    # -- what is not committed ---------------------------------------------------------------------------------------
    def changes(self):
        """[(two-letter status, path)] of everything not committed. Untracked files are listed one by one."""
        out = self.run("status", "--porcelain", "-z", "--untracked-files=all", "--no-renames").stdout
        return [(e[:2], e[3:]) for e in out.split("\0") if len(e) > 3]

    def foreign_changes(self):
        """Tracked files the script never writes that have uncommitted changes (a person edited the clone)."""
        return sorted(p for st, p in self.changes() if st != "??" and not is_own(p))

    def dirty(self):
        """Anything the script would trip over: its own files changed, or a tracked file edited by a person.
        Untracked files outside the script's folders do not count."""
        return any(is_own(p) or st != "??" for st, p in self.changes())

    def _abort_rebase(self):
        git_dir = os.path.join(self.path, ".git")
        if os.path.isdir(os.path.join(git_dir, "rebase-merge")) or os.path.isdir(os.path.join(git_dir, "rebase-apply")):
            self.run("rebase", "--abort", check=False)

    def _remove_untracked_own(self):
        for st, p in self.changes():
            if st == "??" and is_own(p):
                try:
                    os.remove(os.path.join(self.path, p))
                except OSError:
                    pass

    def restore_own(self):
        """Puts the script's own files back to the last commit: what a run that died half way left behind.
        Returns the paths it put back. Files the script does not write are not touched."""
        self._abort_rebase()
        own = sorted(p for _, p in self.changes() if is_own(p))
        if not own:
            return []
        if self.head():
            self.run("reset", "-q", check=False)  # unstage; the working tree stays
            for p in own:
                if self.run("cat-file", "-e", "HEAD:" + p, check=False).returncode == 0:
                    self.run("checkout", "-q", "HEAD", "--", p)
        else:
            self.run("read-tree", "--empty", check=False)
        self._remove_untracked_own()
        return own

    def put_back(self, sha):
        """Undoes what a failed run left: an unfinished rebase, commits after sha, and the files it wrote.
        Call it only after the run looked at the clone and found nothing a person changed."""
        self._abort_rebase()
        if sha:
            self.run("reset", "-q", "--hard", sha, check=False)
        else:
            self.run("read-tree", "--empty", check=False)
        self._remove_untracked_own()

    def commit(self, message):
        """Commits the script's own files (INDEX.md and the year folders). False when there is nothing to commit."""
        own = sorted(p for _, p in self.changes() if is_own(p))
        if not own:
            return False
        self.run("add", "-A", "--", *own)
        if self.run("diff", "--cached", "--quiet", check=False).returncode == 0:
            return False
        self.run("commit", "-q", "-m", message)
        return True

    # -- the remote --------------------------------------------------------------------------------------------------
    def fetch(self):
        p = self.run("fetch", "-q", self.remote, self.branch, check=False, timeout=self.net_timeout)
        if p is None:
            self.last_error = "時間切れ（%d 秒）" % self.net_timeout
            return False
        self.last_error = _first_line(p.stderr)
        return p.returncode == 0

    def why_offline(self):
        """After a failed fetch: (code, sentence, git's own words). Tells an empty repository and a wrong branch name
        apart from a network or sign-in problem, which retrying will not fix."""
        fetch_error = self.last_error
        p = self.run("ls-remote", "--heads", self.remote, check=False, timeout=self.net_timeout)
        if p is None:
            return "timeout", "置き場から %d 秒たっても返事がありません" % self.net_timeout, ""
        if p.returncode != 0:
            return ("unreachable", "置き場につながりません（ネットワーク・git の認証・置き場の URL を確かめる）",
                    _first_line(p.stderr) or fetch_error)
        heads = sorted(l.split("refs/heads/", 1)[1].strip() for l in p.stdout.splitlines() if "refs/heads/" in l)
        if not heads:
            return ("empty", "置き場が空です（ブランチが 1 つもありません）。README の導入の手順 3（最初の commit と push）"
                    "を先に行う", "")
        if self.branch not in heads:
            return ("branch", "置き場にブランチ %s がありません（あるのは %s）。config.env の SHARE_BRANCH を置き場の"
                    "ブランチ名に合わせる" % (self.branch, "、".join(heads[:5])), "")
        return "fetch", "置き場から取り込めません", fetch_error

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
        p = self.run("push", "-q", self.remote, "HEAD:%s" % self.branch, check=False, timeout=self.net_timeout)
        if p is None:
            return False, "時間切れ（%d 秒）" % self.net_timeout
        return p.returncode == 0, _first_line(p.stderr)

    def drop_unpushed(self):
        """Throws away every commit not on the fetched branch (they are made again from AutoNote's files)."""
        ref = self.remote_ref()
        if ref:
            self._abort_rebase()
            self.run("reset", "-q", "--hard", ref)
            self._remove_untracked_own()
