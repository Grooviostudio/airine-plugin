import Foundation

/// Ze souboru na disku udělá hlášení a zařadí ho do fronty. Neposílá nic po
/// síti — volá se z hooku po úpravě souboru a musí doběhnout hned.
public struct Nahlasovani: Sendable {
    let kopie: Kopie
    /// Posílat odkazy ze souboru. Vypnuto, dokud server pole `odkazy` nepřijímá.
    public var odkazy: Bool
    /// Složky pro Znalosti (`Nastaveni.slozky`); `nil` = bez omezení.
    public var slozky: [String]?
    /// Id tohohle zařízení: soubor bez id v hlavičce se páruje jen s místy z něj.
    public var zarizeni: String?
    /// Jen zjistit, co by se stalo: nic nezařadí, nic nezapíše (`airine porovnej --zkouska`).
    public var zkouska = false

    public init(kopie: Kopie, odkazy: Bool = false, slozky: [String]? = nil, zarizeni: String? = nil, zkouska: Bool = false) {
        self.kopie = kopie; self.odkazy = odkazy; self.slozky = slozky; self.zarizeni = zarizeni; self.zkouska = zkouska
    }

    /// Které soubory se hlásí: MD a skills. Ostatní hook tiše přeskočí.
    public static func hlasitelny(_ cesta: String) -> Bool {
        let p = cesta.lowercased()
        return p.hasSuffix(".md") || p.hasSuffix(".mdc")
    }

    public enum Vysledek: Equatable, Sendable {
        /// `rada`: co může agent doplnit (popis); hlášení na tom nezávisí.
        case zarazeno(id: String, otisk: String, rada: String? = nil)
        case beze_zmeny
        case preskoceno(String)
        /// Hlavička uvádí jméno ve tvaru, který server nepřijme. Plugin nic
        /// nehlásí ani nepíše; opraví to agent nebo člověk.
        case bezKarty(chybi: [String], navrhJmena: String?)

