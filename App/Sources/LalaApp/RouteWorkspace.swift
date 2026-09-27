import LalaCore
import SwiftUI

/// The route is a separate workspace: chat can stay visible or the canvas can take the whole window.
struct RouteWorkspace: View {
    @Environment(Workspace.self) private var ws
    @Binding var expanded: Bool
    @State private var selectedBlockID: String? = "source"
    @AppStorage("rightTab") private var tab = Tab.route

    enum Tab: String { case route, schedule }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Section", selection: $tab) {
                            Text("Route").tag(Tab.route)
                            Text(ws.scheduledCount > 0 ? "Schedule · \(ws.scheduledCount)" : "Schedule").tag(Tab.schedule)
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                        Text(tab == .schedule ? "What LALA does on its own"
                             : hasRoute ? "\(ws.intent.side == .long ? "Long" : "Short") \(IntentParser.pretty(ws.intent.asset))" : "Nothing yet")
                            .font(.system(size: 19, weight: .semibold))
                    }
                    Spacer()
                    if tab == .route, hasRoute {
                        Text("\(ws.blocks.count) steps")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } } label: {
                        Image(systemName: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    }
                    .buttonStyle(.borderless)
                    .help(expanded ? "Show chat and route side by side" : "Expand the route to the whole window")
                    .accessibilityLabel(expanded ? "Route in half the window" : "Route in the whole window")
                }
                .padding(.horizontal, 20).padding(.vertical, 16)

                Divider()

                if tab == .schedule {
                    ScheduleView()
                } else if !hasRoute {
                    RouteEmptyState()
                } else if expanded && geometry.size.width >= 900 {
                    HStack(spacing: 0) {
                        RouteCanvas(blocks: ws.blocks, selectedBlockID: $selectedBlockID, horizontal: true)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        Divider()
                        ScrollView { PlanCard(selectedBlockID: $selectedBlockID).padding(18) }
                            .frame(width: 370)
                    }
                } else {
                    VStack(spacing: 0) {
                        RouteCanvas(blocks: ws.blocks, selectedBlockID: $selectedBlockID, horizontal: false)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        Divider()
                        ScrollView { PlanCard(selectedBlockID: $selectedBlockID).padding(16) }
                            .frame(height: min(300, geometry.size.height * 0.30))
                    }
                }
            }
            .background(.background)
            // A new regular purchase shows where it lives.
            .onChange(of: ws.schedules.count) { old, new in if new > old { tab = .schedule } }
        }
    }

    /// The default intent is a placeholder, not the user's plan: until they describe a trade, no route is drawn.
    private var hasRoute: Bool { ws.intent != TradeIntent() || ws.managesPosition }
}

/// Before any plan: what the route will show, and the open positions instead of a made-up one.
struct RouteEmptyState: View {
    @Environment(Workspace.self) private var ws

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Describe a trade in the chat — its steps will show up here")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Where the money comes from, the bridge, the position, stop and take-profit, rule checks. Every step shows live numbers; change them in plain words.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if !ws.positions.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Open positions").font(.caption).foregroundStyle(.secondary)
                        ForEach(ws.positions, id: \.coin) { p in
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(p.size > 0 ? "Long" : "Short") \(IntentParser.pretty(p.coin))").font(.system(size: 14, weight: .semibold))
                                    Text(ws.positionSummary(p)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(Fmt.usd(p.unrealizedPnl))
                                    .font(.system(size: 14, weight: .semibold)).monospacedDigit()
                                    .foregroundStyle(p.unrealizedPnl < 0 ? .red : .green)
                            }
                            .padding(14)
                            .background(RoundedRectangle(cornerRadius: 14).fill(.fill.quaternary))
                        }
                        Text("Manage it in words: “stop to breakeven”, “close half”, “close”.")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(maxWidth: 460, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity)
        }
    }
}

