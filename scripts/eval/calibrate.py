#!/usr/bin/env python3
"""時刻のない正解（国会会議録）に区切りの位置を決め、合成の混在セットの区間を選ぶ（一度だけ回して結果を残す）。

使い方: python3 -I scripts/eval/calibrate.py --autonote <実行ファイル> [--model-path <ggml.bin>]

- 党首討論の音声全体を確定版（whisper、--lang ja）で文字起こしし、会議録に整列する。
  1. 先頭 max_seconds 秒に当たる会議録の範囲 → calibration.json（ref_start_char / ref_end_char）。
     これで、どのビルドも同じ正解の範囲で採点される（出力に合わせて範囲が動く採点を避ける）。
  2. max_seconds 以降から、出力と会議録がよく合う発話のまとまり（15〜35 秒）を選ぶ → mixed-spans.json の ja 区間。
     区間の切れ目は確定版の発話の時刻なので、境界の数語がずれることがある（区間内の CER が 15% 以下のものだけ選ぶ）。
- 英語の区間は AMI TS3003c の後半から、語の時刻で前後 0.5 秒に他の発話がないまとまり（12〜30 秒）を選ぶ。
- 結果のファイルには時刻と文字位置（数値）だけを書く。本文は書かない。
"""

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import common  # noqa: E402
import fetch  # noqa: E402
import metrics  # noqa: E402
import refs  # noqa: E402
import run as runner  # noqa: E402
import textnorm  # noqa: E402

PAIRS = 8
JA_MIN, JA_MAX = 15.0, 35.0
EN_MIN, EN_MAX = 12.0, 30.0


def norm_chars(text):
    return textnorm.tokenize(textnorm.normalize(text, "norm"), "char")


def ja_calibration(decl, toron, autonote, model):
    src = fetch.ensure_source(toron["audio"], decl["sources"][toron["audio"]])
    full_wav = os.path.join(common.prepared_dir(toron["id"]), "full.wav")
    if not os.path.exists(full_wav):
        fetch.to_wav(src, full_wav)
    out = os.path.join(common.DATA, "calibration", "toron-full-whisper-ja.jsonl")
    if not runner.is_done(out):
        os.makedirs(os.path.dirname(out), exist_ok=True)
        print("文字起こし（党首討論の全体）", flush=True)
        runner.transcribe(autonote, full_wav, "whisper", "ja", model, out, 3600)
    finals, _ = common.read_jsonl(out)
    raw = refs.kokkai_text(common.load_json(fetch.ensure_source(toron["record"], decl["sources"][toron["record"]])))
    ref = norm_chars(raw)
    limit = toron["max_seconds"]

    head = [c for u in finals if u["start"] < limit for c in norm_chars(u["text"])]
    s, e, d = metrics.locate(ref, head)
    cal = {"ref_start_char": fetch.raw_to_char_offset(raw, s), "ref_end_char": fetch.raw_to_char_offset(raw, e),
           "ref_tokens": [s, e, len(ref)], "located_cer": round(d / max(1, e - s), 4)}
    print("党首討論 先頭 %d 秒 → 会議録の文字 %d..%d（正規化後 %d..%d / %d、CER %.3f）" % (
        limit, cal["ref_start_char"], cal["ref_end_char"], s, e, len(ref), cal["located_cer"]))

    # 後半: 発話ごとのトークン範囲を会議録に写す
    tail = [u for u in finals if u["start"] >= limit + 30]
    hyp, owner = [], []
    for k, u in enumerate(tail):
        cs = norm_chars(u["text"])
        hyp.extend(cs)
        owner.extend([k] * len(cs))
    ts, te, _ = metrics.locate(ref[e:], hyp)
    window = ref[e + ts:e + te]
    pairs = metrics.align(window, hyp, pairs=True)["pairs"]
    first, last = {}, {}
    for r, h in pairs:
        if r is None or h is None:
            continue
        k = owner[h]
        first.setdefault(k, r)
        last[k] = r
    candidates = []
    i = 0
    while i < len(tail):
        j = i
        while j < len(tail) and tail[j]["end"] - tail[i]["start"] < JA_MIN:
            j += 1
        if j >= len(tail) or tail[j]["end"] - tail[i]["start"] > JA_MAX:
            i += 1
            continue
        gap_before = tail[i]["start"] - (tail[i - 1]["end"] if i > 0 else 0)
        gap_after = (tail[j + 1]["start"] if j + 1 < len(tail) else 1e9) - tail[j]["end"]
        if gap_before >= 0.4 and gap_after >= 0.4 and i in first and j in last:
            r0, r1 = first[i], last[j] + 1
            span_hyp = [c for k in range(i, j + 1) for c in norm_chars(tail[k]["text"])]
            cer = metrics.distance(window[r0:r1], span_hyp) / max(1, r1 - r0)
            if cer <= 0.15:
                candidates.append((tail[i]["start"], tail[j]["end"], r0, r1, cer))
                i = j + 1
                continue
        i += 1
    picked = spread(candidates, PAIRS)
    spans = []
    for start, end, r0, r1, cer in picked:
        spans.append({"lang": "ja", "start": round(max(0.0, start - 0.15), 3), "end": round(end + 0.25, 3),
                      "ref_start": fetch.raw_to_char_offset(raw, e + ts + r0),
                      "ref_end": fetch.raw_to_char_offset(raw, e + ts + r1), "calibration_cer": round(cer, 4)})
    print("日本語の区間: 候補 %d → %d" % (len(candidates), len(spans)))
    return cal, spans


