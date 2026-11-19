import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import summary_eval  # noqa: E402


class MatchScoreTests(unittest.TestCase):
    def test_recall_and_precision(self):
        r = summary_eval.match_scores(["g0", "g1", "g2"], ["p0", "p1"],
                                      [{"gold": 0, "matches": [1]}, {"gold": 1, "matches": []}, {"gold": 2, "matches": [1]}])
        self.assertEqual((r["matched_gold"], r["matched_pred"]), (2, 1))
        self.assertAlmostEqual(r["recall"], 2 / 3)
        self.assertAlmostEqual(r["precision"], 1 / 2)

    def test_out_of_range_indices_are_ignored(self):
        r = summary_eval.match_scores(["g0"], ["p0"], [{"gold": 0, "matches": [5]}, {"gold": 3, "matches": [0]}])
        self.assertEqual((r["matched_gold"], r["matched_pred"]), (0, 0))

    def test_empty_sides(self):
        r = summary_eval.match_scores([], [], [])
        self.assertIsNone(r["recall"])
        self.assertIsNone(r["precision"])


class FaithfulnessTests(unittest.TestCase):
    def test_items_and_score(self):
        minutes = {"summary": ["s"], "decisions": [{"text": "d", "t": "00:00:01"}],
                   "next_actions": [{"text": "a", "owner": "PM", "due": None, "t": "00:00:02", "priority": "high"}],
                   "key_points": [{"text": "k", "t": "00:00:03"}]}
        items = summary_eval.faith_items(minutes)
        self.assertEqual([i for i, _ in items], ["summary.0", "decision.0", "action.0", "key_point.0"])
        self.assertEqual(items[2][1], "a (owner: PM)")
        self.assertEqual(items[3][1], "k")   # MinutesPoint has text, not title/body
        r = summary_eval.faith_scores(items, [{"id": "summary.0", "verdict": "supported"},
                                              {"id": "decision.0", "verdict": "partial"},
                                              {"id": "action.0", "verdict": "unsupported"}])
        self.assertEqual((r["supported"], r["partial"], r["unsupported"], r["missing"]), (1, 1, 1, 1))
        self.assertAlmostEqual(r["score"], 1.5 / 4)
        self.assertEqual(r["by_kind"]["decision"]["partial"], 1)


if __name__ == "__main__":
    unittest.main()


class OpenDataInputTests(unittest.TestCase):
    """人手の要約がないデータ（会見・雑談）の入力の組み立て。"""

    def setUp(self):
        import tempfile
        import common
        self.common = common
        self.saved = common.DATA
        self.tmp = tempfile.TemporaryDirectory()
        common.DATA = self.tmp.name

    def tearDown(self):
        self.common.DATA = self.saved
        self.tmp.cleanup()

    def write_jsonl(self, path, finals):
        import json
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            for u in finals:
                f.write(json.dumps(dict(u, final=True), ensure_ascii=False) + "\n")
            f.write(json.dumps({"summary": {"rtf": 0.1}}) + "\n")

    def test_kaiken_reference_spreads_time_by_length(self):
        self.common.write_json(os.path.join(self.common.prepared_dir("k"), "ref.json"),
                               {"audio_seconds": 30.0, "text": "あいう\nえおかきくけ"})
        t = summary_eval.open_reference({"id": "k", "kind": "kaiken"})
        self.assertEqual([(u["start"], u["end"]) for u in t["utterances"]], [(0.0, 10.0), (10.0, 30.0)])
        self.assertEqual(summary_eval.labelled_text(t), "あいう\nえおかきくけ")

    def test_tracks_become_me_and_other_in_time_order(self):
        run_dir = self.common.run_dir("lab", "c")
        self.write_jsonl(os.path.join(run_dir, "tracks", "me-whisper-ja.jsonl"),
                         [{"start": 0.0, "end": 1.0, "text": "こんにちは"}, {"start": 5.0, "end": 6.0, "text": "はい"}])
        self.write_jsonl(os.path.join(run_dir, "tracks", "other-whisper-ja.jsonl"),
                         [{"start": 2.0, "end": 3.0, "text": "どうも"}, {"start": 4.0, "end": 4.5, "text": " "}])
        t = summary_eval.open_final({"id": "c", "kind": "eaf", "tracks": {"me": {}, "other": {}}}, "lab")
        self.assertEqual([(u["speaker"], u["text"]) for u in t["utterances"]],
                         [("me", "こんにちは"), ("other", "どうも"), ("me", "はい")])
        self.assertEqual(summary_eval.labelled_text(t), "[me] こんにちは\n[other] どうも\n[me] はい")

    def test_table_cell_without_gold(self):
        self.assertEqual(summary_eval.match_cell({"pred": 3}, "recall", "matched_gold", "gold"), "–")
        self.assertEqual(summary_eval.match_cell({"pred": 3}, "precision", "matched_pred", "pred"), "–（生成 3 件）")
