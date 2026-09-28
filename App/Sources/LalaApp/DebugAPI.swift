import AppKit
import Network
import SignerAPI
import SwiftUI

/// Shown next to the zoom while the local debug API is on, so it is never left on unnoticed.
struct DebugBadge: View {
    @AppStorage("debugAPI") private var on = false

    var body: some View {
        if on {
            Label("Debug API", systemImage: "ladybug.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(.orange)
                .help("The local debug API is on: Settings → Debugging")
        }
    }
}

/// A local door for driving LALA from a terminal, e.g. Claude Code with curl:
///
///     T=$(cat ~/Library/Application\ Support/LALA/debug-token)
///     curl -s -H "Authorization: Bearer $T" 127.0.0.1:51789/state
///     curl -s -H "Authorization: Bearer $T" -d '{"text":"выведи всё из Aave"}' 127.0.0.1:51789/send
///     curl -s -H "Authorization: Bearer $T" 127.0.0.1:51789/screenshot -o lala.png
///
/// Off unless Settings turns it on; 127.0.0.1 only; a token that changes every time it starts, in an owner-only
/// file; anything a browser sends (an Origin header, another Host) is refused. It reads the state, types into the
/// chat and takes a picture of the window. It never signs: while its message is handled only status requests reach
/// the signer (SignerClient.untrusted), so money moves still wait for Confirm and Touch ID in the window.
@MainActor
final class DebugAPI {
    static let shared = DebugAPI()
    static let port: UInt16 = 51789
    private var listener: NWListener?
    private var token = ""
    private weak var ws: Workspace?

    func start(_ ws: Workspace) {
        guard listener == nil, let port = NWEndpoint.Port(rawValue: Self.port) else { return }
        self.ws = ws
        token = (0..<24).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        let file = LocalStore.url("debug-token")
        try? FileManager.default.removeItem(at: file)
        FileManager.default.createFile(atPath: file.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600])
        // The loopback interface only: nothing from the network can reach it.
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters, on: port) else { return }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state { FileHandle.standardError.write(Data("LALA debug API: \(error)\n".utf8)) }
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: .main)
            Self.read(connection, Data())
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        try? FileManager.default.removeItem(at: LocalStore.url("debug-token"))
    }

    private nonisolated static func read(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, done, error in
            let all = buffer + (data ?? Data())
            if let request = Request(all) {
                Task { @MainActor in
                    let (status, type, body) = await DebugAPI.shared.handle(request)
                    let head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
                }
            } else if done || error != nil || all.count > 1 << 20 {
                connection.cancel()
            } else {
                read(connection, all)
            }
        }
    }

    private func handle(_ r: Request) async -> (Int, String, Data) {
        // A page in a browser always sends Origin, and a name pointed at 127.0.0.1 shows in Host: neither gets in.
        let hosts = ["127.0.0.1:\(Self.port)", "localhost:\(Self.port)"]
        guard r.headers["origin"] == nil, hosts.contains(r.headers["host"] ?? ""), r.headers["authorization"] == "Bearer \(token)" else {
            return (403, "text/plain", Data("forbidden\n".utf8))
        }
        guard let ws else { return (503, "text/plain", Data("no workspace\n".utf8)) }
        switch (r.method, r.path) {
        case ("GET", "/state"):
            return (200, "application/json", json(state(ws, since: max(0, ws.messages.count - 12))))
        case ("POST", "/send"):
            let text = ((try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any])?["text"] as? String
                ?? String(decoding: r.body, as: UTF8.self)
            guard !text.isEmpty else { return (400, "text/plain", Data("no text\n".utf8)) }
            guard !ws.busy else { return (409, "text/plain", Data("busy\n".utf8)) }
            let before = ws.messages.count
            await SignerClient.$untrusted.withValue(true) { await ws.send(text) }
            return (200, "application/json", json(state(ws, since: before)))
        case ("GET", "/screenshot"):
            guard let png = screenshot() else { return (500, "text/plain", Data("no window\n".utf8)) }
            return (200, "image/png", png)
        default:
            return (404, "text/plain", Data("GET /state · POST /send {\"text\":…} · GET /screenshot\n".utf8))
        }
    }

    private func state(_ ws: Workspace, since: Int) -> [String: Any] {
        let canvas = ws.canvases.first { $0.id == ws.canvasID }
        func num(_ d: Decimal?) -> Any { d.map { NSDecimalNumber(decimal: $0).stringValue } ?? NSNull() }
        return [
            "canvas": canvas?.displayTitle ?? "",
            "outcome": canvas?.outcome.map { $0.ok ? "executed" : "failed" } ?? NSNull(),
            "pending": ws.pendingText ?? NSNull(),
            "busy": ws.busy,
            "messages": ws.messages.dropFirst(since).map { ["user": $0.fromUser, "text": $0.text, "note": $0.note ?? NSNull()] as [String: Any] },
            "balances": [
                "total": num(ws.equity), "solanaUSDC": num(ws.solana?.usdc), "sol": num(ws.solana?.sol),
                "hyperliquid": num(ws.hlTotal), "near": num(ws.near), "kamino": num(ws.kamino), "jupiterLend": num(ws.lendTotal),
                "baseAave": num(ws.base?.aave), "baseMorpho": num(ws.base?.morpho), "baseUSDC": num(ws.base?.usdc),
                "robinhoodUSDG": num(ws.robinhood?.usdg),
            ] as [String: Any],
            "positions": ws.positions.map { "\($0.size > 0 ? "long" : "short") \($0.coin) pnl \($0.unrealizedPnl)" },
            "wallet": ["solana": ws.solanaAddress, "evm": ws.hlAddress],
        ]
    }

    private func json(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
    }

    /// The main window as it is drawn, without the rest of the screen.
    private func screenshot() -> Data? {
        guard let view = NSApp.windows.first(where: { $0.isVisible && $0.title == "LALA" })?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    /// One HTTP/1.1 request, once its headers and body have all arrived; nil while they haven't.
    struct Request: Sendable {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data

        init?(_ data: Data) {
            guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
            let lines = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            let first = lines.first?.split(separator: " ") ?? []
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let length = Int(headers["content-length"] ?? "0") ?? 0
            let rest = data[end.upperBound...]
            guard rest.count >= length else { return nil }
            method = first.first.map(String.init) ?? ""
            path = first.dropFirst().first.map(String.init) ?? ""
            self.headers = headers
            body = Data(rest.prefix(length))
        }
    }
}
