import Foundation

/// Rozhraní k Airine. Protokol kvůli testům (MockServer) a kvůli tomu, že
/// routy kroku 1 ještě nejsou na stagingu.
public protocol AirineAPI: Sendable {
    func zmeny(od kurzor: String?, limit: Int) async throws -> Zmeny
    func nahlas(_ h: Hlaseni) async throws -> OdpovedHlaseni
    /// Archiv karet (POST /api/katalog/archiv): všechno, nebo nic. Vrací počet změněných.
    func archiv(karty: [String], archivovat: Bool) async throws -> Int
    /// Hlášení i s obsahem (`/nahrat` → PUT bajtů → `/potvrdit`). Odpověď je
    /// táž jako u `nahlas`. Když obsah neprojde (strop, kvóta, úložiště),
    /// hází `obsahNeprosel` a volající pošle samotnou kartu.
    func nahrajObsah(_ h: Hlaseni, data: Data, mime: String) async throws -> OdpovedHlaseni
    /// Místa, kde soubor na tomhle zařízení zmizel (POST /api/katalog/mista/zmizela).
    /// Karta zůstane. Vrací počet míst, která přestala platit.
    func zmizela(_ mista: [ZmizeleMisto]) async throws -> Int
    /// Víc souborů s obsahem jedním požadavkem (POST /api/katalog/obsah-davka).
    /// Výsledky jsou ve stejném pořadí. Server bez téhle cesty hází `jine(404, …)`,
    /// příliš velká dávka `davkaVelka`: volající pak pošle soubory po jednom.
    func nahrajDavku(_ soubory: [SouborDavky]) async throws -> [VysledekDavky]
    /// Přeskakované složky a stropy dávky z GET /api/katalog/import.
    func nastaveniImportu() async throws -> NastaveniImportu
}

/// Jeden soubor v dávce obsahu: hlášení karty a text, jehož SHA-256 je otisk.
public struct SouborDavky: Sendable {
    public var hlaseni: Hlaseni
    public var mime: String
    public var obsah: String
    public init(hlaseni: Hlaseni, mime: String, obsah: String) { self.hlaseni = hlaseni; self.mime = mime; self.obsah = obsah }
}

/// Stav jednoho souboru z dávky. `ok`, `uz_prijato` a `rozpor` jsou jako
/// u hlášení; `pretizeno` = poslat znovu po `retry_after` sekundách.
public struct VysledekDavky: Codable, Sendable, Equatable {
    public var id: String
    public var stav: String
    public var otisk: String?
    public var rozpor: Bool?
    public var ulozeny_otisk: String?
    public var retry_after: Double?
    public var strop: Int?
    public var pocet: Int?
    public var tarif: String?
    public init(id: String, stav: String, otisk: String? = nil, retry_after: Double? = nil) {
        self.id = id; self.stav = stav; self.otisk = otisk; self.retry_after = retry_after
    }
}

/// Katalog je plný (Solo 2 000, Team 10 000 souborů): nová karta neprojde,
/// nová verze existující ano. Hlášení počká ve frontě.
public struct StropSouboru: Codable, Sendable, Equatable {
    public var strop: Int?
    public var pocet: Int?
    public var tarif: String?
    public var kdy: Date
    public init(strop: Int? = nil, pocet: Int? = nil, tarif: String? = nil, kdy: Date = Date()) {
        self.strop = strop; self.pocet = pocet; self.tarif = tarif; self.kdy = kdy
    }
    static func zTela(_ t: [String: Any]) -> StropSouboru {
        StropSouboru(strop: t["strop"] as? Int, pocet: t["pocet"] as? Int, tarif: t["tarif"] as? String)
    }
    /// Věta pro člověka v liště.
    public func zprava(ceka: Int) -> String {
        let kolik = strop.map { "\($0.formatted(.number.locale(Locale(identifier: "cs_CZ")))) souborů" }
        let tarif = self.tarif.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        let zavorka = [kolik, tarif].compactMap { $0 }.joined(separator: ", ")
        let ceka = switch ceka {
            case 1: "čeká 1 nový soubor"
            case 2...4: "čekají \(ceka) nové soubory"
            default: "čeká \(ceka) nových souborů"
        }
        return "Katalog je plný" + (zavorka.isEmpty ? "" : " (\(zavorka))") + ". Na Macu \(ceka), nic se neztratí."
    }
}

