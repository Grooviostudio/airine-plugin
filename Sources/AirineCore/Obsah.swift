import Foundation

/// Obsah souboru do Airine (`/nahrat` → PUT → `/potvrdit` na serveru), aby
/// ho četli i kolegové bez souboru. Posílá se jen přesně ta verze, kterou
/// karta popisuje: otisk bajtů na disku musí sedět, jinak plugin pošle jen
/// kartu jako dřív. Vypíná se v nastavení (`airine obsah ne`).
public enum Obsah {
    /// Strop serveru (`MAX_BAJTU` v lib/katalog.js).
    public static let maxBajtu = 1_048_576

    /// Typy, které server přijme (`TYPY_KATALOGU` v lib/katalog.js), podle přípony.
    static let typy: [String: String] = [
        "md": "text/markdown", "mdc": "text/markdown", "markdown": "text/markdown",
        "txt": "text/plain", "csv": "text/csv", "json": "application/json",
        "yaml": "application/yaml", "yml": "application/yaml",
    ]

    public static func mime(_ cesta: String) -> String? {
        typy[URL(fileURLWithPath: cesta).pathExtension.lowercased()]
    }

    /// Proč obsah souboru neodejde. Karta jde vždy, bez obsahu.
    public enum Duvod: String, Error, Sendable {
        case typ          // přípona, kterou server nebere
        case velky        // prázdný nebo nad strop
        case jinaVerze    // bajty na disku nesedí s otiskem karty
        case tajne        // vypadá to na klíč, heslo nebo token
    }

