import AppKit
import Foundation

public struct PreparedAction {
    let snapshot: AXSnapshot?
    let launch: InstalledApplication?
    let candidate: AXCandidate?
    let literal: String?
    public let description: String?
    let emptyStatus: String
    public let observation: String
    public var requests: Int { usage.requests }
    var permit: InputPermit = .standalone()
    var navigation: URL? = nil
    var navigationBrowser: InstalledApplication? = nil
    /// A spoken-style answer about the observed screen. Sends no input.
    var answer: String? = nil
    /// A Shortcuts library entry and its optional text input.
    var shortcut: (name: String, input: String?)? = nil
    /// A saved routine's request, planned and verified again as a nested workflow.
    var routine: (name: String, command: String)? = nil
    var interpretation: InterpretedCommand? = nil
    var captureSeconds: Double = 0
    var modelSeconds: Double = 0
    var preparationSeconds: Double = 0
    var recoveryReads: Int = 0
    var referenceContext: [String: Any] = [:]
    var usage = ModelUsage()

    var hasExecutablePlan: Bool {
        launch != nil || navigation != nil || candidate != nil || answer != nil || shortcut != nil || routine != nil || interpretation?.actionID == "already_satisfied"
    }

    /// Workflow handles app launches and navigation. This sends one observed control action.
    func execute(physicalActivation: Bool = true) async throws -> String {
        guard let snapshot, let candidate else {
            throw AXFailure.unavailable("The selected action has no observed control.")
        }
        return try await cancellableNative {
            try AXActor.perform(candidate, in: snapshot, text: literal, permit: permit,
                                physicalActivation: physicalActivation)
        }
    }

}

enum ObservationRequest { case initial, recovery(pid_t), expanded(pid_t), region(AXSnapshot, Int), verification(pid_t) }

public struct CommandEngine {
    public var inputPermit: InputPermit = .standalone()
    public var selector: JevSelector
    /// Skip the model judgment after an input when the screen visibly changed.
    public var fastVerification = false
    var executePrepared: (PreparedAction) async throws -> String = { try await $0.execute() }
    var observationForegroundPID: () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    var readObservation: (ObservationRequest) async throws -> AXSnapshot = { request in
        try Task.checkCancellation()
        return try await cancellableNative {
            switch request {
            case .initial:
                return try await AXReader.captureReady(maxNodes: 900, seconds: 0.35, promptForPermission: false)
            case .verification(let pid):
                return try await AXReader.captureReady(pid: pid)
            case .recovery(let pid):
                AXReader.invalidateEnablement(pid: pid)
                return try AXReader.capture(maxNodes: 1_200, seconds: 0.45, pid: pid, promptForPermission: false)
            case .expanded(let pid):
                AXReader.invalidateEnablement(pid: pid)
                return try AXReader.capture(maxNodes: 2_000, seconds: 0.65, allChildren: true, pid: pid, promptForPermission: false)
            case .region(let old, let id):
                guard old.handles.indices.contains(id) else { throw AXFailure.changed }
                let fresh = try AXReader.capture(maxNodes: 900, seconds: 0.35, allChildren: true,
                    pid: old.pid, promptForPermission: false, subtree: old.handles[id])
                guard fresh.sameWindow(as: old) else { throw AXFailure.changed }
                return fresh
            }
        }
    }
    public init(selector: JevSelector) {
        self.selector = selector
    }

    public mutating func useDiagnosticInitialNodeLimit(_ nodes: Int) {
        let normal = readObservation
        readObservation = { request in
            if case .initial = request {
                return try await cancellableNative {
                    try AXReader.capture(maxNodes: max(1, min(nodes, 3_000)), seconds: 0.35, promptForPermission: false)
                }
            }
            return try await normal(request)
        }
    }

    /// Compare delivery mechanisms in independent live trials, never as replay
    /// after an unknown native effect. Target selection and validation are shared.
    public mutating func useDiagnosticPhysicalActivation() {
        executePrepared = { try await $0.execute(physicalActivation: true) }
    }

    public mutating func useDiagnosticNativeActivation() {
        executePrepared = { try await $0.execute(physicalActivation: false) }
    }

    public func prepare(_ command: String, observation: AXSnapshot? = nil,
                        progress: [String] = [], excluded: Set<String> = []) async throws -> PreparedAction {
        try await prepare(command, from: 0, observation: observation, progress: progress, excluded: excluded)
    }

