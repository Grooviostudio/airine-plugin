import Foundation

/// Ze souboru na disku udělá hlášení a zařadí ho do fronty. Neposílá nic po
/// síti — volá se z hooku po úpravě souboru a musí doběhnout hned.
public struct Nahlasovani: Sendable {
    let kopie: Kopie
    let zarizeni: String

    public init(kopie: Kopie, zarizeni: String) { self.kopie = kopie; self.zarizeni = zarizeni }

    /// Které soubory se hlásí: MD a skills. Ostatní hook tiše přeskočí.
    public static func hlasitelny(_ cesta: String) -> Bool {
        let p = cesta.lowercased()
        return p.hasSuffix(".md") || p.hasSuffix(".mdc")
    }

    public enum Vysledek: Equatable, Sendable {
        case zarazeno(id: String, otisk: String)
        case beze_zmeny
        case preskoceno(String)
    }

    /// `doplnId`: když hlavička nemá trvalé id, plugin ho vygeneruje a zapíše
    /// do souboru (bez id by soubor neměl identitu, dokud není spojení).
    @discardableResult
    public func nahlas(cesta: String, doplnId: Bool = true) throws -> Vysledek {
        guard Self.hlasitelny(cesta) else { return .preskoceno("není MD") }
        let url = URL(fileURLWithPath: cesta).standardizedFileURL
        var data = try Data(contentsOf: url)
        guard data.count <= 1_048_576 else { return .preskoceno("nad 1 MB") }
        guard var obsah = String(data: data, encoding: .utf8) else { return .preskoceno("není UTF-8") }
        let skill = url.lastPathComponent == "SKILL.md"

        var h = Hlavicka.precti(obsah)
        var id = h.airine["id"]
        if id == nil {
            guard doplnId else { return .preskoceno("bez id v hlavičce") }
            let nove = UUID().uuidString.lowercased()
            let upraveny = Hlavicka.vlozId(obsah, id: nove, skill: skill)
            // Zápis jen když se soubor mezitím nezměnil (agent mohl psát dál).
            guard (try? Data(contentsOf: url)) == data else { return .preskoceno("soubor se mezitím změnil") }
            try Data(upraveny.utf8).write(to: url, options: .atomic)
            obsah = upraveny
            data = Data(upraveny.utf8)
            h = Hlavicka.precti(obsah)
            id = nove
        }
        guard let id else { return .preskoceno("bez id") }
        if try kopie.jeSmazana(id) {
            return .preskoceno("karta je v Airine smazaná; chceš-li ji znovu, smaž z hlavičky id a ulož")
        }

        let otisk = Otisk.sha256(data)
        var otisky = try kopie.stav("otisky", [String: String].self) ?? [:]
        // Předchozí verze = poslední, kterou odsud plugin nahlásil, jinak
        // poslední známá ze serveru. Podle ní server pozná rozpor.
        let znama = try kopie.karta(id)?.otisk
        let predchozi = otisky[id] ?? znama
        if predchozi == otisk { return .beze_zmeny }

        let propojeny = try kopie.projekt(pro: url.deletingLastPathComponent().path)
        let projekt = h.airine["projekt"] ?? propojeny
        let fakta = h.airine.filter { $0.key.hasPrefix("fakt_") }
            .map { Fakt(klic: String($0.key.dropFirst(5)), hodnota: $0.value) }.sorted { $0.klic < $1.klic }
        let hl = Hlaseni(
            id: id,
            name: h.nahore["name"] ?? url.deletingPathExtension().lastPathComponent,
            popis: h.nahore["description"],
            typ: h.airine["typ"] ?? (skill ? "skill" : nil),
            klient_id: h.airine["klient"],
            projekt_id: projekt,
            slozka_id: h.airine["slozka"],
            fakta: fakta.isEmpty ? nil : fakta,
            nahrazuje: h.airine["nahrazuje"],
            vychazi_z: h.seznamy["vychazi_z"],
            vlastnik: h.airine["vlastnik"],
            misto: Misto(druh: "zarizeni", zarizeni: zarizeni, cesta: url.path),
            otisk: otisk,
            otisk_predchozi: predchozi,
            radku: obsah.split(separator: "\n", omittingEmptySubsequences: false).count,
            bajty: data.count,
            hlavicka: h.text
        )
        try kopie.zaradit(hl)
        otisky[id] = otisk
        try kopie.nastavStav("otisky", otisky)
        return .zarazeno(id: id, otisk: otisk)
    }

    /// Rozpor se vyřeší tak, že další verze naváže na verzi serveru (stáhni,
    /// slouč, nahlas). Volá se až po sloučení — samo by přepsalo cizí změnu.
    public func vyresRozpor(id: String) throws {
        guard let serverovy = try kopie.karta(id)?.otisk else { return }
        var otisky = try kopie.stav("otisky", [String: String].self) ?? [:]
        otisky[id] = serverovy
        try kopie.nastavStav("otisky", otisky)
    }
}
