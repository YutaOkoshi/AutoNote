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
