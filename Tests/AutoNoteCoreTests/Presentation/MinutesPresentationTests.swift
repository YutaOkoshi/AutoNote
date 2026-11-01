import Foundation
import Testing
import AutoNoteTestSupport
@testable import AutoNoteCore

@Suite struct MinutesPresentationTests {
    private func fixture(_ id: String) throws -> MinutesOutput {
        let data = try Data(contentsOf: FixtureLibrary.defaultDirectory.appending(path: "meetings/\(id)/minutes.json"))
        return try AutoNoteJSON.decoder().decode(MinutesOutput.self, from: data)
    }

    @Test func v2FixtureShowsEverySectionInSpecOrder() throws {
        let sections = MinutesPresentation.sections(try fixture("20261026-1000-e5f6"))
        #expect(sections.map(\.kind) == [.attendees, .agenda, .summary, .keyPoints, .decisions, .insights, .questions,
                                         .deadlines, .followUps, .risks, .diagram, .actions])
        #expect(sections.map(\.kind) == MinutesSectionKind.allCases)
        #expect(sections.map(\.title) == ["出席者", "議題", "要約", "重要ポイント", "決定事項", "インサイト", "質問", "締め切り",
                                          "フォローアップ", "リスク", "構成図", "アクション"])
        #expect(sections.map(\.symbol) == ["person.2", "list.number", "doc.text", "list.bullet", "checkmark.seal", "lightbulb",
                                           "questionmark.bubble", "calendar.badge.exclamationmark", "arrow.turn.down.right",
                                           "exclamationmark.triangle", "square.stack.3d.up", "checklist"])
    }

    @Test func v1FixtureLeavesOutEmptySections() throws {
        let sections = MinutesPresentation.sections(try fixture("20261024-1400-a1b2"))
        #expect(sections.map(\.kind) == [.agenda, .summary, .decisions, .actions])
    }

    @Test func blankItemsAndSectionsAreLeftOut() {
        var m = Samples.minutes
        m.summary = ["  ", "本文"]
        m.decisions = [Decision(text: " ", t: "00:00:01")]
        m.attendees = [Attendee(name: "")]
        m.architectureDiagram = " \n"
        let kinds = MinutesPresentation.sections(m).map(\.kind)
        #expect(!kinds.contains(.decisions) && !kinds.contains(.attendees) && !kinds.contains(.diagram))
        #expect(MinutesPresentation.sections(m).first { $0.kind == .summary }?.rows.map(\.text) == ["本文"])
    }

    @Test func rowsCarryBadgesTonesAndTimes() throws {
        let sections = MinutesPresentation.sections(try fixture("20261026-1000-e5f6"))
        func rows(_ k: MinutesSectionKind) throws -> [MinutesRow] { try #require(sections.first { $0.kind == k }).rows }

        let attendees = try rows(.attendees)
        #expect(attendees.map(\.text) == ["相手", "自分"]); #expect(attendees.map(\.secondary) == ["ほしぞら食品", nil])
        #expect(attendees[0].timeText == nil)

        let agenda = try rows(.agenda)
        #expect(agenda[0].text == "現状の取り込み"); #expect(agenda[0].detail == "毎朝CSVを手作業で取り込んでおり、取り込み漏れが出やすい。")
        #expect(agenda[0].timeText == "00:15"); #expect(agenda[0].time == TimelineTime(seconds: 15))

        let decisions = try rows(.decisions)
        #expect(decisions[0].symbol == "checkmark.circle.fill"); #expect(decisions[0].symbolTone == .green)
        #expect(try rows(.insights)[0].symbolTone == .yellow)

        let questions = try rows(.questions)
        #expect(questions.map(\.badges) == [[MinutesBadge(text: "未解決", tone: .orange)], [MinutesBadge(text: "解決済み", tone: .green)],
                                            [MinutesBadge(text: "未解決", tone: .orange)]])
        #expect(questions[1].secondary == "自分"); #expect(questions[1].detail == "→ 来週月曜までに届く")
        #expect(questions[2].secondary == nil); #expect(questions[2].detail == nil)

        let deadlines = try rows(.deadlines)
        #expect(deadlines.map(\.secondary) == ["12月20日", "12月10日・自分"]); #expect(deadlines[0].secondaryTone == .red)

        let risks = try rows(.risks)
        #expect(risks.map(\.symbolTone) == [.red, .orange])
        #expect(risks[0].badges == [MinutesBadge(text: "重大度 高", tone: .red)])
        #expect(risks[0].detail == "対策: 受注をキューに積んで順に処理する"); #expect(risks[1].detail == nil)

        let diagram = try #require(sections.first { $0.kind == .diagram })
        #expect(diagram.rows.isEmpty); #expect(diagram.diagram?.hasPrefix("graph LR\n  EC[EC site]") == true)

        let actions = try rows(.actions)
        #expect(actions.map(\.badges) == [[MinutesBadge(text: "高", tone: .red)], [MinutesBadge(text: "高", tone: .red)],
                                          [MinutesBadge(text: "中", tone: .orange)], [MinutesBadge(text: "低", tone: .blue)]])
        #expect(actions.map(\.secondary) == ["担当 相手・期限 来週月曜", "担当 自分・期限 今週金曜", "担当 自分", nil])
        #expect(MinutesPresentation.countText(actions.count) == "4 件")
        // Row ids are unique across the tab (SwiftUI identity).
        let ids = sections.flatMap { $0.rows.map(\.id) }
        #expect(Set(ids).count == ids.count)
    }

    @Test func actionFilter() throws {
        let actions = try #require(MinutesPresentation.sections(try fixture("20261026-1000-e5f6")).first { $0.kind == .actions }).rows
        #expect(MinutesActionFilter.allCases.map(\.label) == ["すべて", "高", "中", "低"])
        #expect(MinutesPresentation.filter(actions, by: .all) == actions)
        #expect(MinutesPresentation.filter(actions, by: .high).map(\.text) == ["出荷システムの仕様書を送る", "受注APIの設計書を作る"])
        #expect(MinutesPresentation.filter(actions, by: .medium).map(\.text) == ["受注APIを作る"])
        #expect(MinutesPresentation.filter(actions, by: .low).map(\.text) == ["トラブルの原因を確認する"])
    }

    @Test func timeTextAndDiagramSource() {
        #expect(MinutesPresentation.timeText(TimelineTime(seconds: 754)) == "12:34")
        #expect(MinutesPresentation.timeText(TimelineTime(seconds: 3725)) == "1:02:05")
        #expect(MinutesPresentation.diagramSource(nil) == nil)
        #expect(MinutesPresentation.diagramSource("\n") == nil)
        #expect(MinutesPresentation.diagramSource("```mermaid\ngraph TD\n  A --> B\n```\n") == "graph TD\n  A --> B")
        #expect(MinutesPresentation.levelText(.medium) == "中"); #expect(MinutesPresentation.severityEmoji(.low) == "🔵")
    }

    @Test func utteranceIndexMatchesVaultLinkTarget() {
        let us = [u(5, .me, "a"), u(15, .other, "b"), u(40, .me, "c")]
        #expect(MinutesPresentation.utteranceIndex(for: TimelineTime(seconds: 16), in: us) == 1)
        #expect(MinutesPresentation.utteranceIndex(for: TimelineTime(seconds: 1), in: us) == 0)
        #expect(MinutesPresentation.utteranceIndex(for: TimelineTime(seconds: 999), in: us) == 2)
        #expect(MinutesPresentation.utteranceIndex(for: TimelineTime(seconds: 1), in: []) == nil)
        let anchors = TranscriptMarkdown.anchors(for: us)
        for s in [0.0, 5, 14, 15, 39, 40, 100] {
            let t = TimelineTime(seconds: s)
            #expect(MinutesPresentation.utteranceIndex(for: t, in: us).map { anchors[$0] }
                    == TranscriptMarkdown.linkTarget(for: t, utterances: us, anchors: anchors))
        }
    }

    /// The 編集 tab passes every key through, so saving never drops a v2 key it does not show.
    @Test func editableMinutesRoundTrips() throws {
        let v2 = try fixture("20261026-1000-e5f6")
        #expect(EditableMinutes(v2).minutes == v2)
        let v1 = try fixture("20261024-1400-a1b2")
        #expect(EditableMinutes(v1).minutes == v1)
        var e = EditableMinutes(v2)
        e.risks.removeAll { $0.value.severity == .high }
        e.questions.remove(at: 0)
        let edited = e.minutes
        #expect(edited.risks.map(\.severity) == [.medium]); #expect(edited.questions.count == 2)
        #expect(edited.architectureDiagram == v2.architectureDiagram); #expect(edited.suggestedTerms == v2.suggestedTerms)
        #expect(edited.schemaVersion == 2)
    }
}

@Suite struct MermaidPreviewPageTests {
    @Test func diagramIsEscapedAndNetworkIsClosed() {
        let html = MermaidPreviewPage.html(diagram: "graph TD\n  A[\"</script><img src=x>\"] --> B", mermaidScript: "/*m*/")
        #expect(!html.contains("</script><img"))
        #expect(html.contains(#"graph TD\n  A[\"<\/script><img src=x>\"] --> B"#))
        #expect(html.contains("content=\"default-src 'none';"))
        #expect(!MermaidPreviewPage.contentSecurityPolicy.contains("connect-src"))
        #expect(!html.contains("http://") && !html.contains("https://"))
        #expect(html.contains(#"securityLevel: "strict""#))
        #expect(MermaidPreviewPage.jsString("a\"b") == #""a\"b""#)
    }
}
