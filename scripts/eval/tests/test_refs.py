import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import refs  # noqa: E402

WORDS_A = """<?xml version="1.0" encoding="ISO-8859-1" standalone="yes"?>
<nite:root nite:id="X.A.words" xmlns:nite="http://nite.sourceforge.net/">
   <vocalsound nite:id="X.A.words0" starttime="1.0" endtime="1.5" type="laugh"/>
   <w nite:id="X.A.words1" starttime="2.0" endtime="2.2">Okay</w>
   <w nite:id="X.A.words2" starttime="2.2" endtime="2.2" punc="true">.</w>
   <w nite:id="X.A.words3" starttime="2.3" endtime="2.5">I&#39;m</w>
   <w nite:id="X.A.words4" starttime="2.5" endtime="2.9">here</w>
   <w nite:id="X.A.words5" starttime="10.0" endtime="10.4">Later</w>
</nite:root>
"""
WORDS_B = """<?xml version="1.0" encoding="ISO-8859-1" standalone="yes"?>
<nite:root nite:id="X.B.words" xmlns:nite="http://nite.sourceforge.net/">
   <w nite:id="X.B.words1" starttime="3.0" endtime="3.4">Hello</w>
   <disfmarker nite:id="X.B.words2" starttime="3.4" endtime="3.4"/>
</nite:root>
"""
ABSSUMM = """<?xml version="1.0" encoding="ISO-8859-1" standalone="yes"?>
<nite:root xmlns:nite="http://nite.sourceforge.net/">
<abstract nite:id="a"><sentence nite:id="s1">They met.</sentence></abstract>
<actions nite:id="b"><sentence nite:id="s2">PM will email.</sentence> <sentence nite:id="s3">ID will draw.</sentence></actions>
<decisions nite:id="c"><sentence nite:id="s4">Use a red case.</sentence></decisions>
<problems nite:id="d"></problems>
</nite:root>
"""


class AmiTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        os.makedirs(os.path.join(self.dir, "words"))
        os.makedirs(os.path.join(self.dir, "abstractive"))
        for name, body in (("X.A.words.xml", WORDS_A), ("X.B.words.xml", WORDS_B)):
            with open(os.path.join(self.dir, "words", name), "w", encoding="latin-1") as f:
                f.write(body)
        with open(os.path.join(self.dir, "abstractive", "X.abssumm.xml"), "w", encoding="latin-1") as f:
            f.write(ABSSUMM)

    def test_words_skip_non_words_and_unescape(self):
        words = refs.ami_words(self.dir, "X")
        self.assertEqual([w["word"] for w in words], ["Okay", ".", "I'm", "here", "Hello", "Later"])
        self.assertEqual(words[0]["speaker"], "A")

    def test_utterances_split_by_speaker_and_gap(self):
        utts = refs.ami_utterances(refs.ami_words(self.dir, "X"), gap=1.0)
        self.assertEqual([(u["speaker"], u["text"]) for u in utts],
                         [("A", "Okay. I'm here"), ("B", "Hello"), ("A", "Later")])
        self.assertEqual(utts[0]["start"], 2.0)

    def test_text_in_range(self):
        utts = refs.ami_utterances(refs.ami_words(self.dir, "X"), gap=1.0)
        self.assertEqual(refs.utterances_text(utts, 0, 5), "Okay. I'm here\nHello")

    def test_summary(self):
        s = refs.ami_summary(self.dir, "X")
        self.assertEqual(s["actions"], ["PM will email.", "ID will draw."])
        self.assertEqual(s["decisions"], ["Use a red case."])
        self.assertEqual(s["problems"], [])


class KokkaiTests(unittest.TestCase):
    def test_clean_speeches(self):
        data = {"speechRecord": [
            {"speechOrder": "0", "speaker": "会議録情報", "speech": "出席委員…"},
            {"speechOrder": "1", "speaker": "溝手顕正", "speech": "○会長（溝手顕正君）　ただいまから開会します。\r\n　〔速記中止〕本日は（拍手）"},
            {"speechOrder": "2", "speaker": "谷垣禎一", "speech": "○谷垣禎一君　総理、（発言する者あり）伺います。"},
        ]}
        self.assertEqual(refs.kokkai_text(data), "ただいまから開会します。本日は\n総理、伺います。")


class GovinfoTests(unittest.TestCase):
    def test_excerpt_from_html(self):
        html = ("<P><I>President Trump.</I> Thank you&mdash;very much. Hello.</P><P>Second para. </P>"
                "<P><I>Prime Minister Abe.</I> This is the fourth time.</P>")
        text = refs.govinfo_excerpt(html, "President Trump.", "Prime Minister Abe.")
        self.assertEqual(text, "Thank you—very much. Hello. Second para.")


class MixedTests(unittest.TestCase):
    def test_reference_segments(self):
        spans = [{"lang": "en", "text": "hello there"}, {"lang": "ja", "text": "こんにちは"}]
        self.assertEqual(refs.mixed_reference(spans), ("hello there\nこんにちは", "hello there", "こんにちは"))


if __name__ == "__main__":
    unittest.main()
