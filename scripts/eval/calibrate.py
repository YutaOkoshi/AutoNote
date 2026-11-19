#!/usr/bin/env python3
"""時刻のない正解（国会会議録）に区切りの位置を決め、合成の混在セットの区間を選ぶ（一度だけ回して結果を残す）。

使い方: python3 -I scripts/eval/calibrate.py --autonote <実行ファイル> [--model-path <ggml.bin>] [--datasets id,id]

--datasets を付けないときは党首討論と合成の混在セット（下の 1・2）。付けたときはそのデータだけを決め、ほかの
項目は残す（会見 kind kaiken・日米会見 kind govinfo）:
- 会見: 音声全体を確定版・ja で文字起こしし、会見録の【質疑応答】の書き出しが出る時刻を探す。そこから
  qa_lead_seconds 秒前の発話の頭を clip_start（切り出しの始め）にし、clip_start から max_seconds 秒に出た発話を
  会見録に整列して正解の範囲（ref_start_char / ref_end_char）を決める。qa_time_in_clip は冒頭発言と質疑の境目。
- 日米会見: 用意した音声をライブ・auto（混在をいちばんよく書き分ける）で文字起こしし、英語の語を大統領文書に
  整列して英語の正解の範囲（en_start_char / en_end_char、en_paragraphs のとき）を、日本語の文字を官邸の冒頭発言に
  整列して冒頭発言の時刻の範囲（ja_range）を決める。

- 党首討論の音声全体を確定版（whisper、--lang ja）で文字起こしし、会議録に整列する。
  1. 先頭 max_seconds 秒に当たる会議録の範囲 → calibration.json（ref_start_char / ref_end_char）。
     これで、どのビルドも同じ正解の範囲で採点される（出力に合わせて範囲が動く採点を避ける）。
  2. max_seconds 以降から、出力と会議録がよく合う発話のまとまり（15〜35 秒）を選ぶ → mixed-spans.json の ja 区間。
     切れ目は、確定版の発話の境目に音声の無音（silencedetect -35 dB・0.3 秒以上）が重なる所の、無音の中央。
     正解の範囲は確定版の出力との整列で決めるので境界の数文字がずれうる（区間内の CER が 15% 以下のものだけ選ぶ）。
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
    # 確定版の発話は隙間なく続くので、切れ目は音声の無音（silencedetect）が発話の境目にかかる所だけにする。
    silences = detect_silences(full_wav, limit + 30)
    cuts = {}   # k → 発話 k の終わり（= k+1 の始まり）に置く切れ目の時刻
    for k in range(len(tail) - 1):
        b = tail[k]["end"]
        for s0, s1 in silences:
            if s0 - 0.5 <= b <= s1 + 0.5:
                cuts[k] = (s0 + s1) / 2.0
                break
    keys = sorted(cuts)
    candidates = []
    a = 0
    while a < len(keys):
        i = keys[a] + 1                          # first utterance of the span
        found = None
        for b in keys[a + 1:]:
            t0, t1 = cuts[keys[a]], cuts[b]
            if t1 - t0 < JA_MIN:
                continue
            if t1 - t0 > JA_MAX:
                break
            j = b                                # last utterance of the span
            if i in first and j in last:
                r0, r1 = first[i], last[j] + 1
                span_hyp = [c for k in range(i, j + 1) for c in norm_chars(tail[k]["text"])]
                cer = metrics.distance(window[r0:r1], span_hyp) / max(1, r1 - r0)
                if cer <= 0.15:
                    found = (t0, t1, r0, r1, cer, b)
            break
        if found:
            candidates.append(found[:5])
            a = keys.index(found[5])
        else:
            a += 1
    picked = spread(candidates, PAIRS)
    spans = []
    for start, end, r0, r1, cer in picked:
        spans.append({"lang": "ja", "start": round(start, 3), "end": round(end, 3),
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


def detect_silences(wav, from_seconds):
    """ffmpeg silencedetect（-35 dB・0.3 秒以上）の無音区間 [(start, end)]（音声の先頭からの秒）。"""
    import re
    import subprocess
    res = subprocess.run(["ffmpeg", "-nostdin", "-ss", str(from_seconds), "-i", wav, "-af",
                          "silencedetect=noise=-35dB:d=0.3", "-f", "null", "-"], capture_output=True, text=True)
    starts = [float(x) for x in re.findall(r"silence_start: ([0-9.]+)", res.stderr)]
    ends = [float(x) for x in re.findall(r"silence_end: ([0-9.]+)", res.stderr)]
    return [(from_seconds + s0, from_seconds + s1) for s0, s1 in zip(starts, ends)]


def spread(candidates, n):
    if len(candidates) <= n:
        return candidates
    step = len(candidates) / float(n)
    return [candidates[int(k * step)] for k in range(n)]


def made_with(autonote, model):
    made = runner.build_info(autonote)
    return {"commit": made.get("commit"), "branch": made.get("branch"), "model": os.path.basename(model),
            "norm_version": textnorm.NORM_VERSION}


def word_tokens_with_owner(finals, script):
    """確定発話の語の単位（日本語は 1 文字、英語は 1 語）のうち script のものと、それぞれの発話の番号。"""
    toks, owner = [], []
    for k, u in enumerate(finals):
        for t in textnorm.tokenize(textnorm.normalize(u["text"], "norm"), "word"):
            if textnorm.token_script(t) == script:
                toks.append(t)
                owner.append(k)
    return toks, owner


def transcribe_once(autonote, wav, engine, lang, model, name):
    out = os.path.join(common.DATA, "calibration", name)
    if not runner.is_done(out):
        os.makedirs(os.path.dirname(out), exist_ok=True)
        print("文字起こし（%s）" % name, flush=True)
        runner.transcribe(autonote, wav, engine, lang, model, out, 3600)
    return common.read_jsonl(out)[0]


def kaiken_calibration(decl, ds, autonote, model):
    src = fetch.ensure_source(ds["audio"], decl["sources"][ds["audio"]])
    full_wav = os.path.join(common.prepared_dir(ds["id"]), "full.wav")
    if not os.path.exists(full_wav):
        fetch.to_wav(src, full_wav)
    finals = transcribe_once(autonote, full_wav, "whisper", "ja", model, "%s-full-whisper-ja.jsonl" % ds["id"])
    raw, qa = refs.kaiken_text(refs.kaiken_turns(fetch.read_text(fetch.ensure_source(ds["record"], decl["sources"][ds["record"]]))))
    if qa is None:
        sys.exit("%s: 会見録に【質疑応答】がない" % ds["id"])
    ref = norm_chars(raw)
    qa_tok = len(norm_chars(raw[:qa]))
    hyp, owner = [], []
    for k, u in enumerate(finals):
        cs = norm_chars(u["text"])
        hyp.extend(cs)
        owner.extend([k] * len(cs))
    # 質疑応答の書き出し（正解の 200 文字）が出力のどこに出るか
    snippet = ref[qa_tok:qa_tok + 200]
    hs, he, hd = metrics.locate(hyp, snippet)
    qa_cer = hd / max(1, len(snippet))
    if he == 0 or qa_cer > 0.35:
        sys.exit("%s: 質疑応答の書き出しが出力に見つからない（CER %.2f）" % (ds["id"], qa_cer))
    qa_time = finals[owner[hs]]["start"]
    want = qa_time - ds.get("qa_lead_seconds", 300)
    first = next((u for u in finals if u["start"] >= want), finals[0]) if want > 0 else finals[0]
    clip_start = max(0.0, round(first["start"] - 0.3, 1)) if want > 0 else 0.0
    clip_end = clip_start + ds["max_seconds"]
    window = [c for u in finals if clip_start <= u["start"] < clip_end for c in norm_chars(u["text"])]
    s, e, d = metrics.locate(ref, window)
    cal = {"clip_start": clip_start, "qa_time_in_clip": round(qa_time - clip_start, 1),
           "ref_start_char": fetch.raw_to_char_offset(raw, s), "ref_end_char": fetch.raw_to_char_offset(raw, e),
           "qa_char": qa, "ref_tokens": [s, e, len(ref)], "located_cer": round(d / max(1, e - s), 4),
           "qa_located_cer": round(qa_cer, 4)}
    print("%s: 質疑は %.0f 秒から（書き出しの CER %.2f）→ 切り出し %.1f〜%.1f 秒、会見録の文字 %d..%d（CER %.3f）" % (
        ds["id"], qa_time, qa_cer, clip_start, clip_end, cal["ref_start_char"], cal["ref_end_char"], cal["located_cer"]))
    return cal


def govinfo_calibration(decl, ds, autonote, model):
    fetch.prepare(decl, ds)   # 音声（と、まだ範囲のない正解）を用意する
    wav = os.path.join(common.prepared_dir(ds["id"]), "audio.wav")
    finals = transcribe_once(autonote, wav, "whisper-live", "auto", model, "%s-whisper-live-auto.jsonl" % ds["id"])
    cal = {}
    markup = fetch.read_text(fetch.ensure_source(ds["record"], decl["sources"][ds["record"]]))
    if ds.get("en_paragraphs"):
        raw = refs.govinfo_paragraphs(markup)
        ref = [t for t in textnorm.tokenize(textnorm.normalize(raw, "norm"), "word")]
        hyp, _ = word_tokens_with_owner(finals, "en")
        s, e, d = metrics.locate(ref, hyp)
        cal.update({"en_start_char": raw_to_word_offset(raw, s), "en_end_char": raw_to_word_offset(raw, e),
                    "en_tokens": [s, e, len(ref)], "en_located_wer": round(d / max(1, e - s), 4)})
        print("%s: 英語の正解 語 %d..%d / %d（WER %.3f）" % (ds["id"], s, e, len(ref), cal["en_located_wer"]))
    if ds.get("ja_record"):
        turns = refs.kaiken_turns(fetch.read_text(fetch.ensure_source(ds["ja_record"], decl["sources"][ds["ja_record"]])))
        opening = "\n".join(t["text"] for t in turns if "冒頭発言" in (t["section"] or ""))
        ref_ja = [t for t in textnorm.tokenize(textnorm.normalize(opening, "norm"), "word") if textnorm.token_script(t) == "ja"]
        hyp, owner = word_tokens_with_owner(finals, "ja")
        hs, he, hd = metrics.locate(hyp, ref_ja)
        if he == 0:
            sys.exit("%s: 冒頭発言が出力に見つからない" % ds["id"])
        t0 = finals[owner[hs]]["start"]
        t1 = finals[owner[he - 1]]["end"] or finals[owner[he - 1]]["start"]
        cal.update({"ja_range": [round(max(0.0, t0 - 0.5), 1), round(t1 + 0.5, 1)],
                    "ja_located_cer": round(hd / max(1, len(ref_ja)), 4)})
        print("%s: 日本語の冒頭発言 %.1f〜%.1f 秒（CER %.3f）" % (ds["id"], t0, t1, cal["ja_located_cer"]))
    return cal


def raw_to_word_offset(raw, token_count):
    """語の単位の位置 → 素の本文の文字位置。二分探索は語の途中（1 文字目の直後）で止まるので、語の終わりまで進める。"""
    if token_count == 0:
        return 0
    i = fetch.raw_to_char_offset(raw, token_count, "word")
    while i < len(raw) and (raw[i].isalnum() or raw[i] in "'’-"):
        i += 1
    return i


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--autonote", required=True)
    ap.add_argument("--model-path", default="")
    ap.add_argument("--datasets", default="")
    args = ap.parse_args(argv)
    decl = common.load_datasets(include_local=False)
    by_id = {d["id"]: d for d in decl["datasets"]}
    model = runner.model_path(decl, args.model_path)
    if args.datasets:
        cal_path = os.path.join(common.EVAL_DIR, "calibration.json")
        calib = common.load_json(cal_path) if os.path.exists(cal_path) else {}
        for ds in common.select(decl, args.datasets):
            if ds["kind"] == "kaiken":
                cal = kaiken_calibration(decl, ds, args.autonote, model)
            elif ds["kind"] == "govinfo":
                cal = govinfo_calibration(decl, ds, args.autonote, model)
            else:
                sys.exit("%s: この種類（%s）は --datasets で決めない" % (ds["id"], ds["kind"]))
            calib[ds["id"]] = dict(cal, made_with=made_with(args.autonote, model))
            common.write_json(cal_path, calib)
        print("calibrate: calibration.json（%s）" % args.datasets)
        return 0
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
