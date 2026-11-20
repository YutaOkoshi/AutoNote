import Testing
@testable import AutoNoteCore

@Suite struct ScriptRestrictionTests {
    private func forbids(_ r: ScriptRestriction, _ text: String) -> Bool { r.forbids(Array(text.utf8)) }

    @Test func restrictionFollowsLanguage() {
        #expect(ScriptRestriction(language: .ja) == .japanese)
        #expect(ScriptRestriction(language: .en) == .english)
        #expect(ScriptRestriction(language: .auto) == .japanese)   // 自動は日本語か英語（ハングル・キリル文字は出さない）
    }

    @Test func japaneseKeepsKanaKanjiLatinDigitsAndSymbols() {
        for text in ["会議", "ようなメンテ", "カタカナ", " from", "AWS", "123", "。、", "！？", "（）", "ｱｲ", "café", "→", "…", "①", "㌔", "🎵", " ", "-", "'"] {
            #expect(!forbids(.japanese, text), "\(text)")
        }
    }

    @Test func japaneseDropsOtherScripts() {
        for text in ["сл", " конечно", "е", "한", "국어", "नम", "مرحبا", "שלום", "ภาษา", "αβ", "ㄅ"] {
            #expect(forbids(.japanese, text), "\(text)")
        }
    }

    @Test func englishKeepsLatinOnly() {
        for text in [" ok", "café", "123", "!?", "—", "ＡＢ"] { #expect(!forbids(.english, text), "\(text)") }
        for text in ["会議", "かな", "。", "сл", "한"] { #expect(forbids(.english, text), "\(text)") }
    }

    @Test func unrestrictedAllowsEverything() {
        for text in ["сл", "한", "会議", " ok"] { #expect(!forbids(.unrestricted, text)) }
    }

    /// バイト単位の BPE はトークンが文字の途中で切れる。先頭バイトだけのトークンは、続きでなり得る文字の範囲で判定する。
    @Test func splitCharacterUsesTheReachableRange() {
        #expect(ScriptRestriction.japanese.forbids([0xD0]))          // U+0400–043F: キリル文字だけ
        #expect(ScriptRestriction.japanese.forbids([0xEC]))          // U+C000–CFFF: ハングルだけ
        #expect(!ScriptRestriction.japanese.forbids([0xE3]))         // U+3000–3FFF: かなとハングル字母が混在
        #expect(ScriptRestriction.english.forbids([0xE3]))
        #expect(!ScriptRestriction.japanese.forbids([0xE3, 0x81]))   // U+3040–307F: ひらがな
        #expect(ScriptRestriction.japanese.forbids([0xE3, 0x84]))    // U+3100–313F: 注音字母・ハングル字母
        #expect(!ScriptRestriction.japanese.forbids(Array("会".utf8) + [0xE3]))
        #expect(ScriptRestriction.japanese.forbids(Array("会".utf8) + [0xD1]))
    }

    /// 続きのバイトから始まるトークンは、文字の切れ目では U+FFFD にしかならないので禁止する（2026-11-19 の評価で
    /// ライブ ja に「し」+ [0x80] が出た）。文字の途中で切れた並び・余った続きのバイトも同じく禁止する。
    @Test func bytesThatCannotBeValidUTF8AreForbidden() {
        let ja = ScriptRestriction.japanese
        #expect(ja.forbids([0x81, 0x82]))
        #expect(ja.forbids([0x80]))
        #expect(ja.forbids([0x82] + Array("会".utf8)))
        #expect(ja.forbids([0xE3, 0x41]))                           // 先頭バイトの後に ASCII
        #expect(ja.forbids(Array("会".utf8) + [0x81]))               // 文字の後に余った続きのバイト
        #expect(ScriptRestriction.english.forbids([0x80]))
        #expect(!ScriptRestriction.unrestricted.forbids([0x80]))     // auto は何も禁止しない
    }

    @Test func pendingPrefixCompletesTheCharacter() {
        let ja = ScriptRestriction.japanese
        #expect(ja.forbids([0xB0, 0x80], after: [0xEA]))            // 가 U+AC00
        #expect(!ja.forbids([0x9C, 0xA0], after: [0xEA]))           // U+A720 ラテン文字拡張 D
        #expect(!ja.forbids([0x81, 0x82], after: [0xE3]))           // あ
        #expect(ja.forbids([0x84], after: [0xE3]))                  // U+3100–313F
        #expect(!ja.forbids([0x82], after: [0xE3, 0x81]))           // あ
        #expect(ja.forbids([0xB5], after: [0xD0]))                  // е U+0435
        #expect(!ja.forbids([0x81], after: [0xE3]))                 // まだ途中（U+3040–307F はひらがな）
        #expect(ja.forbids(Array("a".utf8), after: [0xE3]))         // 文字を完成させずに次の文字
        #expect(ja.forbids(Array("会".utf8), after: [0xE3, 0x81]))
        #expect(ja.forbids([0x81, 0x82, 0x83], after: [0xE3]))      // 完成した後に余った続きのバイト
    }

    @Test func pendingPrefixIsTheTrailingIncompleteCharacter() {
        #expect(ScriptRestriction.pendingPrefix(Array("abc".utf8)).isEmpty)
        #expect(ScriptRestriction.pendingPrefix(Array("あ".utf8)).isEmpty)
        #expect(ScriptRestriction.pendingPrefix(Array("あ".utf8) + [0xE3]) == [0xE3])
        #expect(ScriptRestriction.pendingPrefix([0x61, 0xE3, 0x81]) == [0xE3, 0x81])
        #expect(ScriptRestriction.pendingPrefix([0xF0, 0x9F, 0x8E]) == [0xF0, 0x9F, 0x8E])
        #expect(ScriptRestriction.pendingPrefix([0x81]).isEmpty)     // 先頭が欠けた続きのバイトは対象外
    }
}

@Suite struct WhisperScriptFilterTests {
    // id: 0 "会議", 1 " ok", 2 "сл", 3 [0xD0], 4 [0xEA], 5 [0xB0, 0x80], 6 [0x9C, 0xA0], 7 "한"
    private let vocabulary: [[UInt8]] = [
        Array("会議".utf8), Array(" ok".utf8), Array("сл".utf8), [0xD0], [0xEA], [0xB0, 0x80], [0x9C, 0xA0], Array("한".utf8),
    ]

    @Test func atACharacterBoundaryBansOtherScriptsAndStrayContinuations() {
        let filter = WhisperScriptFilter(restriction: .japanese, vocabulary: vocabulary)
        #expect(Set(filter.banned(after: [])) == [2, 3, 5, 6, 7])
        #expect(Set(filter.banned(after: [0, 1])) == [2, 3, 5, 6, 7])
    }

    /// 文字の途中では、その文字を許される文字として完成させるトークンだけが残る。
    @Test func insideACharacterOnlyAllowedCompletionsRemain() {
        let filter = WhisperScriptFilter(restriction: .japanese, vocabulary: vocabulary)
        #expect(Set(filter.banned(after: [1, 4])) == [0, 1, 2, 3, 4, 5, 7])   // " ok" + 0xEA → U+A720 の 6 だけ
    }

    @Test func aSpecialTokenEndsTheTextRun() {
        let filter = WhisperScriptFilter(restriction: .japanese, vocabulary: vocabulary)
        #expect(Set(filter.banned(after: [4, 50_000])) == [2, 3, 5, 6, 7])    // 特殊トークン（範囲外）の後は文字の切れ目
    }

    @Test func unrestrictedBansNothing() {
        let filter = WhisperScriptFilter(restriction: .unrestricted, vocabulary: vocabulary)
        #expect(filter.banned(after: []).isEmpty)
        #expect(filter.banned(after: [4]).isEmpty)
    }
}
