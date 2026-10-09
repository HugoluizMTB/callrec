// Transcrição no Mac (SpeechAnalyzer) → título/resumo (OpenAI, só texto) → pasta renomeada + .md + SQLite
import AVFoundation
import Foundation
import Speech

enum Pipeline {
    static let summaryModel = "gpt-4o-mini"

    static let prompt = """
    You turn call and meeting transcripts into concise notes (Fathom-style).
    Write every field in the SAME LANGUAGE as the transcript.
    Use ONLY what is in the transcript: never invent names, amounts, dates or tasks.
    Lines start with [mm:ss] — use those times to point to where each item was said.
    If the conversation is short or vague, say so in the summary and leave the lists empty.
    Reply with JSON:
    {"titulo": "file name, 3-7 words, specific (who/topic), no date",
     "resumo": "2-3 sentences: purpose of the conversation and its outcome",
     "pontos": [{"t": "mm:ss", "texto": "key point, with names/amounts/dates mentioned"}],
     "decisoes": [{"t": "mm:ss", "texto": "what was decided"}],
     "proximos_passos": [{"t": "mm:ss", "acao": "concrete action", "quem": "only if said, else empty", "prazo": "only if said, else empty"}]}
    At most 6 key points, 5 decisions, 6 next steps.
    """

    // MARK: transcrição local

    static func transcribe(_ url: URL, speaker: String, offset: Double = 0) async throws -> [Seg] {
        let file = try AVAudioFile(forReading: url)
        let tr = SpeechTranscriber(locale: await Settings.transcriptionLocale(), transcriptionOptions: [],
                                   reportingOptions: [], attributeOptions: [.audioTimeRange])
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [tr]) {
            try await req.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [tr])
        let collect = Task { () -> [Seg] in
            var out: [Seg] = []
            for try await r in tr.results {
                let text = String(r.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard text.trimmingCharacters(in: CharacterSet(charactersIn: " .,")).count > 1 else { continue }
                out.append(Seg(start: r.range.start.seconds + offset, end: r.range.end.seconds + offset,
                               speaker: speaker, text: text))
            }
            return out
        }
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collect.value
    }

    // MARK: resumo (OpenAI)

