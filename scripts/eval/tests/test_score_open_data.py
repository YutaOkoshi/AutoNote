"""会見の区間別・日米会見の日本語の範囲・話者別トラックの採点のテスト。"""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import score  # noqa: E402

SUMMARY = {"rtf": 0.05, "elapsed": 1.0, "audioSeconds": 20}


def utt(start, text, end=None):
    return {"start": start, "end": start + 1 if end is None else end, "text": text}


class PartsTests(unittest.TestCase):
    def test_kaiken_scores_opening_and_questions_separately(self):
        ds = {"kind": "kaiken"}
        ref = {"unit": "char", "text": "冒頭です\n質問です", "window": "calibrated", "languages": ["ja"],
               "parts": [{"name": "opening", "range": [0, 10], "text": "冒頭です"},
                         {"name": "qa", "range": [10, 99], "text": "質問です"}]}
        r = score.score_run(ds, ref, [utt(1, "冒頭です"), utt(12, "失問です")], SUMMARY)
        self.assertEqual(r["parts"]["opening"]["errors"], 0)
        self.assertEqual(r["parts"]["qa"]["errors"], 1)
        self.assertEqual(r["er"]["errors"], 1)


class GovinfoJapaneseTests(unittest.TestCase):
    def test_japanese_opening_is_scored_on_its_time_range_only(self):
        ds = {"kind": "govinfo"}
        ref = {"unit": "word", "en_text": "Thank you", "ja_text": "ありがとうございます", "ja_range": [5, 9],
               "languages": ["ja", "en"]}
        finals = [utt(1, "Thank you"), utt(6, "ありがとうございます Mr. President"), utt(20, "別の日本語")]
        r = score.score_run(ds, ref, finals, SUMMARY)
        self.assertEqual(r["er"]["errors"], 2)            # 「Mr. President」は英語の正解にないので挿入
        self.assertEqual(r["ja_cer"]["errors"], 0)
        self.assertEqual(r["ja_cer"]["ref_len"], 10)

    def test_whole_document_english_without_range(self):
        ds = {"kind": "govinfo"}
        ref = {"unit": "word", "en_text": "Thank you very much", "languages": ["ja", "en"]}
        r = score.score_run(ds, ref, [utt(1, "Thank you"), utt(300, "very much")], SUMMARY)
        self.assertEqual(r["er"]["errors"], 0)


class TrackTests(unittest.TestCase):
    REF = {"unit": "char", "tracks": {"me": "こんにちは\n元気です", "other": "そうですね"},
           "utterances": [{"track": "me", "start": 0.0, "end": 2.0, "text": "こんにちは"},
                          {"track": "other", "start": 3.0, "end": 4.0, "text": "そうですね"},
                          {"track": "me", "start": 5.0, "end": 6.0, "text": "元気です"}]}

    def test_per_track_rates_and_combined(self):
        r = score.score_tracks(self.REF, {"me": [utt(0, "こんにちは", 2), utt(5, "元気です", 6)],
                                          "other": [utt(3, "そうですか", 4)]})
        self.assertEqual(r["me"]["er"]["errors"], 0)
        self.assertEqual(r["other"]["er"]["errors"], 1)
        self.assertEqual(r["combined"]["errors"], 1)
        self.assertEqual(r["combined"]["ref_len"], 14)
        self.assertEqual(r["me"]["leak"]["utterances"], 0)

    def test_other_voice_in_my_track_counts_as_leak(self):
        r = score.score_tracks(self.REF, {"me": [utt(0, "こんにちは", 2), utt(3, "そうですね", 4), utt(5, "元気です", 6)],
                                          "other": [utt(3, "そうですね", 4)]})
        self.assertEqual(r["me"]["leak"]["utterances"], 1)
        self.assertEqual(r["me"]["leak"]["chars"], 5)
        self.assertEqual(r["other"]["leak"]["utterances"], 0)


if __name__ == "__main__":
    unittest.main()
