import Foundation
import LLMCore

/// Claude Pro/Max through the Claude Code the user already installed and signed in to, the way OpenClaw does it.
/// Anthropic's published terms do not allow third-party Claude.ai login, so this stays an opt-in gray-zone option.
public struct ClaudeCodeSubscription: LLMProvider {
    static let candidates = ["~/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "~/.claude/local/claude"]

    public init() {}

    public var info: ProviderInfo {
        ProviderInfo(
            id: "claude-code", name: "Claude (subscription via Claude Code)", kind: .subscription, defaultModel: "claude-opus-5-5",
            note: "Runs the installed Claude Code with no tools. Anthropic doesn't officially allow third-party sign-in — a gray area.",
            existingLoginLabel: "Use the installed Claude Code",
            // All answer through `claude -p` (checked 2026-09-30).
            models: ["claude-opus-5-5", "claude-sonnet-5-5", "claude-fable-5-1", "claude-haiku-4-5"]
        )
    }

    public func existingLogin() -> Credential? {
        let fromPATH = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/claude" }
        let found = (Self.candidates.map { NSString(string: $0).expandingTildeInPath } + fromPATH)
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        return found.map { .external(path: $0) }
    }

    public func client(_ credential: Credential?, save: @escaping SaveCredential) throws -> any LLMClient {
        guard case .external(let path) = credential else { throw LLMError("Claude Code isn't connected.") }
        return ClaudeCodeClient(path: path)
    }
}

struct ClaudeCodeClient: LLMClient {
    let path: String

    /// Headless, no tools, no MCP, no user settings or hooks, nothing saved to session history.
    /// Our system prompt always replaces Claude Code's own, which would answer as a coding agent.
    /// The prompt goes through stdin so it is not visible in the process list.
    static func arguments(_ r: LLMRequest) -> [String] {
        ["-p", "--restricted", "--strict-mcp-config", "--tools", "", "--no-session-persistence",
         "--output-format", "json", "--model", r.model,
         "--system-prompt", r.system.isEmpty ? "You are an assistant. Answer briefly and to the point." : r.system]
    }

    func complete(_ r: LLMRequest) async throws -> String {
        let prompt = r.dialogue.map(\.text).joined(separator: "\n\n")
        let output = try await Self.run(path, Self.arguments(r), input: prompt)
        struct Result: Decodable { let is_error: Bool?; let result: String? }
        guard let result = try? JSONDecoder().decode(Result.self, from: output) else {
            throw LLMError("Claude Code replied unexpectedly: \(String(decoding: output.prefix(200), as: UTF8.self))")
        }
        if result.is_error == true { throw LLMError("Claude Code: \(result.result ?? "error")") }
        return result.result ?? ""
    }

    /// A `claude -p` that hangs (a login prompt, a stalled network) would keep the chat busy for good: it is stopped after
    /// two minutes, the ChatGPT client's limit, or as soon as the task waiting for it is cancelled.
    static func run(_ path: String, _ arguments: [String], input: String, timeout: Duration = .seconds(120)) async throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        var env = ProcessInfo.processInfo.environment
        env["CLAUDECODE"] = nil
        env["CLAUDE_CODE_ENTRYPOINT"] = nil
        process.environment = env
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let pid = process.processIdentifier
        let watchdog = Task { () -> Bool in
            do { try await Task.sleep(for: timeout) } catch { return false }
            kill(pid, SIGTERM)
            return true
        }
        defer { watchdog.cancel() }
        // The prompt and stderr on threads of their own, so a run that stops reading or fills stderr can't block the wait;
        // a stopped run gives the write EPIPE, not the app a SIGPIPE.
        let writer = stdin.fileHandleForWriting
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        Task.detached { try? writer.write(contentsOf: Data(input.utf8)); try? writer.close() }
        let errors = Task.detached { (try? stderr.fileHandleForReading.readToEnd()) ?? Data() }
        let data = try await withTaskCancellationHandler {
            try await Task.detached { try stdout.fileHandleForReading.readToEnd() ?? Data() }.value
        } onCancel: { kill(pid, SIGTERM) }
        process.waitUntilExit()
        watchdog.cancel()
        if await watchdog.value {
            throw LLMError("Claude Code didn't answer in \(timeout.components.seconds) s, so it was stopped. Send it again, or pick another model.")
        }
        try Task.checkCancellation()
        if data.isEmpty, process.terminationStatus != 0 {
            let said = String(decoding: (await errors.value).suffix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw LLMError("Claude Code stopped with code \(process.terminationStatus)" + (said.isEmpty ? "." : ": \(said)"))
        }
        return data
    }
}
