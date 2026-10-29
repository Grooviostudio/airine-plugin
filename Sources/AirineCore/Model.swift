import Foundation

// Tvar dat mezi pluginem a serverem (/api/katalog/*), podle routes/katalog.js
// a SQL `katalog_zmeny` / `katalog_hlaseni`. Server píše contact_id,
// project_id a nahrazuje_id; plugin interně klient_id, projekt_id a nahrazuje.
// Změna tvaru = upravit i MockServer a KontraktTests v testech.

/// Kde karta leží na disku některého zařízení.
public struct Misto: Codable, Hashable, Sendable {
    public var zarizeni_id: String?
    public var cesta: String?
    public var otisk: String?
    public var videno_at: String?
    /// Soubor na tomhle místě zmizel (`/api/katalog/mista/zmizela`).
    public var zmizelo_at: String?
    public init(zarizeni_id: String? = nil, cesta: String? = nil, otisk: String? = nil, videno_at: String? = nil, zmizelo_at: String? = nil) {
        self.zarizeni_id = zarizeni_id; self.cesta = cesta; self.otisk = otisk; self.videno_at = videno_at; self.zmizelo_at = zmizelo_at
    }
}

/// Karta souboru, jak ji vydá kanál změn. Tři tvary:
/// - smazaná: jen `{id, smazano: true}`,
/// - bez práva čtení: `{id, name, vlastnik_id, vlastnik_jmeno, bez_prava: true}`
///   (klient dostane jen `{id, bez_prava: true}`),
/// - plná karta s `cist`, `menit` a `mista`.
/// Archivovaná karta (duplicita, kterou člověk v Airine schoval) přijde jako
/// plná karta s `archivovano_at`. V kopii zůstane, jen se nedoporučuje.
/// Hlášení souboru s jejím id ji neobnoví ani nezaloží znovu.
public struct Karta: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String?
    public var popis: String?
    public var typ: String?
    public var klient_id: String?
    public var projekt_id: String?
    public var slozka_id: String?
    public var vlastnik_id: String?
    public var vlastnik_jmeno: String?
    public var nahrazuje: String?
    public var vychazi_z: [String]?
    public var fakta: [String: String]?
    public var otisk: String?
    public var verze: Int?
    public var ulozeny_otisk: String?          // otisk obsahu, který leží v Airine
    public var rozpor: Bool?
    public var zmenil_id: String?
    public var created_at: String?
    public var updated_at: String?
    public var cist: Bool?
    public var menit: Bool?
    public var mista: [Misto]?
    public var smazano: Bool?
    public var bez_prava: Bool?
    public var archivovano_at: String?

    enum CodingKeys: String, CodingKey {
        case id, name, popis, typ, slozka_id, vlastnik_id, vlastnik_jmeno, vychazi_z, fakta, otisk, verze,
             ulozeny_otisk, rozpor, zmenil_id, created_at, updated_at, cist, menit, mista, smazano, bez_prava,
             archivovano_at
        case klient_id = "contact_id"
        case projekt_id = "project_id"
        case nahrazuje = "nahrazuje_id"
    }

    public init(id: String, name: String? = nil, popis: String? = nil, typ: String? = nil,
                klient_id: String? = nil, projekt_id: String? = nil, nahrazuje: String? = nil,
                fakta: [String: String]? = nil, otisk: String? = nil, vlastnik_id: String? = nil,
                vlastnik_jmeno: String? = nil, mista: [Misto]? = nil, bez_prava: Bool? = nil) {
        self.id = id; self.name = name; self.popis = popis; self.typ = typ
        self.klient_id = klient_id; self.projekt_id = projekt_id; self.nahrazuje = nahrazuje
        self.fakta = fakta; self.otisk = otisk; self.vlastnik_id = vlastnik_id
        self.vlastnik_jmeno = vlastnik_jmeno; self.mista = mista; self.bez_prava = bez_prava
    }

    /// Stejné signály jako serverové `doporuceni()`.
    public var jenNaJednomZarizeni: Bool { Set((mista ?? []).compactMap(\.zarizeni_id)).count == 1 }
    public var neniVAirine: Bool { ulozeny_otisk != otisk }
    public var archivovana: Bool { archivovano_at != nil }
}

