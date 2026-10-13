import Foundation
import GuardJev
import IhatecryptoCore
import TxGuard
import WalletCore

/// One labelled case of Tools/jevcheck: the fields of the review its `kind` names.
struct JevCase: Decodable, Sendable {
    var id: Int
    var kind: String?
    /// A screen case: the user's own chat message (true) or what a lookup brought back.
    var own: Bool?
    var message, command, host, title, text, source: String?
    var recent, canvas, requests, plan, signatures, changes, programs: [String]?
}

private struct Replay: TextClassifier {
    let name = "The second check"
    let answer: (String, Double)
    func classify(_ text: String, source: String) async throws -> (label: String, confidence: Double) { answer }
}

/// `jev-eval <cases.jsonl>`: every case through the second check exactly as the app asks it, one JSON line per case
/// (id, label, confidence, concern, text), for Tools/jevcheck/score.py to count false alarms and misses.
func jevEval(_ path: String) async throws {
    guard let key = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"], !key.isEmpty else { throw WalletError("Set OPENROUTER_API_KEY.") }
    let cases = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").map { try JSONDecoder().decode(JevCase.self, from: Data($0.utf8)) }
    @Sendable func line(_ c: JevCase) async -> String {
        var out: [String: Any] = ["id": c.id]
        do {
            if c.kind == "screen" {
                let text = c.text ?? "", own = c.own ?? false
                let (label, confidence) = try await JevClassifier(apiKey: key, own: own).classify(text, source: c.source ?? "lookup")
                out["label"] = label; out["confidence"] = confidence; out["concern"] = label != "data"
                // What the guard decides, its local rules for commands included (asked once: the answer is replayed).
                let why = own
                    ? (InjectionHeuristics.findings(text).commands.first.map { "local rules: \($0)" } ?? (label != "data" && confidence >= InjectionGuard.threshold ? label : nil))
                    : await InjectionGuard.lookupProblem(text, source: c.source ?? "lookup", classifier: Replay(answer: (label, confidence)))
                out["stopped"] = why != nil; out["text"] = why ?? ""
            } else {
                let r = switch c.kind {
                case "plan": try await JevReviewer.plan(requests: c.requests ?? [], plan: c.plan ?? [], apiKey: key)
                case "tx": try await JevReviewer.transactions(plan: c.plan ?? [], signatures: c.signatures ?? [], changes: c.changes ?? [], apiKey: key)
                case "site": try await JevReviewer.site(host: c.host ?? "", title: c.title ?? "", programs: c.programs ?? [], changes: c.changes ?? [], apiKey: key)
                default: try await JevReviewer.reading(message: c.message ?? "", recent: c.recent ?? [], canvas: c.canvas ?? [], command: c.command ?? "",
                                                       forms: ChatRouter.forms(for: c.command ?? ""), apiKey: key)
                }
                out["label"] = r.label; out["confidence"] = r.confidence; out["concern"] = r.concern; out["text"] = r.text
            }
        } catch { out["error"] = error.localizedDescription }
        return String(decoding: (try? JSONSerialization.data(withJSONObject: out, options: .sortedKeys)) ?? Data(), as: UTF8.self)
    }
    // The API takes 80 requests a second; 24 at once is far under it.
    for start in stride(from: 0, to: cases.count, by: 24) {
        await withTaskGroup(of: String.self) { group in
            for c in cases[start..<min(start + 24, cases.count)] { group.addTask { await line(c) } }
            for await l in group { print(l) }
        }
    }
}
