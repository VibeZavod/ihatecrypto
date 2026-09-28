import AVFoundation
import Observation
import Speech

/// Speaking instead of typing: the words land in the chat's field as they are recognized, and the person sends them
/// (nothing is ever sent by voice alone). Recognition stays on this Mac when the language's on-device model is there.
@Observable
final class VoiceInput {
    enum State: Equatable { case idle, listening, failed(String) }

    private(set) var state = State.idle
    /// What's been heard so far.
    private(set) var transcript = ""
    /// The last few loudness readings, 0…1, for the wave in the field.
    private(set) var levels: [Double] = Array(repeating: 0, count: 28)
    /// Whether this take is recognized on the Mac (otherwise Apple's servers hear it).
    private(set) var onDevice = true
    private(set) var startedAt = Date.now

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    var listening: Bool { state == .listening }

    func start(russian: Bool) async {
        guard state != .listening else { return }
        transcript = ""
        levels = Array(repeating: 0, count: levels.count)
        guard await Self.allowed() else {
            state = .failed("Allow the microphone and speech recognition for ihatecrypto in System Settings › Privacy & Security.")
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: russian ? "ru-RU" : "en-US")), recognizer.isAvailable else {
            state = .failed("Speech recognition isn't available right now.")
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        onDevice = recognizer.supportsOnDeviceRecognition
        request.requiresOnDeviceRecognition = onDevice
        request.addsPunctuation = true

        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0), block: Self.tap(request) { [weak self] level in
            Task { @MainActor in self?.push(level) }
        })
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            state = .failed("The microphone didn't start: \(error.localizedDescription)")
            return
        }
        self.request = request
        task = recognizer.recognitionTask(with: request, resultHandler: Self.results { [weak self] text, final, error in
            Task { @MainActor in self?.heard(text, final: final, error: error) }
        })
        startedAt = .now
        state = .listening
    }

    /// Stops listening and keeps what was heard; the last words come a moment after the audio ends.
    func finish() async {
        guard state == .listening else { return }
        request?.endAudio()
        stopEngine()
        for _ in 0..<30 where task != nil { try? await Task.sleep(for: .milliseconds(50)) }
        task?.cancel()
        task = nil
        state = .idle
    }

    /// Stops listening and drops what was heard.
    func cancel() {
        task?.cancel()
        stopEngine()
        transcript = ""
        state = .idle
    }

    private func stopEngine() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request = nil
    }

    private func heard(_ text: String?, final: Bool, error: String?) {
        if let text { transcript = text }
        guard final else { return }
        task = nil
        // The recognizer stopped by itself (a minute's limit, silence, an error) while still listening.
        guard state == .listening, request != nil else { return }
        stopEngine()
        state = transcript.isEmpty ? error.map { .failed("Didn't catch that: \($0)") } ?? .idle : .idle
    }

    private func push(_ level: Double) {
        levels.removeFirst()
        levels.append(level)
    }

    private static func allowed() async -> Bool {
        let speech = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        return speech ? await AVCaptureDevice.requestAccess(for: .audio) : false
    }

    /// The request and the time of the last level reading, touched only from the audio thread.
    nonisolated private final class Tap: @unchecked Sendable {
        let request: SFSpeechAudioBufferRecognitionRequest
        var last = Date.distantPast
        init(_ request: SFSpeechAudioBufferRecognitionRequest) { self.request = request }
    }

    // The audio tap and the recognizer call back on their own threads: these closures must not be MainActor's.
    nonisolated private static func tap(_ request: SFSpeechAudioBufferRecognitionRequest,
                                        level: @escaping @Sendable (Double) -> Void) -> AVAudioNodeTapBlock {
        let state = Tap(request)
        return { buffer, _ in
            state.request.append(buffer)
            guard Date.now.timeIntervalSince(state.last) > 0.06, let samples = buffer.floatChannelData?[0] else { return }
            state.last = .now
            let n = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<n { sum += samples[i] * samples[i] }
            let rms = n > 0 ? sqrt(sum / Float(n)) : 0
            // Speech sits around −40…−10 dB; map that to 0…1.
            level(min(1, max(0, (20 * log10(Double(max(rms, 1e-6))) + 50) / 40)))
        }
    }

    nonisolated private static func results(_ deliver: @escaping @Sendable (String?, Bool, String?) -> Void)
        -> @Sendable (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            deliver(result?.bestTranscription.formattedString, (result?.isFinal ?? false) || error != nil, error?.localizedDescription)
        }
    }
}
