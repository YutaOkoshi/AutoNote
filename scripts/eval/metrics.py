"""誤り率と出力の性質の指標（Python 3.9 の標準ライブラリのみ）。

- distance / search_distance: Myers のビット並列法（Hyyrö の定式化）で編集距離を速く出す。
  search_distance は出力（hyp）を参照（ref）の任意の区間に合わせたときの最小距離（時刻のない正解用）。
- align: 動的計画法で整列し、置換・脱落・挿入の内訳と、連続した脱落の最長を出す。
- locate: 時刻のない正解の中で、出力に最も合う区間 [start, end) を探す。
"""

import collections
import re

import textnorm


def _peq(tokens):
    peq = {}
    for i, t in enumerate(tokens):
        peq[t] = peq.get(t, 0) | (1 << i)
    return peq


def _myers(ref, hyp, search):
    """Columns are ref tokens, the bit vector is hyp. Returns the score after each ref token (list, len(ref))."""
    m = len(hyp)
    peq = _peq(hyp)
    mask = (1 << m) - 1
    high = 1 << (m - 1)
    pv, mv, score = mask, 0, m
    scores = []
    for r in ref:
        eq = peq.get(r, 0)
        xv = eq | mv
        xh = (((eq & pv) + pv) ^ pv) | eq
        ph = mv | (~(xh | pv) & mask)
        mh = pv & xh
        if ph & high:
            score += 1
        elif mh & high:
            score -= 1
        ph = (ph << 1) & mask
        mh = (mh << 1) & mask
        if not search:
            ph |= 1
        pv = mh | (~(xv | ph) & mask)
        mv = ph & xv
        scores.append(score)
    return scores


def distance(ref, hyp):
    if not hyp:
        return len(ref)
    if not ref:
        return len(hyp)
    return _myers(ref, hyp, search=False)[-1]


def search_distance(ref, hyp):
    """(最小距離, 合った区間の終端 end)。hyp が空なら (0, 0)。"""
    if not hyp:
        return 0, 0
    if not ref:
        return len(hyp), 0
    scores = _myers(ref, hyp, search=True)
    best = min(range(len(scores)), key=lambda j: (scores[j], j))
    best_score = scores[best]
    if best_score >= len(hyp):   # matching nothing at all is as good
        return len(hyp), 0
    return best_score, best + 1


def locate(ref, hyp):
    """参照の中で出力に最も合う区間 (start, end, distance)。"""
    dist, end = search_distance(ref, hyp)
    if end == 0:
        return 0, 0, dist
    head = list(reversed(ref[:end]))
    _, back_end = search_distance(head, list(reversed(hyp)))
    return end - back_end, end, dist


def align(ref, hyp):
    """全体の整列。{"hits","sub","del","ins","max_del_run","del_runs"}。del_runs は連続した脱落の長さの一覧。"""
    n, m = len(hyp), len(ref)
    prev = list(range(m + 1))
    back = []   # per hyp row: 0 = diag, 1 = from left (deletion of ref), 2 = from up (insertion of hyp)
    for i in range(1, n + 1):
        h = hyp[i - 1]
        cur = [i]
        row = bytearray(m + 1)
        row[0] = 2
        ap = cur.append
        for j in range(1, m + 1):
            s = prev[j - 1] + (h != ref[j - 1])
            d = cur[j - 1] + 1
            ins = prev[j] + 1
            if s <= d and s <= ins:
                ap(s)
            elif d <= ins:
                ap(d)
                row[j] = 1
            else:
                ap(ins)
                row[j] = 2
        back.append(row)
        prev = cur
    hits = sub = dele = ins = 0
    runs = []
    run = 0
    i, j = n, m
    while i > 0 or j > 0:
        if i == 0:
            op = 1
        elif j == 0:
            op = 2
        else:
            op = back[i - 1][j]
        if op == 1:
            dele += 1
            run += 1
            j -= 1
            continue
        if run:
            runs.append(run)
            run = 0
        if op == 0:
            if hyp[i - 1] == ref[j - 1]:
                hits += 1
            else:
                sub += 1
            i -= 1
            j -= 1
        else:
            ins += 1
            i -= 1
    if run:
        runs.append(run)
    return {"hits": hits, "sub": sub, "del": dele, "ins": ins, "max_del_run": max(runs) if runs else 0,
            "del_runs": sorted(runs, reverse=True)}


def edits(a):
    return a["sub"] + a["del"] + a["ins"]


def error_rate(ref, hyp, detail=True):
    """誤り率。detail=True なら整列して内訳も出す（遅い）。False なら距離だけ（速い）。"""
    if detail:
        a = align(ref, hyp)
        errors = edits(a)
        out = {"errors": errors, "ref_len": len(ref), "hyp_len": len(hyp), "sub": a["sub"], "del": a["del"],
               "ins": a["ins"], "max_del_run": a["max_del_run"]}
    else:
        errors = distance(ref, hyp)
        out = {"errors": errors, "ref_len": len(ref), "hyp_len": len(hyp)}
    out["rate"] = errors / len(ref) if ref else None
    return out


def foreign_scripts(utterances):
    """日本語・ラテン文字以外の文字種を含む発話の数と割合。"""
    by_script = collections.Counter()
    hit = 0
    for u in utterances:
        found = textnorm.unexpected_scripts(u)
        if found:
            hit += 1
            by_script.update(found)
    total = len(utterances)
    return {"utterances": total, "with_unexpected": hit, "rate": hit / total if total else 0.0,
            "by_script": dict(sorted(by_script.items()))}


def english_retention(ref_en_words, hyp_tokens):
    """正解の英語の語のうち、出力に英語の語として現れた割合（語の多重集合の重なり。順序は見ない）。"""
    ref = collections.Counter(w for w in ref_en_words if textnorm.token_script(w) == "en")
    hyp = collections.Counter(t for t in hyp_tokens if textnorm.token_script(t) == "en")
    kept = sum(min(c, hyp[w]) for w, c in ref.items())
    total = sum(ref.values())
    return {"kept": kept, "ref": total, "rate": kept / total if total else None}


_CHAR_LOOP = re.compile(r"(.{2,12}?)\1{2,}")


def is_repetitive(text):
    """繰り返しの幻覚らしい発話か。2〜12 文字の単位が 3 回以上、2 語以上の句が 3 回以上、1 語が 4 回以上続く。"""
    norm = textnorm.normalize(text, "norm")
    words = norm.split()
    if any(not textnorm.is_cjk(c) for c in "".join(words)) and len(words) > 1:
        for n in range(1, 5):
            need = 4 if n == 1 else 3
            for start in range(0, len(words) - n * need + 1):
                unit = words[start:start + n]
                if all(words[start + k * n:start + (k + 1) * n] == unit for k in range(need)):
                    return True
    compact = "".join(words)
    m = _CHAR_LOOP.search(compact)
    if m and not m.group(1).isascii():
        return True
    return False


def repetition(utterances):
    """繰り返しの幻覚: 発話の中のループと、同じ発話が 3 回以上続くもの（数えるのは発話の数）。"""
    flagged = set(i for i, u in enumerate(utterances) if is_repetitive(u))
    i = 0
    while i < len(utterances):
        j = i
        key = textnorm.normalize(utterances[i], "norm")
        while j + 1 < len(utterances) and textnorm.normalize(utterances[j + 1], "norm") == key and key:
            j += 1
        if j - i + 1 >= 3:
            flagged.update(range(i, j + 1))
        i = j + 1
    return {"utterances": len(flagged)}
