import LLMCatalog
import LLMCore
import SwiftUI

/// The rail's bottom corner (Q01): the chat accounts already connected, each one click from use, then Settings, the
/// browser and What's new. No model choice here (the chat picks models) and no lock: «lock» is a chat command, and a
/// paused trading key resumes in Settings › Wallet.
struct ProfileMenu: View {
    @Environment(Workspace.self) private var ws
    @State private var open = false
    /// The account whose sign-out waits for its confirmation.
    @State private var signingOut: ProviderInfo?
    let compact: Bool

    var body: some View {
        Group {
            if compact {
                Button("Profile") { open.toggle() }.buttonStyle(RailRound(icon: "person.fill", title: "Profile", on: open))
            } else {
                Button { open.toggle() } label: { wideRow }.buttonStyle(.plain).modifier(HoverLift(radius: 16))
                    .accessibilityLabel("Profile")
            }
        }
        .help("Chat accounts, Settings, the browser, What's new")
        .popover(isPresented: $open, arrowEdge: compact ? .trailing : .top) { menu }
        .confirmationDialog("Sign out of \(signingOut?.shortName ?? "")?",
                            isPresented: Binding(get: { signingOut != nil }, set: { if !$0 { signingOut = nil } })) {
            Button("Sign out", role: .destructive) { if let id = signingOut?.id { ws.signOut(id) } }
        } message: {
            Text("The chat stops using the model until you sign in again. Your wallet key stays in secure storage."
                 + (signingOut?.id == "openrouter" ? " The second check (Jev) uses this login too." : ""))
        }
    }

    /// The connected accounts' logos, the one in use named, how many there are.
    private var wideRow: some View {
        let accounts = ws.accounts
        let current = accounts.first { $0.id == ws.providerID }
        let wallet = ws.signerWallet == nil ? "no wallet yet" : "wallet on this Mac"
        let count = "\(accounts.count) account\(accounts.count == 1 ? "" : "s")"
        return HStack(spacing: 10) {
            logos(current.map { c in [c] + accounts.filter { $0.id != c.id } } ?? accounts)
            VStack(alignment: .leading, spacing: 1) {
                Text(current?.shortName ?? "Accounts").font(.ui(13, .semibold)).lineLimit(1)
                // Three logos leave no room for the wallet's words on the rail: the count alone then.
                ViewThatFits(in: .horizontal) {
                    Text(accounts.isEmpty ? "no model connected" : "\(count) · \(wallet)")
                    Text(accounts.isEmpty ? "no model" : count)
                }
                .font(.ui(12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Brand.glassFill))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Brand.glassRim))
        .contentShape(Rectangle())
    }

    @ViewBuilder private func logos(_ accounts: [ProviderInfo]) -> some View {
        if accounts.isEmpty {
            Circle().fill(Brand.glassFill).frame(width: 28, height: 28)
                .overlay(Circle().strokeBorder(Brand.glassRim))
                .overlay(Image(systemName: "person.fill").font(.system(size: 12)).foregroundStyle(.secondary))
        } else {
            HStack(spacing: -8) {
                ForEach(accounts.prefix(3)) { info in
                    if let c = ModelCompany.of(info.id) {
                        ModelCompanyLogo(company: c, size: 28).clipShape(Circle())
                            .overlay(Circle().strokeBorder(Brand.card, lineWidth: 2).padding(-1))
                    }
                }
            }
            .padding(.leading, 1)
        }
    }

    private var menu: some View {
        let accounts = ws.accounts
        return VStack(alignment: .leading, spacing: 6) {
            Text("Accounts").font(.ui(15, .bold)).padding(.horizontal, 6).padding(.top, 4).padding(.bottom, 2)
            ForEach(accounts) { info in
                AccountRow(info: info, inUse: info.id == ws.providerID,
                           use: { go { use(info) } },
                           add: { go { ws.openSettings(.signIns) } },
                           signOut: { go { signingOut = info } })
            }
            Button { go { ws.openSettings(.signIns) } } label: {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .frame(width: 32, height: 32)
                        .overlay(Image(systemName: "plus").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary))
                    Text("Add an account").font(.ui(13, .semibold)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
            }
            .buttonStyle(LitBlock(radius: 12))
            Divider().padding(.vertical, 4)
            HStack(spacing: 6) {
                AppButton(title: "Settings", icon: "gearshape") { go { ws.openSettings() } }
                    .help("Settings · ⌘,")
                AppButton(title: "Browser", icon: "globe") { go { ws.openSite(ws.browser.address) } }
                    .help("The dApp browser, with your wallet")
                AppButton(title: "What's new", icon: "gift", dot: WhatsNew.shared.unseen != nil) { go { WhatsNew.shared.open = true } }
                    .help(WhatsNew.shared.releases.first.map { "Version \($0.version)" + ($0.day.isEmpty ? "" : " · \($0.day)") } ?? "What's new")
            }
        }
        .padding(12)
        .frame(width: 336)
        // What Ollama and LM Studio have downloaded, read as the menu opens: a server that stopped leaves the list.
        .task { await ws.refreshLocalModels() }
    }

