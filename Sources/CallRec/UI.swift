// Janela "Ligações": filtro por data + busca à esquerda, nota em markdown (ler/editar) à direita
import AVFoundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    @Published var calls: [Call] = DB.shared.calls()
    @Published var recording = false
    @Published var busy: String?
    @Published var selected: Int64?
    var recorder: Recorder?

    func reload(select id: Int64? = nil) {
        calls = DB.shared.calls()
        if let id { selected = id } else if selected == nil || !calls.contains(where: { $0.id == selected }) {
            selected = calls.first?.id
        }
    }

    func toggleRecording() {
        if let rec = recorder {
            recorder = nil
            recording = false
            busy = "Transcrevendo…"
            Task {
                _ = await rec.stop()
                await run { try await Pipeline.processRecording(rec.dir) }
            }
        } else {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd_HHmmss"
            let rec = Recorder(dir: audioDir.appendingPathComponent("gravando-\(f.string(from: Date()))"))
            Task {
                do {
                    try await rec.start()
                    recorder = rec
                    recording = true
                } catch {
                    notify("Não consegui gravar", error.localizedDescription)
                }
            }
        }
    }

    func importAudio() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.audio, .movie]
        p.allowsMultipleSelection = true
        NSApp.activate(ignoringOtherApps: true)
        guard p.runModal() == .OK else { return }
        busy = "Transcrevendo…"
        Task { for url in p.urls { await run { try await Pipeline.importFile(url) } } }
    }

    func reprocess(_ c: Call) {
        busy = "Transcrevendo…"
        Task { await run { try await Pipeline.reprocess(c) } }
    }

    func delete(_ c: Call) {
        DB.shared.delete(c.id)
        try? FileManager.default.trashItem(at: c.dir, resultingItemURL: nil)  // vai pra Lixeira
        selected = nil
        reload()
    }

    private func run(_ job: () async throws -> Int64) async {
        do {
            let id = try await job()
            busy = nil
            reload(select: id)
            let c = calls.first { $0.id == id }
            notify("Ligação salva", c?.title ?? "")
            CallsWindow.show()
        } catch {
            busy = nil
            notify("Falha ao processar", error.localizedDescription)
        }
    }
}

func notify(_ title: String, _ body: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", "display notification \"\(body.replacingOccurrences(of: "\"", with: "'"))\" with title \"\(title)\""]
    try? p.run()
}

// MARK: player (ouve a ligação; clicar num tempo pula pra lá)

final class Player: ObservableObject {
    @Published var playing: Int64?
    private var player: AVPlayer?

    func toggle(_ c: Call, at t: Double? = nil) {
        if playing == c.id, t == nil { player?.pause(); playing = nil; return }
        if playing != c.id { player = AVPlayer(playerItem: item(c)) }
        if let t { player?.seek(to: CMTime(seconds: t, preferredTimescale: 600)) }
        player?.play()
        playing = c.id
    }

    private func item(_ c: Call) -> AVPlayerItem? {
        let files = (try? FileManager.default.contentsOfDirectory(at: c.dir, includingPropertiesForKeys: nil)) ?? []
        if let one = files.first(where: { $0.lastPathComponent.hasPrefix("call.") }) { return AVPlayerItem(url: one) }
        // gravação do Mac: junta as duas faixas no tempo certo
        let meta = (try? Data(contentsOf: c.dir.appendingPathComponent("meta.json")))
            .flatMap { try? JSONDecoder().decode(Meta.self, from: $0) }
        let base = [meta?.me_first_pts, meta?.them_first_pts].compactMap { $0 }.min() ?? 0
        let comp = AVMutableComposition()
        for (name, pts) in [("me", meta?.me_first_pts), ("them", meta?.them_first_pts)] {
            let asset = AVURLAsset(url: c.dir.appendingPathComponent("\(name).m4a"))
            guard let src = asset.tracks(withMediaType: .audio).first,
                  let dst = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            try? dst.insertTimeRange(CMTimeRange(start: .zero, duration: asset.duration), of: src,
                                     at: CMTime(seconds: (pts ?? base) - base, preferredTimescale: 600))
        }
        return AVPlayerItem(asset: comp)
    }
}

// MARK: filtro por data

enum DateFilter: Hashable {
    case all, today, week, month, day(Date)