/// Návod firmy pro agenty. Server posílá `obsah` jako objekt (výchozí
/// `{pravidla: [...], typy: [...]}`, firma si ho může přepsat); plugin ho
/// převede na text, který dá agentovi, a místně ho drží jako text.
public struct Navod: Codable, Hashable, Sendable {
    public var verze: Int
    public var obsah: String

    public init(verze: Int, obsah: String) { self.verze = verze; self.obsah = obsah }

    enum CodingKeys: String, CodingKey { case verze, obsah }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        verze = try c.decode(Int.self, forKey: .verze)
        if let text = try? c.decode(String.self, forKey: .obsah) {
            obsah = text
        } else {
            obsah = Self.text(try c.decode(JSONHodnota.self, forKey: .obsah))
        }
    }

    static func text(_ h: JSONHodnota) -> String {
        guard case .objekt(let o) = h else { return h.json }
        var r: [String] = []
        if case .pole(let p)? = o["pravidla"] { r += p.map { "- " + $0.prostyText } }
        if case .pole(let t)? = o["typy"] { r.append("Typy souborů: " + t.map(\.prostyText).joined(separator: ", ")) }
        // Vlastní klíče firmy, které plugin nezná, jdou agentovi tak, jak jsou.
        for (k, v) in o.sorted(by: { $0.key < $1.key }) where !["pravidla", "typy", "verze"].contains(k) {
            r.append("\(k): \(v.prostyText)")
        }
        return r.joined(separator: "\n")
    }
}

