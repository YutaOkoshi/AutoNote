import Testing
import AutoNoteTestSupport
@testable import AutoNoteCore

@Test func defaultTemplateMatchesSpecExample() {
    let v = FrontmatterTemplate.values(manifest: Samples.manifest, title: "プロジェクト定例", transcriptEngine: "whisper.cpp large-v3-turbo", appVersion: "0.1.0", timeZone: Samples.tokyo)
    let expected = ["---", "title: プロジェクト定例", "date: 2026-10-24", #"start: "14:00""#, #"end: "15:02""#, "duration_min: 62", "tags: [meeting]", #"device: "Kestrel Headset 7""#,
                    #"transcript_engine: "whisper.cpp large-v3-turbo""#, "status: minutes_generated", "autonote_id: 20261024-1400-a1b2", #"autonote: "0.1.0""#, "---", ""]
    #expect(FrontmatterTemplate(text: FrontmatterTemplate.defaultText).render(v) == expected.joined(separator: "\n"))
}

@Test func requiredKeysAreRestored() {
    let out = FrontmatterTemplate(text: "---\ntags: [meeting]\n---\n").render(["title": "定例", "date": "2026-10-24", "status": "transcript_only", "autonote_id": "20261024-1400-a1b2"])
    #expect(out == "---\ntags: [meeting]\ntitle: 定例\ndate: 2026-10-24\nstatus: transcript_only\nautonote_id: 20261024-1400-a1b2\n---\n")
}

@Test func escapesHostileTitle() {
    let out = FrontmatterTemplate(text: "title: {{title}}\ndevice: \"{{device}}\"").render(["title": #"Q3: "予算" #1"#, "device": #"A"B"#])
    #expect(out.contains(#"title: "Q3: \"予算\" #1""#)); #expect(out.contains(#"device: "A\"B""#))
    #expect(FrontmatterTemplate.yamlScalar("yes") == #""yes""#); #expect(FrontmatterTemplate.yamlScalar("プロジェクト定例") == "プロジェクト定例")
    #expect(FrontmatterTemplate.yamlScalar("一行目\n二行目") == "一行目 二行目")
}

@Test func crlfTemplateRendersLikeLF() {
    let values = ["title": "定例", "status": "recorded", "autonote_id": "x"]
    let lf = FrontmatterTemplate(text: "---\ntitle: {{title}}\nstatus: {{status}}\nautonote_id: {{autonote_id}}\n---\n").render(values)
    #expect(FrontmatterTemplate(text: "---\r\ntitle: {{title}}\r\nstatus: {{status}}\rautonote_id: {{autonote_id}}\r\n---\r\n").render(values) == lf)
    #expect(!lf.contains("\r"))
}

@Test func freeTextValuesAreQuotedUnlessPlain() {
    for t in ["議題:", "a\t#b", "123", "2026-10-24", "-x", ".x", "Null", "Q&A", "a: b"] {
        #expect(FrontmatterTemplate.yamlScalar(t, freeText: true) == "\"" + t.replacingOccurrences(of: "\"", with: "\\\"") + "\"", "\(t)")
    }
    for t in ["プロジェクト定例", "Kestrel Headset 7", "whisper.cpp large-v3-turbo", "定例_v2"] { #expect(FrontmatterTemplate.yamlScalar(t, freeText: true) == t, "\(t)") }
    #expect(FrontmatterTemplate.yamlScalar("2026-10-24") == "2026-10-24")   // structured rule unchanged
    let t = FrontmatterTemplate(text: "title: {{title}}\ndevice: {{device}}\nnote: {{custom}}\ndate: {{date}}\nduration_min: {{duration_min}}\nautonote_id: {{autonote_id}}\nstatus: {{status}}")
    let out = t.render(["title": "議題:", "device": "123", "custom": "a\t#b", "date": "2026-10-24", "duration_min": "5", "autonote_id": "20261024-1400-a1b2", "status": "recorded"])
    for line in [#"title: "議題:""#, #"device: "123""#, "note: \"a\t#b\"", "date: 2026-10-24", "duration_min: 5", "autonote_id: 20261024-1400-a1b2", "status: recorded"] {
        #expect(out.contains(line + "\n"), "\(line)")
    }
    let fallback = FrontmatterTemplate(text: "x: 1").render(["title": "123", "date": "2026-10-24", "status": "recorded", "autonote_id": "20261024-1400-a1b2"])
    #expect(fallback.contains(#"title: "123""# + "\n")); #expect(fallback.contains("date: 2026-10-24\n")); #expect(fallback.contains("autonote_id: 20261024-1400-a1b2\n"))
}
