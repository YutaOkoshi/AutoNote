"""share-meeting.sh: put one AutoNote meeting into the meeting-record repository as minutes + transcript."""
import hashlib
import os
import urllib.parse
from datetime import timedelta

from . import frontmatter as fmx
from . import index as indexmod
from . import mirror as mirrormod
from . import notify
from . import split
from .gitrepo import GitError, Repo
from .state import Lock, LockTimeout, State, flags, set_flag

NOTICE_TITLE = "会議の記録"


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


class VaultUnreadable(Exception):
    """VAULT_ROOT exists but cannot be listed (typically launchd without the Documents permission)."""


VAULT_UNREADABLE_TODO = ("会議ファイルのフォルダ（VAULT_ROOT）を読めません: %s。launchd から動かしているなら、"
                         "macOS がこのフォルダ（書類フォルダなど）の読み取りを許していない。README の「見回りを入れる」を見る")


def vault_files(vault_root):
    if not os.path.isdir(vault_root):
        return
    try:
        names = sorted(os.listdir(vault_root))
    except OSError as e:
        raise VaultUnreadable("%s (%s)" % (vault_root, e.strerror or type(e).__name__))
    for d in names:
        full = os.path.join(vault_root, d)
        if d.startswith(".") or d.startswith("_") or not os.path.isdir(full):
            continue
        try:
            inner = sorted(os.listdir(full))
        except OSError as e:
            raise VaultUnreadable("%s (%s)" % (full, e.strerror or type(e).__name__))
        for n in inner:
            if n.endswith(".md") and not n.startswith("."):
                yield os.path.join(full, n)


def find_vault_file(cfg, autonote_id, hint=None):
    """The vault file of a meeting, found by `autonote_id` in VAULT_ROOT/*/*.md (titles, and so names, change)."""
    candidates = []
    if hint:
        candidates.append(hint if os.path.isabs(hint) else os.path.join(cfg.vault_root, hint))
    for path in candidates + list(vault_files(cfg.vault_root)):
        try:
            if os.path.isfile(path) and fmx.read_file(path).get("autonote_id", "").strip() == autonote_id:
                return path
        except (OSError, UnicodeDecodeError):
            continue
    return None


def repo_files_for(repo_dir, autonote_id):
    """(minutes paths, transcript paths) in the clone that belong to this meeting, relative to the clone."""
    minutes, transcripts = [], []
    if not os.path.isdir(repo_dir):
        return minutes, transcripts
    for year in sorted(os.listdir(repo_dir)):
        ydir = os.path.join(repo_dir, year)
        if not indexmod.YEAR_RE.match(year) or not os.path.isdir(ydir):
            continue
        for sub, bucket in (("", minutes), ("文字起こし", transcripts)):
            d = os.path.join(ydir, sub) if sub else ydir
            if not os.path.isdir(d):
                continue
            for n in sorted(os.listdir(d)):
                p = os.path.join(d, n)
                if n.endswith(".md") and os.path.isfile(p) and fmx.read_file(p).get("autonote_id") == autonote_id:
                    bucket.append(os.path.relpath(p, repo_dir))
    return minutes, transcripts


def unique_stem(repo_dir, year, base, autonote_id):
    """AutoNote's rule (VaultWriter.uniqueURL): a name taken by another meeting gets -2, -3, …"""
    n = 1
    while True:
        stem = base if n == 1 else "%s-%d" % (base, n)
        taken = False
        for rel in ("%s/%s.md" % (year, stem), "%s/文字起こし/%s" % (year, split.transcript_name(stem))):
            p = os.path.join(repo_dir, rel)
            if os.path.isfile(p) and fmx.read_file(p).get("autonote_id") != autonote_id:
                taken = True
        if not taken:
            return stem
        n += 1


def short_date(date):
    try:
        y, m, d = date.split("-")
        return "%d/%d" % (int(m), int(d))
    except ValueError:
        return date


