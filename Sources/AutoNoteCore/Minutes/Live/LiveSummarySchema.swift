import Foundation

/// The `--json-schema` for a live summary call (the shape of `LiveSummaryOutput`), kept as a raw string like `MinutesSchema`.
public enum LiveSummarySchema {
    public static let json: String = #"""
    {"type":"object","properties":{"now":{"type":"string","maxLength":60},"decisions":{"type":"array","items":{"type":"string"},"maxItems":50},"todos":{"type":"array","maxItems":50,"items":{"type":"object","properties":{"text":{"type":"string"},"owner":{"type":["string","null"]},"side":{"type":"string","enum":["self","other","unknown"]}},"required":["text","owner","side"],"additionalProperties":false}},"asked_question_ids":{"type":"array","items":{"type":"string"},"maxItems":30}},"required":["now","decisions","todos","asked_question_ids"],"additionalProperties":false}
    """#
}
