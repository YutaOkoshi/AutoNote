import os
import random
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import metrics  # noqa: E402


def naive(ref, hyp, free_ref_ends=False):
    """Plain DP edit distance; with free_ref_ends, hyp may match any substring of ref."""
    prev = [0] * (len(ref) + 1) if free_ref_ends else list(range(len(ref) + 1))
    for i, h in enumerate(hyp, 1):
        cur = [i]
        for j, r in enumerate(ref, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (h != r)))
        prev = cur
    return min(prev) if free_ref_ends else prev[-1]


class DistanceTests(unittest.TestCase):
    def test_myers_global_matches_naive(self):
        rng = random.Random(1)
        for _ in range(200):
            ref = [rng.choice("abcd") for _ in range(rng.randint(0, 40))]
            hyp = [rng.choice("abcd") for _ in range(rng.randint(0, 40))]
            self.assertEqual(metrics.distance(ref, hyp), naive(ref, hyp), (ref, hyp))

    def test_myers_search_matches_naive(self):
        rng = random.Random(2)
        for _ in range(200):
            ref = [rng.choice("abcd") for _ in range(rng.randint(1, 60))]
            hyp = [rng.choice("abcd") for _ in range(rng.randint(1, 20))]
            self.assertEqual(metrics.search_distance(ref, hyp)[0], naive(ref, hyp, True), (ref, hyp))

    def test_long_words(self):
        ref = ["w%d" % (i % 97) for i in range(3000)]
        hyp = list(ref)
        del hyp[100:110]
        hyp[2000] = "x"
        self.assertEqual(metrics.distance(ref, hyp), 11)


class AlignTests(unittest.TestCase):
    def test_counts(self):
        a = metrics.align(list("abcd"), list("abxde"))
        self.assertEqual((a["sub"], a["del"], a["ins"], a["hits"]), (1, 0, 1, 3))
        self.assertEqual(metrics.edits(a), 2)

    def test_counts_match_distance(self):
        rng = random.Random(3)
        for _ in range(100):
            ref = [rng.choice("abc") for _ in range(rng.randint(0, 30))]
            hyp = [rng.choice("abc") for _ in range(rng.randint(0, 30))]
            a = metrics.align(ref, hyp)
            self.assertEqual(metrics.edits(a), naive(ref, hyp))
            self.assertEqual(a["hits"] + a["sub"] + a["del"], len(ref))
            self.assertEqual(a["hits"] + a["sub"] + a["ins"], len(hyp))

    def test_longest_deletion_run(self):
        a = metrics.align(list("abcdefghij"), list("abij"))
        self.assertEqual(a["max_del_run"], 6)

    def test_pairs(self):
        pairs = metrics.align(list("abcd"), list("axcde"), pairs=True)["pairs"]
        self.assertEqual(pairs, [(0, 0), (1, 1), (2, 2), (3, 3), (None, 4)])
        pairs = metrics.align(list("abcd"), list("ad"), pairs=True)["pairs"]
        self.assertEqual(pairs, [(0, 0), (1, None), (2, None), (3, 1)])

    def test_locate(self):
        ref = list("xxxxxxabcdefghyyyyyy")
        start, end, dist = metrics.locate(ref, list("abcdefgh"))
        self.assertEqual((start, end, dist), (6, 14, 0))


class ErrorRateTests(unittest.TestCase):
    def test_error_rate_dict(self):
        r = metrics.error_rate(list("abcd"), list("abxd"))
        self.assertEqual(r["errors"], 1)
        self.assertEqual(r["ref_len"], 4)
        self.assertAlmostEqual(r["rate"], 0.25)

    def test_empty_reference(self):
        self.assertIsNone(metrics.error_rate([], list("ab"))["rate"])


class OutputMetricTests(unittest.TestCase):
    def test_foreign_script_rate(self):
        r = metrics.foreign_scripts(["こんにちは", "はいい십ね", "hello", "Привет"])
        self.assertEqual(r["utterances"], 4)
        self.assertEqual(r["with_unexpected"], 2)
        self.assertEqual(r["by_script"], {"CYRILLIC": 1, "HANGUL": 1})
        self.assertAlmostEqual(r["rate"], 0.5)

    def test_english_retention(self):
        r = metrics.english_retention(["the", "remote", "control", "the"], ["the", "remote", "コ", "ン"])
        self.assertEqual((r["kept"], r["ref"]), (2, 4))

    def test_repetition(self):
        self.assertTrue(metrics.is_repetitive("日本の大会社の大会社の大会社としています"))
        self.assertTrue(metrics.is_repetitive("no no no no"))
        self.assertTrue(metrics.is_repetitive("thank you thank you thank you"))
        self.assertFalse(metrics.is_repetitive("very very good"))
        self.assertFalse(metrics.is_repetitive("ははは"))  # 1-char laughter is not a hallucination loop
        self.assertFalse(metrics.is_repetitive("今日はいい天気です"))

    def test_repeated_utterances(self):
        self.assertEqual(metrics.repetition(["a b", "x", "x", "x", "日本の大会社の大会社の大会社"])["utterances"], 4)


if __name__ == "__main__":
    unittest.main()
