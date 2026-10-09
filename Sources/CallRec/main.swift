// CallRec — ícone na barra de menu: gravar/parar, ver ligações, importar áudio
import AppKit
import Combine

@MainActor
final class MenuBar: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var bag: Set<AnyCancellable> = []
    let app = AppState.shared

    func applicationDidFinishLaunching(_ n: Notification) {
        item.button?.target = self
        item.button?.action = #selector(click)
        app.$recording.combineLatest(app.$busy).receive(on: RunLoop.main)
            .sink { [weak self] rec, busy in self?.refresh(rec, busy != nil) }.store(in: &bag)
    }

    func refresh(_ rec: Bool, _ busy: Bool) {
        guard let b = item.button else { return }
        let symbol = busy ? "hourglass" : (rec ? "record.circle.fill" : "phone.badge.waveform")
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "CallRec")?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold))
        if rec && !busy {
            b.image = img?.withSymbolConfiguration(.init(paletteColors: [.systemRed]))
            b.image?.isTemplate = false
            b.attributedTitle = NSAttributedString(string: " REC", attributes: [
                .foregroundColor: NSColor.systemRed, .font: NSFont.systemFont(ofSize: 13, weight: .bold)])
        } else {
            img?.isTemplate = true  // acompanha o tema da barra
            b.image = img
            b.title = ""
        }
        b.imagePosition = .imageLeading
    }

    @objc func click() {
        let m = NSMenu()
        if let busy = app.busy {
            m.addItem(withTitle: busy, action: nil, keyEquivalent: "")
        } else {
            m.addItem(withTitle: app.recording ? "Parar e transcrever" : "Gravar", action: #selector(toggle),
                      keyEquivalent: "").target = self
        }
        m.addItem(.separator())
        m.addItem(withTitle: "Ver ligações…", action: #selector(openList), keyEquivalent: "").target = self
        m.addItem(withTitle: "Importar áudio…", action: #selector(importAudio), keyEquivalent: "").target = self
        m.addItem(.separator())
        let lang = NSMenuItem(title: "Idioma da transcrição", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let sys = sub.addItem(withTitle: "Do sistema", action: #selector(setLanguage(_:)), keyEquivalent: "")
        sys.target = self
        sys.state = Settings.localeID == nil ? .on : .off
        for (id, name) in Settings.languages {
            let it = sub.addItem(withTitle: name, action: #selector(setLanguage(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = id
            it.state = Settings.localeID == id ? .on : .off
        }
        lang.submenu = sub
        m.addItem(lang)
        m.addItem(withTitle: Settings.openAIKey == nil ? "Definir chave da OpenAI…" : "Chave da OpenAI ✓",
                  action: #selector(setKey), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Sair", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = m
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc func toggle() { app.toggleRecording() }
    @objc func openList() { CallsWindow.show() }
    @objc func importAudio() { app.importAudio() }
    @objc func setKey() { Settings.askForKey() }
    @objc func setLanguage(_ sender: NSMenuItem) { Settings.localeID = sender.representedObject as? String }
}

// linha de comando: CallRec --import <arquivo> | --reprocess <id>
let args = CommandLine.arguments
if args.count == 3, ["--reprocess", "--import"].contains(args[1]) {
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        do {
            let id: Int64
            if args[1] == "--import" {
                id = try await Pipeline.importFile(URL(fileURLWithPath: args[2]))
            } else {
                guard let c = DB.shared.calls().first(where: { $0.id == Int64(args[2]) }) else { exit(1) }
                id = try await Pipeline.reprocess(c)
            }
            let r = DB.shared.rows("SELECT title, md, tokens_in, tokens_out FROM calls WHERE id=?", [id]).first ?? [:]
            print("#\(id) \(r["title"] ?? "") — \(r["tokens_in"] ?? 0) in / \(r["tokens_out"] ?? 0) out\n\(r["md"] ?? "")")
        } catch { print("erro: \(error)") }
        sem.signal()
    }
    sem.wait()
    exit(0)
}

MainActor.assumeIsolated {
    let nsapp = NSApplication.shared
    let delegate = MenuBar()
    nsapp.delegate = delegate
    nsapp.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { nsapp.run() }
}
