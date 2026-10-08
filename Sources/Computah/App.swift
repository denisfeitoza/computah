import AppKit
import AVFoundation
import ComputahCore
import FluidAudio

@MainActor final class App: NSObject, NSApplicationDelegate {
    let voice = Voice()
    let speech = AVSpeechSynthesizer()
    var credentialCache: [String: String?] = [:]
    var controlServer: ControlServer?
    var statusMenu: StatusMenu?
    var remoteResult: CheckedContinuation<WorkflowResult, Never>?
    var notch: NotchController?
    var listeningSounds: ListeningSounds?
    var shortcut: ListenShortcut?
    var review: NSWindow?
    let debugState = DebugReviewState()
    var transcript = ""
    var status = "Ready"
    var recentRuns: [RunRecord] = []
    var running = false
    lazy var coordinator = CommandCoordinator(engine: engine, auditLimit: diagnosticAuditLimit)
    var typedTurnID = UUID().uuidString
    var appBeforeReview: NSRunningApplication?
    lazy var jevCosts = JevCostStore(file: root.appendingPathComponent("outputs/computah/jev-costs.json"))
    lazy var engine: CommandEngine = CommandEngine(selector: makeSelector())

    /// TypeSafe Jev when its key exists (fastest), otherwise an OpenRouter chat model.
    /// `COMPUTAH_DECISION=jev|openrouter` forces one backend.
    func makeSelector() -> JevSelector {
        let typesafe = credential("TYPESAFE_API_KEY")
        let forced = setting("COMPUTAH_DECISION")?.lowercased()
        var selector: JevSelector
        if forced == "jev" || (forced != "openrouter" && typesafe != nil) {
            selector = JevSelector(apiKey: typesafe ?? "", model: setting("COMPUTAH_JEV_MODEL") ?? "jev-1.13.0")
        } else {
            selector = JevSelector(apiKey: credential("OPENROUTER_API_KEY") ?? "",
                                   model: setting("COMPUTAH_DECISION_MODEL") ?? "anthropic/claude-haiku-5.5")
            selector.backend = .openRouter
        }
        if let openRouter = credential("OPENROUTER_API_KEY") {
            selector.textModel = TextModel(apiKey: openRouter, model: setting("COMPUTAH_TEXT_MODEL") ?? "inception/mercury-2.5")
        }
        selector.costs = jevCosts.tracker
        return selector
    }

    var hasDecisionKey: Bool { credential("TYPESAFE_API_KEY") != nil || credential("OPENROUTER_API_KEY") != nil }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if startDiagnosticIfRequested() { return }
        coordinator.onStatus = { [weak self] message, active in
            self?.status = message; self?.running = active; self?.refresh()
        }
        coordinator.onResult = { [weak self] result, current in
            guard let self else { return }
            if result.events.contains(where: { $0.action.hasPrefix("Answer") }) { speak(result.status) }
            if current { finishRemote(result) }
            let last = result.events.last
            record(RunRecord(command: result.command, status: result.status,
                observation: last?.after.isEmpty == false ? last?.after : last?.before,
                action: result.events.map(\.action).joined(separator: " → "), requests: result.requests,
                inputTokens: result.inputTokens, elapsed: result.elapsed, recordedAt: Date(), events: result.events, complete: result.complete))
        }
        coordinator.beforeObservation = { [weak self] permit in
            guard let self, NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
                  let previous = appBeforeReview, let url = previous.bundleURL, let bundle = previous.bundleIdentifier else { return }
            _ = try await AppRouting.activate(InstalledApplication(name: previous.localizedName ?? bundle, bundleID: bundle, url: url), permit: permit)
        }
        let notch = NotchController()
        self.notch = notch
        listeningSounds = ListeningSounds()
        notch.toggle = { [weak self] in self?.toggleVoice() }
        notch.debug = { [weak self] in self?.showReview() }
        let statusMenu = StatusMenu()
        statusMenu.toggle = { [weak self] in self?.toggleVoice() }
        statusMenu.debug = { [weak self] in self?.showReview() }
        self.statusMenu = statusMenu
        connectVoiceCallbacks(source: .microphone)
        shortcut = ListenShortcut { [weak self] in self?.toggleVoice() }
        notch.show()
        Voice.preload()
        let server = ControlServer { [weak self] tool, arguments in
            await self?.handleRemote(tool, arguments) ?? ["error": "Computah is closing."]
        }
        server.start()
        controlServer = server
        refresh()
    }

    /// Both microphone UI and explicit audio diagnostics use this wiring.
    func connectVoiceCallbacks(source: InputSource, status: ((String) -> Void)? = nil) {
        voice.onText = { [weak self] text, final, turnID in
            guard let self else { return }
            transcript = text
            refresh()
            coordinator.beginTurn(turnID)
            if final {
                recordInput(text, source: source, turnID: turnID)
                coordinator.submit(text, turn: turnID)
            }
        }
        voice.onTurnBegan = { [weak self] id in self?.coordinator.beginTurn(id) }
        voice.onEager = { [weak self] text, id in self?.coordinator.prepareEager(text, turn: id) }
        voice.onInputLost = { [weak self] in
            self?.coordinator.beginTurn("audio-loss:" + UUID().uuidString)
        }
        voice.onResumed = { [weak self] in self?.discardPreparation() }
        voice.onStatus = status ?? { [weak self] value in
            if self?.voice.isListening == false { self?.discardPreparation() }
            self?.status = value
            self?.refresh()
        }
        voice.onLevel = { [weak self] level in self?.notch?.audioLevel(level) }
        voice.isSuppressed = { [weak self] in self?.speech.isSpeaking == true }
    }

    func toggleVoice() {
        if voice.isListening { discardPreparation(); voice.stop(); return }
        transcript = ""
        coordinator.beginTurn("listening:" + UUID().uuidString)
        voice.language = Language(rawValue: setting("COMPUTAH_SPEECH_LANGUAGE") ?? "pt")
        voice.start()
    }

    func discardPreparation() { coordinator.discardEager() }

    /// Reads answers aloud. The voice follows the speech language setting.
    func speak(_ text: String) {
        speech.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: setting("COMPUTAH_SPEECH_VOICE") ?? "pt-BR")
        speech.speak(utterance)
    }

    func beginDebugCommand() {
        typedTurnID = UUID().uuidString
        coordinator.beginTurn(typedTurnID)
        voice.stop()
    }

    func submitDebugCommand(_ text: String) {
        let command = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        voice.stop()
        // Release the debug editor before any keyboard input reaches the target app.
        review?.makeFirstResponder(nil)
        review?.orderOut(nil)
        run(command)
    }

    func run(_ text: String) {
        transcript = text
        recordInput(text, source: .typed, turnID: typedTurnID)
        coordinator.submit(text, turn: typedTurnID)
        typedTurnID = UUID().uuidString
    }

    func refresh() {
        listeningSounds?.update(listening: voice.isListening)
        notch?.update(listening: voice.isListening, transcript: transcript,
                      needsSetup: !hasDecisionKey)
        statusMenu?.update(listening: voice.isListening, status: status)
        debugState.update(status: status, transcript: transcript,
                          listening: voice.isListening, running: running)
    }

    func applicationWillTerminate(_ notification: Notification) {
        controlServer?.stop()
        coordinator.shutdown()
        voice.stop()
        jevCosts.flush()
        shortcut?.stop()
        notch?.close()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
