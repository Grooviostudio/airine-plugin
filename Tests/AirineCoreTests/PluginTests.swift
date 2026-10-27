import CryptoKit
import Foundation
import Testing
@testable import AirineCore

/// Mock serveru kroku 1: pravidla rozporu a idempotence podle zprávy hlavního
/// serveru (27. 10. 2026). `online = false` simuluje výpadek.
actor MockServer: AirineAPI {
    var online = true
    var karty: [String: Karta] = [:]
    var verze: [String: [String]] = [:]          // id → otisky v pořadí příjmu
    var log: [(Int, String)] = []                // (seq, id)
    var seq = 0
    var navod: Navod? = Navod(verze: 1, obsah: "Hlas soubory po změně.")
    var bezPrava: Set<String> = []
    var resetKurzoru = false
    var ciziZarizeni: Set<String> = []
    var smazane: Set<String> = []
    func nastavCizi(_ z: String) { ciziZarizeni.insert(z) }
    func smaz(_ id: String) { smazane.insert(id) }

    func nastav(online: Bool) { self.online = online }
    func odeberPravo(_ id: String) { bezPrava.insert(id); zmena(id) }
    func vynutPlnou() { resetKurzoru = true }
    func pridej(_ k: Karta) { karty[k.id] = k; verze[k.id] = [k.otisk ?? ""]; zmena(k.id) }

    func zmena(_ id: String) { seq += 1; log.append((seq, id)) }

    func zmeny(od kurzor: String?, limit: Int) async throws -> Zmeny {
        guard online else { throw ChybaServeru.bezSpojeni }
        if resetKurzoru && kurzor != nil { resetKurzoru = false; throw ChybaServeru.kurzorNeplatny }
        let od = Int(kurzor ?? "0") ?? 0
        let nove = log.filter { $0.0 > od }
        let strana = Array(nove.prefix(limit))
        let ids = Array(Set(strana.map(\.1)))
        let vystup = ids.compactMap { id -> Karta? in
            guard let k = karty[id] else { return nil }
            return bezPrava.contains(id) ? Karta(id: id, name: k.name, vlastnik_id: k.vlastnik_id, bez_prava: true) : k
        }
        return Zmeny(karty: vystup, smazano: [], navod: od == 0 ? navod : nil,
                     kurzor: String(strana.last?.0 ?? od), dalsi: nove.count > limit)
    }

    func nahlas(_ h: Hlaseni) async throws -> OdpovedHlaseni {
        guard online else { throw ChybaServeru.bezSpojeni }
        if let z = h.misto.zarizeni, ciziZarizeni.contains(z) { throw ChybaServeru.ciziZarizeni }
        if smazane.contains(h.id) { throw ChybaServeru.smazano }
        if h.name == nil || h.name!.isEmpty { throw ChybaServeru.odmitnuto(Odmitnuti(chyby: [ChybaPole(pole: "name", zprava: "chybí", kod: "chybi")])) }
        if verze[h.id]?.contains(h.otisk) == true { return OdpovedHlaseni(karta: karty[h.id], stav: .uz_prijato) }
        var k = karty[h.id] ?? Karta(id: h.id, name: h.name ?? "")
        let rozpor = k.otisk != nil && h.otisk_predchozi != k.otisk
        verze[h.id, default: []].append(h.otisk)
        if rozpor {
            k.rozpor = true
        } else {
            k.rozpor = nil; k.name = h.name ?? k.name; k.popis = h.popis; k.projekt_id = h.projekt_id; k.otisk = h.otisk
            k.mista = [h.misto]; k.typ = h.typ; k.nahrazuje = h.nahrazuje
        }
        karty[h.id] = k
        zmena(h.id)
        return OdpovedHlaseni(karta: k, stav: rozpor ? .rozpor : .ok)
    }

    func pocetVerzi(_ id: String) -> Int { verze[id]?.count ?? 0 }
}

