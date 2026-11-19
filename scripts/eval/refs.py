"""取得したデータから正解を作る変換（Python 3.9 の標準ライブラリのみ。ダウンロードしたファイルを読むので
`python3 -I` で動かす）。

- AMI: words/<会議>.<話者>.words.xml（NXT 形式）→ 語（時刻・話者つき）→ 発話。abstractive/<会議>.abssumm.xml → 要約 4 区分。
- 国会会議録 API の JSON → 発言者の呼称・速記の注記・拍手などを除いた本文（発言ごとに改行）。
- govinfo の HTML（米国政府刊行物）→ 指定した 2 つの目印の間の英語本文、または話者ラベルと注記を除いた全段落。
- 官邸の会見録（WARP の保存版の HTML）→ 話者の区切り（冒頭発言・質疑応答の各発言）。
- ELAN（.eaf）→ 話者の層ごとの発話（時刻つき）。笑い・聞き取り不能の記号を除く。
"""

import glob
import html
import os
import re
import xml.etree.ElementTree as ET

_NITE_ID = "{http://nite.sourceforge.net/}id"


def ami_words(ann_dir, meeting):
    """全話者の語を開始時刻順に。{"start","end","speaker","word","punc"}。語以外（笑い・言い淀み記号）は除く。"""
    words = []
    for path in sorted(glob.glob(os.path.join(ann_dir, "words", "%s.*.words.xml" % meeting))):
        speaker = os.path.basename(path).split(".")[1]
        root = ET.parse(path).getroot()
        for el in root:
            if el.tag != "w" or el.text is None or el.get("starttime") is None:
                continue
            words.append({"start": float(el.get("starttime")), "end": float(el.get("endtime") or el.get("starttime")),
                          "speaker": speaker, "word": html.unescape(el.text.strip()), "punc": el.get("punc") == "true"})
    words.sort(key=lambda w: (w["start"], w["speaker"]))
    return words


def _join_words(words):
    out = ""
    for w in words:
        if not out:
            out = w["word"]
        elif w["punc"]:
            out += w["word"]
        else:
            out += " " + w["word"]
    return out


def ami_utterances(words, gap=1.0, max_seconds=30.0):
    """話者ごとに、語の間が gap 秒以上空くか max_seconds を超えたら区切る。開始時刻順の発話の一覧。"""
    by_speaker = {}
    for w in words:
        by_speaker.setdefault(w["speaker"], []).append(w)
    utts = []
    for speaker, ws in by_speaker.items():
        cur = []
        for w in ws:
            if cur and not w["punc"] and (w["start"] - cur[-1]["end"] >= gap or w["end"] - cur[0]["start"] > max_seconds):
                utts.append(cur)
                cur = []
            cur.append(w)
        if cur:
            utts.append(cur)
    out = []
    for ws in utts:
        real = [w for w in ws if not w["punc"]] or ws
        out.append({"start": real[0]["start"], "end": max(w["end"] for w in ws), "speaker": ws[0]["speaker"],
                    "text": _join_words(ws)})
    out.sort(key=lambda u: (u["start"], u["speaker"]))
    return out


def utterances_text(utts, start, end):
    """開始時刻が [start, end) の発話の本文を改行でつなぐ。"""
    return "\n".join(u["text"] for u in utts if start <= u["start"] < end)


def ami_summary(ann_dir, meeting):
    path = os.path.join(ann_dir, "abstractive", "%s.abssumm.xml" % meeting)
    root = ET.parse(path).getroot()
    out = {"abstract": [], "actions": [], "decisions": [], "problems": []}
    for section in root:
        if section.tag in out:
            out[section.tag] = [" ".join((s.text or "").split()) for s in section if s.tag == "sentence" and s.text]
    return out


_KOKKAI_SPEAKER = re.compile(r"^○[^　]*　")
_KOKKAI_NOTES = re.compile(r"〔[^〕]*〕|（拍手）|（[^（）]*(?:者あり|と呼ぶ)[^（）]*）")


def kokkai_text(data):
    """国会会議録 API（speechRecord）の発言本文。会議録情報（speechOrder 0）を除き、発言ごとに改行。"""
    lines = []
    for rec in data.get("speechRecord", []):
        if str(rec.get("speechOrder")) == "0":
            continue
        speech = rec.get("speech") or ""
        speech = _KOKKAI_SPEAKER.sub("", speech)
        speech = _KOKKAI_NOTES.sub("", speech)
        speech = re.sub(r"[\r\n　 ]+", "", speech)
        if speech:
            lines.append(speech)
    return "\n".join(lines)


def html_to_text(markup):
    text = re.sub(r"<[^>]*>", " ", markup)
    text = html.unescape(text)
    return " ".join(text.split())


def govinfo_excerpt(markup, start_marker, end_marker):
    """HTML を平文にし、start_marker の直後から end_marker の直前まで。"""
    text = html_to_text(markup)
    i = text.index(start_marker) + len(start_marker)
    j = text.index(end_marker, i)
    return text[i:j].strip()


