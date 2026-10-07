import AppKit
import IhatecryptoCore
import SwiftUI

// The canvas in its own NSHostingView (switch `canvasHost`, on by default), and a pan slides its layers. Through
// `.offset` (CanvasViewport) every step of a pan placed each view on the canvas again — ≈ 19 ms a step, 50 frames a
// second at best (measured 2026-10-06), whatever was on it. Zoom stays SwiftUI's scaleEffect inside: zooming is rare
// and redraws anyway. Nothing on the canvas is dragged, so any drag over it pans.

/// Where the canvas is looked at: the window's fit times the user's zoom; read by the zoom bar and the hosted canvas.
@MainActor @Observable
final class CanvasPlace {
    /// The user's zoom on top of the window's fit.
    var zoom: CGFloat = 1
    /// What fits left of the chat at 100 %, from the window's width.
    var fit: CGFloat = 1
    var scale: CGFloat { fit * zoom }
    /// The size the canvas content is laid out in (as the window's overlay once proposed it).
    var viewport: CGSize = .zero
    /// The content's own size, unscaled, as measured.
    @ObservationIgnored var content: CGSize = .zero
    /// The view the canvas hangs in, told when the content's size changes and asked for drags that start on it.
    @ObservationIgnored weak var scroller: CanvasPanView?
    static var zoomRange: ClosedRange<CGFloat> { 0.4...2.5 }
}

/// The canvas with its zoom bar and the window-moving strip at the top, as CanvasViewport had them.
struct CanvasScroller<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL
    @Environment(Workspace.self) private var ws
    let inset: CGFloat
    let leading: CGFloat
    let contentWidth: CGFloat
    @ViewBuilder let content: Content
    @State private var place = CanvasPlace()
    /// In full screen there's no window to move: the top strip pans like the rest.
    @State private var fullScreen = false

    var body: some View {
        GeometryReader { geo in
            let fit = min(1, max(0.55, (geo.size.width - inset - leading) / contentWidth))
            CanvasScrollHost(place: place, scale: place.scale, leading: leading, root: AnyView(CanvasRoot(place: place, content: content)
                .environment(ws).environment(\.openURL, openURL)))
                .onChange(of: fit, initial: true) { place.fit = fit }
                .onChange(of: geo.size, initial: true) { place.viewport = geo.size }
        }
        .overlay(alignment: .top) { if !fullScreen { WindowDragArea().frame(height: 2 * TrafficLights.center.y) } }
        .overlay(alignment: .bottomLeading) { zoomBar.padding(18).padding(.leading, leading) }
        .onChange(of: place.scale >= CanvasSharpness.from, initial: true) { _, on in CanvasSharpness.shared.track(on) }
        .onChange(of: place.scale) { CanvasSharpness.shared.hold() }
        .onAppear { fullScreen = NSApp.windows.contains { $0.styleMask.contains(.fullScreen) } }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { _ in fullScreen = true }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { _ in fullScreen = false }
        .onDisappear { CanvasSharpness.shared.track(false) }
    }

    private func zoomGlyph(_ name: String) -> some View {
        Image(systemName: name).frame(width: 26, height: 26).contentShape(Rectangle())
    }

    private var zoomBar: some View {
        HStack(spacing: 4) {
            // A step, not animated: an animated zoom re-renders the whole canvas on every frame.
            Button { place.zoom = CanvasPlace.zoomRange.clamped(place.zoom - 0.1) } label: { zoomGlyph("minus") }.help("Zoom out · or pinch")
            Text("\(Int((place.scale * 100).rounded()))%").font(.ui(12, .semibold)).monospacedDigit().frame(width: 44)
            Button { place.zoom = CanvasPlace.zoomRange.clamped(place.zoom + 0.1) } label: { zoomGlyph("plus") }.help("Zoom in · or pinch")
            Button("Fit") { place.scroller?.fit() }
            DebugBadge()
        }
        .buttonStyle(.borderless)
        .padding(.leading, 6).padding(.trailing, 12).padding(.vertical, 4)
        .environment(\.colorScheme, scheme)
        .glassEffect(.regular, in: Capsule())
    }
}

/// The hosted canvas: laid out in the window's size as before, measured, scaled, and dragged as a whole.
private struct CanvasRoot<Content: View>: View {
    let place: CanvasPlace
    let content: Content

