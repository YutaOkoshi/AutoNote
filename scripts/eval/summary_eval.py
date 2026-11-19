#!/usr/bin/env python3
"""要約（議事録）の評価。AMI の正解の decisions・actions との突き合わせと、忠実性の採点を Claude に判定させる。

使い方: python3 -I scripts/eval/summary_eval.py --autonote <実行ファイル> --label <名前>
          [--datasets ami-ES2008a] [--inputs reference,final] [--allow-claude] [--judge-model <id>]

- 入力 2 通り: reference = AMI の正解の書き起こし（要約だけの力）、final = AutoNote の確定版（whisper、--lang en、
  会議の全長）の書き起こし（通しの力）。
- 要約は `autonote dev summarize --fake <transcript> --claude --minutes-out <path>`（アプリと同じ Claude 呼び出し）。
- 採点は `claude -p --output-format json --json-schema <schema>`（アプリと同じ固定の引数。道具なし・MCP なし・1 ターン）。
- **Claude を呼ぶのは --allow-claude を付けたときだけ**。結果は入力のハッシュでキャッシュし（<data>/cache/）、
  同じ入力では呼び直さない。キャッシュがなく --allow-claude もなければ、何を呼ぶかを表示して止まる。
- 結果は集計値だけ: docs/eval/results/<日付>-summary-<label>.json と .md。
"""

import argparse
import datetime
import json
import os
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import common  # noqa: E402
import fetch  # noqa: E402
import refs  # noqa: E402
import run as runner  # noqa: E402

PROMPT_VERSION = "judge-1"
SUMMARY_CACHE_VERSION = "summary-1"
DEFAULT_JUDGE_MODEL = "claude-sonnet-5-5"
CLAUDE_FIXED_ARGS = ["--tools", "", "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}',
                     "--no-session-persistence", "--max-turns", "1", "--setting-sources", "project"]

MATCH_SCHEMA = {
    "type": "object", "additionalProperties": False, "required": ["decisions", "actions"],
    "properties": {
        k: {"type": "array", "items": {
            "type": "object", "additionalProperties": False, "required": ["gold", "matches"],
            "properties": {"gold": {"type": "integer"}, "matches": {"type": "array", "items": {"type": "integer"}}}}}
        for k in ("decisions", "actions")},
}
FAITH_SCHEMA = {
    "type": "object", "additionalProperties": False, "required": ["items"],
    "properties": {"items": {"type": "array", "items": {
        "type": "object", "additionalProperties": False, "required": ["id", "verdict"],
        "properties": {"id": {"type": "string"}, "verdict": {"enum": ["supported", "partial", "unsupported"]}}}}},
}

MATCH_INSTRUCTIONS = """You are grading meeting minutes against a human reference.

Above are (1) the reference DECISIONS and ACTIONS written by human annotators of an English meeting, and (2) the
DECISIONS and NEXT ACTIONS produced by a minutes generator (possibly written in Japanese).

For every reference item, list the indices of generated items of the same kind that state the same decision or the
same action item (same substance; wording, language and level of detail may differ; an item that only partially
covers it still counts if its core is the same). Use an empty list when nothing matches. A generated item may match
several reference items. Compare decisions only with generated decisions and actions only with generated next
actions. Return JSON only, following the schema."""

FAITH_INSTRUCTIONS = """You are checking meeting minutes for faithfulness to the meeting transcript above.

For each minutes item listed above, decide whether the transcript supports it:
- supported: everything the item states is stated or clearly implied in the transcript.
- partial: the core is supported but some detail (a name, number, owner, date, or claim) is not.
- unsupported: the transcript does not support the item, or contradicts it.
The minutes may be written in Japanese while the transcript is English; judge the meaning, not the wording. Do not
reward or penalize style. Return one verdict per item id, JSON only, following the schema."""


# ---------------------------------------------------------------- inputs

def transcript_from_reference(decl, ds):
    ann = fetch.ann_dir(decl, ds)
    utts = refs.ami_utterances(refs.ami_words(ann, ds["meeting"]))
    return {"engine": "reference (AMI manual transcript)", "language": "en",
            "utterances": [{"start": round(u["start"], 3), "end": round(u["end"], 3), "speaker": "unknown",
                            "text": u["text"], "is_final": True} for u in utts]}


