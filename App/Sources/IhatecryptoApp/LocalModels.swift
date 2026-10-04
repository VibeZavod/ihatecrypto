import AppKit
import Foundation
import LLMCatalog
import LLMCore

/// Models that run on this Mac through Ollama: whether Ollama is there, how big a model is (its registry manifest),
/// whether it fits this Mac's memory, and downloading one with Ollama's own /api/pull, with its progress.
enum OllamaModels {
    static let base = "http://localhost:11434"

    /// Ollama's app, or its command-line server (Homebrew).
    static var installed: Bool {
        ["/Applications/Ollama.app", "/opt/homebrew/bin/ollama", "/usr/local/bin/ollama"].contains { FileManager.default.fileExists(atPath: $0) }
    }

    static var memoryGB: Double { Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824 }

    /// A model fits when it and its working memory take at most ~70% of the Mac's: the rest is macOS and the app.
    static func fits(sizeGB: Double) -> Bool { sizeGB * 1.2 <= memoryGB * 0.7 }

    /// The download size, GB, from the registry's manifest («gemma4:12b» → 8.0); nil when the registry doesn't know it.
    static func sizeGB(_ model: String) async -> Double? {
        let parts = model.split(separator: ":", maxSplits: 1).map(String.init)
        let name = parts[0].contains("/") ? parts[0] : "library/\(parts[0])"
        guard let url = URL(string: "https://registry.ollama.ai/v2/\(name)/manifests/\(parts.count > 1 ? parts[1] : "latest")") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/vnd.docker.distribution.manifest.v2+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
              let layers = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["layers"] as? [[String: Any]] else { return nil }
        return layers.reduce(0) { $0 + ((($1["size"] as? NSNumber)?.doubleValue) ?? 0) } / 1_000_000_000
    }

    /// Pulls `model`, reporting 0…1 over all its layers as Ollama streams them; throws Ollama's own error.
    static func pull(_ model: String, progress: @escaping @MainActor (Double) -> Void) async throws {
        var request = URLRequest(url: URL(string: "\(base)/api/pull")!, timeoutInterval: 3600)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "stream": true])
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw LLMError("Ollama didn't start the download (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).") }
        var layers: [String: (done: Double, total: Double)] = [:]
        for try await line in bytes.lines {
            guard let j = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if let error = j["error"] as? String { throw LLMError(error) }
            if let digest = j["digest"] as? String, let total = (j["total"] as? NSNumber)?.doubleValue, total > 0 {
                layers[digest] = ((j["completed"] as? NSNumber)?.doubleValue ?? 0, total)
                let all = layers.values.reduce((0.0, 0.0)) { ($0.0 + $1.done, $0.1 + $1.total) }
                await progress(min(all.0 / all.1, 1))
            }
            if j["status"] as? String == "success" { return }
        }
        throw LLMError("Ollama stopped before the download finished.")
    }
}

extension Workspace {
    /// Downloads a model into Ollama from the model menu; the chat says when it's ready, or why not.
    func downloadModel(_ model: String) async {
        guard modelDownloads[model] == nil else { return }
        modelDownloads[model] = 0
        defer { modelDownloads[model] = nil }
        do {
            try await OllamaModels.pull(model) { [weak self] p in self?.modelDownloads[model] = p }
            await refreshLocalModels()
            reply(say("\(LLMCatalog.displayName(model: model)) is downloaded to this Mac — pick it in the model menu.",
                      "\(LLMCatalog.displayName(model: model)) скачана на этот Mac — выбери её в меню моделей."))
        } catch {
            reply(say("Couldn't download \(model): ", "Не удалось скачать \(model): ") + error.localizedDescription)
        }
    }
}