/// Strop dávky obsahu (`obsah_davka`, `obsah_davka_bajtu` v GET /api/katalog/import).
public struct StropyDavky: Codable, Sendable, Equatable {
    public var souboru: Int
    public var bajtu: Int
    public init(souboru: Int, bajtu: Int) { self.souboru = souboru; self.bajtu = bajtu }
    public static let vychozi = StropyDavky(souboru: 50, bajtu: 3_500_000)

    /// Z odpovědi serveru, jen v rozumných mezích; jinak `nil` a platí dosavadní.
    public static func zeServeru(_ json: [String: Any]) -> StropyDavky? {
        guard let s = json["obsah_davka"] as? Int, let b = json["obsah_davka_bajtu"] as? Int,
              (2...500).contains(s), (65_536...50_000_000).contains(b) else { return nil }
        return StropyDavky(souboru: s, bajtu: b)
    }
}

/// Co plugin bere z GET /api/katalog/import. Co server nepošle, je `nil`.
public struct NastaveniImportu: Sendable, Equatable {
    public var pravidla: PravidlaSlozek?
    public var stropy: StropyDavky?
    public init(pravidla: PravidlaSlozek? = nil, stropy: StropyDavky? = nil) { self.pravidla = pravidla; self.stropy = stropy }
}

extension AirineAPI {
    public func nahrajDavku(_ soubory: [SouborDavky]) async throws -> [VysledekDavky] { throw ChybaServeru.jine(404, "obsah-davka") }

    public func nastaveniImportu() async throws -> NastaveniImportu { NastaveniImportu() }

    /// Server bez téhle cesty: zmizelá místa počkají ve frontě.
    public func zmizela(_ mista: [ZmizeleMisto]) async throws -> Int { throw ChybaServeru.jine(404, "zmizela") }
}

public enum ChybaServeru: Error, Equatable {
    case bezSpojeni                  // síť, DNS, timeout, 5xx: hlášení zůstane ve frontě
    case kurzorNeplatny              // 410: plná synchronizace
    case odmitnuto(Odmitnuti)        // 422: agent musí hlášení opravit
    case neprihlasen                 // 401 (u kanálu i 403): token zrušený nebo bez modulu
    case bezPravaKarty               // 403 bez_prava: kartu nesmím měnit
    case ciziZarizeni                // 409 cizi_zarizeni: uuid zařízení má jiný člen
    case ciziId                      // 409 cizi_id: uuid karty má jiný workspace
    case smazano                     // 410 u hlášení: karta je v Airine smazaná
    case obsahNeprosel(String)       // obsah se nenahrál; karta jde bez něj
    case davkaVelka                  // 413 u dávky obsahu: soubory po jednom
    case stropSouboru(StropSouboru)  // strop_souboru: nová karta počká ve frontě
    case jine(Int, String)
}

public struct HttpAirine: AirineAPI {
    let zaklad: URL
    let token: String
    let zarizeni: String
    let nazevZarizeni: String
    let session: URLSession

    public init(nastaveni: Nastaveni, token: String, session: URLSession = .shared) {
        zaklad = URL(string: nastaveni.server)!
        self.token = token
        zarizeni = nastaveni.zarizeni
        nazevZarizeni = String(nastaveni.nazevZarizeni.prefix(64))
        self.session = session
    }

    func pozadavek(_ cesta: String, metoda: String = "GET", telo: Data? = nil) -> URLRequest {
        var r = URLRequest(url: zaklad.appendingPathComponent(cesta), timeoutInterval: 15)
        r.httpMethod = metoda
        r.setValue(token, forHTTPHeaderField: "x-api-key")
        r.setValue(zarizeni, forHTTPHeaderField: "x-airine-zarizeni")
        // Hlavička jde jen v ASCII-bezpečné podobě; název s diakritikou kóduje procenty.
        r.setValue(nazevZarizeni.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                   forHTTPHeaderField: "x-airine-zarizeni-nazev")
        if let telo { r.httpBody = telo; r.setValue("application/json", forHTTPHeaderField: "content-type") }
        return r
    }

    /// Kolikrát zkusit znovu po 503 s Retry-After a jak dlouho nejvýš čekat.
    static let pokusy503 = 2
    static let nejdeleCekat = 30.0

