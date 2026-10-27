import CryptoKit
import Foundation

/// Místní kopie katalogu a fronta hlášení. Každý řádek je šifrovaný
/// AES-GCM klíčem z Klíčenky; v čitelné podobě je jen id karty a id hlášení.
/// Obsahuje jen to, co server pro člověka vydal (tvrdá práva).
public final class Kopie: @unchecked Sendable {
    let db: Databaze
    let klic: SymmetricKey
    private let enc = JSONEncoder()
    private let dec = JSONDecoder()

    public init(domov: Domov, klic: SymmetricKey) throws {
        try domov.priprav()
        db = try Databaze(domov.databaze)
        self.klic = klic
        try db.proved("CREATE TABLE IF NOT EXISTS karty (id TEXT PRIMARY KEY, data BLOB NOT NULL)")
        try db.proved("CREATE TABLE IF NOT EXISTS stav (klic TEXT PRIMARY KEY, data BLOB NOT NULL)")
        // Fronta: klíč = karta + otisk, takže dvě hlášení téže verze jsou jeden řádek.
        try db.proved("""
            CREATE TABLE IF NOT EXISTS fronta (klic TEXT PRIMARY KEY, poradi INTEGER NOT NULL,
              data BLOB NOT NULL, pokusy INTEGER NOT NULL DEFAULT 0, odmitnuto BLOB)
            """)
    }

    public static func otevri(_ domov: Domov = Domov()) throws -> Kopie {
        try Kopie(domov: domov, klic: Tajemstvi.klicKopie(Tajemstvi.vychozi(domov)))
    }

    // MARK: šifrování

    func zasifruj<T: Encodable>(_ hodnota: T) throws -> Data {
        try AES.GCM.seal(enc.encode(hodnota), using: klic).combined!
    }

    func desifruj<T: Decodable>(_ typ: T.Type, _ data: Data) throws -> T {
        try dec.decode(typ, from: AES.GCM.open(AES.GCM.SealedBox(combined: data), using: klic))
    }

    // MARK: karty

    public func ulozKarty(_ karty: [Karta]) throws {
        for k in karty {
            // Bez práva zůstane jen stub; plný řádek se přepíše, nic se nedoplňuje.
            try db.proved("INSERT INTO karty (id, data) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET data = excluded.data",
                          [.text(k.id), .blob(try zasifruj(k))])
        }
    }

    public func smazKarty(_ ids: [String]) throws {
        for id in ids { try db.proved("DELETE FROM karty WHERE id = ?", [.text(id)]) }
    }

    public func karty() throws -> [Karta] {
        try db.proved("SELECT data FROM karty").compactMap { r in try r.first?.blob.map { try desifruj(Karta.self, $0) } }
    }

    public func karta(_ id: String) throws -> Karta? {
        try db.proved("SELECT data FROM karty WHERE id = ?", [.text(id)]).first?.first?.blob.map { try desifruj(Karta.self, $0) }
    }

    public func vymazKatalog() throws {
        try db.proved("DELETE FROM karty")
        try smazStav("kurzor")
    }

    // MARK: stav

    public func stav<T: Decodable>(_ klicStavu: String, _ typ: T.Type) throws -> T? {
        try db.proved("SELECT data FROM stav WHERE klic = ?", [.text(klicStavu)]).first?.first?.blob.map { try desifruj(typ, $0) }
    }

    public func nastavStav<T: Encodable>(_ klicStavu: String, _ hodnota: T) throws {
        try db.proved("INSERT INTO stav (klic, data) VALUES (?, ?) ON CONFLICT(klic) DO UPDATE SET data = excluded.data",
                      [.text(klicStavu), .blob(try zasifruj(hodnota))])
    }

    public func smazStav(_ klicStavu: String) throws {
        try db.proved("DELETE FROM stav WHERE klic = ?", [.text(klicStavu)])
    }

    public var navod: Navod? { (try? stav("navod", Navod.self)) ?? nil }
    public var posledniSynchronizace: Date? { (try? stav("posledni_sync", Date.self)) ?? nil }

    // MARK: složky → projekt

