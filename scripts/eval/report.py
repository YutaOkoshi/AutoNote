#!/usr/bin/env python3
"""採点結果の表（Markdown）と、基準との差。

使い方: python3 -I scripts/eval/report.py <result.json> [--base <result.json>|none] [--out <path.md>]

- 既定の基準は docs/eval/baseline.json。差は「結果 − 基準」（誤り率はポイント、RTF は比）。
- 判定は差で行う（絶対値は正解の作りの癖で動く）。正規化の版・採点の版が基準と違えば警告を出す。
"""

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import common  # noqa: E402

# 悪化とみなす目安（誤り率はポイント、想定外文字種は発話数）。超えたら表の右端に ▲ を付ける。
WORSE_POINTS = 1.0


def pct(x):
    return "–" if x is None else "%.1f%%" % (100 * x)


def rate(d, key):
    v = d.get(key)
    return None if not v else v.get("rate")


def delta_points(cur, base):
    if cur is None or base is None:
        return ""
    d = 100 * (cur - base)
    return "%+.1f" % d


def foreign_cell(run):
    f = run.get("foreign", {})
    cell = "%d/%d" % (f.get("with_unexpected", 0), f.get("utterances", 0))
    if f.get("by_script"):
        cell += " (" + ", ".join("%s %d" % (k.title(), v) for k, v in f["by_script"].items()) + ")"
    return cell


def build_line(res):
    b = res.get("build", {})
    parts = [res.get("label", "?")]
    if b.get("branch"):
        parts.append(b["branch"])
    if b.get("commit"):
        parts.append(b["commit"][:7])
    return " / ".join(parts)


def render(res, base):
    lines = ["# 文字起こしの評価: %s" % res["label"], ""]
    lines.append("- 日付: %s、ビルド: %s、モデル: %s" % (res["date"], build_line(res), res.get("model")))
    lines.append("- 正規化: %s、採点: %s" % (res["norm_version"], res["scorer_version"]))
    if base:
        lines.append("- 基準: %s（%s）。Δ は「この結果 − 基準」（誤り率はポイント）" % (build_line(base), base["date"]))
        for key in ("norm_version", "scorer_version", "model"):
            if base.get(key) != res.get(key):
                lines.append("- **警告**: %s が基準と違う（基準 %s）。差は参考値" % (key, base.get(key)))
    lines += ["", "列: er = 正規化後の誤り率（主指標）、raw = 素の値、en WER / ja CER = 混在の言語別、"
              "en 残存 = 正解の英語の語が英語のまま出た割合、想定外 = 日本語・ラテン以外の文字種を含む確定発話、"
              "反復 = 繰り返しの幻覚らしい発話数、最長脱落 = 連続して落ちた正解の単位数、RTF = 処理時間 ÷ 音声長。"
              "⚠exit = 出力を書き終えた後に 0 以外で終了した（結果は採用）", ""]
    for ds_id, ds in res["datasets"].items():
        bds = (base or {}).get("datasets", {}).get(ds_id, {})
        unit = {"word": "語", "char": "字"}.get(ds["unit"], ds["unit"])
        lines.append("## %s" % ds["title"])
        lines.append("")
        lines.append("音声 %.0f 秒、単位 %s、正解の区間 %s" % (ds.get("audio_seconds") or 0, unit, ds.get("ref_window")))
        lines.append("")
        lines.append("| エンジン/言語 | er | Δ | raw | en WER | ja CER | en 残存 | 想定外 | Δ | 反復 | 最長脱落 | RTF | RTF 比 |")
        lines.append("|---|---|---|---|---|---|---|---|---|---|---|---|---|")
        for key in sorted(ds["runs"]):
            run = ds["runs"][key]
            brun = bds.get("runs", {}).get(key, {})
            er = rate(run, "er")
            mark = ""
            d = delta_points(er, rate(brun, "er")) if brun else ""
            if d and float(d) >= WORSE_POINTS:
                mark = " ▲"
            fdelta = ""
            if brun:
                fd = run["foreign"]["with_unexpected"] - brun.get("foreign", {}).get("with_unexpected", 0)
                fdelta = "%+d" % fd
            rtf_ratio = ""
            if brun.get("rtf") and run.get("rtf"):
                rtf_ratio = "%.2f" % (run["rtf"] / brun["rtf"])
            ret = run.get("en_retention", {})
            if run.get("exit_code"):
                key = "%s ⚠exit %d" % (key, run["exit_code"])
            lines.append("| %s | %s | %s%s | %s | %s | %s | %s | %s | %s | %d | %s | %s | %s |" % (
                key, pct(er), d, mark, pct(rate(run, "er_raw")), pct(rate(run, "en_wer")), pct(rate(run, "ja_cer")),
                pct(ret.get("rate")) if ret else "–", foreign_cell(run), fdelta, run.get("repetition", 0),
                run.get("er", {}).get("max_del_run", "–"), "%.3f" % run["rtf"] if run.get("rtf") is not None else "–",
                rtf_ratio))
        lines.append("")
        lines += parts_table(ds) + tracks_table(ds)
    return "\n".join(lines) + "\n"


