import AppKit
import ComputahCore

/// Tool calls from the MCP bridge. One remote command runs at a time, through the same
/// coordinator, permit and verification path as a typed Debug Mode command.
extension App {
    func handleRemote(_ tool: String, _ arguments: [String: Any]) async -> [String: Any] {
        switch tool {
        case "run":
            guard let command = (arguments["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !command.isEmpty else { return ["error": "Missing command."] }
            guard remoteResult == nil, !running else { return ["error": "Computah is busy with another command."] }
            let result = await withCheckedContinuation { continuation in
                remoteResult = continuation
                voice.stop()
                run(command)
            }
            return ["status": result.status, "complete": result.complete,
                    "seconds": (result.elapsed * 10).rounded() / 10,
                    "steps": result.events.map { ["action": $0.action, "outcome": $0.outcome] }]
        case "observe":
            do {
                let snapshot = try await Task.detached { try AXReader.capture(promptForPermission: false) }.value
                return ["app": snapshot.appName, "text": snapshot.evidence]
            } catch {
                return ["error": error.localizedDescription]
            }
        case "shortcuts":
            let names = await Task.detached { ShortcutsLibrary.names() }.value
            return ["text": names.isEmpty ? "No shortcuts." : names.joined(separator: "\n")]
        case "speak":
            guard let text = arguments["text"] as? String, !text.isEmpty else { return ["error": "Missing text."] }
            speak(String(text.prefix(1_000)))
            return ["text": "Spoken."]
        default:
            return ["error": "Unknown tool: \(tool)"]
        }
    }

    /// Resolves the waiting remote call with the current command's final result.
    func finishRemote(_ result: WorkflowResult) {
        guard let continuation = remoteResult else { return }
        remoteResult = nil
        continuation.resume(returning: result)
    }
}