    var label: String {
        switch self {
        case .all: "Todas"
        case .today: "Hoje"
        case .week: "Últimos 7 dias"
        case .month: "Este mês"
        case .day(let d): d.formatted(.dateTime.day().month(.abbreviated).year())
        }
    }

    func contains(_ d: Date) -> Bool {
        let cal = Calendar.current
        switch self {
        case .all: return true
        case .today: return cal.isDateInToday(d)
        case .week: return d > cal.date(byAdding: .day, value: -7, to: Date())!
        case .month: return cal.isDate(d, equalTo: Date(), toGranularity: .month)
        case .day(let x): return cal.isDate(d, inSameDayAs: x)
        }
    }
}

func dayTitle(_ d: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(d) { return "Hoje" }
    if cal.isDateInYesterday(d) { return "Ontem" }
    return d.formatted(.dateTime.weekday(.wide).day().month(.wide)).capitalized
}

// MARK: janela

struct CallsView: View {
    @ObservedObject var app = AppState.shared
    @StateObject var player = Player()
    @State var q = ""
    @State var filter: DateFilter = .all
    @State var pickDay = false
    @State var day = Date()
    @State var confirmDelete: Call?

    var filtered: [Call] {
        let hits = q.trimmingCharacters(in: .whitespaces).isEmpty ? nil : DB.shared.search(q)
        return app.calls.filter { filter.contains($0.started) && (hits?.contains($0.id) ?? true) }
    }

    var sections: [(String, [Call])] {
        let groups = Dictionary(grouping: filtered) { Calendar.current.startOfDay(for: $0.started) }
        return groups.keys.sorted(by: >).map { (dayTitle($0), groups[$0]!) }
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                filterBar
                if let busy = app.busy {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text(busy).foregroundStyle(.secondary) }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 6)
                }
                List(selection: $app.selected) {
                    ForEach(sections, id: \.0) { title, calls in
                        Section(title) {
                            ForEach(calls) { c in
                                row(c).tag(c.id)
                                    .contextMenu {
                                        Button("Transcrever de novo") { app.reprocess(c) }
                                        Button("Mostrar no Finder") { NSWorkspace.shared.activateFileViewerSelecting([c.md]) }
                                        Divider()
                                        Button("Apagar…", role: .destructive) { confirmDelete = c }
                                    }
                            }
                        }
                    }
                }
                .overlay { if filtered.isEmpty { Text(app.calls.isEmpty ? "Nenhuma ligação ainda" : "Nada nesse filtro").foregroundStyle(.secondary) } }
                .onDeleteCommand { confirmDelete = app.calls.first { $0.id == app.selected } }
            }
            .searchable(text: $q, placement: .sidebar, prompt: "Buscar nas ligações")
            .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        } detail: {
            if let c = app.calls.first(where: { $0.id == app.selected }) {
                Detail(c: c, player: player, onDelete: { confirmDelete = c }).id(c.id)
            } else {
                Text("Escolha uma ligação").foregroundStyle(.secondary)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { app.toggleRecording() } label: {
                    Label(app.recording ? "Parar" : "Gravar", systemImage: app.recording ? "stop.circle.fill" : "record.circle")
                }
                .tint(app.recording ? .red : nil)
                Button { app.importAudio() } label: { Label("Importar áudio", systemImage: "square.and.arrow.down") }
            }
        }
        .onAppear { app.reload() }
        .confirmationDialog("Apagar \"\(confirmDelete?.title ?? "")\"?", isPresented: Binding(
            get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Apagar", role: .destructive) { if let c = confirmDelete { app.delete(c) }; confirmDelete = nil }
        } message: { Text("O áudio e o .md vão para a Lixeira.") }
    }

    var filterBar: some View {
        HStack(spacing: 6) {
            ForEach([DateFilter.all, .today, .week, .month], id: \.self) { f in
                Button(f.label) { filter = f }
                    .buttonStyle(.bordered).controlSize(.small)
                    .tint(filter == f ? .accentColor : nil)
            }
            Button {
                pickDay.toggle()
            } label: {
                if case .day = filter { Text(filter.label) } else { Image(systemName: "calendar") }
            }
            .buttonStyle(.bordered).controlSize(.small)
            .tint({ if case .day = filter { return Color.accentColor }; return nil }())
            .popover(isPresented: $pickDay) {
                DatePicker("", selection: $day, displayedComponents: .date)
                    .datePickerStyle(.graphical).labelsHidden().padding()
                    .onChange(of: day) { _, d in filter = .day(d); pickDay = false }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    func row(_ c: Call) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: c.source == "mac" ? "laptopcomputer" : "iphone")
                .foregroundStyle(.secondary).frame(width: 16).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.title).font(.body.weight(.medium)).lineLimit(1)
                Text("\(c.started.formatted(date: .omitted, time: .shortened)) · \(dur(c.duration))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct Detail: View {
    let c: Call
    @ObservedObject var player: Player
    var onDelete: () -> Void
    @State var text = ""
    @State var editing = false
    @State var copied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("\(c.started.formatted(date: .abbreviated, time: .shortened)) · \(dur(c.duration))")
                    .foregroundStyle(.secondary)
                Spacer()
                Button { player.toggle(c) } label: {
                    Label(player.playing == c.id ? "Pausar" : "Ouvir",
                          systemImage: player.playing == c.id ? "pause.fill" : "play.fill")
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label(copied ? "Copiado" : "Copiar", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .help("Copia a nota inteira em Markdown (⇧⌘C)")
                if editing {
                    Button("Cancelar") { load(); editing = false }
                    Button("Salvar") { save() }.keyboardShortcut("s").buttonStyle(.borderedProminent)
                } else {
                    Button { editing = true } label: { Label("Editar", systemImage: "pencil") }.keyboardShortcut("e")
                }
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }.help("Apagar")
            }
            .padding(.horizontal, 20).padding(.vertical, 10)
            Divider()
            if editing {
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(16)
            } else {
                ScrollView {
                    MarkdownView(text: text, onTime: { player.toggle(c, at: $0) })
                        .padding(28).frame(maxWidth: 780, alignment: .leading)
                }
            }
        }
        .onAppear(perform: load)
    }

    func load() { text = (try? String(contentsOf: c.md, encoding: .utf8)) ?? c.summary }

    func save() {
        try? text.write(to: c.md, atomically: true, encoding: .utf8)
        if let h = text.split(separator: "\n").first(where: { $0.hasPrefix("# ") }) {
            DB.shared.rename(c.id, title: String(h.dropFirst(2)).trimmingCharacters(in: .whitespaces))
        }
        editing = false
        AppState.shared.reload(select: c.id)
    }
}