def transcript_from_final(decl, ds, autonote, label, model):
    full = os.path.join(common.prepared_dir(ds["id"]), "full.wav")
    if not os.path.exists(full):
        src = fetch.ensure_source(ds["audio"], decl["sources"][ds["audio"]])
        fetch.to_wav(src, full)
    out = os.path.join(common.run_dir(label, ds["id"]), "full-whisper-en.jsonl")
    if not runner.is_done(out):
        os.makedirs(os.path.dirname(out), exist_ok=True)
        print("文字起こし（全長）: %s" % ds["id"], flush=True)
        runner.transcribe(autonote, full, "whisper", "en", model, out, 3600)
    finals, _ = common.read_jsonl(out)
    return {"engine": "autonote whisper (final)", "language": "en",
            "utterances": [{"start": u["start"], "end": u["end"], "speaker": "unknown", "text": u["text"],
                            "is_final": True} for u in finals if u["text"].strip()]}


# ---------------------------------------------------------------- claude

class NeedsClaude(Exception):
    pass


def summarize(autonote, transcript, allow, calls):
    body = json.dumps(transcript, ensure_ascii=False, sort_keys=True)
    key = common.sha256_text("\n".join([SUMMARY_CACHE_VERSION, common.sha256_file(autonote), body]))
    path = os.path.join(common.DATA, "cache", "summaries", key + ".json")
    if os.path.exists(path):
        return common.load_json(path), True
    if not allow:
        raise NeedsClaude("要約（autonote dev summarize --claude）")
    work = tempfile.mkdtemp(prefix="summary-", dir=os.path.join(common.DATA, "cache"))
    try:
        tpath = os.path.join(work, "transcript.json")
        with open(tpath, "w", encoding="utf-8") as f:
            f.write(body)
        out = os.path.join(work, "minutes.json")
        res = subprocess.run([autonote, "dev", "summarize", "--fake", tpath, "--out", os.path.join(work, "out"),
                              "--claude", "--minutes-out", out], capture_output=True, text=True, timeout=1800)
        if res.returncode != 0:
            raise RuntimeError("dev summarize が %d で終了: %s" % (res.returncode, res.stderr.strip()[-500:]))
        minutes = common.load_json(out)
        common.write_json(path, minutes)
        calls.append({"kind": "summarize", "input_chars": len(body)})
        return minutes, False
    finally:
        shutil.rmtree(work, ignore_errors=True)


def claude_json(prompt, schema, model, allow, calls, what):
    schema_text = json.dumps(schema, sort_keys=True)
    key = common.sha256_text("\n".join([PROMPT_VERSION, model, schema_text, prompt]))
    path = os.path.join(common.DATA, "cache", "judge", key + ".json")
    if os.path.exists(path):
        return common.load_json(path), True
    if not allow:
        raise NeedsClaude(what)
    claude = shutil.which("claude") or os.path.expanduser("~/.local/bin/claude")
    cwd = tempfile.mkdtemp(prefix="judge-")
    try:
        args = [claude, "-p", "--output-format", "json", "--json-schema", schema_text] + CLAUDE_FIXED_ARGS
        if model:
            args += ["--model", model]
        res = subprocess.run(args, input=prompt, capture_output=True, text=True, cwd=cwd, timeout=900)
    finally:
        shutil.rmtree(cwd, ignore_errors=True)
    if res.returncode != 0:
        raise RuntimeError("claude -p が %d で終了: %s" % (res.returncode, (res.stderr or res.stdout)[-500:]))
    out = json.loads(res.stdout)
    if out.get("is_error") or "structured_output" not in out:
        raise RuntimeError("claude -p の結果に structured_output がない: %s" % str(out.get("subtype")))
    common.write_json(path, out)
    calls.append({"kind": what, "usage": out.get("usage"), "cost_usd": out.get("total_cost_usd"),
                  "models": sorted((out.get("modelUsage") or {}).keys())})
    return out, False


# ---------------------------------------------------------------- scoring

def numbered(items):
    return "\n".join("[%d] %s" % (i, t) for i, t in enumerate(items))


def generated_actions(minutes):
    out = []
    for a in minutes.get("next_actions", []):
        extra = [x for x in (("owner: " + a["owner"]) if a.get("owner") else "",
                             ("due: " + a["due"]) if a.get("due") else "") if x]
        out.append(a["text"] + (" (" + ", ".join(extra) + ")" if extra else ""))
    return out


