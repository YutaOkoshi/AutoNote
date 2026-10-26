import Foundation
import Testing
import AutoNoteTestSupport
@testable import AutoNoteCore

@Test(arguments: [
    ("えー、来週リリースします。", "来週リリースします。"), ("それで えーと 来週です", "それで 来週です"), ("そうです、えー。", "そうです。"),
    ("えーとですね、はい", "えーとですね、はい"), ("あのー人に聞きます", "あのー人に聞きます"), ("um, I think so.", "I think so."),
    ("Uh", ""), ("えー。えーと。", ""), ("えーえーと", ""), ("umbrella を持参", "umbrella を持参"),
])
func cleans(_ c: (String, String)) { #expect(FillerRemover(fillers: DictionaryFile.defaultFillers).clean(c.0) == c.1) }

@Test func dropsEmptiedUtterances() {
    let out = FillerRemover(fillers: ["えー"]).clean([u(1, .me, "えー。"), u(2, .me, "えー、はい")])
    #expect(out.map(\.text) == ["はい"]); #expect(out[0].start.seconds == 2)
}
