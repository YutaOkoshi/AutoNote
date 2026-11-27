"""INDEX.md (and the reader copy's list): rebuilt every time from the frontmatter of <year>/*.md in the clone."""
import os
import re

from . import frontmatter as fmx
from .names import nfc

YEAR_RE = re.compile(r"^\d{4}$")
DEFAULT_TEMPLATE = """# 会議の一覧

> 自動で作り直す（手で直しても次の更新で消える）。新しい順。まずここで絞り、議事録を読み、言い回しまで要るときだけ文字起こしを読む。

{{rows}}
"""


class Entry:
    def __init__(self, rel, fm, body):
        self.rel = rel = nfc(rel)  # e.g. 2026/<stem>.md, as git's tree spells it
        self.fm = fm
        self.stem = os.path.splitext(os.path.basename(rel))[0]
        self.year = rel.split("/", 1)[0]
        tf = nfc(fm.get("transcript_file", ""))
        self.transcript_rel = "%s/%s" % (self.year, tf) if tf and tf != "なし" else None
        self.summary = summary_line(body)

    @property
    def kind_label(self):
        return {"customer": "顧客", "internal": "社内"}.get(self.fm.get("kind", ""), self.fm.get("kind", "") or "—")

    def sort_key(self):
        return (self.fm.get("date", ""), self.fm.get("start", ""), self.stem)


def summary_line(body, limit=60):
    lines = body.split("\n")
    try:
        i = lines.index("## 要約")
    except ValueError:
        return ""
    for line in lines[i + 1:]:
        if line.startswith("#"):
            break
        s = line.strip()
        if not s or s == "- なし":
            continue
        s = re.sub(r"\s*（→ \d{2}:\d{2}:\d{2}）", "", s).lstrip("- ").strip()
        s = s.split("。", 1)[0]
        if len(s) > limit:
            s = s[:limit] + "…"
        return s
    return ""


def entries(repo_dir):
    out = []
    if not os.path.isdir(repo_dir):
        return out
    for year in sorted(os.listdir(repo_dir)):
        ydir = os.path.join(repo_dir, year)
        if not YEAR_RE.match(year) or not os.path.isdir(ydir):
            continue
        for name in sorted(os.listdir(ydir)):
            if not name.endswith(".md"):
                continue
            with open(os.path.join(ydir, name), encoding="utf-8") as f:
                fm_lines, body = fmx.split_document(f.read())
            fm = fmx.parse(fm_lines)
            if fm.get("autonote_id"):
                out.append(Entry("%s/%s" % (year, name), fm, body))
    out.sort(key=lambda e: e.sort_key(), reverse=True)
    return out


def cell(s):
    s = (s or "").replace("\n", " ").replace("|", "\\|").strip()
    return s or "—"


def link(label, rel):
    if rel is None:
        return "—"
    if re.search(r"[\s()<>]", rel):
        return "[%s](<%s>)" % (label, rel)
    return "[%s](%s)" % (label, rel)


def _template(templates_dir, name):
    path = os.path.join(templates_dir, name)
    if os.path.isfile(path):
        with open(path, encoding="utf-8") as f:
            text = f.read()
        if "{{rows}}" in text:
            return text
    return DEFAULT_TEMPLATE


def render(repo_dir, templates_dir):
    head = "| 日付 | 時刻 | 相手先 | 種類 | 題 | 一行の要約 | 議事録 | 文字起こし |\n|---|---|---|---|---|---|---|---|"
    rows = [head]
    for e in entries(repo_dir):
        rows.append("| %s | %s | %s | %s | %s | %s | %s | %s |" % (
            cell(e.fm.get("date")), cell(e.fm.get("start")), cell(e.fm.get("customer")), e.kind_label,
            cell(e.fm.get("title")), cell(e.summary), link("議事録", e.rel), link("全文", e.transcript_rel)))
    return _template(templates_dir, "INDEX.md").replace("{{rows}}", "\n".join(rows))


def write(repo_dir, templates_dir):
    text = render(repo_dir, templates_dir)
    path = os.path.join(repo_dir, "INDEX.md")
    old = None
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            old = f.read()
    if old != text:
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)
        return True
    return False
