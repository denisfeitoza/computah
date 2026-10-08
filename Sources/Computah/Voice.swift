import AVFoundation
import FluidAudio
import Foundation
import ComputahCore

/// Local speech input: microphone → 16 kHz mono → energy endpointing → Parakeet TDT v3 on the Neural Engine.
/// Emits the same turn events the coordinator already understands:
/// begin (speech starts), eager (short pause), resumed (speech after eager), final (long pause).
@MainActor final class Voice {
    var onText: ((String, Bool, String) -> Void)?
    var onEager: ((String, String) -> Void)?
    var onResumed: (() -> Void)?
    var onInputLost: (() -> Void)?
    var onTurnBegan: ((String) -> Void)?
    var onStatus: ((String) -> Void)?
    var onLevel: ((Double) -> Void)?
    var onProviderEvent: (([String: Any]) -> Void)?
    var onDiagnosticInputFinished: (() -> Void)?
    private(set) var isListening = false
    /// True while Computah itself is talking; the microphone must not turn that into a command.
    var isSuppressed: () -> Bool = { false }

    /// Language hint for Parakeet's script filter. `COMPUTAH_SPEECH_LANGUAGE` overrides it.
    var language: Language? = .portuguese

    private var engine: AVAudioEngine?
    private var routeObserver: NSObjectProtocol?
    private var consumer: Task<Void, Never>?
    private var diagnosticProducer: Task<Void, Never>?
    private var generation = UUID()
    private var endpoint = Endpointer()
    private static var asr: AsrManager?
    private static var loading: Task<AsrManager, Error>?

    nonisolated private static let sampleRate = 16_000.0
    nonisolated private static let preRoll = 4_800            // 300 ms kept before detected speech
    nonisolated private static let partialEvery = 9_600       // a partial transcript per 600 ms of new audio
    nonisolated private static let maxUtterance = 16_000 * 30 // force a final turn at 30 s

    func start(diagnosticPCM: Data? = nil) {
        guard !isListening else { return }
        generation = UUID()
        let id = generation
        endpoint = Endpointer()
        isListening = true
        onStatus?(diagnosticPCM == nil ? "Checking microphone…" : "Starting audio diagnostic…")
        Task {
            if diagnosticPCM == nil, !(await AVCaptureDevice.requestAccess(for: .audio)) {
                stop(message: "Enable microphone access for Computah.")
                return
            }
            do {
                _ = try await Self.recognizer { [weak self] message in
                    Task { @MainActor in if self?.generation == id { self?.onStatus?(message) } }
                }
            } catch {
                guard generation == id else { return }
                stop(message: "Speech model could not load: \(error.localizedDescription)")
                return
            }
            guard generation == id else { return }
            let pair = AsyncStream<[Float]>.makeStream(bufferingPolicy: .bufferingNewest(256))
            do {
                if let diagnosticPCM { produceDiagnostic(diagnosticPCM, id: id, sink: pair.continuation) }
                else { try startMicrophone(sink: pair.continuation, id: id) }
            } catch {
                stop(message: "Microphone could not start: \(error.localizedDescription)")
                return
            }
            onStatus?("Listening…")
            consumer = Task { [weak self] in
                for await chunk in pair.stream {
                    guard let self, generation == id else { return }
                    consume(chunk, id: id)
                }
                guard let self, generation == id else { return }
                finalizeTurn(id: id)
                if diagnosticPCM != nil { onDiagnosticInputFinished?() }
            }
        }
    }

    /// Loads the model at launch so the first press of the shortcut does not wait for CoreML compilation.
    static func preload() {
        Task { @MainActor in _ = try? await recognizer { _ in } }
    }

    /// Loads Parakeet v3 once per process. The first run downloads about 600 MB to Application Support.
    private static func recognizer(progress: @escaping @Sendable (String) -> Void) async throws -> AsrManager {
        if let asr { return asr }
        if let loading { return try await loading.value }
        let task = Task { () -> AsrManager in
            progress("Loading the local speech model…")
            let models = try await AsrModels.downloadAndLoad(version: .v3)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            return manager
        }
        loading = task
        do {
            let manager = try await task.value
            asr = manager
            loading = nil
            return manager
        } catch {
            loading = nil
            throw error
        }
    }