/// Everything LALA runs by itself over time: regular purchases, the position guardian, limits waiting on the book.
/// It all works while LALA is open or sits in the menu bar.
struct ScheduleView: View {
    @Environment(Workspace.self) private var ws
    private static let en = Locale(identifier: "en_US")

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                purchases
                if !upcoming.isEmpty { timeline }
                guardian
                Text("All of this runs while LALA is open or in the menu bar. ⌘Q stops both the purchases and the guardian; stops and take-profits on the exchange stay.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: 520, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Regular purchases

    private var purchases: some View {
        section("Recurring purchases", icon: "arrow.triangle.2.circlepath",
                trailing: ws.schedules.isEmpty ? nil : "≈ \(Fmt.usd(ws.schedules.reduce(0) { $0 + $1.usdc * 30 / Decimal($1.days) })) a month") {
            if ws.schedules.isEmpty {
                hint("None yet. Type “DCA 5 USDC into SOL weekly” in the chat — the first buy happens right away, then on schedule. Each one goes through the same checks and signing.")
            }
            ForEach(ws.schedules, id: \.symbol) { s in
                card {
                    HStack(spacing: 14) {
                        badge(s.symbol)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(s.symbol) for \(Fmt.usd(s.usdc))").font(.system(size: 14, weight: .semibold))
                            Text("\(Self.every(s.days)) · ≈ \(Fmt.usd(s.usdc * 30 / Decimal(s.days))) a month")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(Self.when(s.next)).font(.system(size: 13, weight: .medium)).monospacedDigit()
                            Text(Fmt.date(s.next))
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Button { ws.schedules.removeAll { $0.symbol == s.symbol } } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.hoverIcon).foregroundStyle(.tertiary)
                            .help("Stop buying \(s.symbol)")
                            .accessibilityLabel("Stop buying \(s.symbol)")
                    }
                }
            }
        }
    }

    /// The next purchases of every schedule, in date order.
    private var upcoming: [(date: Date, symbol: String, usdc: Decimal)] {
        var out: [(date: Date, symbol: String, usdc: Decimal)] = []
        for s in ws.schedules {
            for k in 0..<4 { out.append((s.next.addingTimeInterval(Double(s.days * k) * 86_400), s.symbol, s.usdc)) }
        }
        return Array(out.sorted { $0.date < $1.date }.prefix(6))
    }