    var body: some View {
        Color.clear
            .frame(width: place.viewport.width, height: place.viewport.height)
            .overlay(alignment: .topLeading) {
                content
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                        place.content = size
                        place.scroller?.contentChanged()
                    }
                    .scaleEffect(place.scale, anchor: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
            // A drag that starts on a board pans too, as it did; a click on a button stays the button's. The pointer is
            // followed on the screen, not in the canvas, which moves under it.
            .gesture(DragGesture(minimumDistance: 6)
                .onChanged { place.scroller?.drag(to: NSEvent.mouseLocation, after: $0.translation) }
                .onEnded { _ in place.scroller?.endDrag() })
    }
}

private struct CanvasScrollHost: NSViewRepresentable {
    let place: CanvasPlace
    /// Read here so a zoom step updates the view.
    let scale: CGFloat
    let leading: CGFloat
    let root: AnyView

    func makeNSView(context: Context) -> CanvasPanView { CanvasPanView(place: place, root: root, leading: leading) }

    func updateNSView(_ view: CanvasPanView, context: Context) {
        view.leading = leading
        view.scaleChanged(scale)
    }
}

/// The view the canvas hangs in. The hosted canvas sits at `origin` (the old `leading + pan`). A pan, while it lasts,
/// only slides the layers (`sublayerTransform`): AppKit and SwiftUI don't hear of it. Moving the real view on every step
/// made AppKit work out the window's drag regions, the cursor and the hover under the pointer again each time (three
/// quarters of a step, measured with a scroll view). The real place is set once, when the pan stops or a click comes.
final class CanvasPanView: NSView {
    let place: CanvasPlace
    private let hosting: NSHostingView<AnyView>
    var leading: CGFloat = 0
    /// Where the canvas's top left is, as AppKit knows it.
    private var origin = CGPoint.zero
    /// The slide shown by the layers and not given to AppKit yet.
    private var pending = CGSize.zero
    private var commitAt: DispatchWorkItem?
    private var shownScale: CGFloat = 0
    private var placed = false
    private var dragFrom: NSPoint?
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    nonisolated(unsafe) private var clickMonitor: Any?

