import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import textnorm  # noqa: E402


class KanjiNumeralTests(unittest.TestCase):
    def test_digit_by_digit(self):
        self.assertEqual(textnorm.kanji_numerals("二〇一四年"), "2014年")

    def test_positional(self):
        self.assertEqual(textnorm.kanji_numerals("三十五人"), "35人")
        self.assertEqual(textnorm.kanji_numerals("十"), "10")
        self.assertEqual(textnorm.kanji_numerals("百二十"), "120")
        self.assertEqual(textnorm.kanji_numerals("三万五千"), "35000")

    def test_arabic_with_units(self):
        self.assertEqual(textnorm.kanji_numerals("3万5000円"), "35000円")
        self.assertEqual(textnorm.kanji_numerals("2万"), "20000")

    def test_no_numerals_untouched(self):
        self.assertEqual(textnorm.kanji_numerals("総理大臣"), "総理大臣")


class NormalizeTests(unittest.TestCase):
    def test_raw_keeps_punctuation_and_case(self):
        self.assertEqual(textnorm.normalize("Ｈｅｌｌｏ、世界。", "raw"), "Hello、世界。")

    def test_norm_removes_punctuation_and_lowercases(self):
        self.assertEqual(textnorm.normalize("Hello、世界。", "norm").split(), ["hello", "世界"])

    def test_norm_removes_japanese_fillers(self):
        self.assertEqual("".join(textnorm.normalize("えーと、これは、あのー、本です", "norm").split()), "これは本です")

    def test_norm_removes_english_fillers_as_words(self):
        toks = textnorm.tokenize(textnorm.normalize("Um, I'm glad. Mm-hmm. Uh, yes", "norm"), "word")
        self.assertEqual(toks, ["i'm", "glad", "yes"])

    def test_digit_grouping_commas(self):
        self.assertEqual(textnorm.normalize("1,000円", "norm"), "1000円")

    def test_curly_apostrophe(self):
        toks = textnorm.tokenize(textnorm.normalize("I’m here", "norm"), "word")
        self.assertEqual(toks, ["i'm", "here"])


class TokenizeTests(unittest.TestCase):
    def test_char_mode_drops_whitespace(self):
        self.assertEqual(textnorm.tokenize("今日 は\nok", "char"), list("今日はok"))

    def test_word_mode_mixes_words_and_cjk_chars(self):
        toks = textnorm.tokenize("今日はremote controlの話", "word")
        self.assertEqual(toks, ["今", "日", "は", "remote", "control", "の", "話"])

    def test_raw_word_mode_keeps_punctuation_tokens(self):
        self.assertEqual(textnorm.tokenize("Okay. Good", "word"), ["Okay", ".", "Good"])

    def test_script_of_token(self):
        self.assertEqual(textnorm.token_script("remote"), "en")
        self.assertEqual(textnorm.token_script("話"), "ja")
        self.assertEqual(textnorm.token_script("ー"), "ja")
        self.assertEqual(textnorm.token_script("2014"), "other")


class ScriptTests(unittest.TestCase):
    def test_unexpected_scripts(self):
        self.assertEqual(textnorm.unexpected_scripts("はいい십ね"), {"HANGUL"})
        self.assertEqual(textnorm.unexpected_scripts("Привет мир"), {"CYRILLIC"})
        self.assertEqual(textnorm.unexpected_scripts("今日はremote 々ー、café！"), set())


if __name__ == "__main__":
    unittest.main()