def match_scores(gold, pred, verdicts):
    """gold の再現率と pred の適合率。verdicts = [{"gold": i, "matches": [j...]}]。範囲外の番号は捨てる。"""
    matched_gold = set()
    matched_pred = set()
    for v in verdicts:
        g = v.get("gold")
        ms = [j for j in v.get("matches", []) if isinstance(j, int) and 0 <= j < len(pred)]
        if isinstance(g, int) and 0 <= g < len(gold) and ms:
            matched_gold.add(g)
            matched_pred.update(ms)
    return {"gold": len(gold), "pred": len(pred), "matched_gold": len(matched_gold), "matched_pred": len(matched_pred),
            "recall": len(matched_gold) / len(gold) if gold else None,
            "precision": len(matched_pred) / len(pred) if pred else None}


def faith_items(minutes):
    items = []
    for i, s in enumerate(minutes.get("summary", [])):
        items.append(("summary.%d" % i, s))
    for i, d in enumerate(minutes.get("decisions", [])):
        items.append(("decision.%d" % i, d["text"]))
    for i, a in enumerate(generated_actions(minutes)):
        items.append(("action.%d" % i, a))
    for i, k in enumerate(minutes.get("key_points", [])):
        items.append(("key_point.%d" % i, (k.get("title", "") + ": " + k.get("body", "")).strip(": ")))
    return items


def faith_scores(items, verdicts):
    by_id = {v.get("id"): v.get("verdict") for v in verdicts}
    counts = {"supported": 0, "partial": 0, "unsupported": 0, "missing": 0}
    by_kind = {}
    for item_id, _ in items:
        verdict = by_id.get(item_id, "missing")
        counts[verdict] = counts.get(verdict, 0) + 1
        kind = item_id.split(".")[0]
        k = by_kind.setdefault(kind, {"items": 0, "supported": 0, "partial": 0, "unsupported": 0, "missing": 0})
        k["items"] += 1
        k[verdict] = k.get(verdict, 0) + 1
    n = len(items)
    score = (counts["supported"] + 0.5 * counts["partial"]) / n if n else None
    return dict(counts, items=n, score=score, by_kind=by_kind)


def transcript_text(transcript):
    return "\n".join(u["text"] for u in transcript["utterances"])


def evaluate(decl, ds, variant, args, calls):
    if variant == "reference":
        transcript = transcript_from_reference(decl, ds)
    else:
        transcript = transcript_from_final(decl, ds, args.autonote, args.label, runner.model_path(decl, ""))
    minutes, cached_summary = summarize(args.autonote, transcript, args.allow_claude, calls)
    gold = refs.ami_summary(fetch.ann_dir(decl, ds), ds["meeting"])
    pred_dec = [d["text"] for d in minutes.get("decisions", [])]
    pred_act = generated_actions(minutes)
    match_prompt = "\n\n".join([
        "<reference_decisions>\n%s\n</reference_decisions>" % numbered(gold["decisions"]),
        "<reference_actions>\n%s\n</reference_actions>" % numbered(gold["actions"]),
        "<generated_decisions>\n%s\n</generated_decisions>" % numbered(pred_dec),
        "<generated_next_actions>\n%s\n</generated_next_actions>" % numbered(pred_act),
        MATCH_INSTRUCTIONS])
    match, cached_match = claude_json(match_prompt, MATCH_SCHEMA, args.judge_model, args.allow_claude, calls, "judge-match")
    m = match["structured_output"]
    # 忠実性は、入力によらず正解の書き起こしを根拠にする（確定版の誤りから来た誤りも拾うため）。
    ref_transcript = transcript_text(transcript_from_reference(decl, ds))
    items = faith_items(minutes)
    faith_prompt = "\n\n".join([
        "<transcript>\n%s\n</transcript>" % ref_transcript,
        "<minutes_items>\n%s\n</minutes_items>" % "\n".join("%s: %s" % (i, t) for i, t in items),
        FAITH_INSTRUCTIONS])
    faith, cached_faith = claude_json(faith_prompt, FAITH_SCHEMA, args.judge_model, args.allow_claude, calls,
                                      "judge-faithfulness")
    return {
        "transcript_utterances": len(transcript["utterances"]),
        "minutes_schema_version": minutes.get("schema_version"),
        "decisions": match_scores(gold["decisions"], pred_dec, m.get("decisions", [])),
        "actions": match_scores(gold["actions"], pred_act, m.get("actions", [])),
        "faithfulness": faith_scores(items, faith["structured_output"].get("items", [])),
        "cached": {"summary": cached_summary, "match": cached_match, "faithfulness": cached_faith},
        "judge_models": sorted(set((match.get("modelUsage") or {}).keys()) | set((faith.get("modelUsage") or {}).keys())),
        "judge_usage": [usage_of(match), usage_of(faith)],
        "summarize_input_chars": len(json.dumps(transcript, ensure_ascii=False)),
    }


