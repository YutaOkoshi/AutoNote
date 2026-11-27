"""daily-patrol.sh: once a day (launchd). Never deletes minutes or transcripts, and never touches the vault."""
import json
import os
import subprocess
from datetime import date

from . import frontmatter as fmx
from .share import (NOTICE_TITLE, Sharer, VaultUnreadable, find_vault_file, inbox_recordings, recording_name,
                    sha256_file)
from .state import Lock, LockTimeout, flags, set_flag
from .gitrepo import GitError


def _days(since, today):
    try:
        return (today - date.fromisoformat(since)).days
    except (TypeError, ValueError):
        return None


class Patrol:
    def __init__(self, cfg):
        self.cfg = cfg
        self.sharer = Sharer(cfg)
        self.state = self.sharer.state
        self.rc = 0

    def run(self):
        steps = [("outbox", self.sharer.flush_outbox),
                 # 1. pushes and shares that failed earlier
                 ("retry", self.retry),
                 # 2. re-share meetings edited in AutoNote's window or translated later (those emit no Automation)
                 ("reshare", self.reshare_changed),
                 # 3. recordings left in the inbox
                 ("recordings", self.check_inbox if self.cfg.inbox_dir else self.ask_after_keep_days)]
        # 4. shared meetings that AutoNote no longer has
        if self.cfg.autonote_cli:
            steps.append(("autonote", self.check_autonote))
        # the reader copy: rebuilds whatever is missing or stale (also after a failed run)
        if self.cfg.mirror_dir:
            steps.append(("mirror", self.mirror))
        for name, step in steps:
            try:
                step()
            except LockTimeout as e:
                print(e)
                self.rc = 1
            except Exception as e:  # one broken step must not stop the others
                print("見回りの %s で止まりました: %s: %s" % (name, type(e).__name__, e))
                self.state.log("patrol", name, "error", type(e).__name__)
                self.rc = 1
            try:
                self.sharer.send_notices()  # e.g. "VAULT_ROOT を読めません" queued by a step
            except Exception as e:
                print("知らせを送る途中で止まりました: %s: %s" % (type(e).__name__, e))
                self.rc = 1
        self.state.log("patrol", "done", "rc=%d" % self.rc)
        return self.rc

    def retry(self):
        self.rc |= self.sharer.retry_pending()

    def mirror(self):
        with Lock(self.cfg):
            self.sharer._mirror()

    def notify(self, text, todo=False):
        from . import notify
        if todo:
            self.state.add_todo(text)
        notify.send(self.cfg, self.state, NOTICE_TITLE, text)

    def live_rows(self):
        return [r for r in self.state.shared() if "unshared" not in flags(r)]

    def reshare_changed(self):
        for row in self.live_rows():
            try:
                path = find_vault_file(self.cfg, row["autonote_id"], row["source_path"] or None)
            except VaultUnreadable as e:
                self.sharer.report_vault_unreadable(e)
                self.rc = 1
                return
            if not path:
                continue
            if sha256_file(path) != row["source_sha256"]:
                self.rc |= self.sharer.share_file(path, trigger="patrol")

    def ask_after_keep_days(self):
        """No inbox folder to look at: ask once, KEEP_DAYS after sharing, whether the recording was deleted."""
        today = self.cfg.today()
        with Lock(self.cfg):
            rows = self.state.shared()
            asked = []
            for row in rows:
                f = flags(row)
                if not row["recording"] or "unshared" in f or "reminded_keep" in f or "recording_deleted" in f:
                    continue
                days = _days(row["first_shared"], today)
                if days is not None and days >= self.cfg.keep_days:
                    set_flag(row, "reminded_keep")
                    asked.append(row["recording"])
            if asked:
                self.state.save_shared(rows)
        for rec in asked:
            self.notify("録画は消しましたか: 受け取り箱の %s（共有から %d 日たちました。録画の道具の側の元とゴミ箱も）"
                        % (rec, self.cfg.keep_days))

    def check_inbox(self):
        """Reminders for recordings left in the inbox, and `source_recording_deleted: はい` when one is gone.

        Days count from the first share (or from the day the patrol first saw a file nobody shared), and a reminder
        goes out on the due day (days >= KEEP_DAYS), like ask_after_keep_days. A shared recording counts as deleted
        only once it has been seen in the inbox and then is not there; a name never seen gets one "見当たらない"
        notice instead (a typo, or the synced folder is late). An inbox with no recordings at all skips both checks,
        because a synced folder can look empty for a while.
        """
        cfg = self.cfg
        today = cfg.today()
        try:
            present = inbox_recordings(cfg.inbox_dir)
        except OSError as e:
            print("受け取り箱を読めません: %s" % e)
            self.state.add_todo("受け取り箱（INBOX_DIR）を読めません: %s" % e)
            self.rc = 1
            return
        messages = []
        gone = []
        with Lock(cfg):
            seen = {}
            for r in self.state.inbox_seen():
                r["recording"] = recording_name(r["recording"])
                seen.setdefault(r["recording"], r)
            rows = self.state.shared()
            by_rec = {recording_name(r["recording"]): r for r in rows
                      if r["recording"] and "unshared" not in flags(r)}
            for name in present:
                s = seen.get(name)
                if s is None:
                    s = seen[name] = {"recording": name, "first_seen": today.isoformat(), "flags": ""}
                shared = name in by_rec
                start = by_rec[name]["first_shared"] if shared else s["first_seen"]
                since = "共有から" if shared else "置いてから"
                days = _days(start, today)
                if days is None:
                    continue
                f = flags(s)
                if days >= cfg.keep_days and "notified_keep" not in f:
                    set_flag(s, "notified_keep")
                    messages.append(("受け取り箱の録画を消してください（%s %d 日たちました）: %s"
                                     % (since, cfg.keep_days, name), False))
                if days >= cfg.owner_days and "notified_owner" not in f:
                    set_flag(s, "notified_owner")
                    messages.append(("【%sへ】受け取り箱に、%s %d 日たった録画が残っています: %s"
                                     % (cfg.owner_name, since, cfg.owner_days, name), True))
            self.state.save_inbox_seen(list(seen.values()))
            missing = []
            if present:
                for rec, row in by_rec.items():
                    if rec in present or "recording_deleted" in flags(row):
                        continue
                    if rec in seen:
                        gone.append(row)
                    elif "inbox_missing_notified" not in flags(row):
                        set_flag(row, "inbox_missing_notified")
                        missing.append(rec)
                        messages.append(("受け取り箱に見当たらない録画があります: %s（名前の打ち間違いなら --recording を直して"
                                         "載せ直す。同期が遅れているだけなら、置かれた後の見回りで数え始める）" % rec, False))
            if missing and not gone:
                self.state.save_shared(rows)
            if gone:
                self.mark_deleted(rows, gone)
        for text, todo in messages:
            self.notify(text, todo=todo)

    def mark_deleted(self, rows, gone):
        """Under the lock: `source_recording_deleted: はい` in the shared minutes, then push."""
        sharer = self.sharer
        if sharer._check_repo():
            self.rc = 1
            return
        pre = sharer.repo.head()
        for row in gone:
            rel = row["minutes_file"]
            path = os.path.join(self.cfg.repo_dir, rel)
            if rel and os.path.isfile(path):
                with open(path, encoding="utf-8") as f:
                    text = f.read()
                fm = fmx.parse(fmx.split_document(text)[0])
                with open(path, "w", encoding="utf-8") as f:
                    f.write(fmx.set_value(text, "source_recording_deleted", "はい"))
                sharer.repo.commit("update: %s %s" % (fm.get("date", ""), fm.get("title", row["autonote_id"])))
            set_flag(row, "recording_deleted")
        try:
            status, detail = sharer._sync(pre)
        except GitError as e:
            print(e)
            status, detail = "offline", "git"
        if status == "conflict":
            sharer._conflict(detail, "-")  # the commits were dropped; flags stay unsaved, so the next patrol redoes it
            self.rc = 1
            return
        self.state.save_shared(rows)  # the commits stay in the clone even when the push waits for the next run
        for row in gone:
            self.state.log("patrol", row["autonote_id"], "recording deleted" + ("" if status == "ok" else " (push later)"))
        if status != "ok":
            self.rc = 1

    def check_autonote(self):
        try:
            p = subprocess.run([self.cfg.autonote_cli, "list", "--json"], capture_output=True, text=True, timeout=120)
            data = json.loads(p.stdout) if p.returncode == 0 else None
        except (OSError, subprocess.TimeoutExpired, ValueError):
            data = None
        if data is None:
            print("autonote list --json を読めませんでした（AutoNote は起動していますか）")
            self.state.log("patrol", "autonote-list", "failed")
            return
        if isinstance(data, dict):
            data = data.get("meetings") or next((v for v in data.values() if isinstance(v, list)), [])
        known = set(str(x.get("id", "")) for x in data if isinstance(x, dict))
        missing = []
        with Lock(self.cfg):
            rows = self.state.shared()
            for row in rows:
                f = flags(row)
                if "unshared" in f or "missing_notified" in f or row["autonote_id"] in known:
                    continue
                set_flag(row, "missing_notified")
                missing.append(row)
            if missing:
                self.state.save_shared(rows)
        for row in missing:
            self.notify("AutoNote に無い共有の会議があります: %s（%s）。残すか、取り下げるなら share-meeting.sh --unshare %s"
                        % (row["autonote_id"], row["minutes_file"], row["autonote_id"]), todo=True)
