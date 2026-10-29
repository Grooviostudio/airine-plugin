import Foundation

/// Rozhraní k Airine. Protokol kvůli testům (MockServer) a kvůli tomu, že
/// routy kroku 1 ještě nejsou na stagingu.
public protocol AirineAPI: Sendable {
    func zmeny(od kurzor: String?, limit: Int) async throws -> Zmeny
    func nahlas(_ h: Hlaseni) async throws -> OdpovedHlaseni
    /// Archiv karet (POST /api/katalog/archiv): všechno, nebo nic. Vrací počet změněných.
    func archiv(karty: [String], archivovat: Bool) async throws -> Int
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

    func posli(_ r: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, odp) = try await session.data(for: r)
            let kod = (odp as? HTTPURLResponse)?.statusCode ?? 0
            switch kod {
            case 500..<600, 0: throw ChybaServeru.bezSpojeni
            case 401: throw ChybaServeru.neprihlasen
            default: return (data, kod)
            }
        } catch is URLError {
            throw ChybaServeru.bezSpojeni
        }
    }

    static func neocekavany(_ data: Data, _ kod: Int) -> ChybaServeru {
        .jine(kod, String(decoding: data.prefix(300), as: UTF8.self))
    }

    /// Stavy hlášení: tělo nese vždy `{stav, id, …}`, 401 jen kvůli tokenu.
    static func chybaHlaseni(_ data: Data, _ kod: Int) -> ChybaServeru {
        let telo = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
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
