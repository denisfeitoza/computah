import Foundation
import Network
import ComputahCore

/// Loopback control channel for agents. The running app keeps its own Accessibility and
/// Microphone grants; `Computah --mcp` is only a stdio bridge that forwards tool calls here.
/// Each request is one JSON line: {"token", "tool", "arguments"}. The token lives in a 0600 file.
@MainActor final class ControlServer {
    private var listener: NWListener?
    private let token = UUID().uuidString + UUID().uuidString
    private let handle: (String, [String: Any]) async -> [String: Any]

    nonisolated static var descriptor: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Computah/control.json")
    }

    init(handle: @escaping (String, [String: Any]) async -> [String: Any]) {
        self.handle = handle
    }

    func start() {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        guard let listener = try? NWListener(using: parameters) else { return }
        self.listener = listener
        let token = token
        listener.stateUpdateHandler = { [weak listener] state in
            guard case .ready = state, let port = listener?.port?.rawValue else { return }
            let descriptor = ["port": Int(port), "token": token] as [String: Any]
            if let data = try? JSONSerialization.data(withJSONObject: descriptor) {
                try? PrivateFile.write(data, to: ControlServer.descriptor)
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        listener.start(queue: .main)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        try? FileManager.default.removeItem(at: Self.descriptor)
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                var buffer = buffer
                if let data { buffer.append(data) }
                if let newline = buffer.firstIndex(of: 0x0A) {
                    await self.respond(to: buffer[..<newline], on: connection)
                } else if complete || error != nil || buffer.count > 1_000_000 {
                    connection.cancel()
                } else {
                    self.receive(connection, buffer: buffer)
                }
            }
        }
    }

    private func respond(to line: Data, on connection: NWConnection) async {
        var reply: [String: Any]
        if let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
           let supplied = request["token"] as? String, Self.equal(supplied, token),
           let tool = request["tool"] as? String {
            reply = await handle(tool, request["arguments"] as? [String: Any] ?? [:])
        } else {
            reply = ["error": "Unauthorized or malformed request."]
        }
        var data = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data("{}".utf8)
        data.append(0x0A)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// Length-independent comparison for the shared token.
    private static func equal(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