def en_spans(decl, mixed):
    src = mixed["en_source"]
    words = refs.ami_words(fetch.ann_dir(decl, src), src["meeting"])
    utts = refs.ami_utterances(words)
    start_from = 1260.0
    utts = [u for u in utts if u["start"] >= start_from]

    def isolated(t0, t1):
        # no word of anybody may straddle the edges, or sit within 0.5 s outside them
        for w in words:
            if (w["start"] < t0 < w["end"]) or (w["start"] < t1 < w["end"]):
                return False
            if t0 - 0.5 < w["end"] <= t0 or t1 <= w["start"] < t1 + 0.5:
                return False
        return True

    candidates = []
    i = 0
    while i < len(utts):
        j = i
        while j < len(utts) and utts[j]["end"] - utts[i]["start"] < EN_MIN:
            j += 1
        if j < len(utts):
            t0, t1 = utts[i]["start"], max(u["end"] for u in utts[i:j + 1])
            if t1 - t0 <= EN_MAX and isolated(t0, t1):
                candidates.append((t0, t1))
                i = j + 1
                continue
        i += 1
    picked = spread(candidates, PAIRS)
    print("英語の区間: 候補 %d → %d" % (len(candidates), len(picked)))
    return [{"lang": "en", "start": round(t0 - 0.2, 3), "end": round(t1 + 0.2, 3)} for t0, t1, *_ in picked]


def spread(candidates, n):
    if len(candidates) <= n:
        return candidates
    step = len(candidates) / float(n)
    return [candidates[int(k * step)] for k in range(n)]


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--autonote", required=True)
    ap.add_argument("--model-path", default="")
    args = ap.parse_args(argv)
    decl = common.load_datasets(include_local=False)
    by_id = {d["id"]: d for d in decl["datasets"]}
    model = runner.model_path(decl, args.model_path)
    toron, mixed = by_id["kantei-toron"], by_id["mixed-synth"]
    fetch.ensure_source(mixed["en_source"]["annotations"], decl["sources"][mixed["en_source"]["annotations"]])
    cal, ja = ja_calibration(decl, toron, args.autonote, model)
    en = en_spans(decl, mixed)
    made = runner.build_info(args.autonote)
    made = {"commit": made.get("commit"), "branch": made.get("branch"), "model": os.path.basename(model),
            "norm_version": textnorm.NORM_VERSION}
    cal_path = os.path.join(common.EVAL_DIR, "calibration.json")
    calib = common.load_json(cal_path) if os.path.exists(cal_path) else {}
    calib["kantei-toron"] = dict(cal, made_with=made)
    common.write_json(cal_path, calib)
    spans = []
    for k in range(min(len(en), len(ja))):
        spans += [en[k], ja[k]]
    common.write_json(os.path.join(common.EVAL_DIR, mixed["spans"]),
                      {"version": 1, "silence": 0.6, "made_with": made, "spans": spans})
    print("calibrate: calibration.json と %s（%d 区間）" % (mixed["spans"], len(spans)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