    /// The chat goes on with this account, as the model chip's menu does it; its model stays as chosen there.
    private func use(_ info: ProviderInfo) {
        ws.providerID = info.id
        // A server on this Mac runs only what it has downloaded: its first chat model stands in for one that isn't there.
        if info.kind == .local, let live = ws.liveModels[info.id], !live.contains(ws.model),
           let first = live.first(where: { LLMCatalog.chatRefusal(model: $0) == nil }) { ws.model = first }
        // Loaded into memory now, so the first answer doesn't wait for it.
        if info.id == "ollama" { OllamaModels.preload(ws.model) }
        ws.saveCanvas()
    }

    private func go(_ action: () -> Void) {
        open = false
        action()
    }
}

/// One connected account: its logo, its name and kind. A click on the row uses it; the one in use only keeps a faint
/// fill. «…» under the pointer for the rest.
private struct AccountRow: View {
    let info: ProviderInfo
    let inUse: Bool
    let use: () -> Void
    let add: () -> Void
    let signOut: () -> Void
    @State private var hover = false

    var body: some View {
        let name = info.shortName
        HStack(spacing: 0) {
            Button { if !inUse { use() } } label: {
                HStack(spacing: 12) {
                    if let c = ModelCompany.of(info.id) { ModelCompanyLogo(company: c, size: 32) }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name).font(.ui(13.5, .semibold)).lineLimit(1)
                        Text(info.kindName).font(.ui(11.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                }
                .padding(.leading, 10).padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerStyle(inUse ? nil : .link)
            .accessibilityLabel(inUse ? "\(name), in use" : "Use \(name)")
            .help(inUse ? "The chat uses \(name)" : "The chat goes on with \(name)")
            // Under the pointer only, taking no room otherwise; it stays in the layout so an open menu keeps its anchor.
            Menu {
                Group {
                    if !inUse { Button("Use \(name)", systemImage: "checkmark", action: use) }
                    Button("Add another account…", systemImage: "plus", action: add)
                    // A server on this Mac has no login to leave.
                    if info.kind != .local {
                        Divider()
                        Button("Sign out of \(name)…", systemImage: "rectangle.portrait.and.arrow.right", action: signOut)
                    }
                }
                .labelStyle(.titleAndIcon)
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .bold)).foregroundStyle(.secondary)
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .pointerStyle(.link)
            .opacity(hover ? 1 : 0).allowsHitTesting(hover)
            .frame(width: hover ? 28 : 0, alignment: .trailing)
            .accessibilityLabel("More for \(name)")
            .help(info.kind == .local ? "Add another account" : "Add another account, sign out of \(name)")
        }
        .padding(.trailing, 8)
        // The hover fill changes at once; the row in use keeps its own and isn't a click target.
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(inUse ? Brand.accent.opacity(0.08) : hover ? Color.primary.opacity(0.06) : .clear))
        .onHover { hover = $0 }
    }
}

extension ProviderInfo {
    /// «Claude», «ChatGPT», «Ollama»: the way's name without what's in brackets, « API» or « on this Mac».
    var shortName: String {
        var s = name.components(separatedBy: " (")[0]
        for tail in [" API", " on this Mac"] where s.hasSuffix(tail) { s.removeLast(tail.count) }
        return s
    }

    var kindName: String {
        switch kind {
        case .subscription: "Subscription"
        case .apiKey: "API key"
        case .local: "On this Mac · free"
        }
    }
}

/// One of the three equal buttons at the menu's foot; a small accent dot marks something new behind it.
private struct AppButton: View {
    let title: String
    let icon: String
    var dot = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                Text(title).font(.ui(12, .semibold)).lineLimit(1)
            }
            .frame(maxWidth: .infinity).frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            .overlay(alignment: .topTrailing) {
                if dot { Circle().fill(Brand.accent).frame(width: 7, height: 7).padding(.top, 6).padding(.trailing, 8) }
            }
        }
        .buttonStyle(LitBlock(radius: 11))
        .accessibilityLabel(title)
    }
}
