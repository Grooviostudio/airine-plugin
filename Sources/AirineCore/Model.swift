import Foundation

// Tvar dat mezi pluginem a serverem (/api/katalog/*).
// Změna tvaru = upravit i MockServer v testech.

public struct Misto: Codable, Hashable, Sendable {
    public var druh: String              // 'airine' | 'zarizeni'
    public var zarizeni: String?
    public var cesta: String?
    public var otisk: String?
    public var videno: String?
    public init(druh: String, zarizeni: String? = nil, cesta: String? = nil, otisk: String? = nil, videno: String? = nil) {
        self.druh = druh; self.zarizeni = zarizeni; self.cesta = cesta; self.otisk = otisk; self.videno = videno
    }
}

public struct Prava: Codable, Hashable, Sendable {
    public var cist: Bool
    public var menit: Bool
}

public struct Fakt: Codable, Hashable, Sendable {
    public var klic: String
    public var hodnota: String
}

/// Karta souboru. Bez práva čtení přijde jen {id, name, vlastnik_id,
/// bez_prava: true} — plugin pak zahodí popis, fakta i obsah.
public struct Karta: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var popis: String?
    public var typ: String?
    public var klient_id: String?
    public var projekt_id: String?
    public var slozka_id: String?
    public var fakta: [Fakt]?
    public var mista: [Misto]?
    public var otisk: String?
    public var verze: Int?
    public var nahrazuje: String?
    public var nahrazeno: String?
    public var vychazi_z: [String]?
    public var vlastnik: String?                // jméno, když ho server pošle
    public var vlastnik_id: String?
    public var vlastnik_jmeno: String?
    public var v_airine: Bool?
    public var rozpor: Bool?
    public var moje_prava: Prava?
    public var zmeneno: String?
    public var zmenil: String?
    public var bez_prava: Bool?

    public var platna: Bool { nahrazeno == nil }
    public var jenNaZarizeni: Bool {
        v_airine != true && Set((mista ?? []).compactMap { $0.druh == "zarizeni" ? $0.zarizeni : nil }).count == 1
    }
}

public struct Navod: Codable, Hashable, Sendable {
    public var verze: Int
    public var obsah: String
}

public struct Zmeny: Codable, Sendable {
    public var karty: [Karta]
    public var smazano: [String]
    public var navod: Navod?
    public var kurzor: String
    public var dalsi: Bool
}

/// Hlášení souboru. Idempotence plyne z dat: `id` karty generuje plugin
/// (uuid v4) a zapíše ho do hlavičky souboru, server páruje podle (id, otisk).
public struct Hlaseni: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String?
    public var popis: String?
    public var typ: String?
    public var klient_id: String?
    public var projekt_id: String?
    public var slozka_id: String?
    public var fakta: [Fakt]?
    public var nahrazuje: String?
    public var vychazi_z: [String]?
    public var vlastnik: String?
    public var misto: Misto
    public var otisk: String
    public var otisk_predchozi: String?
    public var radku: Int
    public var bajty: Int
    public var hlavicka: String?
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

public struct OdpovedHlaseni: Codable, Sendable {
    public var karta: Karta?
    public var stav: StavHlaseni
    public var varovani: [ChybaPole]?
    public var nesoulad_hlavicky: [String]?
}

/// 422: neúplné nebo chybné hlášení. Agent dostane konkrétní chyby.
public struct Odmitnuti: Codable, Hashable, Sendable {
    public var chyby: [ChybaPole]
}