    func prepare(_ command: String, from offset: Int, observation supplied: AXSnapshot? = nil,
                 progress: [String] = [], excluded: Set<String> = [],
                 interpretation existing: InterpretedCommand? = nil, revisions: [String] = [],
                 relationshipContext: [String: Any]? = nil, conversationContext: [String: Any] = [:], continuation: AXSnapshot? = nil, activatedApps: Set<String> = []) async throws -> PreparedAction {
        let started = Date()
        let usageStart = selector.usage.snapshot
        var snapshot = supplied
        var captureSeconds = 0.0
        var modelSeconds = 0.0
        var recoveryReads = 0
        var captureFailure: String?
        if snapshot == nil {
            let start = Date()
            do { snapshot = try await readObservation(.initial) }
            catch is CancellationError { throw CancellationError() }
            catch { captureFailure = error.localizedDescription }
            captureSeconds += Date().timeIntervalSince(start)
        }
        try Task.checkCancellation()
        var apps = try await cancellableNative { AppRouting.installed() }
        if let browser = AppRouting.defaultBrowser() {
            if let index = apps.firstIndex(where: { $0.bundleID == browser.bundleID }) {
                let app = apps[index]
                apps[index] = InstalledApplication(name: app.name, bundleID: app.bundleID, url: app.url,
                                                   aliases: app.aliases + ["Registered default browser"])
            } else {
                apps.append(InstalledApplication(name: browser.name, bundleID: browser.bundleID, url: browser.url,
                                                 aliases: ["Registered default browser"]))
            }
        }
        apps.removeAll { activatedApps.contains($0.bundleID) }
        if let continuation {
            guard let snapshot, snapshot.sameWindow(as: continuation) else { throw AXFailure.changed }
        }
        let shortcuts = try await cancellableNative { ShortcutsLibrary.names() }
        let language = CommandLanguage(selector: selector)
        var scope = snapshot.map { availableCandidates($0, excluded: excluded) } ?? []
        var interpreted: InterpretedCommand
        if let existing, existing.source != command || existing.clause.startUTF16 != offset {
            throw JevFailure.invalid("Prepared interpretation belongs to a different instruction.")
        }
        let interpretStart = Date()
        interpreted = try await language.interpret(command, from: offset, apps: apps,
            progress: progress, controls: scope, observation: snapshot, fixedClause: existing?.clause, revisions: revisions, relationshipContext: relationshipContext, conversationContext: conversationContext, continuation: continuation,
            shortcuts: shortcuts)
        modelSeconds += Date().timeIntervalSince(interpretStart)
        func eligible(_ candidate: AXCandidate) -> Bool {
            guard !excluded.contains(candidate.description) else { return false }
            switch candidate.operation {
            case .typeText, .replaceText: return interpreted.canType && interpreted.value != nil
            case .setNumber: return interpreted.canSetNumber && interpreted.value != nil
            default: return true
            }
        }
        func prepared(candidate: AXCandidate? = nil, launch: InstalledApplication? = nil, navigation: URL? = nil,
                      status: String = "", description: String? = nil) -> PreparedAction {
            let details = "\(snapshot?.appName ?? "No AX observation"); nodes=\(snapshot?.nodes.count ?? 0); partial=\(snapshot?.partial ?? true); options=\(scope.count); selected=\(candidate?.id ?? interpreted.actionID ?? "none"); recovery reads=\(recoveryReads); capture=\(captureSeconds)s; model=\(modelSeconds)s"
            let usage = selector.usage.snapshot.since(usageStart)
            var result = PreparedAction(snapshot: interpreted.route == .controls || interpreted.relationship != nil ? snapshot : nil, launch: launch, candidate: candidate,
                literal: interpreted.value, description: description ?? candidate?.description, emptyStatus: status,
                observation: details)
            result.usage = usage
            result.permit = inputPermit
            result.navigation = navigation
            if navigation != nil {
                result.navigationBrowser = interpreted.app ?? AppRouting.defaultBrowser()
            }
            result.interpretation = interpreted
            result.referenceContext = conversationContext
            result.captureSeconds = captureSeconds
            result.modelSeconds = modelSeconds
            result.preparationSeconds = Date().timeIntervalSince(started)
            result.recoveryReads = recoveryReads
            return result
        }
        try Task.checkCancellation()
        if let relationship = interpreted.relationship, relationship != .replace {
            return prepared(status: "Goal relationship: " + relationship.rawValue)
        }
        if interpreted.activatesApp {
            guard let app = interpreted.app else { return prepared(status: "The requested app is unclear or unavailable.") }
            return prepared(launch: app, description: "Open \(app.name)")
        }
        if interpreted.route == nil {
            return prepared(status: "No clear action requested.")
        }
        // A memory route with no clear operation is usually a question about remembered facts.
        if interpreted.route == .memory, interpreted.memoryAction != nil {
            switch interpreted.memoryAction {
            case .remember:
                UserMemory.remember(interpreted.clause.text.trimmingCharacters(in: .whitespacesAndNewlines))
                var result = prepared(description: "Remember"); result.answer = "Anotado."; return result
            case .forget:
                UserMemory.forgetAll()
                var result = prepared(description: "Forget"); result.answer = "Esqueci o que você tinha pedido para lembrar."; return result
            case .save_routine:
                guard let name = interpreted.value?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                    return prepared(status: "Say the routine's name, for example: salva isso como rotina fechamento.")
                }
                guard let last = UserMemory.lastCompleted else { return prepared(status: "No completed command to save yet.") }
                UserMemory.saveRoutine(name, command: last)
                var result = prepared(description: "Save routine"); result.answer = "Rotina \(name) salva."; return result
            case .run_routine:
                guard let name = interpreted.routine, let saved = UserMemory.routines[name] else {
                    return prepared(status: "No saved routine matches the request.")
                }
                var result = prepared(description: "Run routine \(name)")
                result.routine = (name, saved)
                return result
            case nil:
                break
            }
        }
        if interpreted.route == .shortcut {
            guard let name = interpreted.shortcut else { return prepared(status: "No shortcut matches the request.") }
            var result = prepared(description: "Run shortcut \(name)")
            result.shortcut = (name, interpreted.value)
            return result
        }
        if interpreted.route == .answer || interpreted.route == .memory {
            guard let textModel = selector.textModel else {
                return prepared(status: "Answering questions needs the OpenRouter text model.")
            }
            let start = Date()
            // In a Chromium browser with remote debugging on, read the whole page, not only the viewport.
            var page: BrowserPage.Page?
            if let snapshot, let bundleID = snapshot.bundleID, BrowserPage.supports(bundleID) {
                page = await BrowserPage.read(bundleID: bundleID, windowTitle: snapshot.windowTitle)
            }
            let reply = try await textModel.answer([
                "question": interpreted.clause.text, "original_request": command,
                "app": snapshot?.appName ?? "Unknown",
                "web_page": page.map { ["url": $0.url, "title": $0.title, "text": $0.text] } as Any? ?? NSNull(),
                "observed_content": snapshot?.selectionEvidence ?? captureFailure ?? "No observation.",
                "user_memory": UserMemory.facts,
                "conversation_context": conversationContext])
            modelSeconds += Date().timeIntervalSince(start)
            var result = prepared(status: reply, description: "Answer")
            result.answer = reply
            return result
        }
        if interpreted.route == .controls {
            var selected = interpreted.actionID
            let missingFromIncompleteRead = selected == nil && snapshot?.unfinishedVisibleRead == true
            if selected == "reobserve" || selected == "inspect_secondary" || missingFromIncompleteRead, let before = snapshot {
                let recovery = try await recover(command, offset: offset, interpretation: interpreted,
                    snapshot: before, primary: scope, progress: progress, excluded: excluded, revisions: revisions,
                    conversationContext: conversationContext, continuation: continuation)
                snapshot = recovery.snapshot
                scope = recovery.candidates
                interpreted = recovery.interpretation
                selected = interpreted.actionID
                captureSeconds += recovery.captureSeconds
                modelSeconds += recovery.modelSeconds
                recoveryReads += recovery.reads
            }
            if selected == "already_satisfied", snapshot != nil {
                return prepared(status: "Requested state needs fresh confirmation.", description: "Already satisfied — verify without input")
            }
            guard let candidate = scope.first(where: { $0.id == selected }) else {
                return prepared(status: captureFailure ?? "No matching control found after bounded observation; no further input sent.")
            }
            guard eligible(candidate) else {
                throw JevFailure.invalid("The selected action and source value disagree.")
            }
            if [.typeText, .replaceText, .setNumber].contains(candidate.operation) {
                let start = Date()
                let resolved = try await language.resolveValue(interpreted)
                modelSeconds += Date().timeIntervalSince(start)
                interpreted = resolved
            }
            return prepared(candidate: candidate)
        }
        let start = Date()
        let resolved = try await language.resolveValue(interpreted)
        modelSeconds += Date().timeIntervalSince(start)
        interpreted = resolved
        guard let value = interpreted.value, let url = CommandLanguage.validatedURL(value) else {
            return prepared(status: "The requested address is incomplete or unclear.")
        }
        return prepared(navigation: url, description: "Visit \(url.absoluteString)")
    }

    func availableCandidates(
        _ scene: AXSnapshot, excluded: Set<String>,
        includeSecondary: Bool = false
    ) -> [AXCandidate] {
        AXGrouping.candidates(in: scene, includeSecondary: includeSecondary).filter { candidate in
            !excluded.contains(candidate.description)
        }
    }
}
