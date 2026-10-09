// SQLite (calls.db) — ligações, trechos da transcrição e índice de busca
import Foundation
import SQLite3

let dataDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/callrec")
let audioDir = dataDir.appendingPathComponent("audio")
private let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct Call: Identifiable, Hashable {
    let id: Int64
    let started: Date
    let duration: Double
    let source: String
    let title: String
    let summary: String
    let dir: URL
    let md: URL
}

struct Seg {
    var start: Double
    var end: Double
    var speaker: String
    var text: String
}

let isoLocal: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    return f
}()

final class DB {
    static let shared = DB()
    private var db: OpaquePointer?

    private init() {
        try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        sqlite3_open(dataDir.appendingPathComponent("calls.db").path, &db)
        run("""
        CREATE TABLE IF NOT EXISTS calls(
          id INTEGER PRIMARY KEY, started_at TEXT, duration_s REAL, source TEXT, title TEXT, summary TEXT,
          todos TEXT, audio TEXT, created_at TEXT, notes TEXT, md TEXT, tokens_in INTEGER, tokens_out INTEGER);
        CREATE TABLE IF NOT EXISTS segments(call_id INTEGER, start REAL, end REAL, speaker TEXT, text TEXT);
        CREATE INDEX IF NOT EXISTS seg_call ON segments(call_id, start);
        CREATE VIRTUAL TABLE IF NOT EXISTS calls_fts USING fts5(title, summary, transcript);
        """)
    }

    private func run(_ sql: String) { sqlite3_exec(db, sql, nil, nil, nil) }

    @discardableResult
    func exec(_ sql: String, _ args: [Any?] = []) -> Int64 {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(st) }
        bind(st, args)
        sqlite3_step(st)
        return sqlite3_last_insert_rowid(db)
    }

    func rows(_ sql: String, _ args: [Any?] = []) -> [[String: Any]] {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(st) }
        bind(st, args)
        var out: [[String: Any]] = []
        while sqlite3_step(st) == SQLITE_ROW {
            var r: [String: Any] = [:]
            for i in 0..<sqlite3_column_count(st) {
                let name = String(cString: sqlite3_column_name(st, i))
                switch sqlite3_column_type(st, i) {
                case SQLITE_INTEGER: r[name] = sqlite3_column_int64(st, i)
                case SQLITE_FLOAT: r[name] = sqlite3_column_double(st, i)
                case SQLITE_TEXT: r[name] = String(cString: sqlite3_column_text(st, i))
                default: break
                }
            }
            out.append(r)
        }
        return out
    }

    private func bind(_ st: OpaquePointer?, _ args: [Any?]) {
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a {
            case let v as Int64: sqlite3_bind_int64(st, idx, v)
            case let v as Int: sqlite3_bind_int64(st, idx, Int64(v))
            case let v as Double: sqlite3_bind_double(st, idx, v)
            case let v as String: sqlite3_bind_text(st, idx, v, -1, TRANSIENT)
            default: sqlite3_bind_null(st, idx)
            }
        }
    }

    // MARK: ligações

    func calls() -> [Call] {
        rows("SELECT id, started_at, duration_s, source, title, summary, audio, md FROM calls ORDER BY started_at DESC")
            .compactMap { r in
                guard let id = r["id"] as? Int64 else { return nil }
                let audio = URL(fileURLWithPath: r["audio"] as? String ?? "")
                let dir = audio.deletingLastPathComponent()
                let md = (r["md"] as? String).map { URL(fileURLWithPath: $0) }
                    ?? (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
                        .first { $0.pathExtension == "md" }
                    ?? dir.appendingPathComponent("ligacao.md")
                return Call(id: id,
                            started: isoLocal.date(from: String((r["started_at"] as? String ?? "").prefix(19))) ?? .distantPast,
                            duration: r["duration_s"] as? Double ?? 0, source: r["source"] as? String ?? "",
                            title: r["title"] as? String ?? "", summary: r["summary"] as? String ?? "",
                            dir: dir, md: md)
            }
    }

    func save(id: Int64?, started: Date, duration: Double, source: String, title: String, summary: String,
              todos: [String], audio: URL, notes: String, md: URL, tokensIn: Int, tokensOut: Int,
              segs: [Seg]) -> Int64 {
        let todosJSON = String(data: (try? JSONSerialization.data(withJSONObject: todos)) ?? Data("[]".utf8),
                               encoding: .utf8)
        let vals: [Any?] = [isoLocal.string(from: started), duration, source, title, summary, todosJSON,
                            audio.path, notes, md.path, tokensIn, tokensOut]
        var callId: Int64
        if let id {
            callId = id
            exec("DELETE FROM segments WHERE call_id=?", [id])
            exec("DELETE FROM calls_fts WHERE rowid=?", [id])
            exec("UPDATE calls SET started_at=?, duration_s=?, source=?, title=?, summary=?, todos=?, audio=?, " +
                 "notes=?, md=?, tokens_in=?, tokens_out=? WHERE id=?", vals + [id])
        } else {
            callId = exec("INSERT INTO calls(started_at,duration_s,source,title,summary,todos,audio,notes,md," +
                          "tokens_in,tokens_out,created_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
                          vals + [isoLocal.string(from: Date())])
        }
        run("BEGIN")
        for s in segs {
            exec("INSERT INTO segments(call_id,start,end,speaker,text) VALUES(?,?,?,?,?)",
                 [callId, s.start, s.end, s.speaker, s.text])
        }
        exec("INSERT INTO calls_fts(rowid,title,summary,transcript) VALUES(?,?,?,?)",
             [callId, title, summary, segs.map(\.text).joined(separator: "\n")])
        run("COMMIT")
        return callId
    }

    func rename(_ id: Int64, title: String) {
        exec("UPDATE calls SET title=? WHERE id=?", [title, id])
        exec("UPDATE calls_fts SET title=? WHERE rowid=?", [title, id])
    }

    func delete(_ id: Int64) {
        exec("DELETE FROM segments WHERE call_id=?", [id])
        exec("DELETE FROM calls_fts WHERE rowid=?", [id])
        exec("DELETE FROM calls WHERE id=?", [id])
    }

    /// ids das ligações cujo título/resumo/transcrição batem com a busca
    func search(_ q: String) -> Set<Int64> {
        let terms = q.split(separator: " ").map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"*" }
        let ids = rows("SELECT rowid FROM calls_fts WHERE calls_fts MATCH ?", [terms.joined(separator: " ")])
            .compactMap { $0["rowid"] as? Int64 }
        return Set(ids)
    }
}
