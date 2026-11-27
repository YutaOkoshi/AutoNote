"""The reader copy (MIRROR_DIR): formatted documents in a synced folder, for readers who do not use git.

  <MIRROR_DIR>/はじめに.docx, 会議の一覧.docx, 議事録/<年>/<名前>.docx, 文字起こし/<年>/<名前>_文字起こし.docx

Built from the clone (not the vault), so it always matches what was shared. Files are made in a temp folder and moved
into place, so the synced folder never holds a half-written file. state/mirror-files.tsv lists what this script wrote;
only those files are ever replaced or removed (anything a reader puts in the folder stays).
"""
import hashlib
import os
import re
import shlex
import shutil
import subprocess
import tempfile

from . import frontmatter as fmx
from . import index as indexmod
from . import mdhtml
from . import templates
from . import split
from .state import read_tsv, write_tsv

MANIFEST_COLUMNS = ["path", "source_sha256"]
ANCHOR_RE = re.compile(r" \^t\d{2}-\d{2}-\d{2}(?:-\d+)?$")


class MirrorError(Exception):
    pass


def _sha(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def header_line(fm):
    date, start, end, dur = (fm.get(k, "").strip() for k in ("date", "start", "end", "duration_min"))
    when = date
    if start:
        when += " " + start + ("〜" + end if end else "")
    if dur:
        when += "（%s 分）" % dur
    parts = ["日時: " + when] if when else []
    if fm.get("customer", "").strip():
        parts.append("相手先: " + fm["customer"].strip())
    return " ／ ".join(parts)


def _insert_after_title(body, header):
    lines = body.strip("\n").split("\n")
    if lines and lines[0].startswith("# ") and header:
        return "\n".join([lines[0], "", header] + lines[1:])
    return "\n".join(([header, ""] if header else []) + lines)


def minutes_doc(text, stem):
    fm_lines, body = fmx.split_document(text)
    fm = fmx.parse(fm_lines)
    lines = body.split("\n")
    for i, line in enumerate(lines):
        if line == "## 文字起こし" and i + 1 < len(lines) and lines[i + 1].startswith("全文は別のファイル"):
            note = "全文は「文字起こし」フォルダの「%s_文字起こし」にあります。" % stem
            if split.UNKNOWN_NOTE in lines[i + 1]:
                note += split.UNKNOWN_NOTE
            note += "本文の（→ 00:07:08）は、文字起こしの [00:07:08] の発言を指します。"
            lines[i + 1] = note
            break
    return _insert_after_title("\n".join(lines), header_line(fm)) + "\n"


def transcript_doc(text, minutes_fm, stem):
    _, body = fmx.split_document(text)
    lines = body.strip("\n").split("\n")
    for i, line in enumerate(lines):
        if line.startswith("> ") and "議事録は" in line:
            note = "> " + (split.UNKNOWN_NOTE if split.UNKNOWN_NOTE in line else "")
            lines[i] = note + "議事録は「議事録」フォルダの「%s」にあります。" % stem
            break
    lines = [ANCHOR_RE.sub("", l) for l in lines]
    return _insert_after_title("\n".join(lines), header_line(minutes_fm)) + "\n"


def index_doc(entries):
    rows = ["| 日付 | 時刻 | 相手先 | 種類 | 題 | 一行の要約 | 議事録 | 文字起こし |", "|---|---|---|---|---|---|---|---|"]
    for e in entries:
        rows.append("| %s | %s | %s | %s | %s | %s | %s | %s |" % (
            indexmod.cell(e.fm.get("date")), indexmod.cell(e.fm.get("start")), indexmod.cell(e.fm.get("customer")),
            e.kind_label, indexmod.cell(e.fm.get("title")), indexmod.cell(e.summary), indexmod.cell(e.stem),
            indexmod.cell(e.stem + "_文字起こし" if e.transcript_rel else "")))
    return ("# 会議の一覧\n\n新しい順です。まずこの一覧で会議を絞り、「議事録」フォルダの同じ名前のものを読みます。"
            "言い回しまで知りたいときだけ「文字起こし」フォルダを読みます。\n\n" + "\n".join(rows) + "\n")


def convert_docx(cfg, html_path, out_path):
    cmd = getattr(cfg, "docx_cmd", None) if cfg is not None else None
    if cmd:
        argv = shlex.split(cmd) + [html_path, out_path]
    else:
        argv = ["/usr/bin/textutil", "-convert", "docx", "-inputencoding", "UTF-8", "-output", out_path, html_path]
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise MirrorError("docx に変換できません（%s）" % type(e).__name__)
    if p.returncode != 0 or not os.path.exists(out_path):
        raise MirrorError("docx に変換できません（exit %d）" % p.returncode)


def desired(cfg, repo_dir):
    """{relative path without extension: (markdown text, title)} for everything the mirror should hold."""
    docs = {}
    readme = templates.load(cfg, "mirror-readme.md")
    if readme is not None:
        docs["はじめに"] = (readme, "はじめに")
    entries = indexmod.entries(repo_dir)
    docs["会議の一覧"] = (index_doc(entries), "会議の一覧")
    for e in entries:
        with open(os.path.join(repo_dir, e.rel), encoding="utf-8") as f:
            docs["議事録/%s/%s" % (e.year, e.stem)] = (minutes_doc(f.read(), e.stem), e.fm.get("title", e.stem))
        if e.transcript_rel and os.path.isfile(os.path.join(repo_dir, e.transcript_rel)):
            with open(os.path.join(repo_dir, e.transcript_rel), encoding="utf-8") as f:
                docs["文字起こし/%s/%s_文字起こし" % (e.year, e.stem)] = (
                    transcript_doc(f.read(), e.fm, e.stem), e.fm.get("title", e.stem) + "（文字起こし）")
    return docs


def sync(cfg, state, repo_dir, full=False):
    """Brings MIRROR_DIR in line with the clone. Raises MirrorError; files already in place stay as they were."""
    if not cfg.mirror_dir:
        return False
    root = cfg.mirror_dir
    manifest_path = state.path("mirror-files.tsv")
    manifest = {r["path"]: r["source_sha256"] for r in read_tsv(manifest_path, MANIFEST_COLUMNS)}
    want = {}
    for base, (text, title) in desired(cfg, repo_dir).items():
        for fmt in cfg.mirror_formats:
            want["%s.%s" % (base, fmt)] = (fmt, text, title)

    work = tempfile.mkdtemp(prefix="mirror-", dir=_work_parent(state))
    try:
        new_manifest = {}
        errors = []
        for rel, (fmt, text, title) in sorted(want.items()):
            sha = _sha(fmt + "\n" + text)
            target = os.path.join(root, rel)
            if not full and manifest.get(rel) == sha and os.path.exists(target):
                new_manifest[rel] = sha
                continue
            built = os.path.join(work, "out." + fmt)
            try:
                if fmt == "md":
                    with open(built, "w", encoding="utf-8") as f:
                        f.write(text)
                else:
                    src = os.path.join(work, "in.html")
                    with open(src, "w", encoding="utf-8") as f:
                        f.write(mdhtml.to_html(text, title=title, mode="docx"))
                    convert_docx(cfg, src, built)
                _place(built, target)
                new_manifest[rel] = sha
            except (MirrorError, OSError) as e:
                errors.append("%s: %s" % (rel, e))
                if rel in manifest:
                    new_manifest[rel] = manifest[rel] if os.path.exists(target) else ""
        for rel in manifest:
            if rel not in want:
                path = os.path.join(root, rel)
                if os.path.isfile(path):
                    os.remove(path)
                _prune(os.path.dirname(path), root)
        write_tsv(manifest_path, MANIFEST_COLUMNS,
                  [{"path": p, "source_sha256": s} for p, s in sorted(new_manifest.items())])
        if errors:
            raise MirrorError("; ".join(errors[:3]) + (" ほか %d 件" % (len(errors) - 3) if len(errors) > 3 else ""))
        return True
    finally:
        shutil.rmtree(work, ignore_errors=True)


def _work_parent(state):
    # Under the state folder: on the same volume as ~/Library/CloudStorage, so the final move is a rename.
    d = state.path("mirror-work")
    os.makedirs(d, exist_ok=True)
    return d


def _place(built, target):
    os.makedirs(os.path.dirname(target), exist_ok=True)
    try:
        os.replace(built, target)
    except OSError:
        # Another volume: copy beside the target under a hidden name, then rename.
        tmp = os.path.join(os.path.dirname(target), ".%s.partial" % os.path.basename(target))
        shutil.copyfile(built, tmp)
        os.replace(tmp, target)


def _prune(d, root):
    root = os.path.abspath(root)
    d = os.path.abspath(d)
    while d.startswith(root + os.sep) and d != root:
        try:
            os.rmdir(d)
        except OSError:
            return
        d = os.path.dirname(d)
