import Foundation
import SQLite3

/// Tenký obal SQLite. Jedno spojení na proces, WAL (aplikace v liště i příkaz
/// `airine` z hooku čtou souběžně), busy_timeout místo pádu na zámku.
public final class Databaze: @unchecked Sendable {
    private var db: OpaquePointer?
    private let zamek = NSLock()

    public struct Chyba: Error, CustomStringConvertible {
        public let description: String
    }

    public init(_ url: URL) throws {
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw Chyba(description: "nelze otevřít \(url.path)")
        }
        sqlite3_busy_timeout(db, 3000)
        try proved("PRAGMA journal_mode=WAL")
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    deinit { sqlite3_close_v2(db) }

    public enum Hodnota { case text(String), blob(Data), cislo(Int64), nic }

    private static let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    @discardableResult
    public func proved(_ sql: String, _ parametry: [Hodnota] = []) throws -> [[Hodnota]] {
        zamek.lock(); defer { zamek.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw chyba(sql) }
        defer { sqlite3_finalize(stmt) }
        for (i, p) in parametry.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, Self.TRANSIENT)
            case .blob(let d): _ = d.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(d.count), Self.TRANSIENT) }
            case .cislo(let n): sqlite3_bind_int64(stmt, idx, n)
            case .nic: sqlite3_bind_null(stmt, idx)
            }
        }
        var radky: [[Hodnota]] = []
        while true {
            let r = sqlite3_step(stmt)
            if r == SQLITE_DONE { break }
            guard r == SQLITE_ROW else { throw chyba(sql) }
            var radek: [Hodnota] = []
            for c in 0..<sqlite3_column_count(stmt) {
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_TEXT: radek.append(.text(String(cString: sqlite3_column_text(stmt, c))))
                case SQLITE_BLOB:
                    let n = Int(sqlite3_column_bytes(stmt, c))
                    radek.append(.blob(n == 0 ? Data() : Data(bytes: sqlite3_column_blob(stmt, c), count: n)))
                case SQLITE_INTEGER: radek.append(.cislo(sqlite3_column_int64(stmt, c)))
                default: radek.append(.nic)
                }
            }
            radky.append(radek)
        }
        return radky
    }

    public func transakce<T>(_ blok: () throws -> T) throws -> T {
        try proved("BEGIN IMMEDIATE")
        do { let v = try blok(); try proved("COMMIT"); return v }
        catch { _ = try? proved("ROLLBACK"); throw error }
    }

    private func chyba(_ sql: String) -> Chyba {
        Chyba(description: "\(String(cString: sqlite3_errmsg(db))) — \(sql.prefix(60))")
    }
}

extension Databaze.Hodnota {
    var text: String? { if case .text(let s) = self { return s }; return nil }
    var blob: Data? { if case .blob(let d) = self { return d }; return nil }
    var cislo: Int64? { if case .cislo(let n) = self { return n }; return nil }
}