        /// Text pro agenta: co doplnit do hlavičky, aby soubor dostal kartu.
        public var proAgenta: String? {
            if case .zarazeno(_, _, let rada) = self { return rada }
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

    /// `doplnId`: když soubor má hlavičku `airine:` (u SKILL.md `metadata:`
    /// s `airine-*`) bez trvalého id, plugin ho vygeneruje a zapíše do souboru.
    /// Soubor bez naší hlavičky dostane kartu taky (jako import složky), ale
    /// plugin do něj nepíše nic: id drží jen v místní kopii podle cesty.
    /// Hlídání složek volá `doplnId: false`, aby nepsalo pod rukama editoru.
    @discardableResult
    public func nahlas(cesta: String, doplnId: Bool = true) throws -> Vysledek {
        guard Self.hlasitelny(cesta) else { return .preskoceno("není MD") }
        // Mimo vybrané složky plugin soubor ani nečte: žádná karta, žádná rada agentovi.
        if let slozky, let proc = Slozky.duvod(cesta, slozky) { return .preskoceno(proc) }
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
        let pole = h.karta(skillSouborem: skill)
        // Naše hlavička = blok `airine:` nebo `airine-*` v metadata. Cizí
        // `name:`/`description:` bez ní nejsou naše (jako import složky);
        // u SKILL.md jsou to standardní pole skillu a platí.
        let nase = !h.blok.isEmpty || !h.meta.isEmpty
        // Jméno, které hlavička uvádí ve špatném tvaru, plugin nepřepisuje:
        // poradí agentovi a nehlásí (karta by se s hlavičkou rozešla).
        if (nase || skill), let j = pole.name, !j.isEmpty, !Self.jePlatneJmeno(j) {
            return .bezKarty(chybi: ["name"], navrhJmena: Self.kebab(j))
        }

        var id = pole.id
        var podleCesty = false
        if id == nil {
            if nase && doplnId && !zkouska {
                let nove = UUID().uuidString.lowercased()
                let upraveny = Hlavicka.vlozId(obsah, id: nove, skill: pole.skill)
                // Zápis jen když se soubor mezitím nezměnil (agent mohl psát dál).
                guard (try? Data(contentsOf: url)) == data else { return .preskoceno("soubor se mezitím změnil") }
                try Data(upraveny.utf8).write(to: url, options: .atomic)
                obsah = upraveny
                data = Data(upraveny.utf8)
                h = Hlavicka.precti(obsah)
                id = nove
            } else {
                id = try idPodleCesty(url.path, otisk: Otisk.sha256(data))
                podleCesty = true
            }
        }
        guard let id else { return .preskoceno("bez id") }
        if try kopie.jeSmazana(id) {
            return .preskoceno(podleCesty ? "karta je v Airine smazaná"
                               : "karta je v Airine smazaná; chceš-li ji znovu, smaž z hlavičky id a ulož")
        }

        let otisk = Otisk.sha256(data)
        var otisky = try kopie.stav("otisky", [String: String].self) ?? [:]
        // Předchozí verze = poslední, kterou odsud plugin nahlásil, jinak
        // poslední známá ze serveru. Podle ní server pozná rozpor.
        let znamaKarta = try kopie.karta(id)
        let predchozi = otisky[id] ?? znamaKarta?.otisk
        // Táž verze na nové cestě (přesun) se hlásí znovu: server přidá místo.
        let cestaZnama = try kopie.stav("cesty", [String: String].self)?[url.path] == id
            || znamaKarta.map { k in (k.mista ?? []).contains { $0.cesta == url.path } || k.mista == nil } ?? true
        if predchozi == otisk && cestaZnama {
            if podleCesty && !zkouska { try zapamatujCestu(url.path, id) }
            return .beze_zmeny
        }

        let propojeny = try kopie.projekt(pro: url.deletingLastPathComponent().path)
        var k = h.karta(skillSouborem: skill)
        if !nase && !k.skill { k.name = nil; k.popis = nil }
        // Co hlavička neříká: u známé karty platí, co má karta (popis, typ a vazby
        // z Airine se novou verzí nemažou), jinak se to odvodí z cesty jako
        // u importu. Popis se nevymýšlí, karta bez popisu je v pořádku.
        let znama = znamaKarta?.bez_prava == true ? nil : znamaKarta
        let jmeno = (k.name?.isEmpty == false ? k.name : nil) ?? znama?.name ?? Self.jmenoZCesty(url.path)
        let typ = k.typ ?? znama?.typ ?? Self.typZCesty(url.path, koren: korenSlozek(url.path))
        let popis = k.popis ?? znama?.popis ?? ""
        let projekt = k.projekt ?? znama?.projekt_id ?? propojeny
        let vazby = odkazy ? Odkazy.zeSouboru(obsah, url: url, koren: try kopie.koren(pro: url.path).map { URL(fileURLWithPath: $0) }) : nil
        let hl = Hlaseni(
            id: id,
            name: jmeno,
            popis: popis,
            typ: typ,
            klient_id: k.klient ?? znama?.klient_id,
            projekt_id: projekt,
            slozka_id: h.airine["slozka"] ?? znama?.slozka_id,
            fakta: k.fakta ?? znama?.fakta,
            nahrazuje: k.nahrazuje ?? znama?.nahrazuje,
            vychazi_z: k.vychazi_z ?? znama?.vychazi_z,
            cesta: url.path,
            otisk: otisk,
            otisk_predchozi: predchozi,
            radku: obsah.split(separator: "\n", omittingEmptySubsequences: false).count,
            bajty: data.count,
            hlavicka: h.text,
            odkazy: vazby?.odkazy,
            odkazy_oriznuto: vazby?.oriznuto == true ? true : nil
        )
        if !zkouska {
            try kopie.zaradit(hl)
            otisky[id] = otisk
            try kopie.nastavStav("otisky", otisky)
            if podleCesty { try zapamatujCestu(url.path, id) }
        }
        var rada: String?
        if popis.trimmingCharacters(in: .whitespaces).isEmpty {
            rada = "Airine: soubor je v katalogu jako „\(jmeno)“, zatím bez popisu (doplní se v Airine v Revizi)."
            if !skill { rada! += " Chceš-li, přidej hlavičku airine: s polem popis (jednou větou, k čemu soubor je); plugin ji při dalším uložení převezme." }
        }
        return .zarazeno(id: id, otisk: otisk, rada: rada)
    }

    // MARK: soubor bez id v hlavičce

    /// Id souboru, který ho v hlavičce nemá: podle cesty (místní paměť, pak
    /// místa karet tohohle zařízení), pak podle otisku u karty, jejíž soubor
    /// na tomhle Macu zmizel (přesun), jinak nové. Do souboru se nepíše.
    func idPodleCesty(_ cesta: String, otisk: String) throws -> String {
        if let id = try kopie.stav("cesty", [String: String].self)?[cesta] { return id }
        let karty = try kopie.karty().filter { $0.smazano != true && $0.bez_prava != true }
        let moje = { (m: Misto) in zarizeni == nil || m.zarizeni_id == nil || m.zarizeni_id == zarizeni }
        if let k = karty.first(where: { ($0.mista ?? []).contains { moje($0) && $0.cesta == cesta } }) { return k.id }
        let presunuta = karty.filter { k in
            k.otisk == otisk && !k.archivovana
                && (k.mista ?? []).contains { moje($0) && ($0.cesta ?? "").hasPrefix("/") }
                && !(k.mista ?? []).contains { moje($0) && FileManager.default.fileExists(atPath: $0.cesta ?? "") }
        }
        // Víc kandidátů = nehádá se (jako server u převzetí).
        if presunuta.count == 1 { return presunuta[0].id }
        return UUID().uuidString.lowercased()
    }

    func zapamatujCestu(_ cesta: String, _ id: String) throws {
        var c = try kopie.stav("cesty", [String: String].self) ?? [:]
        guard c[cesta] != id else { return }
        c[cesta] = id
        try kopie.nastavStav("cesty", c)
    }

    /// Nejhlubší vybraná složka, ve které soubor leží.
    func korenSlozek(_ cesta: String) -> String? {
        (slozky ?? []).map(Slozky.normalizuj).filter { cesta.hasPrefix($0 + "/") }.max { $0.count < $1.count }
    }

    /// Jméno karty z cesty jako import složky: slug názvu souboru, u SKILL.md
    /// název jeho složky.
    public static func jmenoZCesty(_ cesta: String) -> String {
        let u = URL(fileURLWithPath: cesta)
        let zaklad = u.lastPathComponent.lowercased() == "skill.md" ? u.deletingLastPathComponent().lastPathComponent
                                                                     : u.deletingPathExtension().lastPathComponent
        return kebab(zaklad) ?? "soubor"
    }

    /// Typ podle slov v cestě pod vybranou složkou, stejná tabulka jako import
    /// složky (`ZNI_TYPY` v public/znalosti-import.js). Pořadí = priorita.
    static let typyZCesty: [(String, String)] = [
        ("brief", "(^|-)brief"),
        ("nabidka", "(^|-)(nabidk|offer|proposal)"),
        ("postup", "(^|-)(postup|navod|how-?to|guide)"),
        ("zapis", "(^|-)(zapis|meeting|minutes)"),
        ("sablona", "(^|-)(sablon|template)"),
    ]

    public static func typZCesty(_ cesta: String, koren: String?) -> String {
        if URL(fileURLWithPath: cesta).lastPathComponent.lowercased() == "skill.md" { return "skill" }
        let rel = koren.map { String(cesta.dropFirst($0.count + 1)) } ?? URL(fileURLWithPath: cesta).lastPathComponent
        let bezPripony = (rel as NSString).deletingPathExtension
        let s = kebab(bezPripony.replacingOccurrences(of: "/", with: " ")) ?? ""
        return typyZCesty.first { s.range(of: $0.1, options: .regularExpression) != nil }?.0 ?? "poznamky"
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