    private var timeline: some View {
        section("Upcoming", icon: "calendar", trailing: nil) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(upcoming.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(spacing: 0) {
                            Circle().fill(index == 0 ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary)).frame(width: 8, height: 8).padding(.top, 5)
                            if index < upcoming.count - 1 { Rectangle().fill(.separator).frame(width: 1).frame(maxHeight: .infinity) }
                        }
                        .frame(width: 8)
                        Text(item.date.formatted(Date.FormatStyle(locale: Self.en).weekday(.abbreviated).day().month(.abbreviated).hour().minute()))
                            .font(.callout).monospacedDigit().foregroundStyle(index == 0 ? .primary : .secondary)
                            .frame(width: 150, alignment: .leading)
                        Text("\(item.symbol) for \(Fmt.usd(item.usdc))").font(.callout)
                        Spacer()
                    }
                    .frame(minHeight: 30, alignment: .top)
                }
            }
        }
    }

    // MARK: Guardian

    private var guardian: some View {
        section("Position guardian", icon: "shield.lefthalf.filled", trailing: nil) {
            if ws.positions.isEmpty && ws.pendingEntry == nil {
                hint("No open positions. “Scale out” and “trailing 2%” in a plan give the guardian work: breakeven after the first half, a stop that follows the best price.")
            }
            if let o = ws.pendingEntry {
                card {
                    row(icon: "hourglass", title: "Limit waiting: \(o.side == "B" ? "long" : "short") \(IntentParser.pretty(o.coin))",
                        detail: "\(o.size.map { Fmt.num($0, maxFraction: 6) } ?? "") at \(o.limitPx.map(Fmt.price) ?? "?"); stop and take-profit turn on after entry.")
                }
            }
            ForEach(ws.positions, id: \.coin) { p in
                card {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("\(p.size > 0 ? "Long" : "Short") \(IntentParser.pretty(p.coin))").font(.system(size: 14, weight: .semibold))
                            Spacer()
                            Text(Fmt.usd(p.unrealizedPnl)).font(.system(size: 14, weight: .semibold)).monospacedDigit()
                                .foregroundStyle(p.unrealizedPnl < 0 ? .red : .green)
                        }
                        Text(ws.positionSummary(p)).font(.caption).foregroundStyle(.secondary)
                        ForEach(Self.duties(ws.exitRules[p.coin]), id: \.self) { line in
                            Label(line, systemImage: "checkmark.circle").font(.caption)
                        }
                    }
                }
            }
        }
    }

    /// What the guardian still does for a position, in plain words.
    static func duties(_ r: ExitRules?) -> [String] {
        guard let r else { return ["Stop and take-profit sit on the exchange; LALA doesn't move anything."] }
        var out: [String] = []
        if r.partialOrderPending { out.append("After entry, places half at 1R.") }
        if r.breakevenAfterPartial {
            out.append(r.movedToBreakeven ? "Stop is already at breakeven (\(Fmt.price(r.entry)))." : "After the first half, moves the stop to breakeven (\(Fmt.price(r.entry))).")
        }
        if let t = r.trailingPct { out.append("Trailing \(Fmt.pct(t)): the stop follows the best price, now \(Fmt.price(r.peak)).") }
        return out.isEmpty ? ["Stop and take-profit sit on the exchange; LALA doesn't move anything."] : out
    }

    // MARK: Pieces

    static func every(_ days: Int) -> String { days == 1 ? "daily" : days == 7 ? "weekly" : "every \(days) days" }

    static func when(_ date: Date) -> String {
        date <= Date() ? "now" : date.formatted(Date.RelativeFormatStyle(presentation: .named, locale: en))
    }

    private func section<Content: View>(_ title: String, icon: String, trailing: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: icon).font(.system(size: 13, weight: .semibold))
                Spacer()
                if let trailing { Text(trailing).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
            }
            content()
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(.fill.quaternary))
    }

    private func row(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
    }

    private func badge(_ symbol: String) -> some View {
        Text(String(symbol.prefix(3)))
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .frame(width: 38, height: 38)
            .background(Circle().fill(.fill.tertiary))
    }
}