    /// Bajty souboru, jen když na disku leží přesně verze `otisk` a není
    /// v ní nic, co vypadá na tajemství.
    public static func zkontroluj(cesta: String, otisk: String) -> Result<(data: Data, mime: String), Duvod> {
        guard let mime = mime(cesta) else { return .failure(.typ) }
        guard let atributy = try? FileManager.default.attributesOfItem(atPath: cesta),
              (atributy[.type] as? FileAttributeType) == .typeRegular,
              let velikost = atributy[.size] as? Int else { return .failure(.jinaVerze) }
        guard velikost > 0, velikost <= maxBajtu else { return .failure(.velky) }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: cesta)),
              Otisk.sha256(data) == otisk.lowercased() else { return .failure(.jinaVerze) }
        guard tajemstvi(data).isEmpty else { return .failure(.tajne) }
        return .success((data, mime))
    }

    public static func nacti(cesta: String, otisk: String) -> (data: Data, mime: String)? {
        try? zkontroluj(cesta: cesta, otisk: otisk).get()
    }

    /// Leží cesta pod některým vzorem z `airine vynech`? Vzor „/…“ nebo „~/…“
    /// je začátek cesty, jiný sedí na celé složky kdekoli v ní; „**/“ na
    /// začátku se ignoruje. Porovnává se po celých složkách, ne po znacích.
    public static func vynechano(_ cesta: String, _ vzory: [String]) -> Bool {
        let c = "/" + cesta.split(separator: "/").joined(separator: "/") + "/"
        return vzory.contains { vzor in
            var v = vzor.hasPrefix("**/") ? String(vzor.dropFirst(3)) : vzor
            if v.hasPrefix("~") { v = (v as NSString).expandingTildeInPath }
            let usek = v.split(separator: "/").joined(separator: "/")
            guard !usek.isEmpty else { return false }
            return v.hasPrefix("/") ? c.hasPrefix("/" + usek + "/") : c.contains("/" + usek + "/")
        }
    }

    /// Vzory klíčů, hesel a tokenů. Raději soubor navíc bez obsahu než
    /// tajemství v Airine: slovo „token“ samo nevadí, vadí s hodnotou.
    static let vzory: [(String, NSRegularExpression)] = [
        ("sk-", #"\bsk-[A-Za-z0-9_-]{20,}"#),
        ("airine_", #"\bairine_[0-9a-f]{40}\b"#),
        ("github", #"\bgh[pousr]_[A-Za-z0-9]{30,}"#),
        ("aws", #"\bAKIA[0-9A-Z]{16}\b"#),
        ("klíč s hodnotou", #"(?i)\b(api[_-]?key|apikey|secret|client[_-]?secret|password|passwd|heslo|token|access[_-]?key)\b["']?\s*[:=]\s*["']?[A-Za-z0-9_\-+/=.]{12,}"#),
        ("PRIVATE KEY", #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#),
        ("Bearer", #"\bBearer\s+[A-Za-z0-9._~+/-]{20,}"#),
        ("JWT", #"\beyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#),
        ("dlouhé base64", #"[A-Za-z0-9+/]{80,}={0,2}"#),
    ].map { ($0.0, try! NSRegularExpression(pattern: $0.1)) }

    /// Názvy vzorů, které v textu sedí.
    public static func tajemstvi(_ data: Data) -> [String] {
        let text = String(decoding: data, as: UTF8.self)
        let rozsah = NSRange(text.startIndex..., in: text)
        return vzory.filter { $0.1.firstMatch(in: text, range: rozsah) != nil }.map(\.0)
    }

    /// Cesta místa na disku tohohle Macu. Relativní cesty (import z prohlížeče)
    /// se zkusí proti kořenům; z kořene se vyjít nesmí.
    static func naDisku(_ cesta: String, koreny: [URL]) -> [String] {
        if cesta.hasPrefix("/") { return [URL(fileURLWithPath: cesta).standardizedFileURL.path] }
        return koreny.compactMap { k in
            let koren = k.standardizedFileURL.path
            let p = k.appendingPathComponent(cesta).standardizedFileURL.path
            return p.hasPrefix(koren + "/") ? p : nil
        }
    }

    static func radku(_ data: Data) -> Int {
        let text = String(decoding: data, as: UTF8.self)
        return text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count - (text.hasSuffix("\n") ? 1 : 0)
    }

    /// Hlášení, které nemění nic než obsah: popis a vazby jsou ty, které karta
    /// v Airine už má. Server u téže verze jen přidá obsah (`katalog_hlaseni`).
    static func hlaseni(_ k: Karta, cesta: String, data: Data) -> Hlaseni? {
        guard let otisk = k.otisk else { return nil }
        return Hlaseni(id: k.id, name: k.name, popis: k.popis, typ: k.typ, klient_id: k.klient_id,
                       projekt_id: k.projekt_id, slozka_id: k.slozka_id, fakta: k.fakta,
                       nahrazuje: k.nahrazuje, vychazi_z: k.vychazi_z, cesta: cesta, otisk: otisk,
                       radku: radku(data), bajty: data.count)
    }

    public struct Dohnani: Sendable, Equatable {
        public var nahrano = 0              // obsah odešel do Airine
        public var bezSouboru = 0           // na tomhle Macu soubor není
        public var jinaVerze = 0            // soubor je, ale obsah se od karty liší
        public var velke = 0                // prázdný nebo nad 1 MB
        public var vynechano = 0            // pod vzorem z `airine vynech`
        public var mimoSlozky = 0           // mimo složky pro Znalosti
        public var jinyTyp = 0              // přípona, kterou server nebere
        public var tajne: [String] = []     // cesty, které vypadají na tajemství
        public var soubory: [String] = []   // cesty, jejichž obsah odešel (u zkoušky by odešel)
        public var bezPrava = 0
        public var chyby: [String] = []     // id karet, které neprošly
        public var online = true
        public var neprihlasen = false
        public var zbyva = 0                // karty, na které po výpadku nedošlo
    }

    /// Karty, jejichž obsah Airine nemá, a jejich bajty na tomhle Macu.
    /// Archivované a cizí karty přeskočí. `zkouska` jen spočítá, nic neposílá.
    /// `pauza` mezi soubory šetří úložiště serveru (to při rychlé dávce vrací 429).
    public static func dohon(kopie: Kopie, api: AirineAPI, koreny: [URL] = [], vynechat: [String] = [],
                             slozky: [String]? = nil, zkouska: Bool = false, pauza: Duration = .zero) async throws -> Dohnani {
        var v = Dohnani()
        let karty = try kopie.karty().filter { $0.smazano != true && $0.bez_prava != true && !$0.archivovana && $0.neniVAirine && $0.otisk != nil }
        // Soubory jdou po dávkách (POST /api/katalog/obsah-davka) do stropu serveru.
        // Server bez dávek, odmítnutá dávka nebo soubor, který není UTF-8: po jednom.
        let strop = kopie.stropyDavky()
        var davka: [Kandidat] = [], bajty = 0, poJednom = false

        func ulozeno(_ c: Kandidat) throws {
            v.nahrano += 1
            v.soubory.append(c.cesta)
            var ulozena = c.karta
            ulozena.ulozeny_otisk = c.karta.otisk
            try kopie.ulozKarty([ulozena])
        }
        /// Jeden soubor po staru. `true` = konec (výpadek, odhlášení).
        func jednotlive(_ c: Kandidat, zbyva: Int) async throws -> Bool {
            do {
                _ = try await api.nahrajObsah(c.hlaseni, data: c.data, mime: c.mime)
                try ulozeno(c)
                if pauza > .zero { try await Task.sleep(for: pauza) }
            } catch ChybaServeru.bezPravaKarty {
                v.bezPrava += 1
            } catch ChybaServeru.bezSpojeni {
                v.online = false; v.zbyva = zbyva; return true
            } catch ChybaServeru.neprihlasen {
                v.neprihlasen = true; v.zbyva = zbyva; return true
            } catch {
                v.chyby.append(c.karta.id)
            }
            return false
        }
        /// Odešle nasbíranou dávku. Přetížené soubory zkusí znovu po `retry_after`
        /// (nejvýš dvakrát), odmítnuté bez podrobností pošle po jednom.
        func odesli(zbyvaKaret: Int) async throws -> Bool {
            var zbyva = davka, kolo = 0
            davka = []; bajty = 0
            while !zbyva.isEmpty {
                let vysledky: [VysledekDavky]
                do {
                    vysledky = try await api.nahrajDavku(zbyva.map {
                        SouborDavky(hlaseni: $0.hlaseni, mime: $0.mime, obsah: String(decoding: $0.data, as: UTF8.self))
                    })
                } catch ChybaServeru.bezSpojeni {
                    v.online = false; v.zbyva = zbyvaKaret + zbyva.count; return true
                } catch ChybaServeru.neprihlasen {
                    v.neprihlasen = true; v.zbyva = zbyvaKaret + zbyva.count; return true
                } catch is ChybaServeru {              // 404, 413: dál po jednom
                    poJednom = true
                    for (j, c) in zbyva.enumerated() where try await jednotlive(c, zbyva: zbyvaKaret + zbyva.count - j) { return true }
                    return false
                }
                var pretizene: [Kandidat] = [], znovu: [Kandidat] = []
                var cekat = 0.0
                for (c, r) in zip(zbyva, vysledky) {
                    switch r.stav {
                    case "ok", "uz_prijato", "rozpor": try ulozeno(c)
                    case "pretizeno": pretizene.append(c); cekat = max(cekat, r.retry_after ?? 2)
                    case "bez_prava": v.bezPrava += 1
                    case "smazano": v.chyby.append(c.karta.id)
                    default: znovu.append(c)             // neplatne, chyba, neznámý stav
                    }
                }
                for (j, c) in znovu.enumerated() where try await jednotlive(c, zbyva: zbyvaKaret + pretizene.count + znovu.count - j) { return true }
                if pretizene.isEmpty { break }
                kolo += 1
                guard kolo <= 2 else { v.online = false; v.zbyva = zbyvaKaret + pretizene.count; return true }
                try await Task.sleep(for: .seconds(min(cekat, HttpAirine.nejdeleCekat)))
                zbyva = pretizene
            }
            if pauza > .zero { try await Task.sleep(for: pauza) }
            return false
        }

        for (i, k) in karty.enumerated() {
            if k.menit == false { v.bezPrava += 1; continue }
            let cesty = (k.mista ?? []).compactMap(\.cesta).flatMap { naDisku($0, koreny: koreny) }
            let naMacu = cesty.filter { FileManager.default.fileExists(atPath: $0) }
            guard !naMacu.isEmpty else { v.bezSouboru += 1; continue }
            let existuje = slozky.map { s in naMacu.filter { Slozky.duvod($0, s) == nil } } ?? naMacu
            guard !existuje.isEmpty else { v.mimoSlozky += 1; continue }
            guard existuje.contains(where: { !vynechano($0, vynechat) }) else { v.vynechano += 1; continue }
            let vysledky = existuje.filter { !vynechano($0, vynechat) }.map { c in (c, zkontroluj(cesta: c, otisk: k.otisk!)) }
            guard let (cesta, obsah) = vysledky.lazy.compactMap({ c, r in (try? r.get()).map { (c, $0) } }).first,
                  let h = hlaseni(k, cesta: cesta, data: obsah.data) else {
                // Tajemství má přednost: o takovém souboru se musí vědět.
                let duvody = vysledky.compactMap { c, r -> (String, Duvod)? in
                    if case .failure(let d) = r { return (c, d) }; return nil
                }
                if let t = duvody.first(where: { $0.1 == .tajne }) { v.tajne.append(t.0) }
                else {
                    switch duvody.first?.1 {
                    case .velky: v.velke += 1
                    case .typ: v.jinyTyp += 1
                    default: v.jinaVerze += 1
                    }
                }
                continue
            }
            if zkouska { v.nahrano += 1; v.soubory.append(cesta); continue }
            let c = Kandidat(karta: k, cesta: cesta, hlaseni: h, data: obsah.data, mime: obsah.mime)
            guard !poJednom, String(data: c.data, encoding: .utf8) != nil else {
                if try await jednotlive(c, zbyva: karty.count - i + davka.count) { return v }
                continue
            }
            if !davka.isEmpty && (davka.count >= strop.souboru || bajty + c.data.count + 4096 > strop.bajtu) {
                if try await odesli(zbyvaKaret: karty.count - i) { return v }
            }
            davka.append(c); bajty += c.data.count + 4096
        }
        if !davka.isEmpty, try await odesli(zbyvaKaret: 0) { return v }
        return v
    }

    /// Soubor připravený k odeslání: karta, cesta na disku a bajty té verze.
    struct Kandidat {
        var karta: Karta
        var cesta: String
        var hlaseni: Hlaseni
        var data: Data
        var mime: String
    }
}
