import Foundation
import Network

/// `Computah --mcp`: a Model Context Protocol server over stdio (newline-delimited JSON-RPC).
/// It forwards tool calls to the running Computah app through the loopback control channel.
enum MCPBridge {
    static let tools: [[String: Any]] = [
        ["name": "computah_run",
         "description": "Run a natural-language command on this Mac through Computah (any language, e.g. Portuguese). "
            + "Computah reads the frontmost app's Accessibility controls, opens apps or URLs, clicks, types, runs Shortcuts, "
            + "or answers questions about the screen, and verifies each step. Returns the final status and steps.",
         "inputSchema": ["type": "object", "properties": ["command": ["type": "string", "description": "What to do."]],
                         "required": ["command"]]],
        ["name": "computah_observe",
         "description": "Read the frontmost app's window through macOS Accessibility and return its visible controls and text.",
         "inputSchema": ["type": "object", "properties": [:] as [String: Any]]],
        ["name": "computah_shortcuts",
         "description": "List the names in the user's Shortcuts library that computah_run can trigger.",
         "inputSchema": ["type": "object", "properties": [:] as [String: Any]]],
        ["name": "computah_speak",
         "description": "Say a short message aloud on this Mac.",
         "inputSchema": ["type": "object", "properties": ["text": ["type": "string"]], "required": ["text"]]],
    ]

    static func run() -> Never {
        while let line = readLine(strippingNewline: true) {
            guard let request = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let method = request["method"] as? String, let id = request["id"] else { continue }
            let params = request["params"] as? [String: Any] ?? [:]
            switch method {
            case "initialize":
                reply(id, result: ["protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                                   "capabilities": ["tools": [:] as [String: Any]],
                                   "serverInfo": ["name": "computah", "version": "0.2.0"]])
            case "ping":
                reply(id, result: [:])
            case "tools/list":
                reply(id, result: ["tools": tools])
            case "tools/call":
                let name = params["name"] as? String ?? ""
                let tool = name.hasPrefix("computah_") ? String(name.dropFirst("computah_".count)) : name
                let answer = forward(tool, arguments: params["arguments"] as? [String: Any] ?? [:],
                                     timeout: tool == "run" ? 150 : 20)
                let failed = answer["error"] != nil
                let text = (answer["error"] as? String) ?? (answer["text"] as? String)
                    ?? String(decoding: (try? JSONSerialization.data(withJSONObject: answer, options: [.prettyPrinted])) ?? Data(),
                              as: UTF8.self)
                reply(id, result: ["content": [["type": "text", "text": text]], "isError": failed])
            default:
                write(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]])
            }
        }
        exit(0)
    }

    private static func reply(_ id: Any, result: [String: Any]) {
        write(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func write(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        FileHandle.standardOutput.write(data + Data([0x0A]))
    }

    /// One request, one JSON-line reply, over 127.0.0.1.
    private static func forward(_ tool: String, arguments: [String: Any], timeout: TimeInterval) -> [String: Any] {
        guard let data = try? Data(contentsOf: ControlServer.descriptor),
              let descriptor = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let port = descriptor["port"] as? Int, let token = descriptor["token"] as? String,
              let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            return ["error": "Computah is not running. Open /Applications/Computah.app first."]
        }
        guard var payload = try? JSONSerialization.data(withJSONObject: ["token": token, "tool": tool, "arguments": arguments]) else {
            return ["error": "Could not encode the request."]
        }
        payload.append(0x0A)
        let connection = NWConnection(host: "127.0.0.1", port: endpointPort, using: .tcp)
        let queue = DispatchQueue(label: "computah.mcp")
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var buffer = Data()
        nonisolated(unsafe) var failure: String?
        @Sendable func read() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
                if let data { buffer.append(data) }
                if buffer.contains(0x0A) || complete { done.signal() }
                else if let error { failure = error.localizedDescription; done.signal() }
                else { read() }
            }
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: payload, completion: .contentProcessed { error in
                    if let error { failure = error.localizedDescription; done.signal() } else { read() }
                })
            case .failed(let error):
                failure = "Could not reach Computah: \(error.localizedDescription)"
                done.signal()
            default: break
            }
        }
        connection.start(queue: queue)
        let waited = done.wait(timeout: .now() + timeout)
        connection.cancel()
        if waited == .timedOut { return ["error": "Computah did not answer within \(Int(timeout)) seconds."] }
        if let failure { return ["error": failure] }
        let line = buffer.split(separator: 0x0A).first ?? Data()
        return (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] ?? ["error": "Malformed reply from Computah."]
    }
}
