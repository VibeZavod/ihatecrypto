import IhatecryptoCore
import SwiftUI
import WalletCore

extension Workspace {
    var modulesRussian: Bool { replyLanguage == "Russian" }

    /// Why this wallet command can't run with the switches in Settings › Modules; nil when it can.
    func moduleRefusal(_ command: WalletCommand) -> String? { Modules.current.refusal(command, ru: modulesRussian) }

    /// The plan on the canvas: perps or an xyz market, bridged from Solana when it needs money there.
    var tradeRefusal: String? {
        Modules.current.refusal(trade: market?.dex != nil, bridges: intent.amountUSDC != nil || quote != nil, ru: modulesRussian)
    }

    /// A transfer to an address-book entry, by the entry's network.
    func transferRefusal(_ entry: SavedAddress) -> String? {
        ModuleNetwork(place: entry.network.rawValue).flatMap { Modules.current.refusal(network: $0, ru: modulesRussian) }
    }
}

/// Above the chat's field: the networks the assistant may use, as at most three logos and «+N». A click opens their
/// switches; kinds of moves and protocols are in Settings › Modules.
struct NetworksChip: View {
    @Environment(Workspace.self) private var ws
    @AppStorage(Modules.key) private var stored = ""
    @State private var open = false
    /// When the popover last closed: the click on the chip that closes it must not reopen it.
    @State private var closedAt = Date.distantPast

