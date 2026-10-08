import Foundation

extension App {
    var recordsDiagnostics: Bool { LaunchOptions.current.contains("--record-diagnostics") }

    var diagnosticAuditLimit: Int {
        LaunchOptions.current.contains("--scenario") || LaunchOptions.current.contains("--audio-pcm") ? 4_096 : 0
    }

    var root: URL {
        if let path = LaunchOptions.current.value("--root") {
            return URL(fileURLWithPath: path)
        }
        if let path = ProcessInfo.processInfo.environment["COMPUTAH_PROJECT_ROOT"] {
            return URL(fileURLWithPath: path)
        }
        // A developer bundle in outputs/ is relocatable with its checkout.
        // This supports Finder launch without baking a personal path into Info.plist.
        let bundle = Bundle.main.bundleURL
        let checkout = bundle.deletingLastPathComponent().deletingLastPathComponent()
        if bundle.pathExtension == "app",
           FileManager.default.fileExists(atPath: checkout.appendingPathComponent("Package.swift").path) {
            return checkout
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    /// Keychain first (service names below), then the ignored project-root `.env`.
    /// Cached per launch: each Keychain read can show an access prompt until the user chooses Always Allow.
    func credential(_ name: String) -> String? {
        if let cached = credentialCache[name] { return cached }
        let value = readCredential(name)
        credentialCache[name] = .some(value)
        return value
    }

    private func readCredential(_ name: String) -> String? {
        let services = ["TYPESAFE_API_KEY": "typesafe-api", "OPENROUTER_API_KEY": "openrouter-api",
                        "DEEPGRAM_API_KEY": "deepgram-api"]
        if let service = services[name], let value = Self.keychain(service) { return value }
        return dotenv(name)
    }

    /// Non-secret settings: process environment, then `.env`.
    func setting(_ name: String) -> String? {
        if let value = ProcessInfo.processInfo.environment[name], !value.isEmpty { return value }
        return dotenv(name)
    }

    /// Reads through /usr/bin/security, the tool that created the item and is already on its access
    /// list. A direct SecItem read from this app prompts for the login password after every rebuild,
    /// because each build changes the code hash that "Always Allow" was bound to.
    static func keychain(_ service: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private func dotenv(_ name: String) -> String? {
        guard let content = try? String(contentsOf: root.appendingPathComponent(".env"), encoding: .utf8) else { return nil }
        for line in content.components(separatedBy: .newlines) {
            let pieces = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2, pieces[0].trimmingCharacters(in: .whitespaces) == name else { continue }
            let value = pieces[1].trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
        }
        return nil
    }

}
