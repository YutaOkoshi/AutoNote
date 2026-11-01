import Foundation

/// The HTML the 構成図 preview sheet loads: the bundled mermaid.js inlined, the diagram passed as a JSON string, and a
/// Content-Security-Policy that allows no network access (no `connect-src`, no remote scripts, styles, images or
/// fonts). Mermaid runs with `securityLevel: "strict"`, so labels from the minutes cannot inject HTML.
public enum MermaidPreviewPage {
    public static let contentSecurityPolicy =
        "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; font-src data:"

    /// The diagram as a JavaScript string literal. `JSONEncoder` escapes `/`, so `</script>` in the source cannot
    /// close the script element.
    public static func jsString(_ text: String) -> String {
        let data = (try? JSONEncoder().encode([text])) ?? Data("[\"\"]".utf8)
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }

    public static func html(diagram: String, mermaidScript: String) -> String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy)">
        <style>
        :root { color-scheme: light dark; }
        body { margin: 16px; font-family: -apple-system, sans-serif; background: Canvas; color: CanvasText; }
        #error { color: #c00; white-space: pre-wrap; font-family: ui-monospace, monospace; font-size: 12px; }
        #out svg { max-width: 100%; height: auto; }
        </style>
        <script>\(mermaidScript)</script>
        </head><body><div id="out"></div><div id="error"></div>
        <script>
        (async () => {
          const dark = window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches;
          try {
            mermaid.initialize({ startOnLoad: false, securityLevel: "strict", theme: dark ? "dark" : "default" });
            const { svg } = await mermaid.render("autonote-diagram", \(jsString(diagram)));
            document.getElementById("out").innerHTML = svg;
          } catch (e) {
            document.getElementById("error").textContent = "図を描けませんでした: " + (e && e.message ? e.message : e);
          }
        })();
        </script>
        </body></html>
        """
    }
}
