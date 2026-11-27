"""Settings: config.env (KEY=value lines) overlaid by the environment. The environment wins."""
import os
import re
from datetime import datetime

LIB_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PACKAGE_ROOT = os.path.dirname(LIB_DIR)

_VAR = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)")


def _expand(value, known):
    def rep(m):
        name = m.group(1) or m.group(2)
        return known.get(name, os.environ.get(name, ""))
    value = _VAR.sub(rep, value)
    if value.startswith("~/"):
        value = os.path.expanduser("~") + value[1:]
    return value


def parse_env_file(path):
    """Reads shell-style `KEY=value` lines. No commands run: only $VAR / ${VAR} and a leading ~ are expanded."""
    values = {}
    with open(path, encoding="utf-8") as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("export "):
                line = line[len("export "):].lstrip()
            m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", line)
            if not m:
                continue
            key, value = m.group(1), m.group(2).strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                quote, value = value[0], value[1:-1]
                if quote == '"':
                    value = _expand(value.replace('\\"', '"'), values)
            else:
                value = _expand(re.split(r"\s+#", value, 1)[0], values)
            values[key] = value
    return values


class Config:
    def __init__(self, env=None):
        env = dict(os.environ if env is None else env)
        home_default = os.path.join(os.path.expanduser("~"), "Library", "Application Support", "AutoNoteShare")
        self.config_path = env.get("SHARE_CONFIG") or os.path.join(env.get("SHARE_HOME") or home_default, "config.env")
        file_values = parse_env_file(self.config_path) if os.path.isfile(self.config_path) else {}
        merged = dict(file_values)
        merged.update({k: v for k, v in env.items() if v != ""})
        self.values = merged

        g = self.get
        self.home = g("SHARE_HOME", home_default)
        self.repo_dir = g("SHARE_REPO_DIR", os.path.join(self.home, "repo"))
        self.remote = g("SHARE_REMOTE", "origin")
        self.branch = g("SHARE_BRANCH", "main")
        self.state_dir = g("SHARE_STATE_DIR", os.path.join(self.home, "state"))
        self.log_dir = g("SHARE_LOG_DIR", os.path.join(self.home, "logs"))
        self.vault_root = g("VAULT_ROOT", os.path.join(os.path.expanduser("~"), "Documents", "AutoNote"))
        self.inbox_dir = g("INBOX_DIR")
        self.default_recorded_by = g("DEFAULT_RECORDED_BY", "録画した人")
        self.owner_name = g("OWNER_NAME", "オーナー")
        self.repo_web_url = (g("REPO_WEB_URL") or "").rstrip("/") or None
        self.mirror_dir = g("MIRROR_DIR")
        self.mirror_web_url = g("MIRROR_WEB_URL")
        fmt = [x.strip() for x in (g("MIRROR_FORMAT", "docx") or "docx").split(",") if x.strip()]
        self.mirror_formats = [x for x in ("docx", "md") if x in fmt] or ["docx"]
        self.docx_cmd = g("DOCX_CMD")
        self.notify_mode = g("NOTIFY_MODE", "macos")
        self.notify_cmd = g("NOTIFY_CMD")
        self.slack_webhook_url = g("SLACK_WEBHOOK_URL")
        self.slack_webhook_op_ref = g("SLACK_WEBHOOK_OP_REF")
        self.op_cmd = g("OP_CMD", "op")
        self.autonote_cli = g("AUTONOTE_CLI")
        self.keep_days = int(g("RECORDING_KEEP_DAYS", "7"))
        self.owner_days = int(g("RECORDING_OWNER_DAYS", "21"))
        self.outbox_todo_days = int(g("OUTBOX_TODO_DAYS", "3"))
        self.lock_timeout = float(g("SHARE_LOCK_TIMEOUT_SEC", "120"))
        self.lock_poll = float(g("SHARE_LOCK_POLL_SEC", "2"))
        self.templates_dir = g("SHARE_TEMPLATES_DIR", os.path.join(PACKAGE_ROOT, "templates"))
        self._now = g("SHARE_NOW")

    def get(self, key, default=None):
        v = self.values.get(key)
        return v if v not in (None, "") else default

    def now(self):
        """Local time, or SHARE_NOW (ISO 8601) for tests."""
        if self._now:
            return _parse_iso(self._now)
        return datetime.now().astimezone()

    def today(self):
        return self.now().date()


def _parse_iso(s):
    s = s.strip().replace("Z", "+00:00")
    m = re.match(r"^(.*[T ]\d{2}:\d{2}(?::\d{2})?)([+-]\d{2}):?(\d{2})$", s)
    if m:
        s = m.group(1) + m.group(2) + m.group(3)
        for fmt in ("%Y-%m-%dT%H:%M:%S%z", "%Y-%m-%dT%H:%M%z", "%Y-%m-%d %H:%M:%S%z"):
            try:
                return datetime.strptime(s, fmt)
            except ValueError:
                pass
    for fmt in ("%Y-%m-%dT%H:%M:%S", "%Y-%m-%dT%H:%M", "%Y-%m-%d"):
        try:
            return datetime.strptime(s, fmt).astimezone()
        except ValueError:
            pass
    raise ValueError("SHARE_NOW の形が読めません: %s" % s)
