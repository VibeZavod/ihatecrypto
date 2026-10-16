import AppKit
import Darwin
import SwiftUI

/// The rendering before the metal branch, switched on for one /measure run ({"classic": true}): A and B in one build,
/// one after the other, on the same canvas and the same machine state.
@MainActor @Observable final class Render {
    static let shared = Render()
    static var classic = false
    /// Measuring only: the glass panels as plain fills, to see what Liquid Glass costs the GPU.
    var noGlass = false
}

extension View {
    /// `.glassEffect(glass, in: shape)`, or a plain fill while `Render.noGlass` measures what the glass costs.
    func measuredGlass(_ glass: Glass = .regular, in shape: some Shape) -> some View {
        modifier(MeasuredGlass(glass: glass, shape: shape))
    }
}

private struct MeasuredGlass<S: Shape>: ViewModifier {
    let glass: Glass
    let shape: S
    func body(content: Content) -> some View {
        if Render.shared.noGlass { content.background(shape.fill(Color(nsColor: .windowBackgroundColor))) }
        else { content.glassEffect(glass, in: shape) }
    }
}

/// Counts the window's frames while a debug-API scenario runs: a display link on the main run loop fires once a refresh
/// when the main thread is free, so a gap of two or more refreshes is a frame the app dropped (SwiftUI busy on main).
/// The render server's own misses aren't seen here: xctrace's Animation Hitches has those.
@MainActor
final class FrameMeter: NSObject {
    private var link: CADisplayLink?
    private var stamps: [CFTimeInterval] = []
    private var refresh: CFTimeInterval = 1.0 / 60
    private var cpuStart = 0.0
    private var wallStart = 0.0

    func start(in view: NSView) {
        stamps.removeAll(keepingCapacity: true)
        cpuStart = Self.mainThreadCPU()
        wallStart = CACurrentMediaTime()
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        stamps.append(link.timestamp)
        if link.duration > 0 { refresh = link.duration }
    }

    /// fps, dropped refreshes, the longest gap and how busy the main thread was.
    func stop() -> [String: Any] {
        link?.invalidate()
        link = nil
        let wall = CACurrentMediaTime() - wallStart
        let busy = (Self.mainThreadCPU() - cpuStart) / max(wall, 0.001)
        let gaps = zip(stamps.dropFirst(), stamps).map { $0 - $1 }.sorted()
        let dropped = gaps.reduce(0) { $0 + max(0, Int(($1 / refresh).rounded()) - 1) }
        let p = { (q: Double) in gaps.isEmpty ? 0 : gaps[min(gaps.count - 1, Int(Double(gaps.count) * q))] * 1000 }
        let span = (stamps.last ?? 0) - (stamps.first ?? 0)
        return ["hz": (1 / refresh).rounded(), "fps": span > 0 ? (Double(stamps.count - 1) / span * 10).rounded() / 10 : 0,
                "frames": stamps.count, "dropped": dropped, "p50ms": p(0.5), "p95ms": p(0.95), "p99ms": p(0.99),
                "maxms": (gaps.last ?? 0) * 1000, "mainBusy": (busy * 1000).rounded() / 10, "seconds": wall]
    }

    /// This thread's user + system time, in seconds (called on main).
    private static func mainThreadCPU() -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let thread = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, thread) }
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Double(info.user_time.seconds + info.system_time.seconds) + Double(info.user_time.microseconds + info.system_time.microseconds) / 1e6
    }
}
