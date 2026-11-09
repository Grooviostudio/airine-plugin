import Foundation

/// Skilly firmy: karty typu `skill` ze Znalostí se stáhnou do
/// `~/.claude/skills/<name>/SKILL.md` a drží se aktuální podle otisku.
///
/// Pravidla:
/// - Kdo skill dostane, rozhoduje server (`cist` v kanálu změn). Plugin
///   vlastní logiku práv nemá.
/// - Plugin přepisuje a maže jen skilly, které sám vytvořil (evidence
///   v místní kopii), a jen když je člověk mezitím neupravil.
/// - Místní úprava se nepřepíše: odejde jako nová verze karty
///   (`otisk_predchozi` = poslední stažená), rozpor řeší server.
/// - Cizí složka se stejným jménem zůstane, jak je, a hlásí se jako kolize.
public struct Skilly: Sendable {
    let kopie: Kopie
    let api: AirineAPI
    /// Kam skilly patří (`~/.claude/skills`, v testech dočasná složka).
    let slozka: URL

    public init(kopie: Kopie, api: AirineAPI, slozka: URL = Skilly.vychoziSlozka) {
        self.kopie = kopie; self.api = api; self.slozka = slozka
    }

    /// `AIRINE_SKILLY` přepíše cestu (testy, zkouška na stagingu).
    public static var vychoziSlozka: URL {
        if let p = ProcessInfo.processInfo.environment["AIRINE_SKILLY"], !p.isEmpty {
            return URL(fileURLWithPath: (p as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/skills", isDirectory: true)
    }

    /// Skill, který plugin vytvořil. Jen tyhle smí přepsat nebo smazat.
    public struct Zaznam: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        /// Otisk poslední verze, kterou plugin zapsal nebo kterou server převzal.
        public var otisk: String
        public var cesta: String
    }

    public struct Vysledek: Equatable, Sendable {
        public var nove: [String] = []            // jména nově stažených skillů
        public var aktualizovane: [String] = []
        public var smazane: [String] = []
        public var nahlasene: [String] = []       // místní úprava odešla jako nová verze
        public var kolize: [String] = []          // složka stejného jména, kterou plugin nevytvořil
        public var ponechane: [String] = []       // skill už nemá být, ale člověk ho upravil
        public var rozpory: [String] = []         // místní úprava v rozporu se serverem
        /// Skill už leží na disku pod jiným jménem s `metadata.airine-id` téže
        /// karty (člověk ho tam dal sám). Plugin ho nespravuje a nezdvojuje.
        public var mistni: [String] = []
        public var chyby: [String] = []

        public var nic: Bool { self == Vysledek() }

        /// Krátká věta pro lištu a `airine sync`.
        public var shrnuti: String? {
            var c: [String] = []
            if !nove.isEmpty { c.append("nové \(nove.count)") }
            if !aktualizovane.isEmpty { c.append("aktualizované \(aktualizovane.count)") }
            if !smazane.isEmpty { c.append("odebrané \(smazane.count)") }
            if !nahlasene.isEmpty { c.append("místní úpravy odeslané \(nahlasene.count)") }
            if !rozpory.isEmpty { c.append("rozpor \(rozpory.joined(separator: ", "))") }
            if !kolize.isEmpty { c.append("jméno obsazené \(kolize.joined(separator: ", "))") }
            if !ponechane.isEmpty { c.append("upravené, nesmazané \(ponechane.joined(separator: ", "))") }
            if !chyby.isEmpty { c.append("chyby \(chyby.count)") }
            return c.isEmpty ? nil : "Skilly: " + c.joined(separator: ", ")
        }
    }

    public static func evidence(_ kopie: Kopie) throws -> [String: Zaznam] { try kopie.stav("skilly", [String: Zaznam].self) ?? [:] }

    /// Karty, které mají ležet na disku: skill, čitelný, živý, nenahrazený,
    /// s obsahem v Airine a s platným jménem.
    public static func chtene(_ karty: [Karta]) -> [Karta] {
        let nahrazene = Set(karty.filter { $0.bez_prava != true && $0.smazano != true }.compactMap(\.nahrazuje))
        return karty.filter { k in
            k.typ == "skill" && k.cist != false && k.bez_prava != true && k.smazano != true
                && k.archivovano_at == nil && !nahrazene.contains(k.id)
                && k.ulozeny_otisk != nil && k.name.map(Nahlasovani.jePlatneJmeno) == true
        }
    }

    /// Jeden průchod. Volat jen po úspěšném stažení změn (online), jinak by
    /// neúplná kopie vypadala jako odebrané skilly.
    public func probehni() async throws -> Vysledek {
        var v = Vysledek()
        var ev = try Self.evidence(kopie)
        let vsechny = try kopie.karty()
        let chtene = Self.chtene(vsechny)
        let chteneId = Set(chtene.map(\.id))
        let hlasic = Nahlasovani(kopie: kopie)
        let fm = FileManager.default
        let spravovane = Set(ev.values.map { URL(fileURLWithPath: $0.cesta).standardizedFileURL.path })
        let naDisku = Self.mistniSkilly(v: slozka, krome: spravovane)

        for k in chtene.sorted(by: { ($0.name ?? "") < ($1.name ?? "") }) {
            let jmeno = k.name!, cil = k.ulozeny_otisk!
            if var z = ev[k.id] {
                let url = URL(fileURLWithPath: z.cesta)
                guard let data = try? Data(contentsOf: url) else {
                    // Soubor zmizel: plugin ho vrátí (skill pořád platí).
                    if try await zapis(k, otisk: cil, do: url, v: &v) { z.otisk = cil; ev[k.id] = z; v.aktualizovane.append(jmeno) }
                    continue
                }
                let mistni = Otisk.sha256(data)
                if mistni == cil {
                    if z.otisk != cil { z.otisk = cil; ev[k.id] = z }   // server převzal místní úpravu
                } else if mistni == z.otisk {
                    // Neupravený a v Airine je nová verze: přepsat.
                    if try await zapis(k, otisk: cil, do: url, v: &v, jenKdyz: mistni) {
                        z.otisk = cil; ev[k.id] = z; v.aktualizovane.append(jmeno)
                    }
                } else if k.rozpor == true {
                    v.rozpory.append(jmeno)
                } else {
                    // Místní úprava: nová verze karty, rozpor rozhodne server.
                    switch try hlasic.nahlas(cesta: url.path, doplnId: false) {
                    case .zarazeno: v.nahlasene.append(jmeno)
                    case .beze_zmeny: break                    // už ve frontě
                    case .preskoceno(let proc): v.chyby.append("\(jmeno): \(proc)")
                    case .bezKarty: v.chyby.append("\(jmeno): hlavička bez platného jména")
                    }
                }
                continue
            }
            // Ještě ho nemáme. Leží-li už na disku s id této karty, je člověka.
            if let jinde = naDisku[k.id] { v.mistni.append(jinde); continue }
            // Nová složka, jen když je jméno volné.
            let dir = slozka.appendingPathComponent(jmeno, isDirectory: true)
            let url = dir.appendingPathComponent("SKILL.md")
            if fm.fileExists(atPath: dir.path) {
                // Stejný obsah (třeba ručně zkopírovaný) není kolize, ale plugin
                // ho nepřevezme: smazat smí jen to, co sám vytvořil.
                if (try? Data(contentsOf: url)).map(Otisk.sha256) != cil, !v.kolize.contains(jmeno) { v.kolize.append(jmeno) }
                continue
            }
            if try await zapis(k, otisk: cil, do: url, v: &v) {
                ev[k.id] = Zaznam(id: k.id, name: jmeno, otisk: cil, cesta: url.path)
                v.nove.append(jmeno)
            }
        }

        // Co už mít nemá (odebrané právo, smazaná, nahrazená, jiný typ).
        // Prázdná kopie = nejspíš neúplná synchronizace: nic se nemaže.
        if !vsechny.isEmpty {
            for (id, z) in ev where !chteneId.contains(id) {
                let url = URL(fileURLWithPath: z.cesta)
                guard let data = try? Data(contentsOf: url) else { ev[id] = nil; continue }
                if Otisk.sha256(data) != z.otisk { if !v.ponechane.contains(z.name) { v.ponechane.append(z.name) }; continue }
                try fm.removeItem(at: url)
                let dir = url.deletingLastPathComponent()
                if (try? fm.contentsOfDirectory(atPath: dir.path))?.isEmpty == true { try? fm.removeItem(at: dir) }
                ev[id] = nil
                v.smazane.append(z.name)
            }
        }
        try kopie.nastavStav("skilly", ev)
        return v
    }

    /// Skilly ve složce, které plugin nevytvořil: `metadata.airine-id` → jméno složky.
    static func mistniSkilly(v slozka: URL, krome: Set<String>) -> [String: String] {
        let fm = FileManager.default
        var m: [String: String] = [:]
        for jmeno in (try? fm.contentsOfDirectory(atPath: slozka.path)) ?? [] where !jmeno.hasPrefix(".") {
            let url = slozka.appendingPathComponent(jmeno).appendingPathComponent("SKILL.md")
            guard !krome.contains(url.standardizedFileURL.path),
                  let text = try? String(contentsOf: url, encoding: .utf8),
                  let id = Hlavicka.precti(text).meta["id"], !id.isEmpty else { continue }
            m[id] = m[id] ?? jmeno
        }
        return m
    }

    /// Stáhne verzi `otisk` a zapíše ji. `jenKdyz`: soubor se mezitím nesmí
    /// změnit (člověk nebo agent do něj mohl psát). Vrací, jestli zapsal.
    func zapis(_ k: Karta, otisk: String, do url: URL, v: inout Vysledek, jenKdyz: String? = nil) async throws -> Bool {
        let data: Data
        do { data = try await api.obsah(id: k.id, otisk: otisk) }
        catch ChybaServeru.bezSpojeni { v.chyby.append("\(k.name ?? k.id): bez spojení"); return false }
        catch { v.chyby.append("\(k.name ?? k.id): \(error)"); return false }
        guard Otisk.sha256(data) == otisk else { v.chyby.append("\(k.name ?? k.id): obsah nesedí s otiskem"); return false }
        if let jenKdyz, (try? Data(contentsOf: url)).map(Otisk.sha256) != jenKdyz { return false }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        // Hlášení místní úpravy pozná kartu podle cesty (SKILL.md z Airine
        // nemusí mít v hlavičce metadata.airine-id) a předchozí verzi podle otisku.
        var cesty = try kopie.stav("cesty", [String: String].self) ?? [:]
        cesty[url.standardizedFileURL.path] = k.id
        try kopie.nastavStav("cesty", cesty)
        var otisky = try kopie.stav("otisky", [String: String].self) ?? [:]
        otisky[k.id] = otisk
        try kopie.nastavStav("otisky", otisky)
        return true
    }
}
