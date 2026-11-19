"""評価スクリプトの共通部分: 置き場所、宣言の読み込み、JSON の読み書き、ハッシュ。

置き場所（すべて git 管理外の .eval-data/。環境変数 EVAL_DATA で変えられる）:
  <data>/<source path>                 取得したそのままのファイル（datasets.json の sources[].path）
  <data>/prepared/<dataset>/audio.wav  16 kHz モノラル・先頭 max_seconds 秒
  <data>/prepared/<dataset>/ref.json   正解（本文を含むのでリポジトリに入れない）
  <data>/runs/<label>/<dataset>/<engine>-<lang>.jsonl  autonote dev transcribe の出力
  <data>/cache/                        要約の採点のキャッシュ
"""

import hashlib
import json
import os
import sys

EVAL_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(EVAL_DIR))
DATA = os.environ.get("EVAL_DATA") or os.path.join(ROOT, ".eval-data")
RESULTS = os.path.join(ROOT, "docs", "eval", "results")
BASELINE = os.path.join(ROOT, "docs", "eval", "baseline.json")

# Web への要求に使う User-Agent。利用者・プロジェクトを特定できる情報を入れない。
USER_AGENT = "eval-fetch/1.0 (python-urllib)"


def load_json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def write_json(path, value):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(value, f, ensure_ascii=False, indent=2, sort_keys=False)
        f.write("\n")
    os.replace(tmp, path)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def sha256_text(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def load_datasets(include_local=True):
    """datasets.json と、あれば datasets.local.json（手元の録音。git 管理外）を合わせた宣言。"""
    decl = load_json(os.path.join(EVAL_DIR, "datasets.json"))
    local_path = os.environ.get("EVAL_DATASETS_LOCAL") or os.path.join(EVAL_DIR, "datasets.local.json")
    if include_local and os.path.exists(local_path):
        local = load_json(local_path)
        decl["sources"].update(local.get("sources", {}))
        for ds in local.get("datasets", []):
            ds["private"] = True
            decl["datasets"].append(ds)
    return decl


def select(decl, names):
    """--datasets の指定（カンマ区切り、空ならすべて。private は明示したときだけ）。"""
    if not names:
        return [d for d in decl["datasets"] if not d.get("private") and not d.get("disabled")]
    wanted = [n.strip() for n in names.split(",") if n.strip()]
    by_id = {d["id"]: d for d in decl["datasets"]}
    out = []
    for n in wanted:
        if n == "local":
            out.extend(d for d in decl["datasets"] if d.get("private"))
        elif n in by_id:
            out.append(by_id[n])
        else:
            sys.exit("unknown dataset: %s" % n)
    return out


def prepared_dir(ds_id):
    return os.path.join(DATA, "prepared", ds_id)


def run_dir(label, ds_id):
    return os.path.join(DATA, "runs", label, ds_id)


def read_jsonl(path):
    """autonote dev transcribe の出力 → (確定発話の一覧 [{start,end,text}], summary か None)。"""
    finals, summary = [], None
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            obj = json.loads(line)
            if "summary" in obj:
                summary = obj["summary"]
            elif obj.get("final"):
                finals.append({"start": obj.get("start"), "end": obj.get("end"), "text": obj.get("text", "")})
    return finals, summary
