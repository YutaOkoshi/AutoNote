import Foundation
import Testing
import AutoNoteTestSupport
@testable import AutoNoteCore

@Test func replacerAndHintBudget() {
    let r = Replacer([.init(from: "ノート", to: "Note"), .init(from: "オートノート", to: "AutoNote"), .init(from: "A", to: "B"), .init(from: "B", to: "C")])
    #expect(r.apply("オートノートのノート") == "AutoNoteのNote"); #expect(r.apply("A") == "B")
    #expect(HintBudget.estimateTokens("Kubernetes") == 3); #expect(HintBudget.estimateTokens("所沢") == 4); #expect(HintBudget.estimateTokens("AutoNote v2") == 3)
    #expect(HintBudget.fit(Array(repeating: "所沢市役所", count: 30)).included.count == 20)
    let long = String(repeating: "長", count: 200); let h = HintBudget.fit(["短い", long, "次"])
    #expect(h.included == ["短い"]); #expect(h.dropped == [long, "次"])
}

@Test func replacerIsCaseSensitiveAndAppliesToUtterances() {
    let r = Replacer([.init(from: "abc", to: "X")])
    #expect(r.apply("ABC abc") == "ABC X")
    let out = r.apply([u(1, .me, "abc"), u(2, .other, "zabcz")])
    #expect(out.map(\.text) == ["X", "zXz"])
    #expect(out[1].speaker == .other)
}
