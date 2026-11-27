"""daily-patrol.sh: once a day (launchd). Never deletes minutes or transcripts, and never touches the vault."""
import json
import os
import subprocess
from datetime import date

from .share import (NOTICE_TITLE, Sharer, VaultUnreadable, find_vault_file, inbox_recordings, recording_name,
                    sha256_file)
from .state import Lock, LockTimeout, atomic_write, flags, set_flag
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
                 ("recordings", self.check_inbox if self.cfg.inbox_dir else self.ask_after_keep_days),
                 # the repository follows the recording_deleted flags (also the ones set by hand)
                 ("deleted", self.apply_deleted)]
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
        try:
            self.report_problems()
        except Exception as e:
            print("失敗の知らせを出す途中で止まりました: %s: %s" % (type(e).__name__, e))
            self.rc = 1
        self.state.log("patrol", "done", "rc=%d" % self.rc)
        return self.rc

    def report_problems(self):
        """Nobody watches a patrol run by launchd: each failure goes to todo.md (the same line is not repeated),
        and the owner gets one notice a day saying that something failed."""
        problems = list(self.sharer.problems)
        if not problems:
            return
        for text in problems:
            self.state.add_todo(text)
        marker = self.state.path("problem-notice-day")
        today = self.cfg.today().isoformat()
        try:
            with open(marker, encoding="utf-8") as f:
                last = f.read().strip()
        except OSError:
            last = ""
        if last == today:
            return
        atomic_write(marker, today + "\n")
        self.notify("【%sへ】見回りで失敗がありました（%d 件）。state/todo.md を見てください。1 件目: %s"
                    % (self.cfg.owner_name, len(problems), problems[0]))

    def retry(self):
        self.rc |= self.sharer.retry_pending()

    def mirror(self):
        with Lock(self.cfg):
            if not self.sharer._mirror():
                self.rc = 1

    def apply_deleted(self):
        with Lock(self.cfg):
            self.sharer._began = False
            try:
                self.rc |= self.sharer.apply_deleted_flags()
            except GitError as e:
                print(e)
                self.sharer._put_back()
                self.rc = 1

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
                    asked.append((row["recording"], days))
            if asked:
                self.state.save_shared(rows)
        for rec, days in asked:
            self.notify("録画は消しましたか: 受け取り箱の %s（共有から %d 日たちました。録画の道具の側の元とゴミ箱も）。"
                        "消したら share-meeting.sh --recording-deleted <autonote_id> で記録する" % (rec, days))

    def check_inbox(self):
        """Reminders for recordings left in the inbox, and the recording_deleted flag when one is gone.

        A shared recording counts from its first share: after KEEP_DAYS the reminder to delete it, after OWNER_DAYS a
        notice for the owner. A recording nobody shared yet counts from the day it was first seen, and only the owner
        is told ("まだ共有していない録画があります"): asking for it to be deleted would lose a recording that was
        never taken in. Each flag belongs to one of the two counts, so sharing a recording late still gets it its
        reminder. A reminder goes out on the first patrol on or after the due day, with the real number of days.

        A shared recording counts as deleted only once it has been seen in the inbox (by a patrol, or at share time)
        and then is not there; a name never seen gets one "見当たらない" notice instead (a typo, or the synced
        folder is late). An inbox with no recordings at all skips both checks, because a synced folder can look
        empty for a while. Deleted means the flag; apply_deleted_flags() then brings the repository in line.
        """
        cfg = self.cfg
        today = cfg.today()
        try:
            present = inbox_recordings(cfg.inbox_dir)
        except OSError as e:
            msg = "受け取り箱（INBOX_DIR）を読めません: %s" % (e.strerror or type(e).__name__)
            print(msg)
            self.state.add_todo(msg)
            self.sharer._problem(msg)
            self.rc = 1
            return
        messages = []
        with Lock(cfg):
            seen = {}
            for r in self.state.inbox_seen():
                r["recording"] = recording_name(r["recording"])
                seen.setdefault(r["recording"], r)
            rows = self.state.shared()
            by_rec = {recording_name(r["recording"]): r for r in rows
                      if r["recording"] and "unshared" not in flags(r)}
            owner = cfg.owner_name
            for name in present:
                s = seen.get(name)
                if s is None:
                    s = seen[name] = {"recording": name, "first_seen": today.isoformat(), "flags": ""}
                f = flags(s)
                if name in by_rec:
                    days = _days(by_rec[name]["first_shared"], today)
                    if days is None:
                        continue
                    if days >= cfg.keep_days and "notified_keep" not in f:
                        set_flag(s, "notified_keep")
                        messages.append(("受け取り箱の録画を消してください（共有から %d 日たちました）: %s" % (days, name),
                                         False))
                    if days >= cfg.owner_days and "notified_owner" not in f:
                        set_flag(s, "notified_owner")
                        messages.append(("【%sへ】受け取り箱に、共有から %d 日たった録画が残っています: %s"
                                         % (owner, days, name), True))
                else:
                    days = _days(s["first_seen"], today)
                    if days is None:
                        continue
                    if days >= cfg.keep_days and "notified_unshared" not in f:
                        set_flag(s, "notified_unshared")
                        messages.append(("【%sへ】受け取り箱に、まだ共有していない録画があります（置いてから %d 日）: %s。"
                                         "取り込んで --recording を付けて共有するか、要らない録画なら片付ける"
                                         % (owner, days, name), True))
                    if days >= cfg.owner_days and "notified_owner_unshared" not in f:
                        set_flag(s, "notified_owner_unshared")
                        messages.append(("【%sへ】受け取り箱に、置いてから %d 日たった録画が残っています（まだ共有していない）: %s"
                                         % (owner, days, name), True))
            self.state.save_inbox_seen(list(seen.values()))
            changed = False
            if present:
                for rec, row in by_rec.items():
                    if rec in present or "recording_deleted" in flags(row):
                        continue
                    if rec in seen:
                        set_flag(row, "recording_deleted")
                        self.state.log("patrol", row["autonote_id"], "recording gone from the inbox")
                        changed = True
                    elif "inbox_missing_notified" not in flags(row):
                        set_flag(row, "inbox_missing_notified")
                        changed = True
                        messages.append(("受け取り箱に見当たらない録画があります: %s（名前の打ち間違いなら --recording を直して"
                                         "載せ直す。同期が遅れているだけなら、置かれた後の見回りで数え始める）" % rec, False))
            if changed:
                self.state.save_shared(rows)
        for text, todo in messages:
            self.notify(text, todo=todo)

    def check_autonote(self):
        try:
            p = subprocess.run([self.cfg.autonote_cli, "list", "--json"], capture_output=True, text=True, timeout=120)
            data = json.loads(p.stdout) if p.returncode == 0 else None
        except (OSError, subprocess.TimeoutExpired, ValueError):
            data = None
        if data is None:
            print("autonote list --json を読めませんでした（AUTONOTE_CLI のパスと、AutoNote が起動しているかを確かめる）")
            self.state.log("patrol", "autonote-list", "failed")
            self.rc = 1
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
