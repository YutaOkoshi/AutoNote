#!/usr/bin/env python3
"""公開データの取得・検証と、評価用の音声・正解の用意。取得済み・用意済みのものは飛ばす。

使い方: python3 -I scripts/eval/fetch.py [--datasets id,id] [--force-prepare]

- 取得は datasets.json の sources。User-Agent は汎用名、要求の間は 3 秒以上空け、429/5xx は待って再試行する。
- SHA-256 を照合する。宣言が空なら値を表示する（確かめて datasets.json に書く）。sha256_may_change の
  もの（API の応答など）は一致しなくても警告だけにする。
- 用意: <data>/prepared/<id>/audio.wav（ffmpeg で 16 kHz モノラル・先頭 max_seconds 秒）と ref.json。
"""

import argparse
import os
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import common  # noqa: E402
import refs  # noqa: E402
import textnorm  # noqa: E402

_last_request = [0.0]


def _wait_turn():
    gap = time.time() - _last_request[0]
    if gap < 3.0:
        time.sleep(3.0 - gap)
    _last_request[0] = time.time()


def download(url, dest):
    tmp = dest + ".part"
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    for attempt in range(5):
        _wait_turn()
        req = urllib.request.Request(url, headers={"User-Agent": common.USER_AGENT})
        try:
            with urllib.request.urlopen(req, timeout=120) as resp, open(tmp, "wb") as out:
                shutil.copyfileobj(resp, out, 1 << 20)
            os.replace(tmp, dest)
            return
        except urllib.error.HTTPError as e:
            if e.code in (429, 500, 502, 503, 504) and attempt < 4:
                wait = 10 * (attempt + 1)
                print("  HTTP %d、%d 秒待って再試行" % (e.code, wait), file=sys.stderr)
                time.sleep(wait)
                continue
            raise
    raise RuntimeError("download failed: %s" % url)


def ensure_source(name, src):
    path = os.path.join(common.DATA, src["path"])
    if not os.path.exists(path):
        if not src.get("url"):
            sys.exit("%s がない（手元のデータは自分で置く）: %s" % (name, path))
        print("取得: %s" % name)
        download(src["url"], path)
    digest = common.sha256_file(path)
    want = src.get("sha256", "")
    if not want:
        print("  %s の sha256 は宣言なし。実際の値: %s（確かめて datasets.json に書く）" % (name, digest))
    elif digest != want:
        msg = "%s の sha256 が宣言と違う: %s（宣言 %s）" % (name, digest, want)
        if src.get("sha256_may_change"):
            print("  警告: " + msg)
        else:
            sys.exit(msg)
    extract = src.get("extract")
    if extract:
        target = os.path.join(common.DATA, extract)
        if not os.path.isdir(target):
            print("展開: %s" % name)
            safe_extract(path, target)
    return path


def safe_extract(zip_path, target):
    root = os.path.realpath(target)
    with zipfile.ZipFile(zip_path) as z:
        for info in z.infolist():
            dest = os.path.realpath(os.path.join(target, info.filename))
            if not (dest == root or dest.startswith(root + os.sep)):
                sys.exit("zip の中に展開先の外を指すパスがある: %s" % info.filename)
        z.extractall(target)


def to_wav(src, dest, start=0.0, seconds=None, extra_filters=None):
    """ffmpeg で 16 kHz モノラル 16bit の WAV にする。"""
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    cmd = ["ffmpeg", "-nostdin", "-v", "error", "-y"]
    if start:
        cmd += ["-ss", "%.3f" % start]
    cmd += ["-i", src]
    if seconds:
        cmd += ["-t", "%.3f" % seconds]
    if extra_filters:
        cmd += ["-af", extra_filters]
    cmd += ["-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", dest + ".tmp.wav"]
    subprocess.run(cmd, check=True)
    os.replace(dest + ".tmp.wav", dest)


def wav_seconds(path):
    import wave
    with wave.open(path, "rb") as w:
        return w.getnframes() / float(w.getframerate())


def ann_dir(decl, ds_or_src):
    return os.path.join(common.DATA, decl["sources"][ds_or_src["annotations"]]["extract"])


def raw_to_char_offset(raw, token_count, unit="char"):
    """正規化後のトークン数 token_count に対応する、素の本文の文字位置（先頭からの長さ）。"""
    lo, hi = 0, len(raw)
    while lo < hi:
        mid = (lo + hi) // 2
        if len(textnorm.tokenize(textnorm.normalize(raw[:mid], "norm"), unit)) < token_count:
            lo = mid + 1
        else:
            hi = mid
    return lo


def calibration():
    path = os.path.join(common.EVAL_DIR, "calibration.json")
    return common.load_json(path) if os.path.exists(path) else {}