def usage_of(out):
    u = out.get("usage") or {}
    keep = {k: u.get(k) for k in ("input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens")}
    keep["cost_usd"] = out.get("total_cost_usd")
    return keep


def pct(x):
    return "–" if x is None else "%.0f%%" % (100 * x)


def render(res):
    lines = ["# 要約の評価: %s" % res["label"], "",
             "- 日付: %s、採点モデル: %s（%s）、プロンプト: %s" % (res["date"], res["judge_model"],
                                                     ", ".join(res.get("judge_models_seen", [])) or "キャッシュのみ",
                                                     res["prompt_version"]),
             "- 突き合わせ: AMI の decisions / actions と MinutesOutput の decisions / next_actions。再現率 = 正解のうち対応がついた割合、"
             "適合率 = 生成のうち正解のどれかに対応した割合",
             "- 忠実性: 要約・決定事項・次のアクション・要点の各項目を、正解の書き起こしに照らして supported / partial / "
             "unsupported で判定。スコア = (supported + 0.5 × partial) ÷ 項目数", "",
             "| データ | 入力 | 決定 再現率 | 決定 適合率 | アクション 再現率 | アクション 適合率 | 忠実性 | 項目 (S/P/U) |",
             "|---|---|---|---|---|---|---|---|"]
    for ds_id, ds in res["datasets"].items():
        for variant, r in ds.items():
            f = r["faithfulness"]
            lines.append("| %s | %s | %s (%d/%d) | %s (%d/%d) | %s (%d/%d) | %s (%d/%d) | %s | %d (%d/%d/%d) |" % (
                ds_id, variant,
                pct(r["decisions"]["recall"]), r["decisions"]["matched_gold"], r["decisions"]["gold"],
                pct(r["decisions"]["precision"]), r["decisions"]["matched_pred"], r["decisions"]["pred"],
                pct(r["actions"]["recall"]), r["actions"]["matched_gold"], r["actions"]["gold"],
                pct(r["actions"]["precision"]), r["actions"]["matched_pred"], r["actions"]["pred"],
                pct(f["score"]), f["items"], f["supported"], f["partial"], f["unsupported"]))
    lines.append("")
    return "\n".join(lines) + "\n"


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--autonote", required=True)
    ap.add_argument("--label", required=True)
    ap.add_argument("--datasets", default="ami-ES2008a")
    ap.add_argument("--inputs", default="reference,final")
    ap.add_argument("--judge-model", default=DEFAULT_JUDGE_MODEL)
    ap.add_argument("--allow-claude", action="store_true")
    ap.add_argument("--out", default="")
    args = ap.parse_args(argv)
    decl = common.load_datasets()
    calls = []
    result = {"label": args.label, "date": datetime.date.today().isoformat(), "judge_model": args.judge_model,
              "prompt_version": PROMPT_VERSION, "summary_cache_version": SUMMARY_CACHE_VERSION,
              "build": runner.build_info(args.autonote), "datasets": {}}
    try:
        for ds in common.select(decl, args.datasets):
            if not ds.get("summary"):
                continue
            fetch.ensure_source(ds["annotations"], decl["sources"][ds["annotations"]])
            for variant in [v for v in args.inputs.split(",") if v]:
                print("要約の評価: %s %s" % (ds["id"], variant), flush=True)
                result["datasets"].setdefault(ds["id"], {})[variant] = evaluate(decl, ds, variant, args, calls)
    except NeedsClaude as e:
        sys.exit("Claude の呼び出しが要る（%s）。キャッシュがない。呼んでよければ --allow-claude を付ける" % e)
    seen = set()
    for ds in result["datasets"].values():
        for r in ds.values():
            seen.update(r["judge_models"])
    result["judge_models_seen"] = sorted(seen)
    result["claude_calls_this_run"] = calls
    out = args.out or os.path.join(common.RESULTS, "%s-summary-%s.json" % (result["date"], args.label))
    common.write_json(out, result)
    with open(os.path.splitext(out)[0] + ".md", "w", encoding="utf-8") as f:
        f.write(render(result))
    print("summary_eval: %s（今回の Claude 呼び出し %d 回）" % (os.path.relpath(out, common.ROOT), len(calls)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
