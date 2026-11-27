"""Notices. NOTIFY_MODE: dry-run (state/outbox-dry/ only), macos (NOTIFY_CMD or osascript, plus a todo.md line),
slack (Incoming Webhook; the URL comes from SLACK_WEBHOOK_URL or `op read $SLACK_WEBHOOK_OP_REF`).

The webhook URL is a secret: it is never written to logs, state files or stdout. A notice that cannot be sent is kept
in state/outbox/ and sent again on the next run; after OUTBOX_TODO_DAYS it also goes to todo.md once.
Notices carry only titles, dates, links and deadlines, never what was said in the meeting.
"""
import json
import os
import subprocess
import urllib.error
import urllib.request
import uuid
from datetime import datetime

from .state import atomic_write


class NotifyError(Exception):
    pass


def _deliver(cfg, state, msg):
    mode = cfg.notify_mode
    title, text = msg["title"], msg["text"]
    if mode == "dry-run":
        d = state.path("outbox-dry")
        os.makedirs(d, exist_ok=True)
        name = "%s-%s.json" % (cfg.now().strftime("%Y%m%dT%H%M%S"), msg["id"][:8])
        atomic_write(os.path.join(d, name), json.dumps(msg, ensure_ascii=False, indent=1))
        return
    if mode == "macos":
        if cfg.notify_cmd:
            argv = ["/bin/sh", "-c", cfg.notify_cmd + ' "$@"', "notify", title, text]
        else:
            argv = ["/usr/bin/osascript", "-e", "on run argv", "-e",
                    "display notification (item 2 of argv) with title (item 1 of argv)", "-e", "end run",
                    title, text]
        try:
            p = subprocess.run(argv, capture_output=True, text=True, timeout=30)
        except (OSError, subprocess.TimeoutExpired) as e:
            raise NotifyError("macos: %s" % type(e).__name__)
        if p.returncode != 0:
            raise NotifyError("macos: exit %d" % p.returncode)
        state.add_todo("%s: %s" % (title, text))
        return
    if mode == "slack":
        url = _webhook_url(cfg)
        body = json.dumps({"text": "%s\n%s" % (title, text)}, ensure_ascii=False).encode("utf-8")
        req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json; charset=utf-8"})
        try:
            with urllib.request.urlopen(req, timeout=15) as res:
                if res.status // 100 != 2:
                    raise NotifyError("slack: HTTP %d" % res.status)
        except urllib.error.HTTPError as e:
            raise NotifyError("slack: HTTP %d" % e.code)
        except (urllib.error.URLError, OSError) as e:
            raise NotifyError("slack: %s" % type(e).__name__)
        return
    raise NotifyError("NOTIFY_MODE が分かりません: %s" % mode)


def _webhook_url(cfg):
    if cfg.slack_webhook_url:
        return cfg.slack_webhook_url
    if cfg.slack_webhook_op_ref:
        try:
            p = subprocess.run([cfg.op_cmd, "read", cfg.slack_webhook_op_ref], capture_output=True, text=True,
                               timeout=60)
        except (OSError, subprocess.TimeoutExpired) as e:
            raise NotifyError("op read: %s" % type(e).__name__)
        if p.returncode != 0 or not p.stdout.strip():
            raise NotifyError("op read: exit %d" % p.returncode)
        return p.stdout.strip()
    raise NotifyError("SLACK_WEBHOOK_URL も SLACK_WEBHOOK_OP_REF もありません")


def send(cfg, state, title, text):
    """Sends one notice. On failure it is kept in the outbox. Returns True when it went out now."""
    msg = {"id": uuid.uuid4().hex, "created_at": cfg.now().isoformat(timespec="seconds"), "title": title,
           "text": text}
    try:
        _deliver(cfg, state, msg)
        state.log("notify", "sent", title)
        return True
    except NotifyError as e:
        d = state.path("outbox")
        os.makedirs(d, exist_ok=True)
        atomic_write(os.path.join(d, msg["id"] + ".json"), json.dumps(msg, ensure_ascii=False, indent=1))
        state.log("notify", "kept-in-outbox", title, str(e))
        print("知らせを送れませんでした（%s）。state/outbox/ に置き、次の実行で送り直します。" % e)
        return False


def flush_outbox(cfg, state):
    d = state.path("outbox")
    if not os.path.isdir(d):
        return
    now = cfg.now()
    for name in sorted(os.listdir(d)):
        if not name.endswith(".json"):
            continue
        path = os.path.join(d, name)
        try:
            with open(path, encoding="utf-8") as f:
                msg = json.load(f)
        except (OSError, ValueError):
            continue
        try:
            _deliver(cfg, state, msg)
            os.remove(path)
            state.log("notify", "resent", msg.get("title", ""))
        except NotifyError as e:
            state.log("notify", "still-in-outbox", msg.get("title", ""), str(e))
            created = _parse(msg.get("created_at"))
            if created and not msg.get("todo") and (now - created).total_seconds() >= cfg.outbox_todo_days * 86400:
                state.add_todo("知らせを送れていません（%d 日以上）: %s — %s。設定（NOTIFY_MODE と知らせ先）を確かめる"
                               % (cfg.outbox_todo_days, msg.get("title", ""), msg.get("created_at", "")))
                msg["todo"] = True
                atomic_write(path, json.dumps(msg, ensure_ascii=False, indent=1))


def _parse(s):
    if not s:
        return None
    try:
        from .config import _parse_iso
        return _parse_iso(s)
    except ValueError:
        return None