    func posli(_ r: URLRequest) async throws -> (Data, Int) {
        var pokus = 0
        while true {
            let data: Data, odp: URLResponse
            do { (data, odp) = try await session.data(for: r) } catch is URLError { throw ChybaServeru.bezSpojeni }
            let http = odp as? HTTPURLResponse
            let kod = http?.statusCode ?? 0
            // Úložiště je chvíli přetížené: server řekne, za jak dlouho to zkusit.
            if kod == 503, pokus < Self.pokusy503,
               let po = http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init), po >= 0 {
                pokus += 1
                try await Task.sleep(for: .seconds(min(po, Self.nejdeleCekat)))
                continue
            }
            switch kod {
            case 500..<600, 0: throw ChybaServeru.bezSpojeni
            case 401: throw ChybaServeru.neprihlasen
            default: return (data, kod)
            }
        }
    }

    static func neocekavany(_ data: Data, _ kod: Int) -> ChybaServeru {
        .jine(kod, String(decoding: data.prefix(300), as: UTF8.self))
    }

    /// Stavy hlášení: tělo nese vždy `{stav, id, …}`, 401 jen kvůli tokenu.
    static func chybaHlaseni(_ data: Data, _ kod: Int) -> ChybaServeru {
        let telo = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if telo["kod"] as? String == "strop_souboru" || telo["stav"] as? String == "nad_stropem" {
            return .stropSouboru(.zTela(telo))
        }
        switch (kod, telo["stav"] as? String) {
        case (403, "bez_prava"): return .bezPravaKarty
        case (403, _): return .neprihlasen
        case (409, "cizi_zarizeni"): return .ciziZarizeni
        case (409, "cizi_id"): return .ciziId
        case (410, _): return .smazano
        case (422, "neplatne"):
            let omezeni = telo["omezeni"].flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed, .sortedKeys]) }
                .map { String(decoding: $0, as: UTF8.self) } ?? "neplatné hlášení"
            return .odmitnuto(Odmitnuti(chyby: [ChybaPole(pole: "omezeni", zprava: omezeni, kod: "neplatne")]))
        case (422, _):
            return .odmitnuto((try? JSONDecoder().decode(Odmitnuti.self, from: data))
                ?? Odmitnuti(chyby: [ChybaPole(pole: "?", zprava: "neplatné hlášení", kod: nil)]))
        default: return neocekavany(data, kod)
        }
    }

    public func zmeny(od kurzor: String?, limit: Int) async throws -> Zmeny {
        var c = URLComponents(url: zaklad.appendingPathComponent("api/katalog/zmeny"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "limit", value: String(limit))] + (kurzor.map { [URLQueryItem(name: "od", value: $0)] } ?? [])
        var r = pozadavek("api/katalog/zmeny")
        r.url = c.url
        let (data, kod) = try await posli(r)
        switch kod {
        case 200..<300: return try JSONDecoder().decode(Zmeny.self, from: data)
        case 403: throw ChybaServeru.neprihlasen
        case 410: throw ChybaServeru.kurzorNeplatny
        default: throw Self.neocekavany(data, kod)
        }
    }

    public func nahlas(_ h: Hlaseni) async throws -> OdpovedHlaseni {
        let r = pozadavek("api/katalog/hlaseni", metoda: "POST", telo: try JSONEncoder().encode(h))
        let (data, kod) = try await posli(r)
        guard (200..<300).contains(kod) else { throw Self.chybaHlaseni(data, kod) }
        return try JSONDecoder().decode(OdpovedHlaseni.self, from: data)
    }

    public func nahrajObsah(_ h: Hlaseni, data: Data, mime: String) async throws -> OdpovedHlaseni {
        let cesta = "api/katalog/\(h.id)"
        let zadost = try JSONSerialization.data(withJSONObject: ["otisk": h.otisk, "mime": mime, "bajty": data.count])
        let (d1, k1) = try await posli(pozadavek("\(cesta)/nahrat", metoda: "POST", telo: zadost))
        guard (200..<300).contains(k1) else {
            // 413 kvóta, 422 typ nebo velikost: karta půjde bez obsahu.
            if k1 == 413 || k1 == 422 { throw ChybaServeru.obsahNeprosel("nahrat \(k1)") }
            throw Self.chybaHlaseni(d1, k1)
        }
        let odp = (try? JSONSerialization.jsonObject(with: d1)) as? [String: Any] ?? [:]
        guard let ulozeno = odp["ulozeno"] as? String else { throw ChybaServeru.obsahNeprosel("bez ulozeno") }
        if odp["uz_nahrano"] as? Bool != true {
            guard let adresa = (odp["upload_url"] as? String).flatMap(URL.init(string:)), adresa.scheme == "https" else {
                throw ChybaServeru.obsahNeprosel("bez adresy")
            }
            // Úložiště dostane jen bajty a hlavičky, které řekl server. Token
            // Airine a id zařízení sem nejdou.
            var put = URLRequest(url: adresa, timeoutInterval: 60)
            put.httpMethod = (odp["method"] as? String) ?? "PUT"
            for (k, v) in (odp["headers"] as? [String: String]) ?? ["Content-Type": mime] { put.setValue(v, forHTTPHeaderField: k) }
            put.httpBody = data
            let kod: Int
            do { kod = ((try await session.data(for: put)).1 as? HTTPURLResponse)?.statusCode ?? 0 }
            catch is URLError { throw ChybaServeru.bezSpojeni }
            guard (200..<300).contains(kod) else { throw ChybaServeru.obsahNeprosel("úložiště \(kod)") }
        }
        var telo = (try JSONSerialization.jsonObject(with: JSONEncoder().encode(h)) as? [String: Any]) ?? [:]
        telo["ulozeno"] = ulozeno
        let (d2, k2) = try await posli(pozadavek("\(cesta)/potvrdit", metoda: "POST",
                                                 telo: try JSONSerialization.data(withJSONObject: telo)))
        guard (200..<300).contains(k2) else {
            // Bajty nesedí s otiskem nebo zmizely z úložiště: obsah, ne karta.
            if k2 == 422, let o = try? JSONDecoder().decode(Odmitnuti.self, from: d2),
               o.chyby.contains(where: { ["ulozeno", "otisk"].contains($0.pole) && ["nesedi", "chybi"].contains($0.kod ?? "") }) {
                throw ChybaServeru.obsahNeprosel("potvrdit \(o.chyby.map(\.pole))")
            }
            throw Self.chybaHlaseni(d2, k2)
        }
        return try JSONDecoder().decode(OdpovedHlaseni.self, from: d2)
    }

    public func nahrajDavku(_ soubory: [SouborDavky]) async throws -> [VysledekDavky] {
        let polozky: [[String: Any]] = try soubory.map { f in
            var p = (try JSONSerialization.jsonObject(with: JSONEncoder().encode(f.hlaseni)) as? [String: Any]) ?? [:]
            p["mime"] = f.mime
            p["obsah"] = f.obsah
            return p
        }
        let telo = try JSONSerialization.data(withJSONObject: ["soubory": polozky])
        var r = pozadavek("api/katalog/obsah-davka", metoda: "POST", telo: telo)
        r.timeoutInterval = 60
        let (data, kod) = try await posli(r)
        switch kod {
        case 200..<300:
            let v = try JSONDecoder().decode([String: [VysledekDavky]].self, from: data)["vysledky"] ?? []
            guard v.count == soubory.count else { throw Self.neocekavany(data, kod) }
            return v
        case 413: throw ChybaServeru.davkaVelka
        case 403: throw ChybaServeru.neprihlasen
        default: throw Self.chybaHlaseni(data, kod)
        }
    }

    public func nastaveniImportu() async throws -> NastaveniImportu {
        let (data, kod) = try await posli(pozadavek("api/katalog/import"))
        guard (200..<300).contains(kod) else { throw Self.neocekavany(data, kod) }
        let json = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
        return NastaveniImportu(pravidla: PravidlaSlozek.zeServeru(json), stropy: StropyDavky.zeServeru(json))
    }

    public func zmizela(_ mista: [ZmizeleMisto]) async throws -> Int {
        let telo = try JSONEncoder().encode(["mista": mista])
        let (data, kod) = try await posli(pozadavek("api/katalog/mista/zmizela", metoda: "POST", telo: telo))
        guard (200..<300).contains(kod) else { throw Self.neocekavany(data, kod) }
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["zmizelo"] as? Int ?? 0
    }

    public func archiv(karty: [String], archivovat: Bool) async throws -> Int {
        let telo = try JSONSerialization.data(withJSONObject: ["karty": karty, "archivovat": archivovat])
        let (data, kod) = try await posli(pozadavek("api/katalog/archiv", metoda: "POST", telo: telo))
        switch kod {
        case 200..<300:
            return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["zmeneno"] as? Int ?? 0
        case 403: throw ChybaServeru.bezPravaKarty
        case 422: throw ChybaServeru.odmitnuto(Odmitnuti(chyby: [ChybaPole(pole: "karty", zprava: "neplatné id karty", kod: "tvar")]))
        default: throw Self.neocekavany(data, kod)
        }
    }
}
