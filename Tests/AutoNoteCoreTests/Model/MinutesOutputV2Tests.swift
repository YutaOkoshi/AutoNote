import Foundation
import Testing
import AutoNoteTestSupport
@testable import AutoNoteCore

@Suite struct MinutesOutputV2Tests {
    private func fixture(_ id: String) throws -> Data {
        try Data(contentsOf: FixtureLibrary.defaultDirectory.appending(path: "meetings/\(id)/minutes.json"))
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func v1FixtureReadsWithEmptyV2Keys() throws {
        let m = try AutoNoteJSON.decoder().decode(MinutesOutput.self, from: fixture("20261024-1400-a1b2"))
        #expect(m.schemaVersion == 1)
        #expect(m.title == "ルミナ茶発売準備会議")
        #expect(m.summary.count == 3)
        #expect(m.attendees.isEmpty && m.keyPoints.isEmpty && m.insights.isEmpty && m.questions.isEmpty)
        #expect(m.deadlines.isEmpty && m.followUps.isEmpty && m.risks.isEmpty)
        #expect(m.architectureDiagram == nil)
        #expect(m.nextActions.map(\.priority) == [.medium, .medium])
        #expect(NextAction.defaultPriority == .medium)
    }

    @Test func v2FixtureRoundTrips() throws {
        let data = try fixture("20261026-1000-e5f6")
        let m = try AutoNoteJSON.decoder().decode(MinutesOutput.self, from: data)
        #expect(m.schemaVersion == 2)
        #expect(m.summary.count == 4)
        #expect(m.attendees == [Attendee(name: "相手", role: "ほしぞら食品"), Attendee(name: "自分", role: nil)])
        #expect(m.nextActions.map(\.priority) == [.high, .high, .medium, .low])
        #expect(m.questions[1] == MinutesQuestion(question: "出荷システムの仕様書はいつ届くか", askedBy: "自分", isResolved: true,
                                                  answer: "来週月曜までに届く", t: "00:02:10"))
        #expect(m.questions[2].askedBy == nil && m.questions[2].answer == nil)
        #expect(m.deadlines[0] == Deadline(description: "年末セールの開始", date: "12月20日", owner: nil, t: "00:01:15"))
        #expect(m.risks.map(\.severity) == [.high, .medium])
        #expect(m.risks[1].mitigation == nil)
        #expect(m.architectureDiagram?.hasPrefix("graph LR\n") == true)
        let back = try AutoNoteJSON.encoder().encode(m)
        #expect(try AutoNoteJSON.decoder().decode(MinutesOutput.self, from: back) == m)
        // Same keys as the fixture, nothing dropped or renamed.
        #expect(Set(try object(back).keys) == Set(try object(data).keys))
    }

    @Test func encodingWritesEveryKeyMatchingTheSchema() throws {
        let schema = try object(Data(MinutesSchema.json.utf8))
        let required = try #require(schema["required"] as? [String])
        let encoded = try object(AutoNoteJSON.encoder().encode(Samples.minutes))
        #expect(Set(encoded.keys) == Set(required))
        #expect(encoded["architecture_diagram"] is NSNull)
        #expect(encoded["schema_version"] as? Int == 2)
        // Item keys match the schema's required item keys too.
        let props = try #require(schema["properties"] as? [String: Any])
        let full = MinutesOutput(
            title: "t", summary: ["a", "b", "c"], decisions: [Decision(text: "d", t: "00:00:01")],
            agenda: [AgendaItem(title: "a", body: "b", t: "00:00:01")], nextActions: [NextAction(text: "n", t: "00:00:01")],
            suggestedTerms: [], attendees: [Attendee(name: "自分")], keyPoints: [MinutesPoint(text: "k", t: "00:00:01")],
            insights: [MinutesPoint(text: "i", t: "00:00:01")],
            questions: [MinutesQuestion(question: "q", isResolved: false, t: "00:00:01")],
            deadlines: [Deadline(description: "d", date: "12/1", t: "00:00:01")],
            followUps: [MinutesPoint(text: "f", t: "00:00:01")],
            risks: [Risk(description: "r", severity: .low, t: "00:00:01")], architectureDiagram: "graph TD\n  A --> B")
        let all = try object(AutoNoteJSON.encoder().encode(full))
        for (key, value) in all {
            guard let items = value as? [[String: Any]], let first = items.first else { continue }
            let p = try #require(props[key] as? [String: Any])
            let itemSchema = try #require(p["items"] as? [String: Any])
            let req = try #require(itemSchema["required"] as? [String])
            #expect(Set(first.keys) == Set(req), "\(key)")
        }
    }

    /// Automations read `minutes.json` through `AUTONOTE_JSON`: the six v1 keys keep their names and JSON types.
    @Test func v1KeysKeepNamesAndTypes() throws {
        let m = try AutoNoteJSON.decoder().decode(MinutesOutput.self, from: fixture("20261024-1400-a1b2"))
        let o = try object(AutoNoteJSON.encoder().encode(m))
        #expect(o["title"] is String)
        #expect((o["summary"] as? [String])?.count == 3)
        let decisions = try #require(o["decisions"] as? [[String: Any]])
        #expect(decisions[0]["text"] is String && decisions[0]["t"] is String)
        let agenda = try #require(o["agenda"] as? [[String: Any]])
        #expect(agenda[0]["title"] is String && agenda[0]["body"] is String && agenda[0]["t"] is String)
        let actions = try #require(o["next_actions"] as? [[String: Any]])
        #expect(actions[0]["text"] is String && actions[0]["owner"] is String && actions[0]["t"] is String)
        #expect(actions[0]["due"] is NSNull)
        #expect(actions[0]["priority"] as? String == "medium")
        #expect(o["suggested_terms"] as? [String] == ["ほしぞら食品"])
    }

    @Test func unknownLevelReadsAsMedium() throws {
        let json = #"{"text":"x","owner":null,"due":null,"t":"00:00:01","priority":"urgent"}"#
        #expect(try AutoNoteJSON.decoder().decode(NextAction.self, from: Data(json.utf8)).priority == .medium)
    }
}