/// Markdown leve (títulos, listas, checkboxes, negrito/código) — sem WebView
struct MarkdownView: View {
    let text: String
    var onTime: ((Double) -> Void)?

    func inline(_ s: some StringProtocol) -> Text {
        Text((try? AttributedString(markdown: String(s), options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
             ?? AttributedString(String(s)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, raw in
                line(raw.trimmingCharacters(in: .whitespaces))
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    func line(_ l: String) -> some View {
        let t = Self.time(l)
        Group {
            if l.hasPrefix("# ") {
                inline(l.dropFirst(2)).font(.title.weight(.semibold))
            } else if l.hasPrefix("## ") {
                inline(l.dropFirst(3)).font(.headline).padding(.top, 14)
            } else if l.hasPrefix("- [ ] ") || l.hasPrefix("- [x] ") {
                Label { inline(l.dropFirst(6)) } icon: {
                    Image(systemName: l.hasPrefix("- [x]") ? "checkmark.circle.fill" : "circle").foregroundStyle(.secondary)
                }
            } else if l.hasPrefix("- ") {
                HStack(alignment: .firstTextBaseline, spacing: 8) { Text("•").foregroundStyle(.secondary); inline(l.dropFirst(2)) }
            } else if l.isEmpty {
                Color.clear.frame(height: 1)
            } else {
                inline(l).foregroundStyle(l.hasPrefix("**") ? .primary : .secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if let t { onTime?(t) } }
        .help(t != nil ? "Clique para ouvir deste ponto" : "")
    }

    static func time(_ l: String) -> Double? {
        guard let r = l.range(of: #"`(\d{2}):(\d{2})`"#, options: .regularExpression) else { return nil }
        let p = l[r].dropFirst().dropLast().split(separator: ":").compactMap { Double($0) }
        return p.count == 2 ? p[0] * 60 + p[1] : nil
    }
}

enum CallsWindow {
    static var window: NSWindow?

    @MainActor
    static func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 700),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Ligações"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: CallsView())
            w.center()
            window = w
        }
        AppState.shared.reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
