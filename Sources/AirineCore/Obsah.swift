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
    public static func dohon(kopie: Kopie, api: AirineAPI, koreny: [URL] = [], zkouska: Bool = false) async throws -> Dohnani {
        var v = Dohnani()
        let karty = try kopie.karty().filter { $0.smazano != true && $0.bez_prava != true && !$0.archivovana && $0.neniVAirine && $0.otisk != nil }
        for (i, k) in karty.enumerated() {
            if k.menit == false { v.bezPrava += 1; continue }
            let cesty = (k.mista ?? []).compactMap(\.cesta).flatMap { naDisku($0, koreny: koreny) }
            let existuje = cesty.filter { FileManager.default.fileExists(atPath: $0) }
            guard !existuje.isEmpty else { v.bezSouboru += 1; continue }
            let vysledky = existuje.map { c in (c, zkontroluj(cesta: c, otisk: k.otisk!)) }
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
            do {
                _ = try await api.nahrajObsah(h, data: obsah.data, mime: obsah.mime)
                v.nahrano += 1
                v.soubory.append(cesta)
                var ulozena = k
                ulozena.ulozeny_otisk = k.otisk
                try kopie.ulozKarty([ulozena])
            } catch ChybaServeru.bezPravaKarty {
                v.bezPrava += 1
            } catch ChybaServeru.bezSpojeni {
                v.online = false; v.zbyva = karty.count - i; return v
            } catch ChybaServeru.neprihlasen {
                v.neprihlasen = true; v.zbyva = karty.count - i; return v
            } catch {
                v.chyby.append(k.id)
            }
        }
        return v
    }
}
