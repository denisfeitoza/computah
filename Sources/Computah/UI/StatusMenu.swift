import AppKit

/// Menu bar entry point. The notch panel is easy to miss, and Macs without a notch
/// have no visible target at all; the status item is always there.
@MainActor final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let statusLine = NSMenuItem(title: "Pronto", action: nil, keyEquivalent: "")
    private let listenItem = NSMenuItem(title: "", action: #selector(toggleListening), keyEquivalent: "")
    var toggle: (() -> Void)?
    var debug: (() -> Void)?
    var wakeWord: (() -> Void)?
    var isWakeWordOn: () -> Bool = { false }
    private let wakeItem = NSMenuItem(title: "Escuta contínua (diga \"Computa, …\")", action: #selector(toggleWakeWord), keyEquivalent: "")

    override init() {
        super.init()
        statusLine.isEnabled = false
        listenItem.target = self
        let debugItem = NSMenuItem(title: "Abrir Debug Mode (comandos digitados)…", action: #selector(openDebug), keyEquivalent: "d")
        debugItem.target = self
        let quit = NSMenuItem(title: "Encerrar Computah", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        wakeItem.target = self
        for entry in [statusLine, .separator(), listenItem, wakeItem, debugItem, .separator(), quit] { menu.addItem(entry) }
        menu.delegate = self
        item.menu = menu
        update(listening: false, status: "Pronto")
    }

    func update(listening: Bool, status: String) {
        let symbol = listening ? "waveform.circle.fill" : "waveform.circle"
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Computah")
        item.button?.toolTip = "Computah — " + status
        listenItem.title = listening ? "Parar de ouvir (Control + Option)" : "Começar a ouvir (Control + Option)"
        statusLine.title = String(status.prefix(80))
    }

    func menuWillOpen(_ menu: NSMenu) {
        wakeItem.title = isWakeWordOn() ? "Desativar palavra de ativação \"Computa\"" : "Ativar palavra de ativação \"Computa\" (escuta contínua)"
    }
    @objc private func toggleWakeWord() { wakeWord?() }
    @objc private func toggleListening() { toggle?() }
    @objc private func openDebug() { debug?() }
}
