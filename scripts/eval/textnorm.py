"""採点用のテキスト正規化と分割（Python 3.9 の標準ライブラリのみ）。

正規化は 2 段:
- raw: NFKC だけ（句読点・大文字小文字を残す）。「素の値」用。
- norm: NFKC、小文字化、漢数字と「3万5000」の算用数字化、数字の桁区切りの除去、フィラー除去、
  句読点・記号を空白に置き換え。主指標用。参照と出力の両方に同じ規則を当てる。

規則を変えたら NORM_VERSION を上げる（結果ファイルに記録され、基準との比較で版違いを警告する）。
"""

import re
import unicodedata

NORM_VERSION = "norm-1"

# 日本語のフィラー（伸ばし棒の長さ違いを含む）。「あの」「その」「まあ」は語としても使うので伸ばした形だけ除く。
_JA_FILLERS = re.compile(r"(?:えー+っ?と|ええと|えっと|えー+|あの[ー〜]+|その[ー〜]+|うー+ん|んー+|あー+|うー+|おー+)")
_EN_FILLERS = {"um", "umm", "uh", "uhm", "hmm", "hm", "mm", "mmm", "mhm", "mm-hmm", "uh-huh", "erm", "er", "ah", "eh"}

_KANJI_DIGITS = {"〇": 0, "零": 0, "一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9}
_SMALL_UNITS = {"十": 10, "百": 100, "千": 1000}
_BIG_UNITS = {"万": 10_000, "億": 100_000_000}
_KANJI_RUN = re.compile("[〇零一二三四五六七八九十百千][〇零一二三四五六七八九十百千万億]*")
_ARABIC_UNITS = re.compile(r"(\d+)(?:億(\d+)?)?(?:万(\d+)?)?")

_WORD_TOKEN = re.compile(r"[^\W\d_]+(?:['-][^\W\d_]+)*|\d+(?:['][^\W\d_]+)?|\S", re.UNICODE)


def _kanji_run_value(run):
    if not any(c in _SMALL_UNITS or c in _BIG_UNITS for c in run):
        return "".join(str(_KANJI_DIGITS[c]) for c in run)
    total = section = current = 0
    for c in run:
        if c in _KANJI_DIGITS:
            current = current * 10 + _KANJI_DIGITS[c] if current else _KANJI_DIGITS[c]
        elif c in _SMALL_UNITS:
            section += (current or 1) * _SMALL_UNITS[c]
            current = 0
        else:
            total += (section + current or 1) * _BIG_UNITS[c]
            section = current = 0
    return str(total + section + current)


def _arabic_units(m):
    whole = m.group(0)
    if "万" not in whole and "億" not in whole:
        return whole
    num, after_oku, after_man = m.group(1), m.group(2), m.group(3)
    if "億" in whole:
        value = int(num) * 100_000_000
        if "万" in whole:
            value += int(after_oku or 0) * 10_000 + int(after_man or 0)
        else:
            value += int(after_oku or 0)
    else:
        value = int(num) * 10_000 + int(after_man or 0)
    return str(value)


def kanji_numerals(text):
    """漢数字の連なりを算用数字にし、「3万5000」のような単位つき算用数字も 1 つの数にする。"""
    text = _ARABIC_UNITS.sub(_arabic_units, text)
    return _KANJI_RUN.sub(lambda m: _kanji_run_value(m.group(0)), text)


def normalize(text, level):
    text = unicodedata.normalize("NFKC", text)
    if level == "raw":
        return text
    if level != "norm":
        raise ValueError("level must be raw or norm")
    text = text.replace("’", "'").replace("‘", "'").lower()
    text = re.sub(r"(?<=\d),(?=\d{3}(?!\d))", "", text)
    text = kanji_numerals(text)
    text = _JA_FILLERS.sub(" ", text)
    out = []
    for i, c in enumerate(text):
        cat = unicodedata.category(c)
        keep_apostrophe = c == "'" and 0 < i < len(text) - 1 and text[i - 1].isalnum() and text[i + 1].isalnum()
        keep_hyphen = c == "-" and 0 < i < len(text) - 1 and text[i - 1].isalpha() and text[i + 1].isalpha()
        if (cat.startswith("P") or cat.startswith("S")) and not keep_apostrophe and not keep_hyphen:
            out.append(" ")
        else:
            out.append(c)
    words = [w for w in "".join(out).split() if w not in _EN_FILLERS]
    # Hyphenated words other than fillers are split so "remote-control" equals "remote control".
    return " ".join(" ".join(w.split("-")) for w in words)


def is_cjk(c):
    name = unicodedata.name(c, "")
    return name.startswith(("CJK", "HIRAGANA", "KATAKANA", "IDEOGRAPHIC", "HALFWIDTH KATAKANA"))


def tokenize(text, mode):
    """char: 空白以外の 1 文字ずつ。word: 英語などは語、日本語の文字は 1 文字ずつ（混在の単位 = MER）。"""
    if mode == "char":
        return [c for c in text if not c.isspace()]
    if mode != "word":
        raise ValueError("mode must be char or word")
    tokens = []
    segment = []

    def flush():
        if segment:
            tokens.extend(m.group(0) for m in _WORD_TOKEN.finditer("".join(segment)))
            segment.clear()

    for c in text:
        if is_cjk(c):
            flush()
            tokens.append(c)
        else:
            segment.append(c)
    flush()
    return tokens


def token_script(token):
    """ja（日本語の文字）/ en（ラテン文字の語）/ other（数字・記号など）。"""
    if token and all(is_cjk(c) for c in token):
        return "ja"
    if token and token[0].isalpha() and unicodedata.name(token[0], "").startswith("LATIN"):
        return "en"
    return "other"


_ALLOWED_PREFIXES = ("LATIN", "CJK", "HIRAGANA", "KATAKANA", "IDEOGRAPHIC", "HALFWIDTH KATAKANA", "FULLWIDTH LATIN",
                     "COMBINING")


def unexpected_scripts(text):
    """日本語・ラテン文字以外の文字（キリル・ハングルなど）の文字種名の集合。数字・記号・空白は数えない。"""
    found = set()
    for c in text:
        cat = unicodedata.category(c)
        if not (cat.startswith("L") or cat.startswith("M")):
            continue
        name = unicodedata.name(c, "UNKNOWN")
        if name.startswith(_ALLOWED_PREFIXES):
            continue
        found.add(name.split()[0])
    return found