class Sharer:
    def __init__(self, cfg):
        self.cfg = cfg
        self.state = State(cfg)
        self.repo = Repo(cfg.repo_dir, cfg.remote, cfg.branch)
        self.notices = []

    # -- helpers -------------------------------------------------------------------------------------------------
    def _index(self):
        return indexmod.write(self.cfg.repo_dir, self.cfg.templates_dir)

    def _check_repo(self):
        if not self.repo.ok():
            msg = "会議記録の clone がありません: SHARE_REPO_DIR を確かめる（README の導入手順）"
            print(msg)
            self.state.add_todo(msg)
            return False
        if self.repo.dirty():
            msg = "会議記録の clone に未コミットの変更があります（スクリプト専用の clone を人が触った？）: %s" % self.cfg.repo_dir
            print(msg)
            self.state.add_todo(msg)
            return False
        return True

    def _sync(self, pre):
        """fetch + rebase (= git pull --rebase) + push. Returns ("ok"|"conflict"|"offline", detail)."""
        if self.repo.fetch():
            files = self.repo.rebase(self._index)
            if files:
                if pre:
                    self.repo.reset_hard(pre)
                return "conflict", files
            if self._index():
                self.repo.commit("index: rebuild")
            pushed, _ = self.repo.push()
            return ("ok", None) if pushed else ("offline", "push")
        return "offline", "fetch"

    def _conflict(self, files, autonote_id):
        msg = ("GitHub 側で直されています: %s。中身を AutoNote に反映してから載せ直す（スクリプトは上書きも --force の push もしない）"
               % "、".join(files))
        self.state.add_todo(msg)
        self.state.log("share", autonote_id, "conflict")
        self.notices.append(msg)
        print(msg)

    def _mirror(self, full=False):
        if not self.cfg.mirror_dir:
            return
        try:
            mirrormod.sync(self.cfg, self.state, self.cfg.repo_dir, full=full)
        except (mirrormod.MirrorError, OSError) as e:
            msg = "読む人向けの写しを作れませんでした（次の見回りで作り直す）: %s" % e
            print(msg)
            self.state.add_todo(msg)
            self.state.log("mirror", "failed", str(e))

    def _where(self, minutes_rel, year, stem):
        cfg = self.cfg
        if cfg.mirror_web_url:
            return " %s の「議事録/%s/%s」" % (cfg.mirror_web_url, year, stem)
        if cfg.repo_web_url:
            return " %s/blob/%s/%s" % (cfg.repo_web_url, urllib.parse.quote(cfg.branch),
                                       urllib.parse.quote(minutes_rel))
        if cfg.mirror_dir:
            return "（議事録/%s/%s）" % (year, stem)
        return "（%s）" % minutes_rel

    def send_notices(self):
        for text in self.notices:
            notify.send(self.cfg, self.state, NOTICE_TITLE, text)
        self.notices = []

    def flush_outbox(self):
        try:
            with Lock(self.cfg):
                notify.flush_outbox(self.cfg, self.state)
        except LockTimeout as e:
            print(e)

    # -- commands ------------------------------------------------------------------------------------------------
    def share_file(self, path, kind=None, customer=None, recording=None, trigger="manual"):
        path = os.path.abspath(path)
        if not os.path.isfile(path):
            print("会議ファイルがありません: %s" % path)
            return 1
        meeting = split.load_meeting(path)
        mid = meeting.autonote_id
        if not mid:
            print("frontmatter に autonote_id がありません: %s" % path)
            return 1
        try:
            with Lock(self.cfg):
                rc = self._share_locked(path, meeting, kind, customer, recording, trigger)
        except LockTimeout as e:
            print(e)
            return 1
        except GitError as e:
            print(e)
            self.state.log("share", mid, "git-error")
            self.state.add_pending({"autonote_id": mid, "meeting_file": path, "trigger": trigger,
                                    "kind": kind or "", "customer": customer or "", "recording": recording or "",
                                    "reason": "git"})
            return 1
        self.send_notices()
        return rc

    def _share_locked(self, path, m, kind, customer, recording, trigger):
        cfg, state = self.cfg, self.state
        mid = m.autonote_id
        rows = state.shared()
        prev = next((r for r in rows if r["autonote_id"] == mid), None)
        was_pending = any(r["autonote_id"] == mid for r in state.pending())
        kind = kind or (prev["kind"] if prev and prev["kind"] else "internal")
        if recording is None:
            recording = prev["recording"] if prev else ""
        parsed = split.parse_recording_name(recording) if recording else None
        if customer is None:
            customer = prev["customer"] if prev and prev["customer"] else ""
            if not customer and parsed:
                customer = parsed[2]
        if parsed and (parsed[0] != m.date or parsed[1] != m.start):
            warn = "録画の名前の日時（%s %s）と会議の日時（%s %s）が違います" % (parsed[0], parsed[1], m.date, m.start)
            print("警告: " + warn)
            state.log("share", mid, "warning", warn)
        recorded_by = cfg.default_recorded_by if kind == "customer" else cfg.owner_name
        deleted = bool(prev) and "recording_deleted" in flags(prev)
        rec_state = "対象外" if not recording else ("はい" if deleted else "まだ")

        if not self._check_repo():
            return 1
        repo_dir = cfg.repo_dir
        pre = self.repo.head()
        old_minutes, old_transcripts = repo_files_for(repo_dir, mid)
        stem = unique_stem(repo_dir, m.year, m.stem, mid)
        minutes, transcript = split.render_pair(m, stem, kind=kind, customer=customer, recorded_by=recorded_by,
                                                recording_state=rec_state)
        minutes_rel = "%s/%s.md" % (m.year, stem)
        transcript_rel = "%s/文字起こし/%s" % (m.year, split.transcript_name(stem)) if transcript else None
        _write(os.path.join(repo_dir, minutes_rel), minutes)
        if transcript:
            _write(os.path.join(repo_dir, transcript_rel), transcript)
        for rel in old_minutes + old_transcripts:
            if rel not in (minutes_rel, transcript_rel):
                os.remove(os.path.join(repo_dir, rel))
        self._index()
        verb = "update" if (old_minutes or old_transcripts) else "add"
        committed = self.repo.commit("%s: %s %s" % (verb, m.date, m.title))
        status, detail = self._sync(pre)
        if status == "conflict":
            self._conflict(detail, mid)
            return 1
        self._mirror()
        if status == "offline":
            state.add_pending({"autonote_id": mid, "meeting_file": path, "trigger": trigger, "kind": kind,
                               "customer": customer, "recording": recording, "reason": detail})
            state.log("share", mid, "pending (%s)" % detail)
            print("push できませんでした。clone に commit を残し、pending.tsv に入れました（--retry-pending で送り直す）")
            return 1

        row = prev or {"autonote_id": mid, "first_shared": cfg.today().isoformat(), "flags": ""}
        if not row.get("first_shared"):
            row["first_shared"] = cfg.today().isoformat()
        source_rel = os.path.relpath(path, cfg.vault_root)
        row.update({"minutes_file": minutes_rel, "transcript_file": transcript_rel or "",
                    "source_sha256": sha256_file(path),
                    "source_path": source_rel if not source_rel.startswith("..") else path,
                    "kind": kind, "customer": customer, "recorded_by": recorded_by, "recording": recording})
        set_flag(row, "unshared", False)
        set_flag(row, "missing_notified", False)
        notice = self._share_notice(row, m, minutes_rel, stem, committed or was_pending or not prev)
        if notice:
            self.notices.append(notice)
        if prev is None:
            rows.append(row)
        state.save_shared(rows)
        state.remove_pending(mid)
        state.log("share", mid, "ok %s" % verb if committed else "ok unchanged")
        print("共有しました: %s" % minutes_rel)
        return 0

    def _share_notice(self, row, m, minutes_rel, stem, changed):
        f = flags(row)
        dur = m.fm.get("duration_min", "").strip()
        when = "%s %s" % (short_date(m.date), m.start) + ("・%s 分" % dur if dur else "")
        where = self._where(minutes_rel, m.year, stem)
        deadline = ""
        if row.get("recording") and "recording_deleted" not in f:
            try:
                from datetime import date
                first = date.fromisoformat(row["first_shared"])
                due = first + timedelta(days=self.cfg.keep_days)
                deadline = " ／ 受け取り箱の録画を %d/%d までに消してください（ゴミ箱も）" % (due.month, due.day)
            except ValueError:
                pass
        if "notified_new" not in f:
            set_flag(row, "notified_new")
            if m.status == "transcript_only":
                return "文字起こしだけ並びました: %s（%s）%s%s" % (m.title, when, where, deadline)
            set_flag(row, "notified_minutes")
            return "議事録が並びました: %s（%s）%s%s" % (m.title, when, where, deadline)
        if m.status != "transcript_only" and "notified_minutes" not in f:
            set_flag(row, "notified_minutes")
            return "議事録が並びました: %s（%s）%s" % (m.title, when, where)
        if changed:
            return "更新しました: %s（%s）%s" % (m.title, when, where)
        return None

    def unshare(self, mid):
        try:
            with Lock(self.cfg):
                rc = self._unshare_locked(mid)
        except LockTimeout as e:
            print(e)
            return 1
        except GitError as e:
            print(e)
            self.state.add_pending({"autonote_id": mid, "trigger": "unshare", "reason": "git"})
            return 1
        self.send_notices()
        return rc

    def _unshare_locked(self, mid):
        state = self.state
        rows = state.shared()
        prev = next((r for r in rows if r["autonote_id"] == mid), None)
        if not self._check_repo():
            return 1
        repo_dir = self.cfg.repo_dir
        minutes, transcripts = repo_files_for(repo_dir, mid)
        if not minutes and not transcripts and prev is None:
            print("共有した記録がありません: %s" % mid)
            return 1
        title, date = mid, ""
        if minutes:
            fm = fmx.read_file(os.path.join(repo_dir, minutes[0]))
            title, date = fm.get("title", mid), fm.get("date", "")
        pre = self.repo.head()
        for rel in minutes + transcripts:
            os.remove(os.path.join(repo_dir, rel))
        self._index()
        self.repo.commit(("remove: %s %s" % (date, title)).replace("  ", " "))
        status, detail = self._sync(pre)
        if status == "conflict":
            self._conflict(detail, mid)
            return 1
        self._mirror()
        if status == "offline":
            state.add_pending({"autonote_id": mid, "trigger": "unshare", "reason": detail})
            state.log("share", mid, "unshare pending (%s)" % detail)
            print("push できませんでした。pending.tsv に入れました")
            return 1
        if prev is not None:
            set_flag(prev, "unshared")
            state.save_shared(rows)
        state.remove_pending(mid)
        state.log("share", mid, "unshared")
        print("取り下げました: %s" % mid)
        return 0

    def push_ahead(self):
        """Pushes commits left in the clone by an earlier run whose push failed."""
        try:
            with Lock(self.cfg):
                if not self.repo.ok() or self.repo.dirty():
                    return 0
                self.repo.fetch()
                if self.repo.ahead() == 0:
                    return 0
                status, detail = self._sync(self.repo.head())
                if status == "conflict":
                    self._conflict(detail, "-")
                    return 1
                if status == "offline":
                    return 1
                self._mirror()
                return 0
        except (LockTimeout, GitError) as e:
            print(e)
            return 1
        finally:
            self.send_notices()

    def report_vault_unreadable(self, e):
        msg = VAULT_UNREADABLE_TODO % e
        print(msg)
        self.state.add_todo(msg)
        self.state.log("share", "-", "vault unreadable")

    def retry_pending(self):
        rc = self.push_ahead()
        for row in self.state.pending():
            mid = row["autonote_id"]
            if row["trigger"] == "unshare":
                rc |= self.unshare(mid)
                continue
            try:
                path = find_vault_file(self.cfg, mid, row["meeting_file"] or None)
            except VaultUnreadable as e:
                self.report_vault_unreadable(e)
                return 1
            if not path:
                print("会議ファイルが見つかりません（pending のまま）: %s" % mid)
                self.state.log("share", mid, "retry: vault file missing")
                rc = 1
                continue
            rc |= self.share_file(path, kind=row["kind"] or None, customer=row["customer"] or None,
                                  recording=row["recording"] or None, trigger=row["trigger"] or "retry")
        return rc

    def rebuild_index(self):
        try:
            with Lock(self.cfg):
                if not self._check_repo():
                    return 1
                pre = self.repo.head()
                self.repo.fetch()
                self.repo.rebase(self._index)
                self._index()
                self.repo.commit("index: rebuild")
                status, detail = self._sync(pre)
                if status == "conflict":
                    self._conflict(detail, "-")
                    return 1
                self._mirror()
                if status == "offline":
                    print("push できませんでした（次の実行で送り直す）")
                    return 1
                print("INDEX.md を作り直しました")
                return 0
        except (LockTimeout, GitError) as e:
            print(e)
            return 1
        finally:
            self.send_notices()

    def rebuild_mirror(self):
        if not self.cfg.mirror_dir:
            print("MIRROR_DIR が設定されていません")
            return 1
        try:
            with Lock(self.cfg):
                mirrormod.sync(self.cfg, self.state, self.cfg.repo_dir, full=True)
        except (mirrormod.MirrorError, OSError) as e:
            print("写しを作り直せませんでした: %s" % e)
            self.state.add_todo("読む人向けの写しを作れませんでした（次の見回りで作り直す）: %s" % e)
            return 1
        except LockTimeout as e:
            print(e)
            return 1
        print("読む人向けの写しを作り直しました: %s" % self.cfg.mirror_dir)
        return 0


def _write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)
