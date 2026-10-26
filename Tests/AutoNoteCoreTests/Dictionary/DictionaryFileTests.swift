import Foundation
import Testing
@testable import AutoNoteCore

private let specExample = "## 用語\n- AutoNote\n- 所沢\n- Kubernetes\n\n## 置換\n- オートノート => AutoNote\n- クーバネティス => Kubernetes\n\n## フィラー\n- えー\n- えーと\n"

@Test func parsesAndRendersSpecExample() {
    let (d, issues) = DictionaryFile.parse(specExample)
    #expect(d.terms == ["AutoNote", "所沢", "Kubernetes"]); #expect(d.fillers == ["えー", "えーと"]); #expect(issues.isEmpty)
    #expect(d.replacements == [.init(from: "オートノート", to: "AutoNote"), .init(from: "クーバネティス", to: "Kubernetes")])
    #expect(d.render() == specExample)
}

@Test func reportsBrokenReplacementLines() {
    let (d, issues) = DictionaryFile.parse("## 置換\n- 矢印なし\n- => 右だけ\n- 左だけ =>\n- a => b => c\n- a => z\n")
    #expect(d.replacements == [.init(from: "a", to: "b => c")]); #expect(issues.map(\.line) == [2, 3, 4, 6])
}

@Test func sectionsAndProse() {
    #expect(DictionaryFile.parse("## 用語\n- X\n").dictionary.fillers == DictionaryFile.defaultFillers)
    #expect(DictionaryFile.parse("## フィラー\n").dictionary.fillers == [])
    #expect(DictionaryFile.parse("メモ\n- 前\n## その他\n- x\n## 用語\n説明文\n  * Y\n- Y\n").dictionary.terms == ["Y"])
}

@Test func defaultMarkdownRoundTripsAndEmptySectionsRenderHeadingOnly() {
    #expect(DictionaryFile.parse(DictionaryFile.defaultMarkdown).dictionary == DictionaryFile.default)
    let d = DictionaryFile(terms: [], replacements: [], fillers: [])
    #expect(d.render() == "## 用語\n\n## 置換\n\n## フィラー\n")
    #expect(DictionaryFile.parse(d.render()).dictionary == d)
}
