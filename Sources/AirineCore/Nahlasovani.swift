import Foundation

/// Ze souboru na disku udělá hlášení a zařadí ho do fronty. Neposílá nic po
/// síti — volá se z hooku po úpravě souboru a musí doběhnout hned.
public struct Nahlasovani: Sendable {
    let kopie: Kopie
    /// Posílat odkazy ze souboru. Vypnuto, dokud server pole `odkazy` nepřijímá.
    public var odkazy: Bool

    public init(kopie: Kopie, odkazy: Bool = false) { self.kopie = kopie; self.odkazy = odkazy }

    /// Které soubory se hlásí: MD a skills. Ostatní hook tiše přeskočí.
    public static func hlasitelny(_ cesta: String) -> Bool {
        let p = cesta.lowercased()
        return p.hasSuffix(".md") || p.hasSuffix(".mdc")
    }

    public enum Vysledek: Equatable, Sendable {
        case zarazeno(id: String, otisk: String)
        case beze_zmeny
        case preskoceno(String)
        /// Hlavičce chybí, bez čeho server kartu nepřijme (name, typ, popis).
        /// Plugin nic nehlásí ani nepíše; doplní to agent nebo člověk.
        case bezKarty(chybi: [String], navrhJmena: String?)

        /// Text pro agenta: co doplnit do hlavičky, aby soubor dostal kartu.
        public var proAgenta: String? {
            guard case .bezKarty(let chybi, let navrh) = self else { return nil }
            var t = "Airine: soubor zatím nemá kartu, v hlavičce (front matter) chybí: \(chybi.joined(separator: ", "))."
            if let navrh { t += " Návrh jména: name: \(navrh)" }
            return t + " Doplň hlavičku a soubor ulož, plugin ho pak nahlásí."
        }
    }

    /// Jméno karty podle pravidla serveru: `^[a-z0-9]+(-[a-z0-9]+)*$`, nejvýš
    /// 64 znaků, bez diakritiky. Jen návrh do hlavičky, do hlášení nikdy
    /// (jméno je identita karty a nesmí se rozejít s hlavičkou).
    public static func kebab(_ s: String) -> String? {
        let bez = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en"))
            .lowercased()
        var r = "", pomlcka = false
        for ch in bez.unicodeScalars {
            if ("a"..."z").contains(ch) || ("0"..."9").contains(ch) { r.unicodeScalars.append(ch); pomlcka = false }
            else if !pomlcka && !r.isEmpty { r += "-"; pomlcka = true }
        }
        while r.hasSuffix("-") { r.removeLast() }
        if r.count > 64 { r = String(r.prefix(64)); while r.hasSuffix("-") { r.removeLast() } }
        return r.isEmpty ? nil : r
    }

    /// První řádek `<!-- airine vlastnik=… -->`.
    static func maWatermark(_ obsah: String) -> Bool {
        let prvni = obsah.prefix { $0 != "\n" && $0 != "\r\n" }
        return prvni.hasPrefix("<!-- airine ") && prvni.contains("vlastnik=")
    }

    static func jePlatneJmeno(_ s: String) -> Bool {
        s.count <= 64 && s.range(of: "^[a-z0-9]+(-[a-z0-9]+)*$", options: .regularExpression) != nil
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
        // Dokument z repa s watermarkem na prvním řádku má vlastníka a historii
        // v gitu, ne front matter: plugin ho nehlásí, nic do něj nepíše a agentovi
        // nic neradí.
        if Self.maWatermark(obsah) { return .preskoceno("dokument s watermarkem") }
        let skill = url.lastPathComponent == "SKILL.md"

        var h = Hlavicka.precti(obsah)
        // Server bez jména, typu a popisu kartu nepřijme (u SKILL.md je typ
        // `skill`). Takový soubor se nehlásí a nedostane ani id.
        let pole = h.karta(skillSouborem: skill)
        let jmeno = pole.name
        var chybi: [String] = []
        if jmeno.map(Self.jePlatneJmeno) != true { chybi.append("name") }
        if pole.typ == nil { chybi.append("airine.typ") }
        if (pole.popis ?? "").trimmingCharacters(in: .whitespaces).isEmpty { chybi.append(pole.skill ? "description" : "airine.popis (nebo description)") }
        if !chybi.isEmpty {
            let zdroj = (jmeno?.isEmpty == false ? jmeno : nil) ?? (skill ? url.deletingLastPathComponent().lastPathComponent : url.deletingPathExtension().lastPathComponent)
            return .bezKarty(chybi: chybi, navrhJmena: chybi.contains("name") ? Self.kebab(zdroj) : nil)
        }
        var id = pole.id
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
        let k = h.karta(skillSouborem: skill)
        let projekt = k.projekt ?? propojeny
        let vazby = odkazy ? Odkazy.zeSouboru(obsah, url: url, koren: try kopie.koren(pro: url.path).map { URL(fileURLWithPath: $0) }) : nil
        let hl = Hlaseni(
            id: id,
            name: jmeno,
            popis: k.popis,
            typ: k.typ,
            klient_id: k.klient,
            projekt_id: projekt,
            slozka_id: h.airine["slozka"],
            fakta: k.fakta,
            nahrazuje: k.nahrazuje,
            vychazi_z: k.vychazi_z,
            cesta: url.path,
            otisk: otisk,
            otisk_predchozi: predchozi,
            radku: obsah.split(separator: "\n", omittingEmptySubsequences: false).count,
            bajty: data.count,
            hlavicka: h.text,
            odkazy: vazby?.odkazy,
            odkazy_oriznuto: vazby?.oriznuto == true ? true : nil
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
