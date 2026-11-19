#!/usr/bin/env python3
"""文字起こしの採点。結果は集計値だけを docs/eval/results/<日付>-<label>.json に書く（本文は書かない）。

使い方: python3 -I scripts/eval/score.py --label <名前> [--datasets id,id] [--out <path>] [--set-baseline]

指標（データセットごと、エンジン × 言語ごと）:
- er: 正規化後の誤り率（主指標。ami=WER、kokkai=CER、mixed/local の混在=MER、govinfo=冒頭英語の WER）と内訳
  （置換・脱落・挿入、連続した脱落の最長 max_del_run）。er_raw: 素の値（NFKC のみ）。
- en_wer / ja_cer: 混在のとき、英語の語だけ・日本語の文字だけを取り出して比べた値。
- en_retention: 正解の英語の語のうち、出力に英語の語として現れた割合（語の多重集合の重なり）。
- foreign: 日本語・ラテン文字以外の文字種（キリル・ハングルなど）を含む確定発話の数と割合。
- repetition: 繰り返しの幻覚らしい確定発話の数。
- rtf / elapsed / finals: autonote dev transcribe の summary 行。
- parts: 正解を時刻の区間に分けたもの（会見の冒頭発言 opening と質疑 qa）ごとの誤り率。
- tracks: 話者別の音声をトラックごとに文字起こししたもの（アプリの「自分」「相手」）の、トラックごとの誤り率、
  2 トラック合計の誤り率（話者を正しく分けた上での誤り率）、相手の声の混入（leak: 自分のトラックの発話のうち、
  同じ時刻の相手の正解によく合うもの）。
"""

import argparse
import datetime
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import common  # noqa: E402
import metrics  # noqa: E402
import textnorm  # noqa: E402

SCORER_VERSION = "score-1"   # 既存の指標は変えていない（parts / tracks / ja_range は足しただけ）


def toks(text, unit, level="norm"):
    return textnorm.tokenize(textnorm.normalize(text, level), unit)


def only(tokens, script):
    return [t for t in tokens if textnorm.token_script(t) == script]


def score_text(ref_text, hyp_text, unit, window):
    """正規化後（内訳つき）と素の値。window=locate なら参照の中で最も合う区間に合わせる。"""
    ref_n, hyp_n = toks(ref_text, unit), toks(hyp_text, unit)
    ref_r, hyp_r = toks(ref_text, unit, "raw"), toks(hyp_text, unit, "raw")
    out = {}
    if window == "locate":
        start, end, _ = metrics.locate(ref_n, hyp_n)
        out["ref_span"] = [start, end, len(ref_n)]
        ref_n = ref_n[start:end]
        raw_dist, raw_end = metrics.search_distance(ref_r, hyp_r)
        raw_start = metrics.locate(ref_r, hyp_r)[0]
        raw_len = raw_end - raw_start
        out["er_raw"] = {"errors": raw_dist, "ref_len": raw_len, "rate": raw_dist / raw_len if raw_len else None}
    else:
        out["er_raw"] = metrics.error_rate(ref_r, hyp_r, detail=False)
    out["er"] = metrics.error_rate(ref_n, hyp_n)
    return out


def score_run(ds, ref, finals, summary):
    texts = [u["text"] for u in finals]
    hyp_text = "\n".join(texts)
    unit = ref["unit"]
    r = {"finals": len(finals), "foreign": metrics.foreign_scripts(texts), "repetition": metrics.repetition(texts)["utterances"]}
    if summary:
        r.update({"rtf": summary.get("rtf"), "elapsed": summary.get("elapsed"), "audio_seconds": summary.get("audioSeconds")})
    kind = ds["kind"]
    if kind == "govinfo":
        lo, hi = ref.get("en_range") or [0, float("inf")]
        hyp_tokens = toks(in_range(finals, lo, hi), "word")
        ref_tokens = toks(ref["en_text"], "word")
        r["er"] = metrics.error_rate(ref_tokens, only(hyp_tokens, "en"))
        r["en_wer"] = r["er"]
        r["en_retention"] = metrics.english_retention(ref_tokens, hyp_tokens)
        if ref.get("ja_text") and ref.get("ja_range"):
            ja_hyp = only(toks(in_range(finals, *ref["ja_range"]), "word"), "ja")
            r["ja_cer"] = metrics.error_rate(only(toks(ref["ja_text"], "word"), "ja"), ja_hyp)
        return r
    r.update(score_text(ref["text"], hyp_text, unit, ref.get("window", "full")))
    if ref.get("parts"):
        r["parts"] = {p["name"]: metrics.error_rate(toks(p["text"], unit), toks(in_range(finals, *p["range"]), unit), detail=False)
                      for p in ref["parts"]}
    hyp_words = toks(hyp_text, "word")
    if ref.get("en_text"):
        ref_en = toks(ref["en_text"], "word")
        r["en_wer"] = metrics.error_rate(only(ref_en, "en"), only(hyp_words, "en"))
        r["en_retention"] = metrics.english_retention(ref_en, hyp_words)
    elif "en" in ref.get("languages", []):
        ref_words = toks(ref["text"], "word")
        r["en_retention"] = metrics.english_retention(ref_words, hyp_words)
        if "ja" in ref.get("languages", []):   # 混在で区間の言語が分からないとき（手元の録音）は文字種で分ける
            r["en_wer"] = metrics.error_rate(only(ref_words, "en"), only(hyp_words, "en"))
    if ref.get("ja_text") or ("ja" in ref.get("languages", []) and "en" in ref.get("languages", [])):
        ja_ref = ref.get("ja_text") or ref["text"]
        r["ja_cer"] = metrics.error_rate(only(toks(ja_ref, "word"), "ja"), only(hyp_words, "ja"))
    return r


