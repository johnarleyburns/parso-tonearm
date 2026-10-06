// Decodes Mood Starter transition-prep records (the beat grids the phone uses) to JSON.
// Usage: decode-prep <starter.sqlite> <out.json> <id> [<id> ...]
import Foundation
import SQLite3

let args = CommandLine.arguments
guard args.count >= 4 else { fatalError("usage: decode-prep <db> <out.json> <id>...") }
var db: OpaquePointer?
guard sqlite3_open_v2(args[1], &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { fatalError("open") }
var out: [String: Any] = [:]
for id in args[3...] {
    var stmt: OpaquePointer?
    sqlite3_prepare_v2(db, "select p.payload, t.title, t.artist, t.stream_url, t.genre from starter_prep p join starter_track t on t.id = p.id where p.id = ?", -1, &stmt, nil)
    sqlite3_bind_text(stmt, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    guard sqlite3_step(stmt) == SQLITE_ROW else { print("missing \(id)"); continue }
    let data = Data(bytes: sqlite3_column_blob(stmt, 0), count: Int(sqlite3_column_bytes(stmt, 0)))
    let text = { (i: Int32) in String(cString: sqlite3_column_text(stmt, i)) }
    do {
        let p = try BuiltInTransitionPrepPack.decodeRecord(data)
        out[id] = ["title": text(1), "artist": text(2), "url": text(3), "genre": text(4),
                   "bpm": p.bpm, "tempoConfidence": p.tempoConfidence, "constant": p.isConstantTempo,
                   "camelot": p.key.camelot, "duration": p.duration,
                   "beats": p.beatPositions, "downbeats": p.downbeatPositions,
                   "sections": p.sections.map { ["start": $0.start, "kind": $0.kind, "bar": $0.bar] },
                   "loudness": p.loudness]
    } catch { print("decode \(id): \(error)") }
    sqlite3_finalize(stmt)
}
let json = try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
try json.write(to: URL(fileURLWithPath: args[2]))
print("wrote \(out.count) records")
