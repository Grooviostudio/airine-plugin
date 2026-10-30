import Foundation

/// Hlídání vybraných složek (lišta, FSEvents): každá změna MD souboru ve
/// složkách pro Znalosti jde do fronty hlášení bez ohledu na to, kdo ji
/// udělal. Platí stejná pravidla jako u hooku (`Nahlasovani`); do souborů se
/// nepíše. Smazaný nebo přesunutý soubor se jen promítne do míst karty.
public struct Hlidani: Sendable {
    let kopie: Kopie
    let slozky: [String]
    let zarizeni: String?
    let zkouska: Bool

    public init(kopie: Kopie, slozky: [String], zarizeni: String?, zkouska: Bool = false) {
        self.kopie = kopie; self.slozky = slozky; self.zarizeni = zarizeni; self.zkouska = zkouska
    }

    public struct Vysledek: Sendable, Equatable {
        public var nove = 0             // soubor dostane kartu poprvé
        public var zmenene = 0          // nová verze známé karty
        public var bezeZmeny = 0
        public var preskoceno = 0       // pravidla (vynechané složky, watermark, nad 1 MB…)
        public var zmizelo = 0          // místo karty na tomhle Macu už neplatí
        public var zarazeno: Int { nove + zmenene }
        public init() {}
    }

    var nahlasovani: Nahlasovani {
        Nahlasovani(kopie: kopie, slozky: slozky, zarizeni: zarizeni, zkouska: zkouska)
    }

    /// Cesty z události FSEvents (po zklidnění). Existující soubor se
    /// nahlásí, chybějící se promítne do míst.
    public func zpracuj(_ cesty: Set<String>) throws -> Vysledek {
        var v = Vysledek()
        let zname = try znamaMista()
        for c in cesty.map(Slozky.normalizuj).sorted() where !Slozky.vKnihovne(c, slozky) {
            var adresar: ObjCBool = false
            if FileManager.default.fileExists(atPath: c, isDirectory: &adresar) {
                if adresar.boolValue { continue }
                try nahlas(c, &v)
            } else if let ids = zname[c] {
                for id in ids { try zmizelo(id: id, cesta: c, &v) }
            } else {
                // Smazaná složka: FSEvents ohlásí jen ji, místa pod ní zmizela taky.
                for (cesta, ids) in zname where cesta.hasPrefix(c + "/") && !FileManager.default.fileExists(atPath: cesta) {
                    for id in ids { try zmizelo(id: id, cesta: cesta, &v) }
                }
            }
        }
        return v
    }

