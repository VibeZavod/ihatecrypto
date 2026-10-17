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

/// Settings › Modules: the networks and every kind of move listed on the left, the switches of the one picked on the
/// right. A protocol works only while it, its kind and its networks are on.
struct ModulesSettings: View {
    @AppStorage(Modules.key) private var stored = ""
    /// The row picked on the left: "networks" or a ModuleKind's raw value.
    @AppStorage("modulesPick") private var pick = "networks"

    var body: some View {
        let m = Modules(stored: stored)
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Modules").font(.ui(24, .bold))
                Text("What the assistant may use. Off means it never plans a move there. Money already there still shows on the canvas.")
                    .font(.ui(13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top, spacing: 20) {
                sidebar(m)
                detail(ModuleKind(rawValue: pick), m).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: 980, maxHeight: .infinity, alignment: .topLeading)
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func sidebar(_ m: Modules) -> some View {
        VStack(spacing: 2) {
            sideRow("networks", "Networks", icon: "globe", on: ModuleNetwork.allCases.filter(m.isOn).count, of: ModuleNetwork.allCases.count)
            Divider().padding(.horizontal, 10).padding(.vertical, 5)
            ForEach(ModuleKind.allCases, id: \.self) { k in
                let c = count(k, m)
                sideRow(k.rawValue, k.name, icon: Self.icon(k), on: c.on, of: c.of)
            }
            HStack(spacing: 10) {
                Image(systemName: "questionmark.circle").font(.system(size: 15, weight: .medium)).frame(width: 20)
                Text("Predictions").font(.ui(13))
                Spacer(minLength: 6)
                Text("Soon").font(.ui(11.5))
            }
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12).frame(height: 40)
        }
        .padding(6)
        .frame(width: 250)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Brand.glassFill))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Brand.glassRim))
    }

    private func sideRow(_ id: String, _ name: String, icon: String, on: Int, of total: Int) -> some View {
        let picked = pick == id, all = on == total
        return Button { pick = id } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 15, weight: .medium)).frame(width: 20)
                    .foregroundStyle(picked ? Brand.accentInk : Color.secondary)
                Text(name).font(.ui(13.5, .semibold)).foregroundStyle(picked ? .primary : .secondary).lineLimit(1)
                Spacer(minLength: 6)
                Text("\(on)/\(total)").font(.ui(11.5, .semibold))
                    .foregroundStyle(all ? Color.secondary : Brand.accentInk)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Capsule().fill(all ? Color.primary.opacity(0.06) : Brand.accent.opacity(0.12)))
            }
            .padding(.horizontal, 12).frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(picked ? Color.primary.opacity(0.09) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerStyle(.link)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    /// A kind's protocols switched on, of all of them; none while the kind itself is off.
    private func count(_ k: ModuleKind, _ m: Modules) -> (on: Int, of: Int) {
        let ps = ModuleProtocol.allCases.filter { $0.kind == k }
        return (m.isOn(k) ? ps.filter(m.isOn).count : 0, ps.count)
    }

    @ViewBuilder private func detail(_ k: ModuleKind?, _ m: Modules) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if let k {
                let c = count(k, m)
                header(k.name, k.line, icon: Self.icon(k), on: c.on, of: c.of, master: k, m)
                box(ModuleProtocol.allCases.filter { $0.kind == k }) { protocolRow($0, m) }
            } else {
                header("Networks", "Where the assistant may move money", icon: "globe",
                       on: ModuleNetwork.allCases.filter(m.isOn).count, of: ModuleNetwork.allCases.count, master: nil, m)
                box(ModuleNetwork.allCases) { networkRow($0, m) }
            }
        }
    }

    private func header(_ title: String, _ line: String, icon: String, on: Int, of total: Int, master k: ModuleKind?, _ m: Modules) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 19, weight: .medium)).foregroundStyle(Brand.accentInk)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Brand.glassFill))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Brand.glassRim))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.ui(19, .bold))
                Text(line).font(.ui(13)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Text("\(on) of \(total) on").font(.ui(12.5)).foregroundStyle(.secondary)
            if let k {
                Toggle(k.name, isOn: Binding(get: { m.isOn(k) }, set: { v in update { $0.set(k, v) } })).toggleStyle(AccentSwitch())
            }
        }
    }

    /// One framed list, rows between thin lines; it scrolls by itself once it's taller than the window.
    private func box<Item: Hashable, Row: View>(_ items: [Item], @ViewBuilder row: @escaping (Item) -> Row) -> some View {
        let list = VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element) { i, item in
                if i > 0 { Divider() }
                row(item).padding(.horizontal, 16).padding(.vertical, 12)
            }
        }
        return ViewThatFits(in: .vertical) {
            list
            ScrollView { list }
        }
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Brand.glassFill))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Brand.glassRim))
    }

    private func protocolRow(_ p: ModuleProtocol, _ m: Modules) -> some View {
        let used = ModuleNetwork.allCases.filter { p.runs(on: $0) }
        let off = used.filter { !m.isOn($0) }
        let names = off.map(\.name).joined(separator: ", "), verb = off.count == 1 ? "is" : "are"
        // A network it can't work without, or every one it has, being off stops it; one of several leaves the rest.
        let sub = off.isEmpty ? p.place
            : off.contains(where: p.networks.contains) || off.count == used.count ? "\(names) \(verb) off"
            : "\(p.place) · \(names) \(verb) off, the rest work"
        return row(TokenLogo(name: p.logo, size: 34).clipShape(Circle()), p.name, sub,
                   subInk: !off.isEmpty && m.isOn(p) ? Brand.accentInk : .secondary) {
            Toggle(p.name, isOn: Binding(get: { m.isOn(p) }, set: { v in update { $0.set(p, v) } }))
                .toggleStyle(AccentSwitch()).disabled(!m.isOn(p.kind))
        }
        .opacity(m.allows(p) ? 1 : 0.45)
    }

    private func networkRow(_ n: ModuleNetwork, _ m: Modules) -> some View {
        let on = m.isOn(n)
        let users = ModuleProtocol.allCases.filter { $0.runs(on: n) }.map(\.name)
        return row(TokenLogo(name: n.logo, size: 34).clipShape(Circle()).saturation(on ? 1 : 0).opacity(on ? 1 : 0.45),
                   n.name, users.isEmpty ? "Balances only" : "Used by " + users.joined(separator: ", "), subInk: .secondary, dim: !on) {
            Toggle(n.name, isOn: Binding(get: { on }, set: { v in update { $0.set(n, v) } })).toggleStyle(AccentSwitch())
        }
    }

    private func row<Switch: View>(_ logo: some View, _ name: String, _ sub: String, subInk: Color, dim: Bool = false,
                                   @ViewBuilder toggle: () -> Switch) -> some View {
        HStack(spacing: 14) {
            logo
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.ui(14, .semibold)).foregroundStyle(dim ? .secondary : .primary)
                Text(sub).font(.ui(12)).foregroundStyle(subInk).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            toggle()
        }
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