/// Libovolný JSON (návod firmy nemá pevný tvar).
public indirect enum JSONHodnota: Codable, Hashable, Sendable {
    case text(String), cislo(Double), ano(Bool), pole([JSONHodnota]), objekt([String: JSONHodnota]), nic

    public init(from d: Decoder) throws {
        let c = try d.singleValueContainer()
        if c.decodeNil() { self = .nic }
        else if let v = try? c.decode(Bool.self) { self = .ano(v) }
        else if let v = try? c.decode(Double.self) { self = .cislo(v) }
        else if let v = try? c.decode(String.self) { self = .text(v) }
        else if let v = try? c.decode([JSONHodnota].self) { self = .pole(v) }
        else { self = .objekt(try c.decode([String: JSONHodnota].self)) }
    }

    public func encode(to e: Encoder) throws {
        var c = e.singleValueContainer()
        switch self {
        case .text(let v): try c.encode(v)
        case .cislo(let v): try c.encode(v)
        case .ano(let v): try c.encode(v)
        case .pole(let v): try c.encode(v)
        case .objekt(let v): try c.encode(v)
        case .nic: try c.encodeNil()
        }
    }

    var json: String {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? e.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    var prostyText: String { if case .text(let s) = self { return s }; return json }
}

public struct Zmeny: Codable, Sendable {
    public var karty: [Karta]                  // včetně smazaných `{id, smazano: true}`
    public var dalsi: Bool
    public var kurzor: String                  // neprůhledný, jen se posílá zpátky
    public var navod_zmenen: Bool?
    public var navod: Navod?

    public init(karty: [Karta], dalsi: Bool, kurzor: String, navod_zmenen: Bool? = nil, navod: Navod? = nil) {
        self.karty = karty; self.dalsi = dalsi; self.kurzor = kurzor; self.navod_zmenen = navod_zmenen; self.navod = navod
    }
}

/// Hlášení souboru. Idempotence plyne z dat: `id` karty generuje plugin
/// (uuid v4) a zapíše ho do hlavičky souboru, server páruje podle (id, otisk).
/// Zařízení nese hlavička požadavku, ne tělo. Pole, které chybí, server na kartě
/// smaže, proto se posílá vždy celá hlavička.
public struct Hlaseni: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String?
    public var popis: String?
    public var typ: String?
    public var klient_id: String?
    public var projekt_id: String?
    public var slozka_id: String?
    public var fakta: [String: String]?
    public var nahrazuje: String?
    public var vychazi_z: [String]?
    public var cesta: String?                  // místní cesta na tomhle zařízení
    public var otisk: String
    public var otisk_predchozi: String?
    public var radku: Int
    public var bajty: Int
    public var hlavicka: String?
    /// Odkazy na jiné MD soubory (bez textu). Chybí = plugin je neposílá
    /// a server vazby nemění; `[]` = soubor žádné nemá.
    public var odkazy: [Odkaz]?
    public var odkazy_oriznuto: Bool?

    public init(id: String, name: String? = nil, popis: String? = nil, typ: String? = nil,
                klient_id: String? = nil, projekt_id: String? = nil, slozka_id: String? = nil,
                fakta: [String: String]? = nil, nahrazuje: String? = nil, vychazi_z: [String]? = nil,
                cesta: String? = nil, otisk: String, otisk_predchozi: String? = nil,
                radku: Int, bajty: Int, hlavicka: String? = nil, odkazy: [Odkaz]? = nil, odkazy_oriznuto: Bool? = nil) {
        self.id = id; self.name = name; self.popis = popis; self.typ = typ
        self.klient_id = klient_id; self.projekt_id = projekt_id; self.slozka_id = slozka_id
        self.fakta = fakta; self.nahrazuje = nahrazuje; self.vychazi_z = vychazi_z; self.cesta = cesta
        self.otisk = otisk; self.otisk_predchozi = otisk_predchozi; self.radku = radku; self.bajty = bajty
        self.hlavicka = hlavicka; self.odkazy = odkazy; self.odkazy_oriznuto = odkazy_oriznuto
    }
}

public enum StavHlaseni: String, Codable, Sendable { case ok, rozpor, uz_prijato }

public struct ChybaPole: Codable, Hashable, Sendable {
    public var pole: String
    public var zprava: String
    public var kod: String?

    public init(pole: String, zprava: String, kod: String?) { self.pole = pole; self.zprava = zprava; self.kod = kod }

    // Server posílá u validace jen {pole, kod}; text pak dá kód.
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        pole = try c.decode(String.self, forKey: .pole)
        kod = try c.decodeIfPresent(String.self, forKey: .kod)
        zprava = try c.decodeIfPresent(String.self, forKey: .zprava) ?? kod ?? "neplatné"
    }
}

/// Pole, kde se hlášení liší od hlavičky souboru (server je jen ohlásí).
public struct NesouladHlavicky: Codable, Hashable, Sendable {
    public var pole: String
    public var v_hlavicce: JSONHodnota?
    public var v_hlaseni: JSONHodnota?
}

/// 200: stav a co server o kartě ví po zápisu. Celou kartu přinese až kanál změn.
public struct OdpovedHlaseni: Codable, Sendable {
    public var stav: StavHlaseni
    public var id: String
    public var otisk: String?
    public var verze: Int?
    public var rozpor: Bool?
    public var ulozeny_otisk: String?
    public var hlavicka: [NesouladHlavicky]?

    public init(stav: StavHlaseni, id: String, otisk: String? = nil, verze: Int? = nil, rozpor: Bool? = nil) {
        self.stav = stav; self.id = id; self.otisk = otisk; self.verze = verze; self.rozpor = rozpor
    }
}

/// 422: neúplné nebo chybné hlášení. Agent dostane konkrétní chyby.
public struct Odmitnuti: Codable, Hashable, Sendable {
    public var chyby: [ChybaPole]
}
