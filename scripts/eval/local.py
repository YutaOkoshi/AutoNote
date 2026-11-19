#!/usr/bin/env python3
"""手元の録音（共有できない会議を含む）を評価に加える補助。音声・書き起こしはすべて .eval-data/private/ に置き、
宣言は git 管理外の scripts/eval/datasets.local.json に書く。

  add    録音を宣言する:      local.py add --id <id> --audio <録音> [--langs ja,en] [--max-seconds 1200]
  draft  下書きを書き出す:    local.py draft --id <id> --autonote <実行ファイル>
         （確定版 whisper で文字起こしし、.eval-data/private/<id>/draft.txt に 1 行 1 発話で書く。これを直す）
  import 直した書き起こしを正解として取り込む: local.py import --id <id>
         （draft.txt の「[HH:MM:SS] 」と # で始まる行を除いて reference.json にする）

その後は scripts/eval/eval.sh --datasets local（または --datasets <id>）で採点する。結果は .eval-data/results/ に
書かれ、集計値だけを含む（本文は含まない）。共有するかは利用者が決める。
"""

import argparse
import datetime
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import common  # noqa: E402
import fetch  # noqa: E402
import run as runner  # noqa: E402

LOCAL = os.environ.get("EVAL_DATASETS_LOCAL") or os.path.join(common.EVAL_DIR, "datasets.local.json")
_STAMP = re.compile(r"^\[\d{1,2}:\d{2}:\d{2}\]\s*")


def private_dir(ds_id):
    return os.path.join(common.DATA, "private", ds_id)


def load_local():
    if os.path.exists(LOCAL):
        return common.load_json(LOCAL)
    return {"version": 1, "sources": {}, "datasets": []}


def find(ds_id):
    decl = common.load_datasets()
    for ds in decl["datasets"]:
        if ds["id"] == ds_id and ds.get("private"):
            return decl, ds
    sys.exit("datasets.local.json に %s がない（local.py add で宣言する）" % ds_id)


def hhmmss(sec):
    sec = int(sec or 0)
    return "%02d:%02d:%02d" % (sec // 3600, sec % 3600 // 60, sec % 60)


def cmd_add(args):
    if not re.match(r"^[A-Za-z0-9._-]+$", args.id):
        sys.exit("--id は英数字と . _ - だけ")
    audio = os.path.abspath(os.path.expanduser(args.audio))
    if not os.path.exists(audio):
        sys.exit("録音がない: %s" % audio)
    langs = [l for l in args.langs.split(",") if l]
    local = load_local()
    local["sources"]["local-%s" % args.id] = {"path": audio, "sha256": common.sha256_file(audio),
                                              "license": "private（共有しない）"}
    local["datasets"] = [d for d in local["datasets"] if d["id"] != args.id]
    local["datasets"].append({
        "id": args.id, "kind": "local", "title": args.title or args.id, "audio": "local-%s" % args.id,
        "reference": os.path.join("private", args.id, "reference.json"), "max_seconds": args.max_seconds,
        "unit": "word" if "en" in langs and len(langs) > 1 else ("word" if langs == ["en"] else "char"),
        "languages": langs, "langs": args.run_langs.split(",")})
    common.write_json(LOCAL, local)
    print("宣言した: %s → %s" % (args.id, os.path.relpath(LOCAL, common.ROOT)))
    return 0


def cmd_draft(args):
    decl, ds = find(args.id)
    fetch.prepare(decl, ds)
    audio = os.path.join(common.prepared_dir(ds["id"]), "audio.wav")
    lang = args.lang or ("auto" if len(ds.get("languages", [])) > 1 else ds.get("languages", ["ja"])[0])
    out = os.path.join(private_dir(ds["id"]), "draft-whisper-%s.jsonl" % lang)
    if not runner.is_done(out):
        os.makedirs(os.path.dirname(out), exist_ok=True)
        runner.transcribe(args.autonote, audio, "whisper", lang, runner.model_path(decl, args.model_path), out, 7200)
    finals, _ = common.read_jsonl(out)
    draft = os.path.join(private_dir(ds["id"]), "draft.txt")
    if os.path.exists(draft) and not args.force:
        sys.exit("下書きはもうある（上書きするなら --force）: %s" % draft)
    with open(draft, "w", encoding="utf-8") as f:
        f.write("# 確定版（whisper, --lang %s）の下書き。聞きながら本文を直す。[HH:MM:SS] と # の行は取り込まない。\n" % lang)
        f.write("# 聞き取りにくい箇所も、聞こえたとおりに書く（消すと出力側の語が挿入として数えられる）。\n")
        for u in finals:
            f.write("[%s] %s\n" % (hhmmss(u["start"]), u["text"].strip()))
    print("下書き: %s（%d 発話）" % (draft, len(finals)))
    return 0


def parse_draft(text):
    lines = []
    for line in text.splitlines():
        if line.lstrip().startswith("#"):
            continue
        line = _STAMP.sub("", line.strip())
        if line:
            lines.append(line)
    return "\n".join(lines)


def cmd_import(args):
    _, ds = find(args.id)
    draft = args.file or os.path.join(private_dir(ds["id"]), "draft.txt")
    with open(draft, encoding="utf-8") as f:
        text = parse_draft(f.read())
    if not text:
        sys.exit("本文が空: %s" % draft)
    dest = os.path.join(common.DATA, ds["reference"])
    common.write_json(dest, {"text": text, "source": "corrected draft", "imported": datetime.date.today().isoformat()})
    ref = os.path.join(common.prepared_dir(ds["id"]), "ref.json")
    if os.path.exists(ref):
        os.remove(ref)   # 次の fetch で作り直す
    print("正解にした: %s（%d 文字）" % (dest, len(text)))
    return 0


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("add")
    a.add_argument("--id", required=True)
    a.add_argument("--audio", required=True)
    a.add_argument("--title", default="")
    a.add_argument("--langs", default="ja", help="録音で話される言語（ja,en など）")
    a.add_argument("--run-langs", default="ja,auto", help="文字起こしで試す --lang")
    a.add_argument("--max-seconds", type=float, default=1200)
    d = sub.add_parser("draft")
    d.add_argument("--id", required=True)
    d.add_argument("--autonote", required=True)
    d.add_argument("--lang", default="")
    d.add_argument("--model-path", default="")
    d.add_argument("--force", action="store_true")
    i = sub.add_parser("import")
    i.add_argument("--id", required=True)
    i.add_argument("--file", default="")
    args = ap.parse_args(argv)
    return {"add": cmd_add, "draft": cmd_draft, "import": cmd_import}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