def mixed_reference(spans):
    """合成の混在セットの正解: (全体, 英語の区間だけ, 日本語の区間だけ)。区間は改行でつなぐ。"""
    whole = "\n".join(s["text"] for s in spans)
    en = "\n".join(s["text"] for s in spans if s["lang"] == "en")
    ja = "\n".join(s["text"] for s in spans if s["lang"] == "ja")
    return whole, en, ja


_GOV_SPEAKER = re.compile(r"^(?:President [A-Z][a-z]+|Prime Minister [A-Z][a-z]+|Vice President [A-Z][a-z]+|Q|"
                          r"Audience member|Interpreter|Press Secretary [A-Z][a-z]+)\. ")


def govinfo_paragraphs(markup):
    """大統領文書の本文の段落（見出し・話者ラベル・[Laughter] などの注記・末尾の NOTE を除く）を改行でつなぐ。
    通訳を介した発言（Prime Minister … の段落）も英語として音声に出るので含める。"""
    out = []
    for attrs, p in re.findall(r"<p([^>]*)>(.*?)</p>", markup, flags=re.S | re.I):
        if 'class="s1"' in attrs:   # 文書の見出し・日付・話題の小見出し（読み上げない）
            continue
        text = " ".join(html.unescape(re.sub(r"<[^>]*>", "", p)).split())
        if text.startswith("NOTE:"):
            break
        if not text:
            continue
        text = _GOV_SPEAKER.sub("", text)
        text = re.sub(r"\[[^\]]*\]", " ", text)
        text = " ".join(text.split())
        if text:
            out.append(text)
    return "\n".join(out)


_KAIKEN_HEADER = re.compile(r"【([^】]*)】")
_KAIKEN_ROLE = re.compile(r"（([^（）]{1,15})）")


def kaiken_turns(markup):
    """官邸の会見録の本文 → [{"section", "role", "text"}]。section は【…冒頭発言】【質疑応答】など、role は
    （内閣広報官）（記者）（岸田総理）の行の名前（冒頭発言は「総理」）。本文中の（よみがな）（補足）は読み上げないので除く。
    WARP の保存版は同じ本文を 2 回載せるページがあるので、最初の見出しが 2 回目に出たら止める。"""
    t = re.sub(r"<(script|style)\b.*?</\1>", "", markup, flags=re.S | re.I)
    t = re.sub(r"<[^>]+>", "\n", t)
    lines = [l.strip() for l in html.unescape(t).split("\n")]
    lines = [l for l in lines if l]
    head = next((i for i, l in enumerate(lines) if _KAIKEN_HEADER.fullmatch(l)), None)
    if head is None:
        raise ValueError("会見録の見出し（【…】）が見つからない")
    turns, role, section = [], None, None
    for l in lines[head:]:
        if l in ("関連リンク", "もっと見る") or (turns and l == lines[head]):
            break
        m = _KAIKEN_HEADER.fullmatch(l)
        if m:
            section = m.group(1)
            role = "総理" if "総理" in section else None
            continue
        m = _KAIKEN_ROLE.fullmatch(l)
        if m:
            role = m.group(1)
            continue
        text = re.sub(r"（[^（）]*）", "", l)
        if turns and turns[-1]["role"] == role and turns[-1]["section"] == section:
            turns[-1]["text"] += text
        else:
            turns.append({"section": section, "role": role, "text": text})
    return turns


def kaiken_text(turns):
    """(本文（発言ごとに改行）, 質疑応答の始まりの文字位置 | None)。"""
    text, qa = "", None
    for t in turns:
        if qa is None and t["section"] == "質疑応答":
            qa = len(text) + (1 if text else 0)
        text = t["text"] if not text else text + "\n" + t["text"]
    return text, qa


_EAF_TAGS = re.compile(r"<[^<>]{0,8}>")


def eaf_utterances(path):
    """ELAN の .eaf → [{"tier", "start", "end", "text"}]（開始時刻順、秒）。<la>（笑い）<?>（聞き取り不能）などの
    記号は除き、空になった発話は捨てる。"""
    root = ET.parse(path).getroot()
    slots = {t.get("TIME_SLOT_ID"): t.get("TIME_VALUE") for t in root.iter("TIME_SLOT")}
    out = []
    for tier in root.iter("TIER"):
        for ann in tier.iter("ALIGNABLE_ANNOTATION"):
            v1, v2 = slots.get(ann.get("TIME_SLOT_REF1")), slots.get(ann.get("TIME_SLOT_REF2"))
            value = ann.find("ANNOTATION_VALUE")
            text = _EAF_TAGS.sub("", (value.text if value is not None else "") or "").strip()
            if v1 is None or v2 is None or not text:
                continue
            out.append({"tier": tier.get("TIER_ID"), "start": int(v1) / 1000.0, "end": int(v2) / 1000.0, "text": text})
    out.sort(key=lambda u: (u["start"], u["tier"]))
    return out