def prepare(decl, ds, force=False):
    out_dir = common.prepared_dir(ds["id"])
    audio_out = os.path.join(out_dir, "audio.wav")
    ref_out = os.path.join(out_dir, "ref.json")
    kind = ds["kind"]
    if kind == "mixed":
        return prepare_mixed(decl, ds, force)
    src_path = ensure_source(ds["audio"], decl["sources"][ds["audio"]])
    if force or not os.path.exists(audio_out):
        print("音声: %s" % ds["id"])
        to_wav(src_path, audio_out, seconds=ds.get("max_seconds"))
    seconds = wav_seconds(audio_out)
    if not force and os.path.exists(ref_out):
        return
    if kind == "local" and not os.path.exists(os.path.join(common.DATA, ds["reference"])):
        print("正解はまだない: %s（local.py draft → 直す → local.py import）" % ds["id"])
        return
    ref = {"dataset": ds["id"], "unit": ds["unit"], "audio_seconds": round(seconds, 3)}
    if kind == "ami":
        ensure_source(ds["annotations"], decl["sources"][ds["annotations"]])
        utts = refs.ami_utterances(refs.ami_words(ann_dir(decl, ds), ds["meeting"]))
        ref["text"] = refs.utterances_text(utts, 0, seconds)
        ref["languages"] = ["en"]
    elif kind == "kokkai":
        rec = ensure_source(ds["record"], decl["sources"][ds["record"]])
        full = refs.kokkai_text(common.load_json(rec))
        cal = calibration().get(ds["id"], {})
        if ds.get("ref_window") == "calibrated" and cal.get("ref_end_char"):
            ref["text"] = full[cal.get("ref_start_char", 0):cal["ref_end_char"]]
            ref["window"] = "calibrated"
        else:
            ref["text"] = full
            ref["window"] = "locate"
        ref["languages"] = ["ja"]
    elif kind == "govinfo":
        rec = ensure_source(ds["record"], decl["sources"][ds["record"]])
        with open(rec, encoding="utf-8", errors="replace") as f:
            markup = f.read()
        ref["en_text"] = refs.govinfo_excerpt(markup, ds["en_excerpt"]["start"], ds["en_excerpt"]["end"])
        ref["en_range"] = ds["en_range"]
        ref["languages"] = ["ja", "en"]
    elif kind == "local":
        ref.update(prepare_local_ref(ds))
    else:
        sys.exit("unknown dataset kind: %s" % kind)
    common.write_json(ref_out, ref)


def prepare_local_ref(ds):
    """手元の録音: 利用者が直した書き起こし（local.py import で取り込んだもの）を正解にする。"""
    path = os.path.join(common.DATA, ds["reference"])
    if not os.path.exists(path):
        sys.exit("正解がない: %s（docs/eval/README.md の手順で取り込む）" % path)
    gold = common.load_json(path)
    out = {"text": gold["text"], "languages": ds.get("languages", ["ja"])}
    if gold.get("en_text"):
        out["en_text"] = gold["en_text"]
    return out


def prepare_mixed(decl, ds, force=False):
    out_dir = common.prepared_dir(ds["id"])
    audio_out = os.path.join(out_dir, "audio.wav")
    ref_out = os.path.join(out_dir, "ref.json")
    spans_path = os.path.join(common.EVAL_DIR, ds["spans"])
    if not os.path.exists(spans_path):
        print("飛ばす: %s（%s がない。calibrate.py で作る）" % (ds["id"], ds["spans"]))
        return
    if not force and os.path.exists(audio_out) and os.path.exists(ref_out):
        return
    spans = common.load_json(spans_path)
    en_src = ds["en_source"]
    en_audio = ensure_source(en_src["audio"], decl["sources"][en_src["audio"]])
    ensure_source(en_src["annotations"], decl["sources"][en_src["annotations"]])
    words = refs.ami_words(ann_dir(decl, en_src), en_src["meeting"])
    ja_ds = next(d for d in decl["datasets"] if d["id"] == ds["ja_source"]["dataset"])
    ja_audio = ensure_source(ja_ds["audio"], decl["sources"][ja_ds["audio"]])
    ja_full = refs.kokkai_text(common.load_json(ensure_source(ja_ds["record"], decl["sources"][ja_ds["record"]])))
    tmp = os.path.join(out_dir, "parts")
    os.makedirs(tmp, exist_ok=True)
    parts, ref_spans = [], []
    gap = spans.get("silence", 0.6)
    silence = os.path.join(tmp, "silence.wav")
    subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-y", "-f", "lavfi", "-i",
                    "anullsrc=r=16000:cl=mono", "-t", str(gap), "-c:a", "pcm_s16le", silence], check=True)
    clock = 0.0
    for i, sp in enumerate(spans["spans"]):
        part = os.path.join(tmp, "%02d-%s.wav" % (i, sp["lang"]))
        src = en_audio if sp["lang"] == "en" else ja_audio
        to_wav(src, part, start=sp["start"], seconds=sp["end"] - sp["start"], extra_filters="loudnorm=I=-23:TP=-2")
        if sp["lang"] == "en":
            text = refs._join_words([w for w in words if sp["start"] <= w["start"] and w["end"] <= sp["end"]])
        else:
            text = ja_full[sp["ref_start"]:sp["ref_end"]]
        dur = wav_seconds(part)
        ref_spans.append({"lang": sp["lang"], "text": text, "start": round(clock, 3), "end": round(clock + dur, 3)})
        parts.extend([part, silence])
        clock += dur + gap
    listing = os.path.join(tmp, "list.txt")
    with open(listing, "w") as f:
        for p in parts:
            f.write("file '%s'\n" % p.replace("'", "'\\''"))
    subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-y", "-f", "concat", "-safe", "0", "-i", listing,
                    "-c:a", "pcm_s16le", audio_out + ".tmp.wav"], check=True)
    os.replace(audio_out + ".tmp.wav", audio_out)
    shutil.rmtree(tmp)
    whole, en, ja = refs.mixed_reference(ref_spans)
    common.write_json(ref_out, {"dataset": ds["id"], "unit": ds["unit"], "audio_seconds": round(wav_seconds(audio_out), 3),
                                "text": whole, "en_text": en, "ja_text": ja, "spans": ref_spans,
                                "languages": ["ja", "en"]})
    print("音声: %s（%d 区間）" % (ds["id"], len(ref_spans)))


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--datasets", default="")
    ap.add_argument("--force-prepare", action="store_true")
    args = ap.parse_args(argv)
    if not shutil.which("ffmpeg"):
        sys.exit("ffmpeg がない（brew install ffmpeg）")
    decl = common.load_datasets()
    for ds in common.select(decl, args.datasets):
        prepare(decl, ds, args.force_prepare)
    print("fetch: 完了")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
