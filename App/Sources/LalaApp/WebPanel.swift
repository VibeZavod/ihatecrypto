import AppKit
import SwiftUI
import WebKit

/// A page opened from the canvas or the chat (a token's chart, an explorer, a transaction), beside the boards instead
/// of in a browser, so the app stays in front. A plain web view: no wallet and no scripts of ours in it; signing only
/// happens in the app itself (Browser.swift is the dApp browser, with the wallet). Only web pages load here: a link
/// to an app (a wallet's deep link, mailto) is dropped.
@MainActor @Observable
final class SidePage: NSObject, WKNavigationDelegate, WKUIDelegate {
    @ObservationIgnored let webView: WKWebView
    var url: URL?
    var title = ""
    var loading = false
    var canGoBack = false

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        webView.allowsBackForwardNavigationGestures = true
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    func open(_ url: URL) {
        self.url = url
        webView.load(URLRequest(url: url))
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let scheme = action.request.url?.scheme?.lowercased() else { return .cancel }
        return ["http", "https", "about", "blob", "data"].contains(scheme) ? .allow : .cancel
    }

    /// A link that asks for a new window opens here instead.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil, let url = action.request.url { webView.load(URLRequest(url: url)) }
        return nil
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { changed() }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { changed() }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { changed() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { changed() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { changed() }

    private func changed() {
        title = webView.title ?? ""
        url = webView.url ?? url
        loading = webView.isLoading
        canGoBack = webView.canGoBack
    }
}

extension Workspace {
    /// Opens a web page in the panel beside the canvas.
    func openWeb(_ url: URL) {
        sidePage.open(url)
        withAnimation(.easeOut(duration: 0.2)) { showWeb = true }
    }
}

/// The page beside the boards: back, reload, the site, and a way out to the user's browser.
struct WebPanel: View {
    @Environment(Workspace.self) private var ws
    @State private var copied = false

    var body: some View {
        let page = ws.sidePage
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { page.webView.goBack() } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.hoverIcon).disabled(!page.canGoBack).help("Back")
                Button { if page.loading { page.webView.stopLoading() } else { page.webView.reload() } } label: {
                    Image(systemName: page.loading ? "xmark" : "arrow.clockwise")
                }
                .buttonStyle(.hoverIcon).help(page.loading ? "Stop" : "Reload")
                Image(systemName: page.url?.scheme == "https" ? "lock.fill" : "lock.open").font(.system(size: 10)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(page.title.isEmpty ? page.url?.host() ?? "" : page.title).font(.ui(12, .semibold)).lineLimit(1)
                    Text(page.url?.host() ?? "").font(.ui(10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                Button {
                    guard let url = page.url else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: { Image(systemName: copied ? "checkmark" : "link") }
                    .buttonStyle(.hoverIcon).help("Copy the link")
                Button { if let url = page.url { NSWorkspace.shared.open(url) } } label: { Image(systemName: "safari") }
                    .buttonStyle(.hoverIcon).help("Open in your browser")
                Button { withAnimation(.easeOut(duration: 0.2)) { ws.showWeb = false } } label: { Image(systemName: "xmark") }
                    .buttonStyle(.hoverIcon).help("Close")
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            Divider()
            WebViewHost(webView: page.webView)
        }
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Brand.card))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Brand.cardBorder))
        .shadow(color: .black.opacity(0.18), radius: 24, y: 12)
    }
}
