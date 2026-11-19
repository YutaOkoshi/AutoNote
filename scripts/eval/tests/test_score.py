import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import score  # noqa: E402

SUMMARY = {"rtf": 0.05, "elapsed": 1.0, "audioSeconds": 20}


def utt(start, text):
    return {"start": start, "end": start + 1, "text": text}


class ScoreRunTests(unittest.TestCase):
    def test_mixed_reference_gives_language_split(self):
        ds = {"kind": "mixed"}
        ref = {"unit": "word", "text": "hello there\nこんにちは", "en_text": "hello there", "ja_text": "こんにちは",
               "languages": ["ja", "en"]}
        r = score.score_run(ds, ref, [utt(0, "Hello, there."), utt(2, "こんにちわ")], SUMMARY)
        self.assertEqual(r["en_wer"]["errors"], 0)
        self.assertEqual(r["ja_cer"]["errors"], 1)
        self.assertEqual(r["er"]["errors"], 1)
        self.assertEqual(r["en_retention"]["rate"], 1.0)
        self.assertEqual(r["rtf"], 0.05)

    def test_japanese_rendering_of_english_drops_retention(self):
        ds = {"kind": "mixed"}
        ref = {"unit": "word", "text": "remote control", "en_text": "remote control", "ja_text": "", "languages": ["ja", "en"]}
        r = score.score_run(ds, ref, [utt(0, "リモートコントロール")], SUMMARY)
        self.assertEqual(r["en_retention"]["kept"], 0)
        self.assertEqual(r["en_wer"]["del"], 2)

    def test_govinfo_scores_only_english_in_range(self):
        ds = {"kind": "govinfo"}
        ref = {"unit": "word", "en_text": "Thank you very much.", "en_range": [0, 10], "languages": ["ja", "en"]}
        finals = [utt(1, "Thank you very much"), utt(12, "much much more English later")]
        r = score.score_run(ds, ref, finals, SUMMARY)
        self.assertEqual(r["er"]["errors"], 0)
        self.assertEqual(r["finals"], 2)

    def test_located_window(self):
        ds = {"kind": "kokkai"}
        ref = {"unit": "char", "text": "前置きの文。本題の発言です。後の発言。", "window": "locate", "languages": ["ja"]}
        r = score.score_run(ds, ref, [utt(0, "本題の発言です")], SUMMARY)
        self.assertEqual(r["er"]["errors"], 0)
        self.assertEqual(r["ref_span"][1] - r["ref_span"][0], 7)


if __name__ == "__main__":
    unittest.main()
