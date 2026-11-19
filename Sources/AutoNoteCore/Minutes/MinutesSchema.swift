import Foundation

/// `scripts/minutes-schema.json` (schema v2), kept as a raw string so the package needs no resources.
/// `ClaudeCodeSummarizerTests.schemaMatchesScriptsFile` keeps the two identical.
public enum MinutesSchema {
    /// The `title` property's `maxLength` for minutes written in `language`: Japanese 20 (the spec's schema, as in
    /// `json`), English 60, as an English meeting name needs more letters (a real run's English title went past 20
    /// and the structured output was refused). Both fit a file name untruncated (`MeetingFileName.maxTitleLength`).
    public static func titleMaxLength(_ language: TranslationLanguage) -> Int {
        language == .en ? 60 : 20
    }

    /// The schema passed with `--json-schema` for minutes written in `language`: `json` (= scripts/minutes-schema.json)
    /// for Japanese; for English the same with the title's `maxLength` (and its description) from `titleMaxLength`.
    public static func json(for language: TranslationLanguage) -> String {
        guard language == .en else { return json }
        let ja = titleMaxLength(.ja), en = titleMaxLength(.en)
        // `maxLength` appears once in the schema (the title); `SummaryLanguageTests` checks nothing else changes.
        return json
            .replacingOccurrences(of: "\"maxLength\": \(ja),", with: "\"maxLength\": \(en),")
            .replacingOccurrences(of: "会議名（\(ja) 文字以内", with: "会議名（\(en) 文字以内")
    }

    public static let json: String = #"""
    {
      "type": "object",
      "properties": {
        "schema_version": {
          "type": "integer",
          "enum": [2],
          "description": "スキーマの版。常に 2"
        },
        "title": {
          "type": "string",
          "maxLength": 20,
          "description": "会議名（20 文字以内、ファイル名に使える文字）"
        },
        "summary": {
          "type": "array",
          "items": { "type": "string" },
          "minItems": 3,
          "maxItems": 5,
          "description": "会議全体の要約。3〜5 段落で、各要素が 1 段落"
        },
        "decisions": {
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "text": { "type": "string" },
              "t": { "type": "string", "pattern": "^\\d{2}:\\d{2}:\\d{2}$" }
            },
            "required": ["text", "t"],
            "additionalProperties": false
          }
        },
        "agenda": {
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "title": { "type": "string" },
              "body": { "type": "string" },
              "t": { "type": "string", "pattern": "^\\d{2}:\\d{2}:\\d{2}$" }
            },
            "required": ["title", "body", "t"],
            "additionalProperties": false
          }
        },
        "next_actions": {
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "text": { "type": "string" },
              "owner": { "type": ["string", "null"] },
              "due": { "type": ["string", "null"] },
              "t": { "type": "string", "pattern": "^\\d{2}:\\d{2}:\\d{2}$" },
              "priority": { "type": "string", "enum": ["high", "medium", "low"] }
            },
            "required": ["text", "owner", "due", "t", "priority"],
            "additionalProperties": false
          }
        },
        "suggested_terms": {
          "type": "array",
          "items": { "type": "string" }
        },
        "attendees": {
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "name": { "type": "string" },
              "role": { "type": ["string", "null"] }
            },
            "required": ["name", "role"],
            "additionalProperties": false
          }
        },
        "key_points": {
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "text": { "type": "string" },
              "t": { "type": "string", "pattern": "^\\d{2}:\\d{2}:\\d{2}$" }
            },
            "required": ["text", "t"],
            "additionalProperties": false
          }
        },
        "insights": {
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "text": { "type": "string" },
              "t": { "type": "string", "pattern": "^\\d{2}:\\d{2}:\\d{2}$" }
            },
            "required": ["text", "t"],
            "additionalProperties": false
          }
        },
        "questions": {
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "question": { "type": "string" },
              "asked_by": { "type": ["string", "null"] },
              "is_resolved": { "type": "boolean" },
              "answer": { "type": ["string", "null"] },
              "t": { "type": "string", "pattern": "^\\d{2}:\\d{2}:\\d{2}$" }
            },
            "required": ["question", "asked_by", "is_resolved", "answer", "t"],
            "additionalProperties": false
          }
        },
        "deadlines": {
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "description": { "type": "string" },
              "date": { "type": "string" },
              "owner": { "type": ["string", "null"] },
              "t": { "type": "string", "pattern": "^\\d{2}:\\d{2}:\\d{2}$" }
            },
            "required": ["description", "date", "owner", "t"],
            "additionalProperties": false
          }
        },
        "follow_ups": {
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "text": { "type": "string" },
              "t": { "type": "string", "pattern": "^\\d{2}:\\d{2}:\\d{2}$" }
            },
            "required": ["text", "t"],
            "additionalProperties": false
          }
        },
        "risks": {
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "description": { "type": "string" },
              "severity": { "type": "string", "enum": ["high", "medium", "low"] },
              "mitigation": { "type": ["string", "null"] },
              "t": { "type": "string", "pattern": "^\\d{2}:\\d{2}:\\d{2}$" }
            },
            "required": ["description", "severity", "mitigation", "t"],
            "additionalProperties": false
          }
        },
        "architecture_diagram": {
          "type": ["string", "null"],
          "description": "システム構成・データフローの議論があったときだけ Mermaid の graph TD/LR。無ければ null"
        }
      },
      "required": ["schema_version", "title", "summary", "decisions", "agenda", "next_actions", "suggested_terms",
                   "attendees", "key_points", "insights", "questions", "deadlines", "follow_ups", "risks",
                   "architecture_diagram"],
      "additionalProperties": false
    }
    """#
}
