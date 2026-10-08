import Foundation

/// The user's Shortcuts library as actions. One shortcut can replace many fragile clicks
/// (create an event, send a message, toggle a setting) and the user can add new ones without code.
public enum ShortcutsLibrary {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: (names: [String], at: Date)?

    /// Names from `shortcuts list`, cached for one minute.
    public static func names() -> [String] {
        lock.lock()
        if let cached, Date().timeIntervalSince(cached.at) < 60 { lock.unlock(); return cached.names }
        lock.unlock()
        let output = (try? run(["list"], timeout: 5).output) ?? ""
        let names = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        lock.lock(); cached = (Array(names.prefix(200)), Date()); lock.unlock()
        return Array(names.prefix(200))
    }

    public struct Outcome {
        public let status: Int32
        public let output: String
    }

    /// Runs one shortcut. Text input and output pass through private temporary files.
    public static func perform(_ name: String, input: String?, permit: InputPermit) throws -> Outcome {
        try permit.check()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("computah-shortcut-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let outputFile = folder.appendingPathComponent("output.txt")
        var arguments = ["run", name, "--output-path", outputFile.path, "--output-type", "public.plain-text"]
        if let input, !input.isEmpty {
            let inputFile = folder.appendingPathComponent("input.txt")
            try PrivateFile.write(Data(input.utf8), to: inputFile)
            arguments += ["--input-path", inputFile.path]
        }
        let status = try permit.perform { try run(arguments, timeout: 60).status }
        let output = (try? String(contentsOf: outputFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Outcome(status: status, output: String(output.prefix(1_500)))
    }

    private static func run(_ arguments: [String], timeout: TimeInterval) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        // Drain stdout while the process runs so a full pipe cannot block it.
        let reader = DispatchGroup()
        nonisolated(unsafe) var data = Data()
        reader.enter()
        DispatchQueue.global().async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            reader.leave()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            process.terminate()
            throw AXFailure.unavailable("The shortcut did not finish within \(Int(timeout)) seconds; its effect is unknown.")
        }
        reader.wait()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
