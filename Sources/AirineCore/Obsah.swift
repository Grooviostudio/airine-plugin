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

    /// Bajty souboru, jen když na disku leží přesně verze `otisk`.
    public static func nacti(cesta: String, otisk: String) -> (data: Data, mime: String)? {
        guard let mime = mime(cesta),
              let atributy = try? FileManager.default.attributesOfItem(atPath: cesta),
              (atributy[.type] as? FileAttributeType) == .typeRegular,
              let velikost = atributy[.size] as? Int, velikost > 0, velikost <= maxBajtu,
              let data = try? Data(contentsOf: URL(fileURLWithPath: cesta)),
              Otisk.sha256(data) == otisk.lowercased() else { return nil }
        return (data, mime)
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
            guard let (cesta, obsah) = existuje.lazy.compactMap({ c in nacti(cesta: c, otisk: k.otisk!).map { (c, $0) } }).first,
                  let h = hlaseni(k, cesta: cesta, data: obsah.data) else { v.jinaVerze += 1; continue }
            if zkouska { v.nahrano += 1; continue }
            do {
                _ = try await api.nahrajObsah(h, data: obsah.data, mime: obsah.mime)
                v.nahrano += 1
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
