import Foundation
import LLMCore

/// Claude Pro/Max through the Claude Code the user already installed and signed in to, the way OpenClaw does it.
/// Anthropic's published terms do not allow third-party Claude.ai login, so this stays an opt-in gray-zone option.
public struct ClaudeCodeSubscription: LLMProvider {
    static let candidates = ["~/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "~/.claude/local/claude"]

    public init() {}

    public var info: ProviderInfo {
        ProviderInfo(
            id: "claude-code", name: "Claude (subscription via Claude Code)", kind: .subscription, defaultModel: "claude-haiku-4-5",
            note: "Runs the installed Claude Code with no tools. Anthropic doesn't officially allow third-party sign-in — a gray area.",
            existingLoginLabel: "Use the installed Claude Code"
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

    // ponytail: no timeout; `-p` exits on its own, add one if a hung login prompt ever shows up.
    static func run(_ path: String, _ arguments: [String], input: String) async throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        var env = ProcessInfo.processInfo.environment
        env["CLAUDECODE"] = nil
        env["CLAUDE_CODE_ENTRYPOINT"] = nil
        process.environment = env
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        let data = try await Task.detached { try stdout.fileHandleForReading.readToEnd() ?? Data() }.value
        process.waitUntilExit()
        return data
    }
}