    /// Které složky patří ke kterému projektu (`airine propoj`). Podle toho
    /// pozná začátek session, ke kterému projektu dát doporučení.
    public func slozky() throws -> [String: String] { try stav("slozky", [String: String].self) ?? [:] }

    public func propoj(slozka: String, projekt: String) throws {
        var s = try slozky()
        s[URL(fileURLWithPath: slozka).standardizedFileURL.path] = projekt
        try nastavStav("slozky", s)
    }

    /// Nejdelší shoda prefixu cesty.
    public func projekt(pro cesta: String) throws -> String? {
        let c = URL(fileURLWithPath: cesta).standardizedFileURL.path
        return try slozky().filter { c == $0.key || c.hasPrefix($0.key + "/") }
            .max { $0.key.count < $1.key.count }?.value
    }

    // MARK: fronta

    public struct Polozka: Sendable {
        public let hlaseni: Hlaseni
        public let pokusy: Int
        public let odmitnuto: Odmitnuti?
    }

    public func zaradit(_ h: Hlaseni) throws {
        let poradi = Int64(Date().timeIntervalSince1970 * 1000)
        // Tatáž verze znovu (agent uložil dvakrát) nic nepřidá; odmítnutí se ale
        // smaže, protože nové hlášení mohlo chybějící pole doplnit.
        try db.proved("""
            INSERT INTO fronta (klic, poradi, data) VALUES (?, ?, ?)
            ON CONFLICT(klic) DO UPDATE SET data = excluded.data, odmitnuto = NULL, pokusy = 0
            """, [.text("\(h.id):\(h.otisk)"), .cislo(poradi), .blob(try zasifruj(h))])
    }

    public func fronta(vcetneOdmitnutych: Bool = false) throws -> [Polozka] {
        try db.proved("SELECT data, pokusy, odmitnuto FROM fronta ORDER BY poradi").compactMap { r in
            let odm = try r[2].blob.map { try desifruj(Odmitnuti.self, $0) }
            if odm != nil && !vcetneOdmitnutych { return nil }
            return Polozka(hlaseni: try desifruj(Hlaseni.self, r[0].blob!), pokusy: Int(r[1].cislo ?? 0), odmitnuto: odm)
        }
    }

    public func odeslano(_ h: Hlaseni) throws {
        try db.proved("DELETE FROM fronta WHERE klic = ?", [.text("\(h.id):\(h.otisk)")])
    }

    public func pokusSelhal(_ h: Hlaseni) throws {
        try db.proved("UPDATE fronta SET pokusy = pokusy + 1 WHERE klic = ?", [.text("\(h.id):\(h.otisk)")])
    }

    public func odmitnuto(_ h: Hlaseni, _ o: Odmitnuti) throws {
        try db.proved("UPDATE fronta SET odmitnuto = ? WHERE klic = ?", [.blob(try zasifruj(o)), .text("\(h.id):\(h.otisk)")])
    }

    /// Po novém uuid zařízení musí čekající hlášení nést nové místo.
    public func prepisZarizeni(_ nove: String) throws {
        for p in try fronta(vcetneOdmitnutych: true) {
            var h = p.hlaseni
            if h.misto.zarizeni == nove { continue }
            h.misto.zarizeni = nove
            try db.proved("UPDATE fronta SET data = ? WHERE klic = ?", [.blob(try zasifruj(h)), .text("\(h.id):\(h.otisk)")])
        }
    }

    /// Karta smazaná v Airine: zmizí z kopie i fronty a plugin ji znovu nehlásí.
    public func oznacSmazanou(_ h: Hlaseni) throws {
        var smazane = try stav("smazane", [String].self) ?? []
        if !smazane.contains(h.id) { smazane.append(h.id) }
        try db.transakce {
            try nastavStav("smazane", smazane)
            try smazKarty([h.id])
            try db.proved("DELETE FROM fronta WHERE klic LIKE ?", [.text("\(h.id):%")])
        }
    }

    public func jeSmazana(_ id: String) throws -> Bool {
        (try stav("smazane", [String].self) ?? []).contains(id)
    }
}
