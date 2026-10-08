import Foundation

/// Facts the user asked Computah to remember, and named routines (a saved request that is
/// planned and verified again each time it runs). Stored privately (0600) in Application Support.
public enum UserMemory {
    struct Store: Codable {
        var facts: [String] = []
        var routines: [String: String] = [:]
        var lastCompleted: String?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: Store?

    static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Computah/memory.json")
    }

    private static func load() -> Store {
        if let cached { return cached }
        let store = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Store.self, from: $0) } ?? Store()
        cached = store
        return store
    }

    private static func update(_ change: (inout Store) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var store = load()
        change(&store)
        cached = store
        if let data = try? JSONEncoder().encode(store) { try? PrivateFile.write(data, to: file) }
    }

    static var facts: [String] { lock.lock(); defer { lock.unlock() }; return load().facts }
    static var routines: [String: String] { lock.lock(); defer { lock.unlock() }; return load().routines }
    static var lastCompleted: String? { lock.lock(); defer { lock.unlock() }; return load().lastCompleted }

    static func remember(_ fact: String) {
        update { store in
            store.facts.removeAll { $0 == fact }
            store.facts.append(fact)
            if store.facts.count > 100 { store.facts.removeFirst(store.facts.count - 100) }
        }
    }

    static func forgetAll() { update { $0.facts.removeAll() } }

    static func saveRoutine(_ name: String, command: String) { update { $0.routines[name] = command } }

    static func completed(_ command: String) { update { $0.lastCompleted = command } }
}
