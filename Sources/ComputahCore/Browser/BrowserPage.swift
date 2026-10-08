import Foundation

/// Reads the visible tab of a Chromium browser (Comet, Chrome, Brave, Edge, Arc) through the
/// Chrome DevTools Protocol. Remote debugging must be enabled by the user inside the browser
/// (`<browser>://inspect/#remote-debugging`); the browser then writes `DevToolsActivePort`.
/// Read-only: the page text feeds answers and planning, never executable input.
public enum BrowserPage {
    struct Profile { let bundleID: String; let folder: String }

    static let profiles: [Profile] = [
        Profile(bundleID: "ai.perplexity.comet", folder: "Comet"),
        Profile(bundleID: "com.google.Chrome", folder: "Google/Chrome"),
        Profile(bundleID: "com.brave.Browser", folder: "BraveSoftware/Brave-Browser"),
        Profile(bundleID: "com.microsoft.edgemac", folder: "Microsoft Edge"),
        Profile(bundleID: "company.thebrowser.Browser", folder: "Arc/User Data"),
    ]

    public static func supports(_ bundleID: String?) -> Bool {
        profiles.contains { $0.bundleID == bundleID }
    }

    /// The browser-level WebSocket URL, if remote debugging is on.
    static func endpoint(bundleID: String) -> URL? {
        guard let profile = profiles.first(where: { $0.bundleID == bundleID }) else { return nil }
        let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(profile.folder).appendingPathComponent("DevToolsActivePort")
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let lines = content.split(separator: "\n").map(String.init)
        guard lines.count >= 2, let port = Int(lines[0]), (1...65_535).contains(port), lines[1].hasPrefix("/devtools/browser/") else {
            return nil
        }
        return URL(string: "ws://127.0.0.1:\(port)\(lines[1])")
    }

    public struct Page {
        public let url: String
        public let title: String
        public let text: String
    }

    /// The page whose title matches the focused window title (the active tab), with its full text.
    public static func read(bundleID: String, windowTitle: String, maxCharacters: Int = 20_000) async -> Page? {
        guard let endpoint = endpoint(bundleID: bundleID) else { return nil }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let socket = session.webSocketTask(with: endpoint)
        socket.resume()
        defer { socket.cancel(with: .goingAway, reason: nil) }
        var nextID = 0
        func call(_ method: String, _ params: [String: Any] = [:], session sessionID: String? = nil) async throws -> [String: Any] {
            nextID += 1
            let id = nextID
            var message: [String: Any] = ["id": id, "method": method, "params": params]
            if let sessionID { message["sessionId"] = sessionID }
            let data = try JSONSerialization.data(withJSONObject: message)
            try await socket.send(.string(String(decoding: data, as: UTF8.self)))
            while true {
                guard case .string(let text) = try await socket.receive(),
                      let reply = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { continue }
                guard reply["id"] as? Int == id else { continue }
                if let error = reply["error"] as? [String: Any] {
                    throw NSError(domain: "CDP", code: 1, userInfo: [NSLocalizedDescriptionKey: error["message"] as? String ?? "CDP error"])
                }
                return reply["result"] as? [String: Any] ?? [:]
            }
        }
        let work = Task { () -> Page? in
            let targets = (try await call("Target.getTargets"))["targetInfos"] as? [[String: Any]] ?? []
            let pages = targets.filter { $0["type"] as? String == "page" }
            // The AX window title of a Chromium window is the active tab's title.
            let title = windowTitle.trimmingCharacters(in: .whitespaces)
            let target = pages.first { page in
                let pageTitle = page["title"] as? String ?? ""
                return !pageTitle.isEmpty && (title.hasPrefix(pageTitle) || pageTitle.hasPrefix(title))
            } ?? pages.first { $0["attached"] as? Bool == true } ?? pages.first
            guard let target, let targetID = target["targetId"] as? String else { return nil }
            let attached = try await call("Target.attachToTarget", ["targetId": targetID, "flatten": true])
            guard let sessionID = attached["sessionId"] as? String else { return nil }
            let evaluated = try await call("Runtime.evaluate", [
                "expression": "document.body ? document.body.innerText : ''", "returnByValue": true,
            ], session: sessionID)
            let text = ((evaluated["result"] as? [String: Any])?["value"] as? String) ?? ""
            _ = try? await call("Target.detachFromTarget", ["sessionId": sessionID])
            return Page(url: target["url"] as? String ?? "", title: target["title"] as? String ?? "",
                        text: String(text.prefix(maxCharacters)))
        }
        // The browser may show its own "allow remote debugging" prompt; do not wait on it forever.
        let timeout = Task { try await Task.sleep(nanoseconds: 4_000_000_000); work.cancel(); socket.cancel() }
        defer { timeout.cancel() }
        return try? await work.value
    }
}