    /// Jednou po startu: projde jen vybrané složky (žádný celý disk), nahlásí,
    /// co se změnilo, když lišta neběžela, a najde místa, která zmizela.
    public func porovnej() throws -> Vysledek {
        var v = Vysledek()
        for koren in slozky.map(Slozky.normalizuj) {
            let url = URL(fileURLWithPath: koren, isDirectory: true)
            guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey]) else { continue }
            for case let u as URL in e {
                let p = u.standardizedFileURL.path
                let jmeno = u.lastPathComponent
                if (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    // Do knihoven, sestavení, skrytých složek a pracovních kopií se
                    // nevstupuje vůbec, kromě míst se skills a pravidly agentů.
                    if Slozky.vzdyPreskocene.contains(jmeno) || (jmeno.hasPrefix(".") && !Self.vedeKPovolene(p, koren)) || p.contains("/.claude/worktrees") {
                        e.skipDescendants()
                    }
                    continue
                }
                guard Nahlasovani.hlasitelny(p), Slozky.duvod(p, slozky) == nil else { continue }
                try nahlas(p, &v)
            }
        }
        for (cesta, ids) in try znamaMista() where Slozky.duvod(cesta, slozky) == nil && !FileManager.default.fileExists(atPath: cesta) {
            for id in ids { try zmizelo(id: id, cesta: cesta, &v) }
        }
        return v
    }

    /// Skrytá složka, pod kterou (nebo nad kterou) leží povolené místo skills.
    static func vedeKPovolene(_ cesta: String, _ koren: String) -> Bool {
        let rel = String(cesta.dropFirst(koren.count + 1))
        let i = rel.split(separator: "/").firstIndex { $0.hasPrefix(".") }.map { rel.split(separator: "/")[$0...].joined(separator: "/") } ?? rel
        return Slozky.povoleneSkryte.contains { i == $0 || i.hasPrefix($0 + "/") || $0.hasPrefix(i + "/") }
    }

    func nahlas(_ cesta: String, _ v: inout Vysledek) throws {
        let pred = try kopie.stav("otisky", [String: String].self) ?? [:]
        let r: Nahlasovani.Vysledek
        do { r = try nahlasovani.nahlas(cesta: cesta, doplnId: false) }
        catch { v.preskoceno += 1; return }          // soubor zmizel mezi událostí a čtením
        switch r {
        case .zarazeno(let id, _, _):
            if pred[id] == nil, try kopie.karta(id) == nil { v.nove += 1 } else { v.zmenene += 1 }
            if !zkouska { try kopie.zrusZmizele(cesta: cesta) }
        case .beze_zmeny:
            v.bezeZmeny += 1
            if !zkouska { try kopie.zrusZmizele(cesta: cesta) }
        case .preskoceno, .bezKarty: v.preskoceno += 1
        }
    }

    func zmizelo(id: String, cesta: String, _ v: inout Vysledek) throws {
        v.zmizelo += 1
        guard !zkouska else { return }
        try kopie.zaraditZmizele(ZmizeleMisto(karta_id: id, cesta: cesta))
        var c = try kopie.stav("cesty", [String: String].self) ?? [:]
        if c[cesta] != nil { c[cesta] = nil; try kopie.nastavStav("cesty", c) }
    }

    /// Cesta → karty: místa tohohle zařízení z kopie a soubory bez id
    /// v hlavičce, které plugin nahlásil a server je ještě nevrátil.
    /// Zmizelá místa, která už čekají ve frontě, se nepočítají znovu.
    func znamaMista() throws -> [String: Set<String>] {
        var m: [String: Set<String>] = [:]
        for k in try kopie.karty() where k.smazano != true && k.bez_prava != true {
            for misto in k.mista ?? [] where misto.zarizeni_id == zarizeni || zarizeni == nil {
                guard let c = misto.cesta, c.hasPrefix("/"), misto.zmizelo_at == nil else { continue }
                m[c, default: []].insert(k.id)
            }
        }
        for (c, id) in try kopie.stav("cesty", [String: String].self) ?? [:] { m[c, default: []].insert(id) }
        for z in try kopie.zmizela() { m[z.cesta]?.remove(z.karta_id); if m[z.cesta]?.isEmpty == true { m[z.cesta] = nil } }
        return m
    }
}

/// Místo souboru, které na tomhle zařízení přestalo platit (smazaný nebo
/// přesunutý soubor). Karta se nemaže ani nearchivuje.
public struct ZmizeleMisto: Codable, Hashable, Sendable {
    public var karta_id: String
    public var cesta: String
    public init(karta_id: String, cesta: String) { self.karta_id = karta_id; self.cesta = cesta }
}

extension Kopie {
    public func zmizela() throws -> [ZmizeleMisto] { try stav("zmizela", [ZmizeleMisto].self) ?? [] }

    public func zaraditZmizele(_ z: ZmizeleMisto) throws {
        var f = try zmizela()
        guard !f.contains(z) else { return }
        f.append(z)
        try nastavStav("zmizela", f)
    }

    /// Soubor je zpátky (obnovený z koše, vrácený přesun): místo zase platí.
    public func zrusZmizele(cesta: String) throws {
        let f = try zmizela()
        let zbytek = f.filter { $0.cesta != cesta }
        if zbytek.count != f.count { try nastavStav("zmizela", zbytek) }
    }

    func odeslanaZmizela(_ odeslana: [ZmizeleMisto]) throws {
        let hotova = Set(odeslana)
        try nastavStav("zmizela", try zmizela().filter { !hotova.contains($0) })
    }
}

extension Kopie {
    /// Hlášení `h` server přiřadil existující kartě `id`: cesta, otisk
    /// a čekající hlášení téhož souboru přejdou na ni.
    func prevezmi(_ h: Hlaseni, id: String) throws {
        var cesty = try stav("cesty", [String: String].self) ?? [:]
        var otisky = try stav("otisky", [String: String].self) ?? [:]
        for (c, i) in cesty where i == h.id { cesty[c] = id }
        if let o = otisky.removeValue(forKey: h.id) { otisky[id] = o }
        try db.transakce {
            try nastavStav("cesty", cesty)
            try nastavStav("otisky", otisky)
            for p in try fronta(vcetneOdmitnutych: true) where p.hlaseni.id == h.id && p.hlaseni.otisk != h.otisk {
                var n = p.hlaseni
                try db.proved("DELETE FROM fronta WHERE klic = ?", [.text("\(n.id):\(n.otisk)")])
                n.id = id
                try zaradit(n)
            }
        }
    }
}
