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
        webWallet = false
        withAnimation(.easeOut(duration: 0.2)) { showWeb = true }
    }

    /// A site to use with the wallet («open jup.ag»): the dApp browser (Browser.swift) in the same panel, which moves
    /// like the chat. Its own window closes first: one web view can't show in two places.
    func openSite(_ text: String) {
        NSApp.windows.first { $0.title == "Browser" }?.close()
        browser.workspace = self
        browser.attachDelegate()
        browser.open(text)
        webWallet = true
        withAnimation(.easeOut(duration: 0.2)) { showWeb = true }
    }
}

/// The page beside the boards: back, reload, the site, and a way out to the user's browser. With the wallet («open
/// jup.ag», or the wallet button on a page) it's the dApp browser instead. Its header moves it; a double-click brings it
/// back beside the chat.
struct WebPanel: View {
    @Environment(Workspace.self) private var ws
    @Environment(\.openWindow) private var openWindow
    @Binding var drag: CGSize
    var endDrag: (CGSize) -> Void = { _ in }
    var dock: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            if ws.webWallet {
                grip(walletHeader)
                Divider()
                BrowserView(window: false)
            } else {
                grip(plainHeader)
                Divider()
                WebViewHost(webView: ws.sidePage.webView)
            }
        }
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Brand.card))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Brand.cardBorder))
        .shadow(color: .black.opacity(0.18), radius: 24, y: 12)
    }

    /// The whole header, its text too: drag to move, double-click to go back beside the chat. Its buttons still click
    /// (a child's gesture wins). Only its empty space moved it before, and the wallet header has almost none.
    private func grip(_ header: some View) -> some View {
        header.contentShape(Rectangle()).pointerStyle(.grabIdle)
            .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .global).onChanged { drag = $0.translation }.onEnded { endDrag($0.translation) })
            .simultaneousGesture(TapGesture(count: 2).onEnded { dock() })
    }

    private var walletHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "wallet.pass").font(.system(size: 12, weight: .semibold)).foregroundStyle(Brand.accentInk)
            Text("With your wallet").font(.ui(12, .semibold))
            Text("· every signature is shown first").font(.ui(10)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 6)
            Button {
                ws.showWeb = false
                // After the panel lets go of the page's view: the window shows that same page, connections kept.
                Task { try? await Task.sleep(for: .milliseconds(150)); openWindow(id: "browser") }
            } label: { Image(systemName: "macwindow.on.rectangle") }
                .buttonStyle(.hoverIcon).help("Move to its own window")
            Button { withAnimation(.easeOut(duration: 0.2)) { ws.showWeb = false } } label: { Image(systemName: "xmark") }
                .buttonStyle(.hoverIcon).help("Close")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var plainHeader: some View {
        let page = ws.sidePage
        return HStack(spacing: 6) {
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
            if let url = page.url { CopyButton(text: url.absoluteString, icon: "link", help: "Copy the link") }
            Button { if let url = page.url { ws.openSite(url.absoluteString) } } label: { Image(systemName: "wallet.pass") }
                .buttonStyle(.hoverIcon).help("Open with your wallet: the site can ask to connect and to sign")
            Button { if let url = page.url { NSWorkspace.shared.open(url) } } label: { Image(systemName: "safari") }
                .buttonStyle(.hoverIcon).help("Open in your browser")
            Button { withAnimation(.easeOut(duration: 0.2)) { ws.showWeb = false } } label: { Image(systemName: "xmark") }
                .buttonStyle(.hoverIcon).help("Close")
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }
}
