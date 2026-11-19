#!/usr/bin/env python3
"""2 つのビルドの処理時間（RTF）を、交互に複数回回した中央値で比べる。

使い方: python3 -I scripts/eval/rtf.py --a <label>=<autonote> --b <label>=<autonote>
          [--cases kantei-toron:ja,ami-IS1009c:en] [--engines whisper,whisper-live] [--rounds 3]

- 1 回の文字起こしは 20〜130 秒と短く、他のプロセスの負荷で RTF が 2 倍近く揺れる（run.py の 1 回の値は参考）。
  A・B を 1 本ずつ交互に回し（A B A B …）、同じ時間帯の負荷が両方に乗るようにして、中央値の比を出す。
- 結果: docs/eval/results/<日付>-rtf-<A>-vs-<B>.json と .md（elapsed・rtf の各回と中央値、比 = B ÷ A）。
"""

import argparse
import datetime
import os
import shutil
import statistics
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import common  # noqa: E402
import run as runner  # noqa: E402


def parse_build(text):
    label, _, path = text.partition("=")
    if not label or not path:
        sys.exit("--a / --b は <label>=<autonote の実行ファイル>")
    return label, path


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--a", required=True)
    ap.add_argument("--b", required=True)
    ap.add_argument("--cases", default="kantei-toron:ja,ami-IS1009c:en")
    ap.add_argument("--engines", default="whisper,whisper-live")
    ap.add_argument("--rounds", type=int, default=3)
    ap.add_argument("--model-path", default="")
    args = ap.parse_args(argv)
    decl = common.load_datasets(include_local=False)
    model = runner.model_path(decl, args.model_path)
    builds = [parse_build(args.a), parse_build(args.b)]
    cases = [c.split(":") for c in args.cases.split(",") if c]
    engines = [e for e in args.engines.split(",") if e]
    samples = {}
    work = tempfile.mkdtemp(prefix="rtf-", dir=common.DATA)
    for rnd in range(args.rounds):
        for ds_id, lang in cases:
            audio = os.path.join(common.prepared_dir(ds_id), "audio.wav")
            for engine in engines:
                for label, autonote in builds:
                    out = os.path.join(work, "%s-%s-%s-%s-%d.jsonl" % (label, ds_id, engine, lang, rnd))
                    print("RTF: 回 %d %s %s %s %s" % (rnd + 1, label, ds_id, engine, lang), flush=True)
                    runner.transcribe(autonote, audio, engine, lang, model, out, 3600)
                    _, summary = common.read_jsonl(out)
                    key = "%s %s/%s" % (ds_id, engine, lang)
                    samples.setdefault(key, {}).setdefault(label, []).append(
                        {"elapsed": summary["elapsed"], "rtf": summary["rtf"]})
    shutil.rmtree(work, ignore_errors=True)
    (la, _), (lb, _) = builds
    result = {"date": datetime.date.today().isoformat(), "a": la, "b": lb, "rounds": args.rounds,
              "model": os.path.basename(model), "builds": {l: runner.build_info(p) for l, p in builds}, "cases": {}}
    lines = ["# 処理時間の比較: %s と %s" % (la, lb), "",
             "- 日付: %s、交互に %d 回ずつ、モデル: %s。比 = %s ÷ %s（中央値どうし）" % (
                 result["date"], args.rounds, result["model"], lb, la), "",
             "| ケース | %s RTF（中央値・各回） | %s RTF（中央値・各回） | 比 |" % (la, lb), "|---|---|---|---|"]
    for key, by in samples.items():
        ma = statistics.median(s["rtf"] for s in by[la])
        mb = statistics.median(s["rtf"] for s in by[lb])
        result["cases"][key] = {la: by[la], lb: by[lb], "median_rtf": {la: ma, lb: mb}, "ratio": mb / ma if ma else None}
        lines.append("| %s | %.3f（%s） | %.3f（%s） | %.2f |" % (
            key, ma, ", ".join("%.3f" % s["rtf"] for s in by[la]), mb, ", ".join("%.3f" % s["rtf"] for s in by[lb]),
            mb / ma if ma else 0))
    out = os.path.join(common.RESULTS, "%s-rtf-%s-vs-%s.json" % (result["date"], la, lb))
    common.write_json(out, result)
    with open(os.path.splitext(out)[0] + ".md", "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    print("rtf: %s" % os.path.relpath(out, common.ROOT))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
