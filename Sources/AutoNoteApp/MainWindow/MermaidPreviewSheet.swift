import AutoNoteCore
import SwiftUI
import WebKit

/// The 構成図 preview: the bundled mermaid.js (`Contents/Resources/mermaid/mermaid.min.js`) draws the diagram in a
/// WKWebView. Nothing leaves the Mac: the page has a no-network Content-Security-Policy (`MermaidPreviewPage`), the
/// web view uses a non-persistent data store, and a content rule list blocks every http(s) and other non-local load.
struct MermaidPreviewSheet: View {
    let source: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("構成図", systemImage: "square.stack.3d.up").font(.headline)
                Spacer()
                Button("閉じる") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            if let script = Self.mermaidScript {
                MermaidWebView(html: MermaidPreviewPage.html(diagram: source, mermaidScript: script))
            } else {
                ContentUnavailableView("プレビューを表示できません", systemImage: "exclamationmark.triangle",
                                       description: Text("アプリに mermaid.js が含まれていません。scripts/build-app.sh で作ったアプリで開いてください。"))
            }
        }
        .frame(minWidth: 640, idealWidth: 820, minHeight: 420, idealHeight: 600)
    }

    /// Read once per launch from the app bundle.
    @MainActor private static let mermaidScript: String? = {
        guard let url = Bundle.main.resourceURL?.appending(path: "mermaid/mermaid.min.js") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }()
}

private struct MermaidWebView: NSViewRepresentable {
    let html: String

    /// Blocks every load that is not the inline page itself (http, https, file, data frames...).
    private static let blockRules = """
    [{"trigger":{"url-filter":".*"},"action":{"type":"block"}},
     {"trigger":{"url-filter":"^about:"},"action":{"type":"ignore-previous-rules"}}]
    """

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        let html = html
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "autonote.mermaid.offline",
                                                                encodedContentRuleList: Self.blockRules) { list, _ in
            Task { @MainActor in
                // Without the rule list the CSP still keeps the page offline.
                if let list { view.configuration.userContentController.add(list) }
                view.loadHTMLString(html, baseURL: nil)
            }
        }
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}
}
