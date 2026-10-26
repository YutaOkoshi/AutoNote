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
