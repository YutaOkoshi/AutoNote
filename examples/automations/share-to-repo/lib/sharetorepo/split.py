"""Splits one AutoNote meeting file into the shared minutes file and the shared transcript file.

AutoNote's layout (Sources/AutoNoteCore/Vault/MeetingDocument.swift): frontmatter, `# title`, the minutes sections,
`## ブックマーク`, `## 文字起こし` with lines like `**[HH:MM:SS] 話者**: text ^tHH-MM-SS`, then (optionally) the
translated minutes `## 議事録の訳文（…）`. Utterance links look like `[[#^t00-07-08|07:09]]`, `[[#^t00-07-08-2|07:08]]`,
`[[#^t01-02-03|1:02:04]]`, and inside table cells `[[#^t00-07-08\\|07:09]]`.
"""
import os
import re

from . import frontmatter as fmx
from .names import nfc

LINK_RE = re.compile(r"\[\[#\^t([0-9]{2})-([0-9]{2})-([0-9]{2})(?:-[0-9]+)?\\?\|[0-9:]+\]\]")
SPEAKER_RE = re.compile(r"^\*\*\[\d{2}:\d{2}:\d{2}\] (.+?)\*\*: ")
RECORDING_RE = re.compile(r"^(\d{4}-\d{2}-\d{2})_(\d{2})(\d{2})_([^_]+)_.+\.[A-Za-z0-9]+$")

SHARE_KEYS = ["kind", "customer", "recorded_by", "transcript_file", "source_recording_deleted"]
TIME_NOTE = "本文の（→ 00:07:08）は、文字起こしの `[00:07:08]` の発言を指します。"
UNKNOWN_NOTE = "話者はすべて「不明」です。"


def convert_links(text):
    return LINK_RE.sub(lambda m: "（→ %s:%s:%s）" % (m.group(1), m.group(2), m.group(3)), text)


def parse_recording_name(name):
    """`2026-12-02_1000_相手先_用件.mp4` → ("2026-12-02", "10:00", "相手先"); other shapes → None."""
    m = RECORDING_RE.match(os.path.basename(name or ""))
    if not m:
        return None
    return m.group(1), "%s:%s" % (m.group(2), m.group(3)), m.group(4)


class Meeting:
    def __init__(self, path, text):
        self.path = path
        self.fm_lines, body = fmx.split_document(text)
        self.fm = fmx.parse(self.fm_lines)
        lines = body.split("\n")
        bookmark = _find(lines, lambda l: l == "## ブックマーク")
        transcript = _find(lines, lambda l: l == "## 文字起こし", start=bookmark or 0)
        if transcript is None and bookmark is not None:
            transcript = _find(lines, lambda l: l == "## 文字起こし")
        translation = None
        if transcript is not None:
            translation = _find(lines, lambda l: l.startswith("## "), start=transcript + 1)
        head_end = min(x for x in (bookmark, transcript, len(lines)) if x is not None)
        self.head = "\n".join(lines[:head_end]).strip("\n")
        self.bookmarks = None
        if bookmark is not None:
            end = min(x for x in (transcript, translation, len(lines)) if x is not None and x > bookmark)
            self.bookmarks = "\n".join(lines[bookmark:end]).strip("\n")
        self.transcript = None
        if transcript is not None:
            end = translation if translation is not None else len(lines)
            content = "\n".join(lines[transcript + 1:end]).strip("\n")
            self.transcript = content or None
        self.translation = "\n".join(lines[translation:]).strip("\n") if translation is not None else None

    @property
    def autonote_id(self):
        return self.fm.get("autonote_id", "").strip()

    @property
    def title(self):
        t = self.fm.get("title", "").strip()
        if t:
            return t
        for line in self.head.split("\n"):
            if line.startswith("# "):
                return line[2:].strip()
        return self.autonote_id

    @property
    def date(self):
        return self.fm.get("date", "").strip()

    @property
    def start(self):
        return self.fm.get("start", "").strip()

    @property
    def status(self):
        return self.fm.get("status", "").strip()

    @property
    def year(self):
        d = self.date
        if re.match(r"^\d{4}-", d):
            return d[:4]
        return os.path.basename(os.path.dirname(self.path)) or "unknown"

    @property
    def stem(self):
        """The file name without .md, in NFC (the vault file itself is NFD on a Mac's disk)."""
        return nfc(os.path.splitext(os.path.basename(self.path))[0])

    def speakers_unknown(self):
        speakers = [m.group(1) for m in (SPEAKER_RE.match(l) for l in (self.transcript or "").split("\n")) if m]
        return bool(speakers) and all(s == "不明" for s in speakers)


def _find(lines, pred, start=0):
    for i in range(start, len(lines)):
        if pred(lines[i]):
            return i
    return None


def load_meeting(path):
    with open(path, encoding="utf-8") as f:
        return Meeting(path, f.read())


def transcript_name(stem):
    return stem + "_文字起こし.md"


def render_pair(m, stem, kind, customer, recorded_by, recording_state):
    """Returns (minutes text, transcript text or None) for the shared repository."""
    has_transcript = m.transcript is not None
    tname = transcript_name(stem)
    fm = fmx.without_keys(m.fm_lines, SHARE_KEYS)
    fm += [
        "kind: %s" % kind,
        "customer: %s" % fmx.quote(customer),
        "recorded_by: %s" % fmx.quote(recorded_by),
        "transcript_file: %s" % (fmx.quote("文字起こし/" + tname) if has_transcript else "なし"),
        "source_recording_deleted: %s" % recording_state,
    ]
    parts = [convert_links(m.head)]
    if kind != "customer" and m.bookmarks:
        parts.append(convert_links(m.bookmarks))
    if has_transcript:
        note = "全文は別のファイル `文字起こし/%s` にあります。" % tname
        if m.speakers_unknown():
            note += UNKNOWN_NOTE
        parts.append("## 文字起こし\n" + note + TIME_NOTE)
    else:
        parts.append("## 文字起こし\nこの会議には文字起こしがありません。")
    if m.translation:
        parts.append(convert_links(m.translation))
    minutes = "---\n" + "\n".join(fm) + "\n---\n\n" + "\n\n".join(parts) + "\n"
    if not has_transcript:
        return minutes, None

    tfm = []
    for key in ("title", "date", "autonote_id"):
        line = fmx.raw_line(m.fm_lines, key)
        tfm.append(line if line is not None else "%s: %s" % (key, fmx.quote(m.fm.get(key, ""))))
    tfm.append("minutes_file: %s" % fmx.quote("../%s.md" % stem))
    note = "> "
    if m.speakers_unknown():
        note += UNKNOWN_NOTE
    note += "議事録は `../%s.md` にあります。" % stem
    transcript = ("---\n" + "\n".join(tfm) + "\n---\n\n# %s（文字起こし）\n\n" % m.title + note + "\n\n"
                  + m.transcript + "\n")
    return minutes, transcript
