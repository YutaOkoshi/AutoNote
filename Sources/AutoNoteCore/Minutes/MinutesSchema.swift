import Foundation

/// `scripts/minutes-schema.json`, kept as a raw string so the package needs no resources.
/// `ClaudeCodeSummarizerTests.schemaMatchesScriptsFile` keeps the two identical.
public enum MinutesSchema {
    public static let json: String = #"""
    {
      "type": "object",
      "properties": {
        "title": {
          "type": "string",
          "maxLength": 20,
          "description": "会議名（20 文字以内、ファイル名に使える文字）"
        },
        "summary": {
          "type": "array",
          "items": { "type": "string" },
          "minItems": 3,
          "maxItems": 3,
          "description": "3 行の要約"
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
              "t": { "type": "string", "pattern": "^\\d{2}:\\d{2}:\\d{2}$" }
            },
            "required": ["text", "owner", "due", "t"],
            "additionalProperties": false
          }
        },
        "suggested_terms": {
          "type": "array",
          "items": { "type": "string" }
        }
      },
      "required": ["title", "summary", "decisions", "agenda", "next_actions", "suggested_terms"],
      "additionalProperties": false
    }
    """#
}
