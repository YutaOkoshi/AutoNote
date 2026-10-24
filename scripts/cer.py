#!/usr/bin/env python3
"""文字誤り率（CER）を出す（計画 00 Task 5 のスパイク用）。Python 3 の標準ライブラリだけで動く。

使い方: python3 -I scripts/cer.py [--no-punct] <hyp.txt> <ref.txt>

- 両方のテキストを NFKC で正規化し（全角英数と半角英数の差を消す）、空白・改行を除いてから、
  文字単位の Levenshtein 距離 ÷ 参照テキストの文字数を出す。
- --no-punct を付けると、句読点・括弧など Unicode の P* カテゴリの文字も除く
  （whisper の句読点の付け方の差を CER から外して見たいとき用）。
- 出力は 1 行: `<CER 小数 4 桁> (<距離>/<参照文字数>)`
"""

import sys
import unicodedata


def normalize(text, no_punct):
    text = unicodedata.normalize("NFKC", text)
    return "".join(
        c
        for c in text
        if not c.isspace() and not (no_punct and unicodedata.category(c).startswith("P"))
    )


def levenshtein(a, b):
    if len(a) < len(b):
        a, b = b, a
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def main(argv):
    no_punct = "--no-punct" in argv
    paths = [a for a in argv if a != "--no-punct"]
    if len(paths) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    with open(paths[0], encoding="utf-8") as f:
        hyp = normalize(f.read(), no_punct)
    with open(paths[1], encoding="utf-8") as f:
        ref = normalize(f.read(), no_punct)
    if not ref:
        print("参照テキストが空", file=sys.stderr)
        return 1
    dist = levenshtein(hyp, ref)
    print(f"{dist / len(ref):.4f} ({dist}/{len(ref)})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
