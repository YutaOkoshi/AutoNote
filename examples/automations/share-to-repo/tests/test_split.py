import os
import unittest

from helpers import FIXTURES, GOLDEN, NO_TRANSCRIPT, STANDARD, TRANSCRIPT_ONLY, read
from sharetorepo import split

VAULT = os.path.join(FIXTURES, "vault", "2026")


def render(name, kind="customer", customer="サンプル商事", recorded_by="営業担当", recording_state="まだ"):
    m = split.load_meeting(os.path.join(VAULT, name))
    stem = os.path.splitext(name)[0]
    return m, split.render_pair(m, stem, kind=kind, customer=customer, recorded_by=recorded_by,
                                recording_state=recording_state)


class LinkTests(unittest.TestCase):
    def test_four_link_forms(self):
        cases = {
            "a [[#^t00-07-08|07:09]] b": "a （→ 00:07:08） b",
            "[[#^t01-02-03|1:02:04]]": "（→ 01:02:03）",
            "[[#^t00-07-08-2|07:08]]": "（→ 00:07:08）",
            "| [[#^t00-07-08\\|07:09]] |": "| （→ 00:07:08） |",
        }
        for src, want in cases.items():
            self.assertEqual(split.convert_links(src), want, src)

    def test_other_links_untouched(self):
        for src in ["[[別のノート]]", "[[#要約|要約へ]]", "[[#^abc|ブロック]]", "[[#^t1-2-3|x]]", "[テキスト](https://example.invalid)"]:
            self.assertEqual(split.convert_links(src), src)


class SplitTests(unittest.TestCase):
    def test_golden_customer(self):
        _, (minutes, transcript) = render(STANDARD)
        self.assertEqual(minutes, read(os.path.join(GOLDEN, "customer-minutes.md")))
        self.assertEqual(transcript, read(os.path.join(GOLDEN, "customer-transcript.md")))

    def test_customer_drops_bookmarks_internal_keeps_them(self):
        _, (customer, _) = render(STANDARD)
        self.assertNotIn("## ブックマーク", customer)
        _, (internal, _) = render(STANDARD, kind="internal", customer="", recorded_by="オーナー",
                                  recording_state="対象外")
        self.assertIn("## ブックマーク\n- （→ 00:07:08） 料金の話\n- （→ 01:02:03）\n", internal)
        self.assertIn("kind: internal\n", internal)
        self.assertIn('customer: ""\n', internal)
        self.assertIn("source_recording_deleted: 対象外\n", internal)
        # The translated minutes stay at the end, after the transcript note.
        self.assertLess(internal.index("## 文字起こし"), internal.index("## 議事録の訳文（英語）"))

    def test_transcript_only_keeps_autonote_sentence(self):
        m, (minutes, transcript) = render(TRANSCRIPT_ONLY, kind="internal", customer="", recorded_by="オーナー",
                                          recording_state="対象外")
        self.assertEqual(m.status, "transcript_only")
        self.assertIn("> 議事録は未生成です。`autonote regenerate 20261203-1400-77aa` で作り直せます。", minutes)
        self.assertIn("**[00:00:05] 自分**: 週次の確認を始めます。 ^t00-00-05", transcript)
        # Speakers are known here, so the "all unknown" sentence is left out.
        self.assertNotIn("不明", transcript)
        self.assertNotIn("話者はすべて", minutes)

    def test_meeting_without_transcript(self):
        m, (minutes, transcript) = render(NO_TRANSCRIPT, kind="internal", customer="", recorded_by="オーナー",
                                          recording_state="対象外")
        self.assertIsNone(transcript)
        self.assertIn("transcript_file: なし\n", minutes)
        self.assertIn("## 文字起こし\nこの会議には文字起こしがありません。\n", minutes)

    def test_existing_share_keys_in_vault_are_replaced(self):
        m = split.load_meeting(os.path.join(VAULT, STANDARD))
        m.fm_lines.append("kind: internal")
        minutes, _ = split.render_pair(m, "x", kind="customer", customer="", recorded_by="営業担当",
                                       recording_state="まだ")
        self.assertEqual(minutes.count("kind:"), 1)
        self.assertIn("kind: customer\n", minutes)

    def test_recording_name_parse(self):
        self.assertEqual(split.parse_recording_name("2026-12-02_1000_サンプル商事_トライアル打合せ.mp4"),
                         ("2026-12-02", "10:00", "サンプル商事"))
        self.assertIsNone(split.parse_recording_name("録画.mp4"))


if __name__ == "__main__":
    unittest.main()