    static func summarize(_ segs: [Seg]) async throws -> (notes: [String: Any], tin: Int, tout: Int) {
        let text = segs.map { "[\(clock($0.start))] \($0.speaker): \($0.text)" }.joined(separator: "\n")
        guard !text.isEmpty else { return (["titulo": "Ligação sem fala", "resumo": "Nenhuma fala detectada."], 0, 0) }
        guard let key = Settings.openAIKey else {
            return (["titulo": "Ligação", "resumo": "Sem chave da OpenAI — defina em CallRec ▸ Chave da OpenAI…"], 0, 0)
        }
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": summaryModel, "response_format": ["type": "json_object"],
            "messages": [["role": "system", "content": prompt], ["role": "user", "content": String(text.prefix(200_000))]],
        ])
        let (data, _) = try await URLSession.shared.data(for: req)
        let r = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let content = ((r["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String,
              let notes = try JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any]
        else { throw NSError(domain: "openai", code: 1, userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? ""]) }
        let u = r["usage"] as? [String: Any]
        return (notes, u?["prompt_tokens"] as? Int ?? 0, u?["completion_tokens"] as? Int ?? 0)
    }

    // MARK: fluxo completo

    /// Gravação do Mac: me.m4a + them.m4a + meta.json
    static func processRecording(_ dir: URL, existing: Int64? = nil) async throws -> Int64 {
        let meta = try JSONDecoder().decode(Meta.self, from: Data(contentsOf: dir.appendingPathComponent("meta.json")))
        let base = [meta.me_first_pts, meta.them_first_pts].compactMap { $0 }.min() ?? 0
        var segs: [Seg] = []
        for (name, speaker, pts) in [("me", "Eu", meta.me_first_pts), ("them", "Outro", meta.them_first_pts)] {
            let url = dir.appendingPathComponent("\(name).m4a")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            segs += try await transcribe(url, speaker: speaker, offset: (pts ?? base) - base)
        }
        segs.sort { $0.start < $1.start }
        let started = ISO8601DateFormatter().date(from: meta.started_at) ?? Date()
        return try await finish(dir: dir, started: started, duration: meta.duration_s, source: "mac",
                                audio: dir.appendingPathComponent("them.m4a"), segs: segs, existing: existing)
    }

    /// Áudio de fora (celular etc.): copia para uma pasta nova e transcreve como faixa única
    static func importFile(_ src: URL) async throws -> Int64 {
        let started = (try? src.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        let dir = audioDir.appendingPathComponent("importando-\(Int(Date().timeIntervalSince1970))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("call." + src.pathExtension.lowercased())
        try FileManager.default.copyItem(at: src, to: dest)
        let dur = try AVAudioFile(forReading: dest).duration
        let segs = try await transcribe(dest, speaker: "Ligação")
        return try await finish(dir: dir, started: started, duration: dur, source: "importado",
                                audio: dest, segs: segs, existing: nil)
    }

    static func reprocess(_ c: Call) async throws -> Int64 {
        if FileManager.default.fileExists(atPath: c.dir.appendingPathComponent("meta.json").path) {
            return try await processRecording(c.dir, existing: c.id)
        }
        guard let audio = try FileManager.default.contentsOfDirectory(at: c.dir, includingPropertiesForKeys: nil)
            .first(where: { $0.lastPathComponent.hasPrefix("call.") }) else { throw NSError(domain: "callrec", code: 2) }
        let segs = try await transcribe(audio, speaker: "Ligação")
        return try await finish(dir: c.dir, started: c.started, duration: c.duration, source: c.source,
                                audio: audio, segs: segs, existing: c.id)
    }

    private static func finish(dir: URL, started: Date, duration: Double, source: String, audio: URL,
                               segs: [Seg], existing: Int64?) async throws -> Int64 {
        let (notes, tin, tout) = try await summarize(segs)
        let title = (notes["titulo"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Ligação"
        let fm = FileManager.default
        // pasta e .md com o nome dado pela IA
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd_HHmm"
        var newDir = audioDir.appendingPathComponent("\(stamp.string(from: started))_\(slug(title))")
        if newDir != dir {
            if fm.fileExists(atPath: newDir.path) { newDir = URL(fileURLWithPath: newDir.path + "-\(Int.random(in: 100...999))") }
            try fm.moveItem(at: dir, to: newDir)
        }
        for f in (try? fm.contentsOfDirectory(at: newDir, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "md" {
            try? fm.removeItem(at: f)
        }
        let md = newDir.appendingPathComponent("\(slug(title)).md")
        try renderMarkdown(title: title, started: started, duration: duration, source: source, notes: notes, segs: segs)
            .write(to: md, atomically: true, encoding: .utf8)
        let todos = (notes["proximos_passos"] as? [[String: Any]] ?? []).compactMap { $0["acao"] as? String }
        let notesJSON = String(data: (try? JSONSerialization.data(withJSONObject: notes)) ?? Data(), encoding: .utf8) ?? "{}"
        return DB.shared.save(id: existing, started: started, duration: duration, source: source, title: title,
                              summary: notes["resumo"] as? String ?? "", todos: todos,
                              audio: newDir.appendingPathComponent(audio.lastPathComponent), notes: notesJSON,
                              md: md, tokensIn: tin, tokensOut: tout, segs: segs)
    }

    static func renderMarkdown(title: String, started: Date, duration: Double, source: String,
                               notes: [String: Any], segs: [Seg]) -> String {
        let pt = (Settings.localeID ?? Locale.current.identifier).hasPrefix("pt")
        let h = pt ? ["Resumo", "Pontos principais", "Decisões", "Próximos passos", "Transcrição"]
                   : ["Summary", "Key points", "Decisions", "Next steps", "Transcript"]
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        var L = ["# \(title)", "", "\(f.string(from: started)) · \(dur(duration)) · \(source)", ""]
        if let r = notes["resumo"] as? String, !r.isEmpty { L += ["## \(h[0])", "", r, ""] }
        for (key, head) in [("pontos", h[1]), ("decisoes", h[2])] {
            let items = notes[key] as? [[String: Any]] ?? []
            if !items.isEmpty {
                L += ["## \(head)", ""] + items.map { "- `\($0["t"] as? String ?? "")` \($0["texto"] as? String ?? "")" } + [""]
            }
        }
        let steps = notes["proximos_passos"] as? [[String: Any]] ?? []
        if !steps.isEmpty {
            L += ["## \(h[3])", ""]
            for s in steps {
                let extra = [s["quem"] as? String, s["prazo"] as? String].compactMap { $0 }.filter { !$0.isEmpty }
                    .joined(separator: " — ")
                L.append("- [ ] \(s["acao"] as? String ?? "")\(extra.isEmpty ? "" : " — " + extra) `\(s["t"] as? String ?? "")`")
            }
            L.append("")
        }
        L += ["## \(h[4])", ""] + segs.map { "**\($0.speaker)** `\(clock($0.start))` \($0.text)  " }
        return L.joined(separator: "\n") + "\n"
    }
}

extension AVAudioFile {
    var duration: Double { Double(length) / fileFormat.sampleRate }
}

func clock(_ s: Double) -> String { String(format: "%02d:%02d", Int(s) / 60, Int(s) % 60) }
func dur(_ s: Double) -> String { s >= 60 ? "\(Int(s) / 60) min" : "\(Int(s)) s" }

func slug(_ s: String) -> String {
    let base = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
    let parts = base.split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
    let out = parts.joined(separator: "-")
    return out.isEmpty ? "ligacao" : String(out.prefix(60))
}
