"""State files under SHARE_STATE_DIR: TSV tables, todo.md, the mkdir lock, and the monthly logs."""
import os
import shutil
import tempfile
import time

SHARED_COLUMNS = ["autonote_id", "minutes_file", "transcript_file", "source_sha256", "source_path", "first_shared",
                  "kind", "customer", "recorded_by", "recording", "flags"]
PENDING_COLUMNS = ["autonote_id", "meeting_file", "trigger", "kind", "customer", "recording", "added_at", "reason"]
INBOX_SEEN_COLUMNS = ["recording", "first_seen", "flags"]


def atomic_write(path, text):
    d = os.path.dirname(path)
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=d)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.remove(tmp)
        raise


def _clean(v):
    return str(v if v is not None else "").replace("\t", " ").replace("\r", " ").replace("\n", " ")


def read_tsv(path, columns):
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8") as f:
        lines = [l.rstrip("\n") for l in f if l.strip()]
    if not lines:
        return []
    head = lines[0].split("\t")
    rows = []
    for line in lines[1:]:
        cells = line.split("\t")
        row = {c: "" for c in columns}
        row.update(dict(zip(head, cells)))
        rows.append(row)
    return rows


def write_tsv(path, columns, rows):
    out = ["\t".join(columns)]
    for r in rows:
        out.append("\t".join(_clean(r.get(c, "")) for c in columns))
    atomic_write(path, "\n".join(out) + "\n")


def flags(row):
    return set(x for x in (row.get("flags") or "").split(",") if x)


def set_flag(row, flag, on=True):
    f = flags(row)
    if on:
        f.add(flag)
    else:
        f.discard(flag)
    row["flags"] = ",".join(sorted(f))


class State:
    def __init__(self, cfg):
        self.cfg = cfg
        self.dir = cfg.state_dir
        os.makedirs(self.dir, exist_ok=True)

    def path(self, name):
        return os.path.join(self.dir, name)

    # shared.tsv
    def shared(self):
        return read_tsv(self.path("shared.tsv"), SHARED_COLUMNS)

    def save_shared(self, rows):
        write_tsv(self.path("shared.tsv"), SHARED_COLUMNS, rows)

    # pending.tsv
    def pending(self):
        return read_tsv(self.path("pending.tsv"), PENDING_COLUMNS)

    def add_pending(self, row):
        rows = [r for r in self.pending() if not (r["autonote_id"] == row["autonote_id"])]
        full = {c: "" for c in PENDING_COLUMNS}
        full.update(row)
        full["added_at"] = self.cfg.now().isoformat(timespec="seconds")
        rows.append(full)
        write_tsv(self.path("pending.tsv"), PENDING_COLUMNS, rows)

    def remove_pending(self, autonote_id):
        rows = self.pending()
        kept = [r for r in rows if r["autonote_id"] != autonote_id]
        if len(kept) != len(rows):
            write_tsv(self.path("pending.tsv"), PENDING_COLUMNS, kept)

    # inbox-seen.tsv
    def inbox_seen(self):
        return read_tsv(self.path("inbox-seen.tsv"), INBOX_SEEN_COLUMNS)

    def save_inbox_seen(self, rows):
        write_tsv(self.path("inbox-seen.tsv"), INBOX_SEEN_COLUMNS, rows)

    # todo.md
    def add_todo(self, text):
        path = self.path("todo.md")
        text = _clean(text)
        current = ""
        if os.path.exists(path):
            with open(path, encoding="utf-8") as f:
                current = f.read()
        if any(line.startswith("- [ ] ") and line.endswith(" " + text) for line in current.splitlines()):
            return
        if not current:
            current = "# 要対応（共有スクリプトが書く。済んだら [x] にするか行を消す）\n\n"
        stamp = self.cfg.now().strftime("%Y-%m-%d %H:%M")
        atomic_write(path, current + "- [ ] %s %s\n" % (stamp, text))

    # logs/<kind>-YYYY-MM.log
    def log(self, kind, *fields):
        now = self.cfg.now()
        os.makedirs(self.cfg.log_dir, exist_ok=True)
        path = os.path.join(self.cfg.log_dir, "%s-%s.log" % (kind, now.strftime("%Y-%m")))
        with open(path, "a", encoding="utf-8") as f:
            f.write("\t".join([now.isoformat(timespec="seconds")] + [_clean(x) for x in fields]) + "\n")


class LockTimeout(Exception):
    pass


class Lock:
    """`state/lock` taken with mkdir (macOS has no flock(1)). Holds `owner` = "<pid>\t<time>". Reentrant per process."""
    _depth = {}

    def __init__(self, cfg):
        self.cfg = cfg
        self.path = os.path.join(cfg.state_dir, "lock")

    def __enter__(self):
        depth = Lock._depth.get(self.path, 0)
        if depth == 0:
            self._acquire()
        Lock._depth[self.path] = depth + 1
        return self

    def __exit__(self, *exc):
        depth = Lock._depth.get(self.path, 1) - 1
        Lock._depth[self.path] = depth
        if depth == 0:
            shutil.rmtree(self.path, ignore_errors=True)
        return False

    def _acquire(self):
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        deadline = time.time() + self.cfg.lock_timeout
        while True:
            try:
                os.mkdir(self.path)
                with open(os.path.join(self.path, "owner"), "w", encoding="utf-8") as f:
                    f.write("%d\t%s\n" % (os.getpid(), time.strftime("%Y-%m-%dT%H:%M:%S")))
                return
            except FileExistsError:
                if self._stale():
                    shutil.rmtree(self.path, ignore_errors=True)
                    continue
                if time.time() > deadline:
                    raise LockTimeout("ロックを %d 秒待っても取れません: %s" % (self.cfg.lock_timeout, self.path))
                time.sleep(self.cfg.lock_poll)

    def _stale(self):
        owner = os.path.join(self.path, "owner")
        try:
            with open(owner, encoding="utf-8") as f:
                pid = int(f.read().split("\t", 1)[0])
        except (OSError, ValueError):
            # Between mkdir and writing owner, or a broken lock: give it a moment before calling it stale.
            try:
                return time.time() - os.stat(self.path).st_mtime > 10
            except OSError:
                return False
        if pid == os.getpid():
            return False
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return True
        except PermissionError:
            return False
        return False
