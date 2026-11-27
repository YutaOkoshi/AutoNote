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
from .names import nfc, settle
from .state import Lock, LockTimeout, State, flags, set_flag

NOTICE_TITLE = "会議の記録"
# What the patrol counts as a recording in the inbox. Wider than what the guides ask for (templates.EXTS_TEXT):
# AutoNote cannot import .mov, but one left in the inbox still has to be noticed and deleted.
RECORDING_EXTS = (".mp4", ".m4a", ".mp3", ".wav", ".mov")


def recording_name(value):
    """What --recording means: the file name in the inbox. A dragged-in path is cut to its name; the Unicode form is
    made NFC so it compares equal to the name the synced folder lists (which may be NFD)."""
    return nfc(os.path.basename((value or "").rstrip("/")))


def inbox_recordings(inbox_dir):
    """Recording file names in the inbox (NFC). Raises OSError when the folder cannot be read."""
    return sorted(nfc(n) for n in os.listdir(inbox_dir)
                  if not n.startswith(".") and n.lower().endswith(RECORDING_EXTS)
                  and os.path.isfile(os.path.join(inbox_dir, n)))


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
    """(minutes paths, transcript paths) in the clone that belong to this meeting, relative to the clone.

    On the way, names in the year folders that are not NFC on disk are renamed to NFC (names.settle), so the paths
    returned here compare equal, as plain strings, to the NFC paths this package writes."""
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
                p = settle(os.path.join(d, n))
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
        self.repo = Repo(cfg.repo_dir, cfg.remote, cfg.branch, net_timeout=cfg.git_timeout)
        self.notices = []
        self._reported = set()  # notices already queued in this run (one per kind and subject)
        self._pre = None
        self._began = False  # True once this run recorded the clone's HEAD and may have written to the clone
        self.problems = []  # failures the owner should hear about; the patrol puts them in todo.md and one notice
        self.offline_why = ""

    # -- helpers -------------------------------------------------------------------------------------------------
    def _index(self):
        return indexmod.write(self.cfg.repo_dir, self.cfg.templates_dir)

    def _check_repo(self):
        """None when the clone can be used, else the reason (already printed and written to todo.md)."""
        msg = None
        if not self.repo.ok():
            msg = "会議記録の clone がありません: SHARE_REPO_DIR を確かめる（README の導入手順）"
        else:
            missing = self.repo.identity_missing()
            if missing:
                msg = ("git の %s が設定されていないので commit できません。`git -C \"%s\" config user.name \"<名前>\"` と "
                       "`git -C \"%s\" config user.email \"<メール>\"` で設定してから --retry-pending する"
                       % (" と ".join(missing), self.cfg.repo_dir, self.cfg.repo_dir))
            else:
                # What a run that died half way left in the script's own files is put back, not reported.
                restored = self.repo.restore_own()
                if restored:
                    print("前の実行が残した書きかけを元に戻しました: %s" % "、".join(restored[:5]))
                    self.state.log("share", "-", "restored", str(len(restored)))
                foreign = self.repo.foreign_changes()
                if foreign:
                    msg = ("会議記録の clone に、スクリプトが書かないファイルの未コミットの変更があります: %s。スクリプト専用の clone "
                           "なので、commit するか元に戻してから --retry-pending する（%s）"
                           % ("、".join(foreign[:5]) + (" ほか" if len(foreign) > 5 else ""), self.cfg.repo_dir))
        if msg:
            print(msg)
            self.state.add_todo(msg)
            self._problem(msg)
        return msg

    def _problem(self, text):
        if text not in self.problems:
            self.problems.append(text)

    def _offline(self, code, sentence, detail=""):
        """Remembers why the repository could not be reached, in words that say what to check."""
        self.offline_why = sentence + ("（git: %s）" % detail if detail else "")
        self._problem("置き場に送れていません: %s" % sentence)
        self.state.log("share", "-", "offline", code)
        return code

    def _begin(self):
        self._pre = self.repo.head()
        self._began = True
        return self._pre

    def _put_back(self):
        """After an error: undo what this run wrote to the clone. Nothing to undo before _begin()."""
        if self._began:
            self.repo.put_back(self._pre)

    def _sync(self, pre):
        """fetch + rebase (= git pull --rebase) + push. Returns ("ok"|"conflict"|"offline", detail).

        On a conflict every commit not yet pushed is dropped and the clone is set to the fetched branch, so one bad
        commit cannot block later runs. What was dropped is made again from AutoNote's files (pending.tsv, and the
        patrol's re-share, since source_sha256 only moves on success).
        """
        if not self.repo.fetch():
            return "offline", self._offline(*self.repo.why_offline())
        files = self.repo.rebase(self._index)
        if files:
            self.repo.drop_unpushed()
            return "conflict", files
        if self._index():
            self.repo.commit("index: rebuild")
        pushed, err = self.repo.push()
        if pushed:
            return "ok", None
        return "offline", self._offline("push", "置き場に push できません（書き込みの権限・ブランチの保護・ネットワークを"
                                        "確かめる）", err)

    def _report_once(self, key, msg, todo=True):
        if key in self._reported:
            return
        self._reported.add(key)
        if todo:
            self.state.add_todo(msg)
        self.notices.append(msg)
        print(msg)

    def _conflict(self, files, autonote_id):
        msg = ("GitHub 側で直されています: %s。まだ送っていなかった変更を捨てて置き場にそろえました。捨てた分は AutoNote の中身で"
               "載せ直すので、GitHub 側の直しは上書きされます（残したい直しは AutoNote に反映する）" % "、".join(files))
        self.state.log("share", autonote_id, "conflict")
        self._report_once(("conflict", tuple(files)), msg)

    def _mirror(self, full=False):
        """Brings the reader copy in line. False when it could not be made (already printed and in todo.md)."""
        if not self.cfg.mirror_dir:
            return True
        try:
            mirrormod.sync(self.cfg, self.state, self.cfg.repo_dir, full=full)
            return True
        except (mirrormod.MirrorError, OSError) as e:
            msg = "読む人向けの写しを作れませんでした（次の見回りで作り直す）: %s" % e
            print(msg)
            self.state.add_todo(msg)
            self._problem(msg)
            self.state.log("mirror", "failed", str(e))
            return False

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

    def report_vault_unreadable(self, e):
        self.state.log("share", "-", "vault unreadable")
        self._report_once("vault", VAULT_UNREADABLE_TODO % e)

    def _pending(self, mid, path, trigger, kind, customer, recording, reason):
        self.state.add_pending({"autonote_id": mid, "meeting_file": path or "", "trigger": trigger, "kind": kind or "",
                                "customer": customer or "", "recording": recording or "", "reason": reason})

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
        if recording is not None:
            recording = recording_name(recording)
        try:
            with Lock(self.cfg):
                self._began = False
                try:
                    rc = self._share_locked(path, meeting, kind, customer, recording, trigger)
                except GitError as e:
                    print(e)
                    self._put_back()
                    self.state.log("share", mid, "git-error")
                    self._pending(mid, path, trigger, kind, customer, recording, "git")
                    rc = 1
                except Exception:
                    self._put_back()  # do not leave half-written files for the next run
                    raise
        except LockTimeout as e:
            print("%s（pending.tsv に入れました。--retry-pending か見回りで送り直す）" % e)
            self._pending(mid, path, trigger, kind, customer, recording, "lock")
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
        if recording and cfg.inbox_dir:
            try:
                in_inbox = recording in inbox_recordings(cfg.inbox_dir)
            except OSError:
                in_inbox = None  # cannot tell; the patrol reports an unreadable inbox
            if in_inbox:
                # Seen now counts as seen: a recording deleted right after "議事録が並びました" (before the next
                # patrol ever looks) is then recognised as deleted, not as a misspelt name.
                seen = state.inbox_seen()
                if not any(recording_name(r["recording"]) == recording for r in seen):
                    seen.append({"recording": recording, "first_seen": cfg.today().isoformat(), "flags": ""})
                    state.save_inbox_seen(seen)
            elif in_inbox is False:
                print("警告: 受け取り箱にありません: %s（名前の打ち間違いなら --recording を直して載せ直す。同期が遅れて"
                      "いるだけなら気にしなくてよい）" % recording)
                state.log("share", mid, "warning", "recording not in inbox")
        recorded_by = cfg.default_recorded_by if kind == "customer" else cfg.owner_name
        deleted = bool(prev) and "recording_deleted" in flags(prev)
        rec_state = "対象外" if not recording else ("はい" if deleted else "まだ")

        reason = self._check_repo()
        if reason:
            self._pending(mid, path, trigger, kind, customer, recording, "clone")
            return 1
        repo_dir = cfg.repo_dir
        pre = self._begin()
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
            self._mirror()
            self._pending(mid, path, trigger, kind, customer, recording, "conflict")
            return 1
        self._mirror()
        if status == "offline":
            self._pending(mid, path, trigger, kind, customer, recording, detail)
            state.log("share", mid, "pending (%s)" % detail)
            print("push できませんでした: %s。clone に commit を残し、pending.tsv に入れました（--retry-pending で送り直す）"
                  % self.offline_why)
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
                self._began = False
                try:
                    rc = self._unshare_locked(mid)
                except GitError as e:
                    print(e)
                    self._put_back()
                    self._pending(mid, "", "unshare", "", "", "", "git")
                    rc = 1
                except Exception:
                    self._put_back()
                    raise
        except LockTimeout as e:
            print("%s（pending.tsv に入れました）" % e)
            self._pending(mid, "", "unshare", "", "", "", "lock")
            return 1
        self.send_notices()
        return rc

    def _unshare_locked(self, mid):
        state = self.state
        rows = state.shared()
        prev = next((r for r in rows if r["autonote_id"] == mid), None)
        if self._check_repo():
            self._pending(mid, "", "unshare", "", "", "", "clone")
            return 1
        repo_dir = self.cfg.repo_dir
        minutes, transcripts = repo_files_for(repo_dir, mid)
        if not minutes and not transcripts and (prev is None or "unshared" in flags(prev)):
            if any(r["autonote_id"] == mid for r in state.pending()):
                # e.g. shared and taken back while offline: both commits went out with the earlier push
                state.remove_pending(mid)
                state.log("share", mid, "unshare settled")
                print("取り下げは済んでいます: %s" % mid)
                return 0
            print("共有した記録がありません: %s" % mid)
            return 1
        title, date = mid, ""
        if minutes:
            fm = fmx.read_file(os.path.join(repo_dir, minutes[0]))
            title, date = fm.get("title", mid), fm.get("date", "")
        pre = self._begin()
        for rel in minutes + transcripts:
            os.remove(os.path.join(repo_dir, rel))
        self._index()
        self.repo.commit(("remove: %s %s" % (date, title)).replace("  ", " "))
        status, detail = self._sync(pre)
        if status == "conflict":
            self._conflict(detail, mid)
            self._mirror()
            self._pending(mid, "", "unshare", "", "", "", "conflict")
            return 1
        self._mirror()
        if status == "offline":
            self._pending(mid, "", "unshare", "", "", "", detail)
            state.log("share", mid, "unshare pending (%s)" % detail)
            print("push できませんでした: %s。pending.tsv に入れました" % self.offline_why)
            return 1
        if prev is not None:
            set_flag(prev, "unshared")
            state.save_shared(rows)
        state.remove_pending(mid)
        state.log("share", mid, "unshared")
        print("取り下げました: %s" % mid)
        return 0

    def recording_deleted(self, mid):
        """share-meeting.sh --recording-deleted <id>: the owner says the recording of this meeting is gone.
        The way to reach `source_recording_deleted: はい` when there is no inbox folder for the patrol to watch."""
        try:
            with Lock(self.cfg):
                self._began = False
                rows = self.state.shared()
                row = next((r for r in rows if r["autonote_id"] == mid and "unshared" not in flags(r)), None)
                if row is None:
                    print("共有した記録がありません: %s" % mid)
                    return 1
                if not row["recording"]:
                    print("この会議は --recording なしで共有されています（録画の印は「対象外」）: %s。録画があるなら、"
                          "--recording <録画のファイル名> を付けて載せ直してから" % mid)
                    return 1
                set_flag(row, "recording_deleted")
                self.state.save_shared(rows)
                self.state.log("share", mid, "recording deleted (by hand)")
                try:
                    rc = self.apply_deleted_flags()
                except GitError as e:
                    print(e)
                    self._put_back()
                    rc = 1
                if rc == 0 and self.repo.ok() and self.repo.ahead() > 0:
                    rc = self.push_ahead()  # the line is already in a commit that has not gone out yet
        except LockTimeout as e:
            print(e)
            return 1
        finally:
            self.send_notices()
        print("録画を「消した」にしました: %s" % mid if rc == 0
              else "録画を「消した」と記録しました。置き場への反映は次の送り直し（--retry-pending か見回り）で行います: %s" % mid)
        return rc

    def apply_deleted_flags(self):
        """Under the lock: writes `source_recording_deleted: はい` into the minutes of every meeting whose row has
        the recording_deleted flag, and pushes. The flag in shared.tsv is the truth and the repository follows it,
        so a commit lost to a conflict or a failed push is simply made again on a later run. Needs no vault file
        (launchd may not be allowed to read the vault)."""
        cfg = self.cfg
        todo = []
        for row in self.state.shared():
            f = flags(row)
            rel = nfc(row["minutes_file"])
            path = os.path.join(cfg.repo_dir, rel)
            if "recording_deleted" not in f or "unshared" in f or not rel or not os.path.isfile(path):
                continue
            with open(path, encoding="utf-8") as fh:
                text = fh.read()
            fm = fmx.parse(fmx.split_document(text)[0])
            if fm.get("source_recording_deleted") != "はい":
                todo.append((row, path, text, fm))
        if not todo:
            return 0
        if self._check_repo():
            return 1
        pre = self._begin()
        for row, path, text, fm in todo:
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(fmx.set_value(text, "source_recording_deleted", "はい"))
            self.repo.commit(("update: %s %s" % (fm.get("date", ""), fm.get("title", row["autonote_id"]))).strip())
        status, detail = self._sync(pre)
        if status == "conflict":
            self._conflict(detail, "-")  # the commits were dropped; the flags stay, so the next run writes them again
            self._mirror()
            return 1
        self._mirror()
        for row, _, _, _ in todo:
            self.state.log("share", row["autonote_id"],
                           "recording deleted" + ("" if status == "ok" else " (push later)"))
        if status == "offline":
            print("push できませんでした: %s（clone に commit を残しました。次の実行で送り直す）" % self.offline_why)
            return 1
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
                    self._mirror()
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
                if self._check_repo():
                    return 1
                pre = self._begin()
                self._index()
                self.repo.commit("index: rebuild")
                status, detail = self._sync(pre)  # fetches, rebases and writes the index again over what came in
                if status == "conflict":
                    self._conflict(detail, "-")
                    return 1
                self._mirror()
                if status == "offline":
                    print("push できませんでした: %s（次の実行で送り直す）" % self.offline_why)
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
