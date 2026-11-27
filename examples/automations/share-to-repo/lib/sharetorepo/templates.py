"""Fills the placeholders in templates/: {{keep_days}} (RECORDING_KEEP_DAYS) and {{exts}} (recording file types)."""
import os

EXTS_TEXT = "mp4・m4a・mov・wav・mp3"


def fill(cfg, text):
    return text.replace("{{keep_days}}", str(cfg.keep_days)).replace("{{exts}}", EXTS_TEXT)


def load(cfg, name):
    """The filled template, or None when templates/<name> does not exist."""
    path = os.path.join(cfg.templates_dir, name)
    if not os.path.isfile(path):
        return None
    with open(path, encoding="utf-8") as f:
        return fill(cfg, f.read())
