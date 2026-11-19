"""会見録（WARP）・大統領文書の全段落・ELAN の変換のテスト（外部のファイルは使わない）。"""

import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import refs  # noqa: E402

KAIKEN = """<html><body><div class="warp-banner">保存日 2024</div>
<p>動画が再生できない方は</p>
<h3>【岸田総理冒頭発言】</h3>
<p>本日は、御説明をいたします。</p>
<p>尖閣（せんかく）（諸島）について申し上げます。</p>
<h3>【質疑応答】</h3>
<p>（内閣広報官）</p><p>それでは、御質問を頂きます。</p>
<p>（記者）</p><p>日本経済新聞の秋山です。</p><p>お願いします。</p>
<p>（岸田総理）</p><p>お答えします。</p>
<p>関連リンク</p><p>ほかの会見</p>
<h3>【岸田総理冒頭発言】</h3><p>本日は、御説明をいたします。</p>
</body></html>"""

GOV = """<p class="s1">Administration of Donald J. Trump, 2025</p><h1>The President's News Conference</h1>
<p class="s1">February 7, 2025</p>
<p class="s2">President Trump<span class="p">. Thank you very much.</span></p>
<p class="s2">Audience member. <span class="p">Ahh.</span></p>
<p>[<i>The President gave the Prime Minister a book.</i>] Okay, thank you.</p>
<p class="s1">U.S. Trade Policy</p>
<p class="s2">Q<span class="p">. Mr. President, a question? [Laughter]</span></p>
<p class="s2">Prime Minister Ishiba<span class="p">. I am unable to respond.</span></p>
<p>N<span class="s3">OTE</span>: The President spoke at 2:20 p.m.</p>
<p>Categories: Interviews.</p>"""

EAF = """<?xml version="1.0" encoding="utf-8"?>
<ANNOTATION_DOCUMENT FORMAT="3.0" VERSION="3.0">
  <HEADER TIME_UNITS="milliseconds"/>
  <TIME_ORDER>
    <TIME_SLOT TIME_SLOT_ID="ts1" TIME_VALUE="3470"/><TIME_SLOT TIME_SLOT_ID="ts2" TIME_VALUE="4440"/>
    <TIME_SLOT TIME_SLOT_ID="ts3" TIME_VALUE="4750"/><TIME_SLOT TIME_SLOT_ID="ts4" TIME_VALUE="5630"/>
    <TIME_SLOT TIME_SLOT_ID="ts5" TIME_VALUE="6000"/><TIME_SLOT TIME_SLOT_ID="ts6" TIME_VALUE="7000"/>
  </TIME_ORDER>
  <TIER TIER_ID="speaker_1">
    <ANNOTATION><ALIGNABLE_ANNOTATION ANNOTATION_ID="a1" TIME_SLOT_REF1="ts1" TIME_SLOT_REF2="ts2">
      <ANNOTATION_VALUE>でも<la>そうですね<?></ANNOTATION_VALUE></ALIGNABLE_ANNOTATION></ANNOTATION>
    <ANNOTATION><ALIGNABLE_ANNOTATION ANNOTATION_ID="a2" TIME_SLOT_REF1="ts5" TIME_SLOT_REF2="ts6">
      <ANNOTATION_VALUE><la></ANNOTATION_VALUE></ALIGNABLE_ANNOTATION></ANNOTATION>
  </TIER>
  <TIER TIER_ID="speaker_2">
    <ANNOTATION><ALIGNABLE_ANNOTATION ANNOTATION_ID="a3" TIME_SLOT_REF1="ts3" TIME_SLOT_REF2="ts4">
      <ANNOTATION_VALUE>うん。</ANNOTATION_VALUE></ALIGNABLE_ANNOTATION></ANNOTATION>
  </TIER>
</ANNOTATION_DOCUMENT>"""


class KaikenTests(unittest.TestCase):
    def test_turns_have_roles_sections_and_no_readings(self):
        turns = refs.kaiken_turns(KAIKEN)
        self.assertEqual([(t["section"], t["role"]) for t in turns], [
            ("岸田総理冒頭発言", "総理"), ("質疑応答", "内閣広報官"), ("質疑応答", "記者"), ("質疑応答", "岸田総理")])
        self.assertEqual(turns[0]["text"], "本日は、御説明をいたします。尖閣について申し上げます。")
        self.assertEqual(turns[2]["text"], "日本経済新聞の秋山です。お願いします。")

    def test_stops_at_related_links_and_does_not_read_the_page_twice(self):
        turns = refs.kaiken_turns(KAIKEN)
        self.assertNotIn("ほかの会見", "".join(t["text"] for t in turns))
        self.assertEqual(sum(t["text"].count("本日は") for t in turns), 1)
        again = refs.kaiken_turns(KAIKEN.replace("<p>関連リンク</p><p>ほかの会見</p>", ""))
        self.assertEqual(sum(t["text"].count("本日は") for t in again), 1)

    def test_text_marks_where_questions_start(self):
        text, qa = refs.kaiken_text(refs.kaiken_turns(KAIKEN))
        self.assertTrue(text[qa:].startswith("それでは、御質問を頂きます。"))
        self.assertEqual(text.count("\n"), 3)

    def test_page_without_heading_is_an_error(self):
        with self.assertRaises(ValueError):
            refs.kaiken_turns("<p>本文だけ</p>")


class GovinfoParagraphTests(unittest.TestCase):
    def test_paragraphs_drop_headings_labels_notes_and_the_trailer(self):
        text = refs.govinfo_paragraphs(GOV)
        self.assertEqual(text.split("\n"), ["Thank you very much.", "Ahh.", "Okay, thank you.",
                                            "Mr. President, a question?", "I am unable to respond."])


class EafTests(unittest.TestCase):
    def test_utterances_are_sorted_and_marks_removed(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "x.eaf")
            with open(path, "w", encoding="utf-8") as f:
                f.write(EAF.replace("<la>", "&lt;la&gt;").replace("<?>", "&lt;?&gt;"))
            utts = refs.eaf_utterances(path)
        self.assertEqual(utts, [
            {"tier": "speaker_1", "start": 3.47, "end": 4.44, "text": "でもそうですね"},
            {"tier": "speaker_2", "start": 4.75, "end": 5.63, "text": "うん。"}])


if __name__ == "__main__":
    unittest.main()