    init(place: CanvasPlace, root: AnyView, leading: CGFloat) {
        self.place = place
        self.leading = leading
        hosting = NSHostingView(rootView: root)
        super.init(frame: .zero)
        wantsLayer = true
        // Its size is ours to set: it never asks the window's hosting view to lay out again.
        hosting.sizingOptions = []
        hosting.safeAreaRegions = []
        addSubview(hosting)
        place.scroller = self
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .canvasZoom, object: nil, queue: .main) { [weak self] note in
                let factor = note.userInfo?["factor"] as? CGFloat
                MainActor.assumeIsolated { if let self, let factor { self.zoom(by: factor, about: self.pointer()) } }
            },
            center.addObserver(forName: .canvasPan, object: nil, queue: .main) { [weak self] note in
                let dx = note.userInfo?["dx"] as? CGFloat ?? 0, dy = note.userInfo?["dy"] as? CGFloat ?? 0
                MainActor.assumeIsolated { self?.move(by: CGSize(width: dx, height: dy)) }
            },
            center.addObserver(forName: .canvasFit, object: nil, queue: .main) { [weak self] note in
                let what = note.object as? String
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // Another canvas: its start in view, the zoom left as the user set it.
                    if what == "home" { return self.home() }
                    // The Portfolio button with the portfolio already in place: nothing to move, the window's edge answers.
                    if what == "portfolio", self.place.zoom == 1, self.atHome {
                        NotificationCenter.default.post(name: .canvasEdgePulse, object: nil)
                    }
                    self.fit()
                }
            },
        ]
        // A click lands where the canvas is seen: a slide not given to AppKit yet goes first.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.commit() }
            return event
        }
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
    }

    override var isFlipped: Bool { true }

    // MARK: Place

    /// Where the canvas's top left is seen, the slide included.
    private var seen: CGPoint { CGPoint(x: origin.x + pending.width, y: origin.y + pending.height) }
    private var atHome: Bool { abs(seen.x - leading) < 0.5 && abs(seen.y) < 0.5 }

    /// Puts the canvas's top left at `p` for AppKit and SwiftUI as well (a click, a zoom, the end of a pan).
    private func setOrigin(_ p: CGPoint) {
        commitAt?.cancel()
        commitAt = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pending = .zero
        layer?.sublayerTransform = CATransform3DIdentity
        origin = p
        resizeHosting()
        CATransaction.commit()
        // What came into view gets sharpened once it's still (zoomed in).
        CanvasSharpness.shared.hold()
    }

    func commit() {
        guard pending != .zero else { return }
        setOrigin(seen)
    }

    func home() { setOrigin(CGPoint(x: leading, y: 0)) }

    func fit() {
        place.zoom = 1
        scaleChanged(place.scale)
        home()
    }

    /// The canvas moved by `d` (positive: the boards go right and down). Only the layers slide; AppKit is told once it stops.
    func move(by d: CGSize) {
        guard d != .zero else { return }
        pending.width += d.width
        pending.height += d.height
        // On whole pixels: a fractional slide under a zoom made the boards wobble against each other.
        let s = window?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.sublayerTransform = CATransform3DMakeTranslation((pending.width * s).rounded() / s, (pending.height * s).rounded() / s, 0)
        CATransaction.commit()
        commitAt?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.commit() } }
        commitAt = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    // MARK: Size

    override func layout() {
        super.layout()
        if !placed, bounds.width > 0 {
            placed = true
            origin = CGPoint(x: leading, y: 0)
        }
        resizeHosting()
    }

    func contentChanged() { resizeHosting() }

    /// The scale changed (a zoom step, the window's fit): the canvas grows or shrinks about its top left, as the zoom
    /// buttons always did.
    func scaleChanged(_ scale: CGFloat) {
        guard scale != shownScale else { return }
        shownScale = scale
        resizeHosting()
    }

    private func resizeHosting() {
        let s = place.scale
        let frame = NSRect(x: origin.x, y: origin.y,
                           width: max(place.viewport.width, place.content.width * s), height: max(place.viewport.height, place.content.height * s))
        if hosting.frame != frame { hosting.frame = frame }
    }

    // MARK: Zoom

    /// The pointer in this view, for a zoom about it; the middle when it's elsewhere.
    private func pointer() -> CGPoint {
        guard let window else { return CGPoint(x: bounds.midX, y: bounds.midY) }
        let p = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return bounds.contains(p) ? p : CGPoint(x: bounds.midX, y: bounds.midY)
    }

    /// Changes the zoom by `factor`, keeping `point` (in this view) where it is.
    func zoom(by factor: CGFloat, about point: CGPoint) {
        let next = CanvasPlace.zoomRange.clamped(place.zoom * factor)
        let k = next / place.zoom
        guard k != 1 else { return }
        let c = seen
        let moved = CanvasZoom.pan(keeping: (point.x, point.y), from: (c.x, c.y), by: k)
        place.zoom = next
        shownScale = place.scale
        setOrigin(CGPoint(x: moved.x, y: moved.y))
    }

    override func magnify(with event: NSEvent) {
        zoom(by: 1 + event.magnification, about: convert(event.locationInWindow, from: nil))
    }

    override func scrollWheel(with event: NSEvent) {
        let step: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        // ⌘ + scroll zooms (for a mouse wheel); two fingers pan, the system's momentum included.
        if event.modifierFlags.contains(.command) {
            zoom(by: 1 + event.scrollingDeltaY * step * 0.01, about: convert(event.locationInWindow, from: nil))
        } else {
            move(by: CGSize(width: event.scrollingDeltaX * step, height: event.scrollingDeltaY * step))
        }
    }

    // MARK: Drag

    override func mouseDown(with event: NSEvent) { dragFrom = NSEvent.mouseLocation }
    override func mouseDragged(with event: NSEvent) { drag(to: NSEvent.mouseLocation) }
    override func mouseUp(with event: NSEvent) { endDrag() }

    /// A drag over the canvas, followed on the screen (the canvas moves under the pointer). `after`: how far SwiftUI let
    /// it go before calling it a drag, so those first points move the canvas too.
    func drag(to screen: NSPoint, after start: CGSize = .zero) {
        defer { dragFrom = screen }
        let from = dragFrom ?? NSPoint(x: screen.x - start.width, y: screen.y + start.height)
        // Screen coordinates grow upwards; the canvas's go down.
        move(by: CGSize(width: screen.x - from.x, height: from.y - screen.y))
    }

    func endDrag() {
        dragFrom = nil
        commit()
    }
}