def in_range(finals, lo, hi):
    """開始時刻が [lo, hi) の確定発話の本文を改行でつなぐ。"""
    return "\n".join(u["text"] for u in finals if u["start"] is not None and lo <= u["start"] < hi)


def leaked(utt, track, ref_utts, unit, slack=1.0, threshold=0.5):
    """自分のトラックの発話 utt が、同じ時刻の相手の正解によく合うか（相手の声がこのトラックに入って文字になった）。"""
    hyp = toks(utt["text"], unit)
    if not hyp or utt["start"] is None:
        return False
    end = utt["end"] if utt["end"] is not None else utt["start"]
    near = [u for u in ref_utts if u["start"] <= end + slack and utt["start"] - slack <= u["end"]]

    def ratio(us):
        ref = [t for u in us for t in toks(u["text"], unit)]
        return metrics.search_distance(ref, hyp)[0] / len(hyp) if ref else 1.0
    own = ratio([u for u in near if u.get("track") == track])
    other = ratio([u for u in near if u.get("track") not in (track, None)])
    return other < threshold and other < own


def score_tracks(ref, track_finals):
    """トラックごとの誤り率、2 トラック合計（話者を分けた上での誤り率）、相手の声の混入。"""
    unit = ref["unit"]
    out, errors, ref_len = {}, 0, 0
    for name, finals in sorted(track_finals.items()):
        texts = [u["text"] for u in finals]
        er = metrics.error_rate(toks(ref["tracks"][name], unit), toks("\n".join(texts), unit))
        leaks = [u for u in finals if leaked(u, name, ref.get("utterances", []), unit)]
        out[name] = {"er": er, "finals": len(finals), "repetition": metrics.repetition(texts)["utterances"],
                     "leak": {"utterances": len(leaks), "chars": sum(len(toks(u["text"], unit)) for u in leaks),
                              "hyp_chars": er["hyp_len"]}}
        errors += er["errors"]
        ref_len += er["ref_len"]
    out["combined"] = {"errors": errors, "ref_len": ref_len, "rate": errors / ref_len if ref_len else None}
    return out


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--label", required=True)
    ap.add_argument("--datasets", default="")
    ap.add_argument("--out", default="")
    ap.add_argument("--set-baseline", action="store_true")
    args = ap.parse_args(argv)
    decl = common.load_datasets()
    label_dir = os.path.join(common.DATA, "runs", args.label)
    meta = common.load_json(os.path.join(label_dir, "meta.json"))
    selected = common.select(decl, args.datasets)
    result = {"label": args.label, "date": datetime.date.today().isoformat(), "build": meta.get("build", {}),
              "model": meta.get("model"), "norm_version": textnorm.NORM_VERSION, "scorer_version": SCORER_VERSION,
              "datasets": {}}
    private = False
    for ds in selected:
        ref_path = os.path.join(common.prepared_dir(ds["id"]), "ref.json")
        run_dir = common.run_dir(args.label, ds["id"])
        if not os.path.exists(ref_path) or not os.path.isdir(run_dir):
            continue
        private = private or bool(ds.get("private"))
        ref = common.load_json(ref_path)
        entry = {"title": ds.get("title", ds["id"]), "kind": ds["kind"], "unit": ref["unit"],
                 "audio_seconds": ref.get("audio_seconds"), "ref_window": ref.get("window", "full"), "runs": {}}
        for name in sorted(os.listdir(run_dir)):
            if not name.endswith(".jsonl"):
                continue
            finals, summary = common.read_jsonl(os.path.join(run_dir, name))
            if summary is None:
                continue
            engine, lang = name[:-len(".jsonl")].rsplit("-", 1)
            print("採点: %s %s %s" % (ds["id"], engine, lang), flush=True)
            scored = score_run(ds, ref, finals, summary)
            if ref.get("tracks"):
                track_finals = {}
                for track in ref["tracks"]:
                    tpath = os.path.join(run_dir, "tracks", "%s-%s-%s.jsonl" % (track, engine, lang))
                    if os.path.exists(tpath):
                        tf, tsum = common.read_jsonl(tpath)
                        if tsum is not None:
                            track_finals[track] = tf
                if len(track_finals) == len(ref["tracks"]):
                    scored["tracks"] = score_tracks(ref, track_finals)
            exit_path = os.path.join(run_dir, name[:-len(".jsonl")] + ".exit")
            if os.path.exists(exit_path):
                with open(exit_path) as f:
                    scored["exit_code"] = int(f.read().strip() or 0)
            entry["runs"]["%s/%s" % (engine, lang)] = scored
        result["datasets"][ds["id"]] = entry
    if private:
        result["private"] = True   # 手元の録音を含む。集計値だけだが、共有するかは利用者が決める
    # 手元の録音を含む結果は、既定ではリポジトリの外（.eval-data/results/）に置く。
    results_dir = os.path.join(common.DATA, "results") if private else common.RESULTS
    out = args.out or os.path.join(results_dir, "%s-%s.json" % (result["date"], args.label))
    common.write_json(out, result)
    print("score: %s" % os.path.relpath(out, common.ROOT))
    if args.set_baseline:
        if private:
            sys.exit("手元の録音を含む結果は基準にしない（--datasets で公開データだけにする）")
        common.write_json(common.BASELINE, result)
        print("基準にした: %s" % os.path.relpath(common.BASELINE, common.ROOT))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