    /// Raw 16 kHz mono signed PCM16, plus trailing silence so the endpointer closes the turn.
    private func produceDiagnostic(_ pcm: Data, id: UUID, sink: AsyncStream<[Float]>.Continuation) {
        diagnosticProducer = Task {
            let samples: [Float] = pcm.withUnsafeBytes { raw in
                raw.bindMemory(to: Int16.self).map { Float($0) / 32_768 }
            } + [Float](repeating: 0, count: 16_000 * 2)
            for offset in stride(from: 0, to: samples.count, by: 1_280) {
                guard generation == id, !Task.isCancelled else { return }
                sink.yield(Array(samples[offset..<min(offset + 1_280, samples.count)]))
                do { try await Task.sleep(nanoseconds: 80_000_000) } catch { return }
            }
            sink.finish()
        }
    }

    private func startMicrophone(sink: AsyncStream<[Float]>.Continuation, id: UUID) throws {
        let audio = AVAudioEngine()
        let input = audio.inputNode
        let source = input.outputFormat(forBus: 0)
        guard source.sampleRate > 0, source.channelCount > 0,
              let destination = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate,
                                              channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: source, to: destination) else {
            throw NSError(domain: "Voice", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported microphone format"])
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: source) { [weak self] buffer, _ in
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * Self.sampleRate / source.sampleRate) + 32)
            guard let converted = AVAudioPCMBuffer(pcmFormat: destination, frameCapacity: capacity) else { return }
            var supplied = false
            var error: NSError?
            let status = converter.convert(to: converted, error: &error) { _, inputStatus in
                if supplied { inputStatus.pointee = .noDataNow; return nil }
                supplied = true
                inputStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, error == nil else {
                Task { @MainActor [weak self] in self?.loseAudio(id: id) }
                return
            }
            // The resampler can return zero frames while it primes; that is not lost audio.
            guard let channel = converted.floatChannelData?[0], converted.frameLength > 0 else { return }
            if case .dropped = sink.yield(Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))) {
                Task { @MainActor [weak self] in self?.loseAudio(id: id) }
            }
        }
        // AirPods or a new default input stop the engine; a silent "Listening…" must not remain.
        routeObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: audio, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.restartMicrophone(sink: sink, id: id) }
        }
        do { try audio.start() }
        catch { input.removeTap(onBus: 0); throw error }
        engine = audio
    }

    /// A new input device (AirPods, a USB mic) changes the engine's format. Rebuild the tap
    /// on the new device; the current turn ends, because audio around the switch is missing.
    private func restartMicrophone(sink: AsyncStream<[Float]>.Continuation, id: UUID) {
        guard generation == id else { return }
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        routeObserver = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        if !endpoint.finalized { onInputLost?() }
        endpoint = Endpointer()
        do { try startMicrophone(sink: sink, id: id) }
        catch { loseAudio(id: id) }
    }

    private func consume(_ chunk: [Float], id: UUID) {
        let rms = sqrt(chunk.reduce(0) { $0 + $1 * $1 } / Float(max(1, chunk.count)))
        onLevel?(min(1, Double(rms) * 12))
        if isSuppressed() {
            endpoint = Endpointer()
            return
        }
        switch endpoint.feed(chunk, rms: rms) {
        case .none: break
        case .began(let turn):
            // Energy alone is not speech: a key click or a cough must not revoke a running command.
            // The coordinator begins the turn on the first non-empty transcript instead (onText).
            onProviderEvent?(["type": "TurnInfo", "event": "StartOfTurn", "turn": turn])
        case .partial(let turn, let samples):
            transcribe(samples, turn: turn, id: id) { [weak self] text in
                guard self?.endpoint.turn == turn, self?.endpoint.finalized == false else { return }
                self?.onText?(text, false, turn)
            }
        case .eager(let turn, let samples):
            transcribe(samples, turn: turn, id: id) { [weak self] text in
                guard let self, endpoint.turn == turn, endpoint.eagerArmed, !endpoint.finalized else { return }
                onProviderEvent?(["type": "TurnInfo", "event": "EagerEndOfTurn", "transcript": text, "turn": turn])
                onText?(text, false, turn)
                onEager?(text, turn)
            }
        case .resumed(let turn):
            onProviderEvent?(["type": "TurnInfo", "event": "TurnResumed", "turn": turn])
            onResumed?()
        case .final(let turn, let samples):
            deliverFinal(samples, turn: turn, id: id)
        }
    }

    private func finalizeTurn(id: UUID) {
        if let (turn, samples) = endpoint.flush() { deliverFinal(samples, turn: turn, id: id) }
    }

    private func deliverFinal(_ samples: [Float], turn: String, id: UUID) {
        transcribe(samples, turn: turn, id: id) { [weak self] text in
            self?.onProviderEvent?(["type": "TurnInfo", "event": "EndOfTurn", "transcript": text, "turn": turn])
            self?.onText?(text, true, turn)
        }
    }

    /// The ASR actor serializes calls, so a final result never overtakes an earlier partial.
    private func transcribe(_ samples: [Float], turn: String, id: UUID, deliver: @escaping @MainActor (String) -> Void) {
        guard let asr = Self.asr, samples.count >= 4_800 else { return }
        let language = language
        Task { [weak self] in
            var state = TdtDecoderState.make()
            guard let result = try? await asr.transcribe(samples, decoderState: &state, language: language) else { return }
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let self, generation == id, !text.isEmpty else { return }
            deliver(text)
        }
    }

    private func loseAudio(id: UUID) {
        guard generation == id else { return }
        onInputLost?()
        stop(message: "Audio was interrupted. Stopped the affected request; start listening again and repeat it.")
    }

    func stop(message: String = "Ready") {
        generation = UUID()
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        routeObserver = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        diagnosticProducer?.cancel()
        diagnosticProducer = nil
        consumer?.cancel()
        consumer = nil
        isListening = false
        onLevel?(0)
        onStatus?(message)
    }

    /// Energy endpointing with an adaptive noise floor. 1,280-sample chunks are about 80 ms.
    struct Endpointer {
        enum Event {
            case none
            case began(String)
            case partial(String, [Float])
            case eager(String, [Float])
            case resumed(String)
            case final(String, [Float])
        }
        private(set) var turn = ""
        private(set) var finalized = true
        private(set) var eagerArmed = false
        private var noise: Float = 0.004
        private var history: [Float] = []
        private var utterance: [Float] = []
        private var voiced = 0
        private var silent = 0
        private var sinceLastPartial = 0

        mutating func feed(_ chunk: [Float], rms: Float) -> Event {
            let speech = rms > max(noise * 3, 0.012)
            if !speech { noise = noise * 0.95 + rms * 0.05 }
            if finalized {
                history.append(contentsOf: chunk)
                if history.count > Voice.preRoll { history.removeFirst(history.count - Voice.preRoll) }
                voiced = speech ? voiced + chunk.count : 0
                guard voiced >= 1_920 else { return .none }  // 120 ms of speech starts a turn
                turn = UUID().uuidString
                finalized = false
                eagerArmed = false
                utterance = history
                history = []
                silent = 0
                sinceLastPartial = 0
                return .began(turn)
            }
            utterance.append(contentsOf: chunk)
            sinceLastPartial += chunk.count
            if speech {
                silent = 0
                if eagerArmed { eagerArmed = false; return .resumed(turn) }
            } else {
                silent += chunk.count
            }
            let silence = Double(silent) / Voice.sampleRate
            // Natural pauses inside one request reach about 0.8 s in Portuguese speech; end the turn later.
            if silence >= 1.2 || utterance.count >= Voice.maxUtterance {
                finalized = true
                eagerArmed = false
                return .final(turn, utterance)
            }
            if silence >= 0.5, !eagerArmed {
                eagerArmed = true
                return .eager(turn, utterance)
            }
            if speech, sinceLastPartial >= Voice.partialEvery {
                sinceLastPartial = 0
                return .partial(turn, utterance)
            }
            return .none
        }

        mutating func flush() -> (String, [Float])? {
            guard !finalized else { return nil }
            finalized = true
            return (turn, utterance)
        }
    }
}