PART_NAMES = {"opening": "冒頭発言", "qa": "質疑"}


def parts_table(ds):
    runs = {k: r for k, r in ds["runs"].items() if r.get("parts")}
    if not runs:
        return []
    names = list(next(iter(runs.values()))["parts"])
    out = ["区間別の誤り率（正解の範囲を冒頭発言と質疑の境目で分けたもの。境目の発話は始まりの時刻で振り分ける）", "",
           "| エンジン/言語 | " + " | ".join("%s（%s 字）" % (PART_NAMES.get(n, n), runs[next(iter(runs))]["parts"][n]["ref_len"])
                                        for n in names) + " |",
           "|---|" + "---|" * len(names)]
    for key in sorted(runs):
        out.append("| %s | %s |" % (key, " | ".join(pct(runs[key]["parts"][n].get("rate")) for n in names)))
    return out + [""]


def tracks_table(ds):
    runs = {k: r for k, r in ds["runs"].items() if r.get("tracks")}
    if not runs:
        return []
    out = ["話者別の音声（アプリの「自分」「相手」のトラック）。混入 = そのトラックの発話のうち、同じ時刻の相手の正解に"
           "よく合うもの（発話数 / 文字数）", "",
           "| エンジン/言語 | 自分 | 相手 | 2 トラック計 | 混合音声（上の er） | 混入 自分 | 混入 相手 | 反復 自分/相手 |",
           "|---|---|---|---|---|---|---|---|"]
    for key in sorted(runs):
        t = runs[key]["tracks"]
        leak = lambda n: "%d / %d字" % (t[n]["leak"]["utterances"], t[n]["leak"]["chars"])
        out.append("| %s | %s | %s | %s | %s | %s | %s | %d/%d |" % (
            key, pct(t["me"]["er"]["rate"]), pct(t["other"]["er"]["rate"]), pct(t["combined"]["rate"]),
            pct(rate(runs[key], "er")), leak("me"), leak("other"), t["me"]["repetition"], t["other"]["repetition"]))
    return out + [""]


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("result")
    ap.add_argument("--base", default="")
    ap.add_argument("--out", default="")
    args = ap.parse_args(argv)
    res = common.load_json(args.result)
    base = None
    if args.base != "none":
        path = args.base or common.BASELINE
        if os.path.exists(path):
            base = common.load_json(path)
            if base.get("label") == res.get("label") and base.get("date") == res.get("date") and not args.base:
                base = None   # 基準そのもの
    text = render(res, base)
    out = args.out or os.path.splitext(args.result)[0] + ".md"
    with open(out, "w", encoding="utf-8") as f:
        f.write(text)
    print("report: %s" % os.path.relpath(out, common.ROOT))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