func docasnyDomov() throws -> Domov {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("airine-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return Domov(slozka: d)
}

func kopie(_ d: Domov) throws -> Kopie { try Kopie(domov: d, klic: SymmetricKey(size: .bits256)) }

func soubor(_ d: Domov, _ jmeno: String, _ obsah: String) throws -> String {
    let url = d.slozka.appendingPathComponent("prace").appendingPathComponent(jmeno)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try obsah.write(to: url, atomically: true, encoding: .utf8)
    return url.path
}

@Suite struct HlavickaTests {
    @Test func cteNahoreIBlokAirine() {
        let h = Hlavicka.precti("---\nname: brief-alfa\ndescription: \"Brief webu\"\nairine:\n  id: abc\n  typ: brief\n  vychazi_z: [x, y]\n---\n# Tělo\n")
        #expect(h.nahore["name"] == "brief-alfa")
        #expect(h.nahore["description"] == "Brief webu")
        #expect(h.airine["id"] == "abc")
        #expect(h.seznamy["vychazi_z"] == ["x", "y"])
    }

    @Test func skillNeseIdVMetadata() {
        let h = Hlavicka.precti("---\nname: nabidka\nmetadata:\n  airine-id: s1\n  jiny: 1\n---\n")
        #expect(h.airine["id"] == "s1")
        #expect(h.airine["jiny"] == nil)
    }

    @Test func vlozeniIdNemeniTelo() {
        let telo = "# Nadpis\n\nText s --- uvnitř\n"
        let bez = Hlavicka.vlozId(telo, id: "n1", skill: false)
        #expect(bez.hasSuffix(telo))
        #expect(Hlavicka.precti(bez).airine["id"] == "n1")

        let s = "---\nname: x\nairine:\n  typ: brief\n---\n" + telo
        let v = Hlavicka.vlozId(s, id: "n2", skill: false)
        #expect(v.hasSuffix(telo))
        let h = Hlavicka.precti(v)
        #expect(h.airine["id"] == "n2" && h.airine["typ"] == "brief" && h.nahore["name"] == "x")
    }

    @Test func bezHlavickyNicNecte() { #expect(Hlavicka.precti("# jen text").text == nil) }
}

@Suite struct OfflineTests {
    @Test func vypadekFrontaPockaAPakSeOdesleJednou() async throws {
        let d = try docasnyDomov(); let k = try kopie(d); let server = MockServer()
        let n = Nahlasovani(kopie: k, zarizeni: "mac-1")
        let cesta = try soubor(d, "brief.md", "---\nname: brief\ndescription: Brief\n---\nA\n")

        await server.nastav(online: false)
        guard case .zarazeno(let id, _) = try n.nahlas(cesta: cesta) else { Issue.record("nezařazeno"); return }
        #expect(Hlavicka.precti(try String(contentsOfFile: cesta, encoding: .utf8)).airine["id"] == id)
        var v = try await Synchronizace(kopie: k, api: server).probehni()
        #expect(!v.online && v.odeslano == 0)
        #expect(try k.fronta().count == 1)

        // Doporučení jde i offline, z kopie.
        #expect(try Doporuceni(kopie: k, projekt: nil).text().contains("stav k nikdy"))

        await server.nastav(online: true)
        v = try await Synchronizace(kopie: k, api: server).probehni()
        #expect(v.online && v.odeslano == 1 && v.stazeno >= 1)
        #expect(try k.fronta().isEmpty)
        #expect(try k.karta(id)?.name == "brief")
        #expect(k.navod?.verze == 1)

        // Opakované nahlášení téže verze nic nezařadí a server nic nezdvojí.
        #expect(try n.nahlas(cesta: cesta) == .beze_zmeny)
        _ = try await Synchronizace(kopie: k, api: server).probehni()
        #expect(await server.pocetVerzi(id) == 1)
    }

    @Test func dvojiOdeslaniTeVerzeJeJednaVerze() async throws {
        let d = try docasnyDomov(); let k = try kopie(d); let server = MockServer()
        let cesta = try soubor(d, "a.md", "---\nname: a\nairine:\n  id: k1\n---\nA\n")
        try Nahlasovani(kopie: k, zarizeni: "mac-1").nahlas(cesta: cesta)
        let h = try #require(try k.fronta().first).hlaseni
        _ = try await server.nahlas(h)                     // odešlo, ale odpověď se ztratila
        let v = try await Synchronizace(kopie: k, api: server).probehni()
        #expect(v.odeslano == 1)
        #expect(await server.pocetVerzi("k1") == 1)
    }

    @Test func soubeznaZmenaDvouZarizeniJeRozpor() async throws {
        let server = MockServer()
        await server.pridej(Karta(id: "k2", name: "dohoda", otisk: "puvodni"))
        let dA = try docasnyDomov(), kA = try kopie(dA)
        let dB = try docasnyDomov(), kB = try kopie(dB)
        for k in [kA, kB] { _ = try await Synchronizace(kopie: k, api: server).probehni() }

        let pA = try soubor(dA, "dohoda.md", "---\nname: dohoda\nairine:\n  id: k2\n---\nverze A\n")
        let pB = try soubor(dB, "dohoda.md", "---\nname: dohoda\nairine:\n  id: k2\n---\nverze B\n")
        try Nahlasovani(kopie: kA, zarizeni: "A").nahlas(cesta: pA)
        try Nahlasovani(kopie: kB, zarizeni: "B").nahlas(cesta: pB)
        let vA = try await Synchronizace(kopie: kA, api: server).probehni()
        let vB = try await Synchronizace(kopie: kB, api: server).probehni()
        #expect(vA.rozpory.isEmpty)
        #expect(vB.rozpory == ["k2"])
        #expect(await server.pocetVerzi("k2") == 3)          // nic se nepřepsalo
        #expect(try kB.karta("k2")?.rozpor == true)

        // B stáhne, sloučí a naváže na verzi serveru: rozpor zmizí.
        let n = Nahlasovani(kopie: kB, zarizeni: "B")
        try n.vyresRozpor(id: "k2")
        try "---\nname: dohoda\nairine:\n  id: k2\n---\nverze A+B\n".write(toFile: pB, atomically: true, encoding: .utf8)
        try n.nahlas(cesta: pB)
        let v2 = try await Synchronizace(kopie: kB, api: server).probehni()
        #expect(v2.rozpory.isEmpty && v2.odeslano == 1)
    }

    @Test func druhaUpravaOfflineNavazujeNaPrvni() throws {
        let d = try docasnyDomov(); let k = try kopie(d)
        let cesta = try soubor(d, "b.md", "---\nname: b\nairine:\n  id: k3\n---\n1\n")
        let n = Nahlasovani(kopie: k, zarizeni: "mac")
        guard case .zarazeno(_, let o1) = try n.nahlas(cesta: cesta) else { Issue.record(""); return }
        try "---\nname: b\nairine:\n  id: k3\n---\n2\n".write(toFile: cesta, atomically: true, encoding: .utf8)
        try n.nahlas(cesta: cesta)
        let f = try k.fronta()
        #expect(f.count == 2)
        #expect(f[1].hlaseni.otisk_predchozi == o1)
    }

    @Test func odmitnuteHlaseniCekaNaOpravu() async throws {
        let d = try docasnyDomov(); let k = try kopie(d); let server = MockServer()
        var h = Hlaseni(id: "k4", misto: Misto(druh: "zarizeni"), otisk: "x", radku: 1, bajty: 1)
        h.name = ""
        try k.zaradit(h)
        let v = try await Synchronizace(kopie: k, api: server).probehni()
        #expect(v.odmitnuto == 1)
        #expect(try k.fronta().isEmpty)
        #expect(try k.fronta(vcetneOdmitnutych: true).first?.odmitnuto?.chyby.first?.pole == "name")
        h.name = "opraveno"
        try k.zaradit(h)                                     // nové hlášení téže verze smaže odmítnutí
        #expect(try await Synchronizace(kopie: k, api: server).probehni().odeslano == 1)
    }
}

@Suite struct PravaAKopieTests {
    @Test func odebranePravoSmazePopis() async throws {
        let d = try docasnyDomov(); let k = try kopie(d); let server = MockServer()
        await server.pridej(Karta(id: "c1", name: "dohoda-ceny", popis: "Sazba 1 200 Kč", projekt_id: "p1",
                                  fakta: [Fakt(klic: "sazba", hodnota: "1200")], vlastnik_id: "u1"))
        _ = try await Synchronizace(kopie: k, api: server).probehni()
        #expect(try Doporuceni(kopie: k, projekt: "p1").text().contains("Sazba 1 200 Kč"))

        await server.odeberPravo("c1")
        _ = try await Synchronizace(kopie: k, api: server).probehni()
        let karta = try #require(try k.karta("c1"))
        #expect(karta.popis == nil && karta.fakta == nil && karta.bez_prava == true)
        #expect(try Doporuceni(kopie: k, projekt: nil).text().contains("bez přístupu"))
    }

    @Test func kopieJeNaDiskuSifrovana() async throws {
        let d = try docasnyDomov(); let k = try kopie(d); let server = MockServer()
        await server.pridej(Karta(id: "c2", name: "tajny-nazev-xyz", popis: "tajny-popis-xyz"))
        _ = try await Synchronizace(kopie: k, api: server).probehni()
        var surove = try Data(contentsOf: d.databaze)
        if let wal = try? Data(contentsOf: URL(fileURLWithPath: d.databaze.path + "-wal")) { surove += wal }
        #expect(surove.range(of: Data("tajny-popis-xyz".utf8)) == nil)
        #expect(surove.range(of: Data("tajny-nazev-xyz".utf8)) == nil)
    }

    @Test func neplatnyKurzorZnamenaPlnouSynchronizaci() async throws {
        let d = try docasnyDomov(); let k = try kopie(d); let server = MockServer()
        await server.pridej(Karta(id: "c3", name: "a"))
        _ = try await Synchronizace(kopie: k, api: server).probehni()
        try k.ulozKarty([Karta(id: "duch", name: "zůstal po chybě")])
        await server.vynutPlnou()
        _ = try await Synchronizace(kopie: k, api: server).probehni()
        #expect(try k.karty().map(\.id) == ["c3"])
    }

    @Test func strankovaniStahneVse() async throws {
        let d = try docasnyDomov(); let k = try kopie(d); let server = MockServer()
        for i in 0..<1203 { await server.pridej(Karta(id: "x\(i)", name: "n\(i)")) }
        let v = try await Synchronizace(kopie: k, api: server).probehni()
        #expect(v.stazeno == 1203)
        #expect(try k.karty().count == 1203)
    }

    @Test func propojeniSlozkyNejdelsiShoda() throws {
        let k = try kopie(try docasnyDomov())
        try k.propoj(slozka: "/a/b", projekt: "p1")
        try k.propoj(slozka: "/a/b/c", projekt: "p2")
        #expect(try k.projekt(pro: "/a/b/c/d") == "p2")
        #expect(try k.projekt(pro: "/a/b/x") == "p1")
        #expect(try k.projekt(pro: "/a/bb") == nil)
    }
}

@Suite struct McpTests {
    @Test func inicializaceNastrojeAVolani() async throws {
        let d = try docasnyDomov(); let k = try kopie(d)
        try k.nastavStav("navod", Navod(verze: 2, obsah: "NÁVOD-FIRMY"))
        let m = MistniMcp(kopie: k, zarizeni: "mac")
        let ini = try #require(await m.zpracuj(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#))
        #expect(ini.contains("NÁVOD-FIRMY"))
        #expect(await m.zpracuj(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        let list = try #require(await m.zpracuj(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
        #expect(list.contains("co_plati") && list.contains("nahlas_soubor"))
        let cesta = try soubor(d, "c.md", "---\nname: c\n---\nx\n")
        let call = try #require(await m.zpracuj(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"nahlas_soubor","arguments":{"cesta":"\#(cesta)"}}}"#))
        #expect(call.contains("Uloženo do fronty"))
    }
}

@Suite struct StavyHlaseniTests {
    @Test func ciziZarizeniDostaneNoveUuidAOdesleSe() async throws {
        let d = try docasnyDomov(); let k = try kopie(d); let server = MockServer()
        let stare = try Nastaveni.nacti(d).zarizeni
        await server.nastavCizi(stare)
        let cesta = try soubor(d, "z.md", "---\nname: z\nairine:\n  id: z1\n---\nx\n")
        try Nahlasovani(kopie: k, zarizeni: stare).nahlas(cesta: cesta)
        let v = try await Synchronizace.spust(domov: d, kopie: k) { _ in server }
        let nove = try Nastaveni.nacti(d).zarizeni
        #expect(nove != stare)
        #expect(v.odeslano == 1 && !v.ciziZarizeni)
        #expect(await server.karty["z1"]?.mista?.first?.zarizeni == nove)
    }

    @Test func smazanaKartaSeUzNehlasi() async throws {
        let d = try docasnyDomov(); let k = try kopie(d); let server = MockServer()
        await server.smaz("s1")
        let cesta = try soubor(d, "s.md", "---\nname: s\nairine:\n  id: s1\n---\nx\n")
        let n = Nahlasovani(kopie: k, zarizeni: "mac")
        try n.nahlas(cesta: cesta)
        let v = try await Synchronizace(kopie: k, api: server).probehni()
        #expect(v.smazanych == 1)
        #expect(try k.fronta(vcetneOdmitnutych: true).isEmpty)
        try "---\nname: s\nairine:\n  id: s1\n---\ny\n".write(toFile: cesta, atomically: true, encoding: .utf8)
        guard case .preskoceno = try n.nahlas(cesta: cesta) else { Issue.record("smazaná karta se zařadila"); return }
    }

    @Test func statusyHlaseniZTela() {
        func ch(_ kod: Int, _ json: String) -> ChybaServeru { HttpAirine.chybaHlaseni(Data(json.utf8), kod) }
        #expect(ch(403, #"{"stav":"bez_prava","id":"a"}"#) == .bezPravaKarty)
        #expect(ch(403, "{}") == .neprihlasen)
        #expect(ch(409, #"{"stav":"cizi_zarizeni","id":"a"}"#) == .ciziZarizeni)
        #expect(ch(409, #"{"stav":"cizi_id","id":"a"}"#) == .ciziId)
        #expect(ch(410, #"{"stav":"smazano","id":"a"}"#) == .smazano)
        guard case .odmitnuto(let o) = ch(422, #"{"chyby":[{"pole":"name","kod":"chybi"}]}"#) else { Issue.record(""); return }
        #expect(o.chyby == [ChybaPole(pole: "name", zprava: "chybi", kod: "chybi")])
        guard case .odmitnuto(let o2) = ch(422, #"{"stav":"neplatne","id":"a","omezeni":{"fakta":16}}"#) else { Issue.record(""); return }
        #expect(o2.chyby.first?.zprava == #"{"fakta":16}"#)
    }

    @Test func doporuceniUkazeJmenoVlastnika() async throws {
        let k = try kopie(try docasnyDomov())
        try k.ulozKarty([Karta(id: "b1", name: "smlouva", vlastnik_id: "u1", vlastnik_jmeno: "Eva", bez_prava: true)])
        let t = try Doporuceni(kopie: k, projekt: nil).text()
        #expect(t.contains("požádej o něj Eva") && !t.contains("u1"))
    }
}
