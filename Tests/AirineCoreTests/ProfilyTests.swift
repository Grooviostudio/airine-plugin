import CryptoKit
import Foundation
import Testing
@testable import AirineCore

/// Víc workspace na jednom Macu: složka → profil, oddělená tajemství a kopie,
/// výchozí profil beze změny jmen.
@Suite struct ProfilyTests {
    func dvaProfily(_ koren: URL) throws -> (Profily, String, String) {
        let a = koren.appendingPathComponent("Prace/Firma A", isDirectory: true)
        let b = a.appendingPathComponent("Podslozka", isDirectory: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        var p = Profily()
        try p.pridej("firma-a", nazev: "Firma A")
        try p.prirad(a.path, "firma-a")
        try p.prirad(b.path, Profily.vychozi)
        return (p, a.path, b.path)
    }

    @Test func nejdelsiShodaAVychozi() throws {
        let d = try docasnyDomov()
        let (p, a, b) = try dvaProfily(d.slozka)
        #expect(p.profil(pro: a) == "firma-a")
        #expect(p.profil(pro: a + "/docs/x.md") == "firma-a")
        // Podsložka vrácená výchozímu profilu vyhraje (delší shoda).
        #expect(p.profil(pro: b + "/y.md") == Profily.vychozi)
        // Stejný začátek jména není podsložka.
        #expect(p.profil(pro: a + " B/z.md") == Profily.vychozi)
        #expect(p.profil(pro: "/jinde/uplne") == Profily.vychozi)
        // Soubor, který ještě neexistuje (Write ho teprve založí), patří taky.
        #expect(p.profil(pro: a + "/novy/novy.md") == "firma-a")
    }

    @Test func unicodeATildaASymlink() throws {
        let d = try docasnyDomov()
        let slozka = d.slozka.appendingPathComponent("Pl\u{00F3}cha", isDirectory: true)   // složené ó
        try FileManager.default.createDirectory(at: slozka, withIntermediateDirectories: true)
        var p = Profily()
        try p.pridej("x", nazev: "X")
        try p.prirad(slozka.path, "x")
        let rozlozene = d.slozka.appendingPathComponent("Plo\u{0301}cha/a.md").path        // o + čárka
        #expect(p.profil(pro: rozlozene) == "x")
        let odkaz = d.slozka.appendingPathComponent("odkaz")
        try FileManager.default.createSymbolicLink(at: odkaz, withDestinationURL: slozka)
        #expect(p.profil(pro: odkaz.path + "/b.md") == "x")
        // Docasná složka leží pod /var → /private/var: klíč je vždy rozvedený.
        #expect(Profily.klic(slozka.path) == Profily.klic(odkaz.path))
    }

    @Test func neznamyProfilVMapeJeVychozi() throws {
        let p = Profily(profily: [:], slozky: ["/a": "smazany"])
        #expect(p.profil(pro: "/a/b") == Profily.vychozi)
    }

    @Test func idProfilu() throws {
        var p = Profily()
        #expect(throws: ChybaProfilu.self) { try p.pridej("Firma A", nazev: "x") }
        #expect(throws: ChybaProfilu.self) { try p.pridej("", nazev: "x") }
        #expect(throws: ChybaProfilu.self) { try p.prirad("/tmp", "neni") }
        try p.pridej("firma-a2", nazev: "A")
        try p.pridej(Profily.vychozi, nazev: "Hlavní")
        #expect(p.nazev(Profily.vychozi) == "Hlavní")
    }

    @Test func ulozeniAPrava() throws {
        let d = try docasnyDomov()
        #expect(Profily.nacti(d.koren) == Profily())
        let (p, _, _) = try dvaProfily(d.slozka)
        try p.uloz(d.koren)
        #expect(Profily.nacti(d.koren) == p)
        let prava = try FileManager.default.attributesOfItem(atPath: Profily.soubor(d.koren).path)[.posixPermissions] as? Int
        #expect(prava == 0o600)
    }

    @Test func domovProfiluAVychoziBezZmeny() throws {
        let d = try docasnyDomov()
        let v = d.profil(Profily.vychozi)
        #expect(v.slozka == d.slozka && v.profil == nil && v.databaze == d.databaze)
        let a = d.profil("firma-a")
        #expect(a.slozka.path == d.slozka.appendingPathComponent("profily/firma-a").path)
        #expect(a.koren == d.koren && a.idProfilu == "firma-a")
        // Profil profilu se počítá od kořene, ne zanořeně.
        #expect(a.profil("firma-b").slozka.path == d.slozka.appendingPathComponent("profily/firma-b").path)
    }

    @Test func klicenkaPriponaJenUJinehoProfilu() {
        #expect(Klicenka().ucet("token") == "token")
        #expect(Klicenka(profil: "firma-a").ucet("klic-kopie") == "klic-kopie.firma-a")
        let q = Klicenka(bezOkna: true, profil: "firma-a").dotazCteni("token")
        #expect(q[kSecAttrAccount as String] as? String == "token.firma-a")
    }

    @Test func oddelenaTajemstviAKopie() throws {
        let d = try docasnyDomov()
        let a = d.profil("firma-a")
        let ta = SouborTajemstvi(domov: d), tb = SouborTajemstvi(domov: a)
        let ka = try Tajemstvi.klicKopie(ta), kb = try Tajemstvi.klicKopie(tb)
        #expect(ka.withUnsafeBytes { Data($0) } != kb.withUnsafeBytes { Data($0) })
        try ta.zapis("token", Data("airine_a".utf8))
        #expect(try tb.cti("token") == nil)
        let kopA = try Kopie(domov: d, klic: ka), kopB = try Kopie(domov: a, klic: kb)
        try kopA.propoj(slozka: "/x", projekt: "p-a")
        #expect(try kopB.projekt(pro: "/x/y") == nil)
        #expect(FileManager.default.fileExists(atPath: a.databaze.path) && a.databaze != d.databaze)
    }

    @Test func souborCizihoWorkspaceSeNehlasi() throws {
        let d = try docasnyDomov()
        let (p, a, b) = try dvaProfily(d.slozka)
        #expect(Slozky.jinyWorkspace(a + "/x.md", (p, Profily.vychozi)))
        #expect(!Slozky.jinyWorkspace(a + "/x.md", (p, "firma-a")))
        #expect(Slozky.jinyWorkspace(b + "/x.md", (p, "firma-a")))
        #expect(!Slozky.jinyWorkspace(a + "/x.md", nil))
    }

    @Test func hlavickaJmenujeWorkspace() async throws {
        let d = try docasnyDomov(); let k = try kopie(d)
        #expect(try Doporuceni(kopie: k, projekt: nil).text().hasPrefix("# Airine: co platí"))
        #expect(try Doporuceni(kopie: k, projekt: nil).text(workspace: "Firma A").hasPrefix("# Airine (workspace Firma A): co platí"))
        // MCP: co_plati bez argumentů najde projekt podle složky sezení.
        try k.propoj(slozka: "/prace/a", projekt: "p1")
        let m = MistniMcp(otevri: { k }, workspace: "Firma A", vychoziCesta: "/prace/a/repo")
        let odp = try #require(await m.zpracuj(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"co_plati","arguments":{}}}"#))
        // Projekt bez karet: co_plati bez argumentů ukáže celý katalog a řekne proč.
        #expect(odp.contains("workspace Firma A") && odp.contains("K propojenému projektu (p1)"))
    }

    @Test func propojeniPresSymlink() throws {
        let d = try docasnyDomov(); let k = try kopie(d)
        let cil = d.slozka.appendingPathComponent("Developer/Firma", isDirectory: true)
        try FileManager.default.createDirectory(at: cil.appendingPathComponent("repo"), withIntermediateDirectories: true)
        let odkaz = d.slozka.appendingPathComponent("Plocha-Firma")
        try FileManager.default.createSymbolicLink(at: odkaz, withDestinationURL: cil)
        try k.propoj(slozka: cil.path, projekt: "p1")
        #expect(try k.projekt(pro: odkaz.path) == "p1")
        #expect(try k.projekt(pro: odkaz.path + "/repo") == "p1")
        #expect(try k.koren(pro: odkaz.path + "/repo/a.md") == cil.standardizedFileURL.path)
        // Zrušení přes odkaz zruší uložené propojení cíle.
        #expect(try k.zrusPropojeni(slozka: odkaz.path) == "p1")
        #expect(try k.projekt(pro: cil.path) == nil)
        #expect(try k.zrusPropojeni(slozka: cil.path) == nil)
    }

    @Test func prazdnyProjektUkazeCelyKatalog() throws {
        let k = try kopie(try docasnyDomov())
        try k.ulozKarty([Karta(id: "a", name: "produkt"), Karta(id: "b", name: "brief", projekt_id: "p2")])
        let z = try Doporuceni(kopie: k, projekt: "p1", zalozni: true)
        #expect(z.prazdnyProjekt == "p1" && z.projekt == nil && Set(z.platne.map(\.id)) == ["a", "b"])
        let t = z.text(workspace: "Firma A")
        #expect(t.hasPrefix("# Airine (workspace Firma A): co platí (stav"))
        #expect(t.contains("K propojenému projektu (p1) zatím nic nahlášeného. Ukazuju celý katalog workspace Firma A."))
        // Projekt s kartami: jen jeho, žádná záloha.
        let p = try Doporuceni(kopie: k, projekt: "p2", zalozni: true)
        #expect(p.prazdnyProjekt == nil && p.platne.map(\.id) == ["b"])
        // Bez `zalozni` zůstává prázdný (výslovné projekt_id v co_plati).
        #expect(try Doporuceni(kopie: k, projekt: "p1").platne.isEmpty)
    }
}