/// Renders every step supplied by the planner. It has no display cap; the canvas pans and zooms for long routes.
struct RouteCanvas: View {
    let blocks: [Block]
    @Binding var selectedBlockID: String?
    let horizontal: Bool

    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    /// The route's own size, to fit it into the canvas at 100%.
    @State private var routeSize: CGSize = .zero
    @GestureState private var drag: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        GeometryReader { geometry in
            // 100% means «the whole route is visible»; the zoom bar keeps its own strip at the bottom.
            let fit = routeSize.width > 0
                ? min(1, (geometry.size.width - 48) / routeSize.width, (geometry.size.height - 104) / routeSize.height) : 1
            ZStack {
                Canvas { context, size in
                    let dot = Color.primary.opacity(0.09)
                    for x in stride(from: CGFloat(16), through: size.width, by: 26) {
                        for y in stride(from: CGFloat(16), through: size.height, by: 26) {
                            context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 2, height: 2)), with: .color(dot))
                        }
                    }
                }
                .accessibilityHidden(true)

                route
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { routeSize = $0 }
                    .scaleEffect(fit * zoom * pinch)
                    .offset(x: pan.width + drag.width, y: pan.height + drag.height)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.bottom, 56)
            }
            // Scaling does not shrink the layout: without a fixed frame a long route pushes the zoom bar off the canvas.
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .simultaneousGesture(panGesture)
            .simultaneousGesture(magnifyGesture)
            .clipped()
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 8) {
                    Button { changeZoom(by: -0.15) } label: { Image(systemName: "minus.magnifyingglass") }
                        .help("Zoom out")
                    Text("\(Int(zoom * 100))%")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .frame(width: 42)
                    Button { changeZoom(by: 0.15) } label: { Image(systemName: "plus.magnifyingglass") }
                        .help("Zoom in")
                    Divider().frame(height: 16)
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { zoom = 1; pan = .zero }
                    } label: { Image(systemName: "scope") }
                    .help("Recenter the route")
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
                .padding(16)
            }
            .help("Drag to pan; pinch or +/− to zoom; click a step to see its data.")
            .accessibilityLabel("Route canvas with \(blocks.count) steps")
        }
    }

    @ViewBuilder private var route: some View {
        if horizontal {
            HStack(spacing: 9) {
                ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                    routeNode(block, index: index)
                    if index < blocks.count - 1 { connector(horizontal: true) }
                }
            }
        } else {
            VStack(spacing: 8) {
                ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                    routeNode(block, index: index)
                    if index < blocks.count - 1 { connector(horizontal: false) }
                }
            }
        }
    }

    private func routeNode(_ block: Block, index: Int) -> some View {
        Button { selectedBlockID = block.id } label: {
            Group {
                if horizontal {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            Text(String(format: "%02d / STEP", index + 1))
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Circle().fill(color(for: block.status)).frame(width: 8, height: 8)
                        }
                        Text(block.title)
                            .font(.system(size: 16, weight: .semibold))
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(block.label)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2)
                        HStack {
                            Text(statusText(for: block.status))
                                .font(.caption2).foregroundStyle(color(for: block.status))
                            Spacer()
                            Image(systemName: "arrow.up.right").foregroundStyle(.secondary)
                        }
                    }
                    .padding(16)
                    .frame(width: 210, height: 132)
                } else {
                    HStack(spacing: 12) {
                        Text(String(format: "%02d", index + 1))
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(block.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                            Text("\(block.label) · \(statusText(for: block.status))")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Circle().fill(color(for: block.status)).frame(width: 8, height: 8)
                    }
                    .padding(.horizontal, 14)
                    .frame(width: 300, height: 78)
                }
            }
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(block.id == (selectedBlockID ?? blocks.first?.id) ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.separator), lineWidth: 1.5)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Step \(index + 1): \(block.label). \(block.title). \(statusText(for: block.status))")
        .accessibilityHint("Opens the step's data and checks")
    }

    private func connector(horizontal: Bool) -> some View {
        Image(systemName: horizontal ? "arrow.right" : "arrow.down")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.tertiary)
            .frame(width: horizontal ? 25 : 20, height: horizontal ? 20 : 14)
            .accessibilityHidden(true)
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 5)
            .updating($drag) { value, state, _ in state = value.translation }
            .onEnded { value in
                pan.width += value.translation.width
                pan.height += value.translation.height
            }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .updating($pinch) { value, state, _ in state = value.magnification }
            .onEnded { value in zoom = min(1.8, max(0.5, zoom * value.magnification)) }
    }

    private func changeZoom(by amount: CGFloat) {
        withAnimation(.easeOut(duration: 0.15)) { zoom = min(1.8, max(0.5, zoom + amount)) }
    }

    private func color(for status: Block.Status) -> Color {
        switch status {
        case .ready: .green
        case .warning: .yellow
        case .needsInput: .orange
        case .blocked: .red
        case .noData, .info: .secondary
        }
    }

    private func statusText(for status: Block.Status) -> String {
        switch status {
        case .ready: "Ready"
        case .warning: "Warning"
        case .needsInput: "Needs input"
        case .blocked: "Stopped"
        case .noData: "No data"
        case .info: "Not needed"
        }
    }
}
