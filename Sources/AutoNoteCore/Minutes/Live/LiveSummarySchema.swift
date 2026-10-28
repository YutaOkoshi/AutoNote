import Foundation

/// The `--json-schema` for a live summary call (the shape of `LiveSummaryOutput`), kept as a raw string like `MinutesSchema`.
public enum LiveSummarySchema {
    public static let json: String = #"""
    {"type":"object","properties":{"now":{"type":"string","maxLength":60},"decisions":{"type":"array","items":{"type":"string"},"maxItems":50},"todos":{"type":"array","maxItems":50,"items":{"type":"object","properties":{"text":{"type":"string"},"owner":{"type":["string","null"]}},"required":["text","owner"],"additionalProperties":false}}},"required":["now","decisions","todos"],"additionalProperties":false}
    """#
}