private extension ModuleProtocol {
    /// Whether it works on `n`. Uniswap, Aave and Morpho check the network per move (their `networks` is empty), so
    /// the networks their place names count too.
    func runs(on n: ModuleNetwork) -> Bool { networks.contains(n) || place.contains(n.name) }
}

extension Workspace {
    /// Modules a later version brings start switched off and are asked about once, on the canvas: «New in ihatecrypto:
    /// BNB Chain — turn it on?» with a card for each and one to keep them off. The first run of this mechanism records
    /// every module there is as known, so nothing the user already has changes.
    func offerNewModules() {
        let d = UserDefaults.standard
        guard d.stringArray(forKey: Modules.knownKey) != nil else { d.set(Modules.allIDs, forKey: Modules.knownKey); return }
        let new = Modules.current.newIDs
        guard !new.isEmpty, (d.string(forKey: "onboardingStep") ?? "").isEmpty, nextSteps == nil else { return }
        let names = new.map(Modules.name).joined(separator: ", ")
        reply(say("New in ihatecrypto: \(names). It stays off until you say — turn it on?",
                  "Новое в ihatecrypto: \(names). Пока выключено — включить?"))
        offerCards(new.prefix(4).map { id in
            ChatRouter.Option(title: say("Turn on \(Modules.name(id))", "Включить \(Modules.name(id))"), comment: "Settings › Modules", command: Self.moduleOn + id)
        } + [ChatRouter.Option(title: say("Keep it off", "Оставить выключенным"),
                               comment: say("Settings › Modules turns it on any time", "Включить можно в Settings › Modules"), command: Self.moduleKeepOff)])
    }

    /// The two answers' cards, carried instead of a chat command.
    static let moduleOn = "turn on module ", moduleKeepOff = "keep the new modules off"

    func answerNewModules(_ command: String) {
        var m = Modules.current
        if command.hasPrefix(Self.moduleOn) {
            let id = String(command.dropFirst(Self.moduleOn.count))
            m.choices[id] = true
            reply(say("\(Modules.name(id)) is on.", "\(Modules.name(id)) включено."))
        } else {
            for id in m.newIDs { m.choices[id] = false }
            reply(say("Left off. Settings › Modules turns it on any time.", "Оставил выключенным. Включить можно в Settings › Modules."))
        }
        UserDefaults.standard.set(m.stored, forKey: Modules.key)
    }
}