    var body: some View {
        let on = ModuleNetwork.allCases.filter(Modules(stored: stored).isOn)
        Button {
            if open { open = false; return }
            guard Date.now.timeIntervalSince(closedAt) > 0.3 else { return }
            open = true
        } label: {
            HStack(spacing: 6) {
                if on.isEmpty {
                    Text("No networks").font(.ui(12, .semibold)).foregroundStyle(.orange)
                } else {
                    HStack(spacing: -6) {
                        ForEach(on.prefix(3), id: \.self) { n in
                            TokenLogo(name: n.logo, size: 20).clipShape(Circle())
                                .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                        }
                    }
                    if on.count > 3 { Text("+\(on.count - 3)").font(.ui(12, .bold)).foregroundStyle(.secondary) }
                }
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
            }
            .padding(.leading, 5).padding(.trailing, 9).frame(height: 30)
            .background(Capsule().fill(open ? Brand.accent.opacity(0.14) : Brand.glassFill))
            .overlay(Capsule().strokeBorder(Brand.glassRim))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Networks the assistant may use: \(on.map(\.name).joined(separator: ", "))")
        .popover(isPresented: $open, arrowEdge: .top) { menu }
        .onChange(of: open) {
            if !open { closedAt = .now }
            // Closing doesn't clear what Settings, opened from this menu, has just set.
            if open { ws.tuning = "Choosing networks" } else if ws.tuning == "Choosing networks" { ws.tuning = nil }
        }
    }

    private var menu: some View {
        let m = Modules(stored: stored)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("NETWORKS").font(.ui(10, .semibold)).tracking(1.2)
                Spacer()
                Text("\(ModuleNetwork.allCases.filter(m.isOn).count) of \(ModuleNetwork.allCases.count) on").font(.ui(11, .semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 6)
            ForEach(ModuleNetwork.allCases, id: \.self) { n in
                // Switches in one column on the right: a Toggle's own label puts each one right after its text.
                HStack(spacing: 12) {
                    TokenLogo(name: n.logo, size: 28).clipShape(Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(n.name).font(.ui(13, .bold))
                        Text(n.uses.replacingOccurrences(of: " · ", with: "\u{00A0}· ")).font(.ui(11)).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Toggle(n.name, isOn: binding(n)).toggleStyle(AccentSwitch())
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
            Divider().padding(.horizontal, 8).padding(.vertical, 6)
            Text("Off: the assistant won’t plan moves there. Money on that network still shows on the canvas.")
                .font(.ui(11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16).padding(.bottom, 6)
            Button {
                open = false
                ws.openSettings(.modules)
            } label: {
                Text("DeFi, perps, protocols: Settings › Modules").font(.ui(11, .semibold)).underline()
                    .foregroundStyle(Color(nsColor: .linkColor))
            }
            .buttonStyle(.plain).pointerStyle(.link)
            .padding(.horizontal, 16).padding(.bottom, 4)
        }
        .padding(.vertical, 12)
        .frame(width: 340)
    }

    private func binding(_ n: ModuleNetwork) -> Binding<Bool> {
        Binding(get: { Modules(stored: stored).isOn(n) }, set: { on in
            var m = Modules(stored: stored)
            m.set(n, on)
            stored = m.stored
        })
    }
}

/// The networks menu's switch, drawn: the accent when on and 36 pt wide (macOS 26's switch is 54 pt and keeps the
/// system color whatever the tint).
struct AccentSwitch: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            Capsule().fill(configuration.isOn ? Brand.accent : Color.primary.opacity(0.14))
                .frame(width: 36, height: 22)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle().fill(.white).shadow(color: .black.opacity(0.2), radius: 1, y: 0.5).padding(2)
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

/// Settings › Modules: networks, kinds of moves and their protocols. A protocol works only while it, its kind and its
/// networks are on; new modules arrive switched off.
struct ModulesSettings: View {
    @AppStorage(Modules.key) private var stored = ""
    private let columns = [GridItem(.flexible(), spacing: 14, alignment: .top), GridItem(.flexible(), spacing: 14, alignment: .top),
                           GridItem(.flexible(), spacing: 14, alignment: .top)]

    var body: some View {
        let m = Modules(stored: stored)
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .lastTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Modules").font(.ui(24, .bold))
                        Text("What the assistant may use. Off means it never plans a move there. Money already there still shows on the canvas.")
                            .font(.ui(13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 16)
                    let live = ModuleProtocol.allCases.filter(m.allows).count
                    Text("\(live) of \(ModuleProtocol.allCases.count) protocols on").font(.ui(12, .semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 12).padding(.vertical, 6).background(Capsule().fill(Brand.glassFill))
                        .overlay(Capsule().strokeBorder(Brand.glassRim))
                }
                VStack(alignment: .leading, spacing: 10) {
                    caption("NETWORKS")
                    HStack(spacing: 8) {
                        ForEach(ModuleNetwork.allCases, id: \.self) { n in networkChip(n, on: m.isOn(n)) }
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    caption("WHAT IT CAN DO")
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                        ForEach(ModuleKind.allCases, id: \.self) { kindCard($0, m) }
                        soonCard
                    }
                    Text("New modules always arrive switched off. Turn one on when you want the assistant to use it.")
                        .font(.ui(10)).foregroundStyle(.secondary)
                }
            }
            .padding(28)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.ui(11, .bold)).tracking(1.3).foregroundStyle(.secondary)
    }

    private func networkChip(_ n: ModuleNetwork, on: Bool) -> some View {
        Button { update { $0.set(n, !on) } } label: {
            HStack(spacing: 7) {
                TokenLogo(name: n.logo, size: 22).clipShape(Circle()).saturation(on ? 1 : 0).opacity(on ? 1 : 0.5)
                Text(n.name).font(.ui(13, .semibold)).foregroundStyle(on ? .primary : .secondary)
            }
            .padding(.leading, 5).padding(.trailing, 12).frame(height: 34)
            .background(Capsule().fill(on ? Brand.glassFill : .clear))
            .overlay(Capsule().strokeBorder(on ? Brand.glassRim : Color.primary.opacity(0.18)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityValue(on ? "on" : "off")
        .help(on ? "\(n.name) is on — click to switch it off" : "\(n.name) is off — click to switch it on")
    }

    private func kindCard(_ k: ModuleKind, _ m: Modules) -> some View {
        let on = m.isOn(k)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: Self.icon(k)).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(on ? Brand.accentInk : Color.secondary)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 10).fill(on ? Brand.accent.opacity(0.16) : Color.primary.opacity(0.06)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(k.name).font(.ui(15, .semibold))
                    Text(k.line).font(.ui(10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Toggle(k.name, isOn: Binding(get: { on }, set: { v in update { $0.set(k, v) } }))
                    .toggleStyle(AccentSwitch())
            }
            Divider().padding(.vertical, 10)
            ForEach(ModuleProtocol.allCases.filter { $0.kind == k }, id: \.self) { p in
                let offNetwork = p.networks.first { !m.isOn($0) }
                HStack(spacing: 10) {
                    TokenLogo(name: p.logo, size: 26).clipShape(Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.name).font(.ui(13, .semibold))
                        Text(offNetwork.map { "\($0.name) is off" } ?? p.place).font(.ui(10))
                            .foregroundStyle(offNetwork == nil ? Color.secondary : Brand.accentInk).lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    Toggle(p.name, isOn: Binding(get: { m.isOn(p) }, set: { v in update { $0.set(p, v) } }))
                        .toggleStyle(AccentSwitch()).disabled(!on)
                }
                .padding(.vertical, 5)
                .opacity(m.allows(p) ? 1 : 0.5)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Brand.glassFill))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Brand.glassRim))
    }

    private var soonCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "questionmark.circle").font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(width: 34, height: 34).background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Predictions").font(.ui(15, .semibold))
                    Text("Yes / no markets on real events").font(.ui(10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Text("Soon").font(.ui(12, .semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 4).background(Capsule().fill(Color.primary.opacity(0.06)))
            }
            Text("Comes in a later update. It will appear here switched off.").font(.ui(10)).foregroundStyle(.secondary)
        }
        .padding(14)
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.18), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
    }

    private func update(_ change: (inout Modules) -> Void) {
        var m = Modules(stored: stored)
        change(&m)
        stored = m.stored
    }

    static func icon(_ k: ModuleKind) -> String {
        switch k {
        case .swaps: "arrow.left.arrow.right"
        case .earn: "percent"
        case .perps: "chart.line.uptrend.xyaxis"
        case .stocks: "chart.bar"
        case .bridges: "point.topleft.down.to.point.bottomright.curvepath"
        case .payments: "creditcard"
        }
    }
}
