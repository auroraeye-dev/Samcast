import SwiftUI
import WebKit

/// Displays a handed-over page inside QuackCast.
///
/// Rendered directly in the view hierarchy rather than presented as a modal:
/// modal presentation depended on finding a key window and a root view
/// controller in a presentable state, and when that failed the page simply
/// never appeared even though it had arrived. A plain child view always shows.
///
/// A web view can also be pointed at a new URL, which SFSafariViewController
/// cannot — so a second handoff replaces the first in place instead of
/// silently re-showing the old page.
struct WebPageView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let web = WKWebView()
        web.allowsBackForwardNavigationGestures = true
        context.coordinator.loaded = url
        web.load(URLRequest(url: url))
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        guard context.coordinator.loaded != url else { return }
        context.coordinator.loaded = url
        web.load(URLRequest(url: url))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var loaded: URL?
    }
}
