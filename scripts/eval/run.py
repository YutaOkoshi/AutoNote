#!/usr/bin/env python3
"""用意した音声を autonote dev transcribe で文字起こしする。済んだもの（summary 行のある jsonl）は飛ばす。

使い方: python3 -I scripts/eval/run.py --autonote <実行ファイル> --label <名前>
          [--datasets id,id] [--engines whisper,whisper-live] [--langs ja,auto] [--model-path <ggml.bin>] [--force]

- 出力: <data>/runs/<label>/<dataset>/<engine>-<lang>.jsonl（と .err）、<data>/runs/<label>/meta.json。
- 言語は datasets.json の langs（--langs で絞れる）。確定版 = whisper、ライブ = whisper-live。
- 話者別の音声があるデータ（tracks）は、トラックごとにも回す: <data>/runs/<label>/<dataset>/tracks/<トラック>-<engine>-<lang>.jsonl。
  アプリは「自分」（マイク）と「相手」（システム音声）を別々に文字起こしするので、その形を再現する。
- RTF を比べられるよう 1 本ずつ順に回す。--realtime は付けない（処理時間だけを測る）。
- --data には評価専用の一時ディレクトリを渡し、利用者の設定・録音には触れない。
- 1 つの label は 1 つのビルド（実行ファイルの SHA-256）だけ。違うビルドで続けようとすると止まる。
  meta.json の commit は「実行したときのその worktree の HEAD」で、ビルドした時点のものとは限らない。
"""

import argparse
import datetime
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import common  # noqa: E402

ENGINES = ("whisper", "whisper-live")


def model_path(decl, override):
    if override:
        return override
    m = decl["model"]
    return os.path.join(os.path.expanduser(m["dir"]), m["file"])


def build_info(autonote):
    """ビルドの識別。場所は「worktree の名前/その中の相対パス」だけにする（結果はコミットするので、
    ホームの絶対パス＝利用者名を入れない）。"""
    path = os.path.abspath(autonote)
    info = {"autonote": os.path.basename(path), "sha256": common.sha256_file(autonote)}
    repo = os.path.dirname(path)
    try:
        top = subprocess.run(["git", "-C", repo, "rev-parse", "--show-toplevel"], capture_output=True, text=True,
                             check=True).stdout.strip()
        head = subprocess.run(["git", "-C", repo, "rev-parse", "HEAD"], capture_output=True, text=True, check=True)
        branch = subprocess.run(["git", "-C", repo, "rev-parse", "--abbrev-ref", "HEAD"], capture_output=True, text=True)
        info["autonote"] = os.path.join(os.path.basename(top), os.path.relpath(path, os.path.realpath(top)))
        info["commit"] = head.stdout.strip()
        info["branch"] = branch.stdout.strip()
    except (subprocess.CalledProcessError, OSError):
        pass
    return info


def is_done(path):
    if not os.path.exists(path):
        return False
    _, summary = common.read_jsonl(path)
    return summary is not None


def transcribe(autonote, audio, engine, lang, model, out, timeout):
    app_dir = os.path.join(common.DATA, "app")
    os.makedirs(app_dir, exist_ok=True)
    cmd = [autonote, "dev", "transcribe", audio, "--engine", engine, "--model-path", model, "--lang", lang,
           "--data", app_dir]
    stem = out[:-len(".jsonl")]
    with open(out + ".tmp", "w", encoding="utf-8") as so, open(stem + ".err", "w") as se:
        code = subprocess.run(cmd, stdout=so, stderr=se, timeout=timeout).returncode
    if code != 0:
        _, summary = common.read_jsonl(out + ".tmp")
        if summary is None:
            raise RuntimeError("autonote dev transcribe が %d で終了（%s）" % (code, stem + ".err"))
        # 出力を書き終えた後に落ちた（終了処理など）。結果は使い、終了コードを残して採点の表に出す。
        print("  警告: 出力の後に終了コード %d（%s）" % (code, stem + ".err"), flush=True)
        with open(stem + ".exit", "w") as f:
            f.write("%d\n" % code)
    elif os.path.exists(stem + ".exit"):
        os.remove(stem + ".exit")
    os.replace(out + ".tmp", out)


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--autonote", required=True)
    ap.add_argument("--label", required=True)
    ap.add_argument("--datasets", default="")
    ap.add_argument("--engines", default=",".join(ENGINES))
    ap.add_argument("--langs", default="")
    ap.add_argument("--model-path", default="")
    ap.add_argument("--timeout", type=int, default=3600)
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--allow-build-change", action="store_true")
    args = ap.parse_args(argv)
    decl = common.load_datasets()
    model = model_path(decl, args.model_path)
    if not os.path.exists(model):
        sys.exit("モデルがない: %s" % model)
    engines = [e for e in args.engines.split(",") if e]
    only_langs = set(l for l in args.langs.split(",") if l)
    label_dir = os.path.join(common.DATA, "runs", args.label)
    meta_path = os.path.join(label_dir, "meta.json")
    build = build_info(args.autonote)
    if os.path.exists(meta_path):
        meta = common.load_json(meta_path)
        if meta.get("build", {}).get("sha256") != build["sha256"] and not args.allow_build_change:
            sys.exit("label %s は別のビルド（sha256 %s…）の結果を持っている。別の label にするか、"
                     "文字起こしに関係しない作り直しなら --allow-build-change" % (args.label, meta["build"]["sha256"][:12]))
        if meta.get("build", {}).get("sha256") != build["sha256"]:
            meta.setdefault("previous_builds", []).append(meta["build"])
            meta["build"] = build
    else:
        meta = {"label": args.label, "build": build, "model": os.path.basename(model),
                "started": datetime.datetime.now().isoformat(timespec="seconds")}
    if meta.get("model") != os.path.basename(model):
        sys.exit("label %s はモデル %s の結果を持っている" % (args.label, meta.get("model")))
    common.write_json(meta_path, meta)
    for ds in common.select(decl, args.datasets):
        audio = os.path.join(common.prepared_dir(ds["id"]), "audio.wav")
        if not os.path.exists(audio):
            print("飛ばす: %s（用意されていない。fetch.py を先に）" % ds["id"])
            continue
        for lang in ds["langs"]:
            if only_langs and lang not in only_langs:
                continue
            for engine in engines:
                out = os.path.join(common.run_dir(args.label, ds["id"]), "%s-%s.jsonl" % (engine, lang))
                if not is_done(out) or args.force:
                    os.makedirs(os.path.dirname(out), exist_ok=True)
                    print("文字起こし: %s %s %s %s" % (args.label, ds["id"], engine, lang), flush=True)
                    transcribe(args.autonote, audio, engine, lang, model, out, args.timeout)
                for track in sorted(ds.get("tracks", {})):
                    track_audio = os.path.join(common.prepared_dir(ds["id"]), "track-%s.wav" % track)
                    track_out = os.path.join(common.run_dir(args.label, ds["id"]), "tracks",
                                             "%s-%s-%s.jsonl" % (track, engine, lang))
                    if is_done(track_out) and not args.force:
                        continue
                    os.makedirs(os.path.dirname(track_out), exist_ok=True)
                    print("文字起こし: %s %s（%s）%s %s" % (args.label, ds["id"], track, engine, lang), flush=True)
                    transcribe(args.autonote, track_audio, engine, lang, model, track_out, args.timeout)
    print("run: 完了（%s）" % args.label)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
