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
        return Zmeny(karty: vystup, dalsi: nove.count > limit, kurzor: String(strana.last?.0 ?? od),
                     navod: od == 0 ? navod : nil)
    }

    func nahlas(_ h: Hlaseni) async throws -> OdpovedHlaseni { try await nahlas(h, zarizeni: nil) }

    /// Zařízení posílá skutečný klient v hlavičce `x-airine-zarizeni`, proto zvlášť.
    func nahlas(_ h: Hlaseni, zarizeni: String?) async throws -> OdpovedHlaseni {
        guard online else { throw ChybaServeru.bezSpojeni }
        if let z = zarizeni, ciziZarizeni.contains(z) { throw ChybaServeru.ciziZarizeni }
        if smazane.contains(h.id) { throw ChybaServeru.smazano }
        if h.name == nil || h.name!.isEmpty { throw ChybaServeru.odmitnuto(Odmitnuti(chyby: [ChybaPole(pole: "name", zprava: "chybí", kod: "chybi")])) }
        if verze[h.id]?.contains(h.otisk) == true { return OdpovedHlaseni(stav: .uz_prijato, id: h.id, otisk: h.otisk) }
        var k = karty[h.id] ?? Karta(id: h.id, name: h.name ?? "")
        let rozpor = k.otisk != nil && h.otisk_predchozi != k.otisk
        verze[h.id, default: []].append(h.otisk)
        if rozpor {
            k.rozpor = true
        } else {
            k.rozpor = nil; k.name = h.name ?? k.name; k.popis = h.popis; k.projekt_id = h.projekt_id; k.otisk = h.otisk
            k.mista = [Misto(zarizeni_id: zarizeni, cesta: h.cesta, otisk: h.otisk)]; k.typ = h.typ; k.nahrazuje = h.nahrazuje
            k.fakta = h.fakta
        }
        karty[h.id] = k
        zmena(h.id)
        return OdpovedHlaseni(stav: rozpor ? .rozpor : .ok, id: h.id, otisk: k.otisk, rozpor: rozpor)
    }

    func pocetVerzi(_ id: String) -> Int { verze[id]?.count ?? 0 }
}

/// Klient jednoho zařízení: jako HttpAirine nese zařízení mimo tělo hlášení.
struct ZarizeniMock: AirineAPI {
    let server: MockServer
    let zarizeni: String
    func zmeny(od kurzor: String?, limit: Int) async throws -> Zmeny { try await server.zmeny(od: kurzor, limit: limit) }
    func nahlas(_ h: Hlaseni) async throws -> OdpovedHlaseni { try await server.nahlas(h, zarizeni: zarizeni) }
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
        let n = Nahlasovani(kopie: k)
        let cesta = try soubor(d, "brief.md", "---\nname: brief\ndescription: Brief\nairine:\n  typ: brief\n---\nA\n")

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
        let cesta = try soubor(d, "a.md", "---\nname: a\ndescription: d\nairine:\n  typ: brief\n  id: k1\n---\nA\n")
        try Nahlasovani(kopie: k).nahlas(cesta: cesta)
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

        let pA = try soubor(dA, "dohoda.md", "---\nname: dohoda\ndescription: d\nairine:\n  typ: brief\n  id: k2\n---\nverze A\n")
        let pB = try soubor(dB, "dohoda.md", "---\nname: dohoda\ndescription: d\nairine:\n  typ: brief\n  id: k2\n---\nverze B\n")
        try Nahlasovani(kopie: kA).nahlas(cesta: pA)
        try Nahlasovani(kopie: kB).nahlas(cesta: pB)
        let vA = try await Synchronizace(kopie: kA, api: server).probehni()
        let vB = try await Synchronizace(kopie: kB, api: server).probehni()
        #expect(vA.rozpory.isEmpty)
        #expect(vB.rozpory == ["k2"])
        #expect(await server.pocetVerzi("k2") == 3)          // nic se nepřepsalo
        #expect(try kB.karta("k2")?.rozpor == true)

        // B stáhne, sloučí a naváže na verzi serveru: rozpor zmizí.
        let n = Nahlasovani(kopie: kB)
        try n.vyresRozpor(id: "k2")
        try "---\nname: dohoda\ndescription: d\nairine:\n  typ: brief\n  id: k2\n---\nverze A+B\n".write(toFile: pB, atomically: true, encoding: .utf8)
        try n.nahlas(cesta: pB)
        let v2 = try await Synchronizace(kopie: kB, api: server).probehni()
        #expect(v2.rozpory.isEmpty && v2.odeslano == 1)
    }

    @Test func druhaUpravaOfflineNavazujeNaPrvni() throws {
        let d = try docasnyDomov(); let k = try kopie(d)
        let cesta = try soubor(d, "b.md", "---\nname: b\ndescription: d\nairine:\n  typ: brief\n  id: k3\n---\n1\n")
        let n = Nahlasovani(kopie: k)
        guard case .zarazeno(_, let o1) = try n.nahlas(cesta: cesta) else { Issue.record(""); return }
        try "---\nname: b\ndescription: d\nairine:\n  typ: brief\n  id: k3\n---\n2\n".write(toFile: cesta, atomically: true, encoding: .utf8)
        try n.nahlas(cesta: cesta)
        let f = try k.fronta()
        #expect(f.count == 2)
        #expect(f[1].hlaseni.otisk_predchozi == o1)
    }

    @Test func odmitnuteHlaseniCekaNaOpravu() async throws {
        let d = try docasnyDomov(); let k = try kopie(d); let server = MockServer()
        var h = Hlaseni(id: "k4", otisk: "x", radku: 1, bajty: 1)
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
                                  fakta: ["sazba": "1200"], vlastnik_id: "u1"))
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
        let m = MistniMcp(kopie: k)
        let ini = try #require(await m.zpracuj(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#))
        #expect(ini.contains("NÁVOD-FIRMY"))
        #expect(await m.zpracuj(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        let list = try #require(await m.zpracuj(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
        #expect(list.contains("co_plati") && list.contains("nahlas_soubor"))
        let cesta = try soubor(d, "c.md", "---\nname: c\ndescription: d\nairine:\n  typ: brief\n---\nx\n")
        let call = try #require(await m.zpracuj(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"nahlas_soubor","arguments":{"cesta":"\#(cesta)"}}}"#))
        #expect(call.contains("Uloženo do fronty"))
    }
}

@Suite struct StavyHlaseniTests {
    @Test func ciziZarizeniDostaneNoveUuidAOdesleSe() async throws {
        let d = try docasnyDomov(); let k = try kopie(d); let server = MockServer()
        let stare = try Nastaveni.nacti(d).zarizeni
        await server.nastavCizi(stare)
        let cesta = try soubor(d, "z.md", "---\nname: z\ndescription: d\nairine:\n  typ: brief\n  id: z1\n---\nx\n")
        try Nahlasovani(kopie: k).nahlas(cesta: cesta)
        let v = try await Synchronizace.spust(domov: d, kopie: k) { n in ZarizeniMock(server: server, zarizeni: n.zarizeni) }
        let nove = try Nastaveni.nacti(d).zarizeni
        #expect(nove != stare)
        #expect(v.odeslano == 1 && !v.ciziZarizeni)
        #expect(await server.karty["z1"]?.mista?.first?.zarizeni_id == nove)
    }

    @Test func smazanaKartaSeUzNehlasi() async throws {
        let d = try docasnyDomov(); let k = try kopie(d); let server = MockServer()
        await server.smaz("s1")
        let cesta = try soubor(d, "s.md", "---\nname: s\ndescription: d\nairine:\n  typ: brief\n  id: s1\n---\nx\n")
        let n = Nahlasovani(kopie: k)
        try n.nahlas(cesta: cesta)
        let v = try await Synchronizace(kopie: k, api: server).probehni()
        #expect(v.smazanych == 1)
        #expect(try k.fronta(vcetneOdmitnutych: true).isEmpty)
        try "---\nname: s\ndescription: d\nairine:\n  typ: brief\n  id: s1\n---\ny\n".write(toFile: cesta, atomically: true, encoding: .utf8)
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

/// Tvar JSON podle serveru (routes/katalog.js, SQL katalog_zmeny a katalog_hlaseni).
@Suite struct KontraktTests {
    @Test func zmenyZeServeru() throws {
        let json = #"""
        {"karty":[
          {"id":"a1","smazano":true},
          {"id":"a2","bez_prava":true},
          {"id":"a3","name":"smlouva","vlastnik_id":"u1","vlastnik_jmeno":"Eva","bez_prava":true},
          {"id":"a4","name":"brief","popis":"Brief webu","typ":"brief","contact_id":"c1","project_id":"p1",
           "slozka_id":null,"vlastnik_id":"u1","nahrazuje_id":"a0","vychazi_z":["a5"],"fakta":{"sazba":"1200"},
           "otisk":"o2","verze":3,"ulozeny_otisk":"o1","rozpor":false,"zmenil_id":"u1","smazano_at":null,
           "created_at":"2026-10-27T08:00:00Z","updated_at":"2026-10-27T09:00:00Z","cist":true,"menit":false,
           "vlastnik_jmeno":"Eva","mista":[{"zarizeni_id":"z1","cesta":"/x/brief.md","otisk":"o2","videno_at":"2026-10-27T09:00:00Z"}]}
        ],"dalsi":false,"kurzor":"2026-10-27T09:00:00Z|a4","navod_zmenen":true,
         "navod":{"verze":2,"vlastni":false,"obsah":{"verze":1,"pravidla":["Hlas soubory po změně."],"typy":["brief","skill"]},"vychozi_prava":{}}}
        """#
        let z = try JSONDecoder().decode(Zmeny.self, from: Data(json.utf8))
        #expect(z.karty.count == 4 && z.karty[0].smazano == true && z.karty[1].bez_prava == true)
        #expect(z.karty[2].vlastnik_jmeno == "Eva")
        let k = z.karty[3]
        #expect(k.klient_id == "c1" && k.projekt_id == "p1" && k.nahrazuje == "a0")
        #expect(k.fakta == ["sazba": "1200"] && k.cist == true && k.menit == false)
        #expect(k.mista?.first?.zarizeni_id == "z1" && k.jenNaJednomZarizeni && k.neniVAirine)
        let n = try #require(z.navod)
        #expect(n.verze == 2 && n.obsah.contains("- Hlas soubory po změně.") && n.obsah.contains("Typy souborů: brief, skill"))
        #expect(!n.obsah.contains("verze"))
    }

    @Test func odpovedHlaseni() throws {
        let json = #"{"stav":"rozpor","id":"a4","otisk":"o2","verze":4,"rozpor":true,"ulozeny_otisk":"o1","hlavicka":[{"pole":"name","v_hlavicce":"brief","v_hlaseni":"brief-2"}]}"#
        let o = try JSONDecoder().decode(OdpovedHlaseni.self, from: Data(json.utf8))
        #expect(o.stav == .rozpor && o.rozpor == true && o.hlavicka?.first?.pole == "name")
    }

    @Test func hlaseniMaFaktaJakoObjektACestuNahore() throws {
        let h = Hlaseni(id: "a4", name: "brief", fakta: ["sazba": "1200"], cesta: "/x/brief.md", otisk: "o2", radku: 3, bajty: 40)
        let o = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(h)) as? [String: Any])
        #expect((o["fakta"] as? [String: String]) == ["sazba": "1200"])
        #expect(o["cesta"] as? String == "/x/brief.md")
        #expect(o["misto"] == nil && o["zarizeni"] == nil)
    }
}

@Suite struct BezKartyTests {
    @Test func neuplnaHlavickaSeNehlasiANicNepise() throws {
        let d = try docasnyDomov(); let k = try kopie(d)
        let telo = "---\ndescription: Zápis\n---\nx\n"
        let cesta = try soubor(d, "Zápis schůzky.md", telo)
        let v = try Nahlasovani(kopie: k).nahlas(cesta: cesta)
        #expect(v == .bezKarty(chybi: ["name", "airine.typ"], navrhJmena: "zapis-schuzky"))
        #expect(try String(contentsOfFile: cesta, encoding: .utf8) == telo)
        #expect(try k.fronta().isEmpty)
        #expect(v.proAgenta?.contains("name: zapis-schuzky") == true)
    }

    @Test func skillStaciJmenoAPopis() throws {
        let d = try docasnyDomov(); let k = try kopie(d)
        let cesta = try soubor(d, "nabidka/SKILL.md", "---\nname: nabidka\ndescription: Nabídka\n---\nx\n")
        guard case .zarazeno = try Nahlasovani(kopie: k).nahlas(cesta: cesta) else { Issue.record("nezařazeno"); return }
        #expect(try k.fronta().first?.hlaseni.typ == "skill")
    }

    /// Stejné pravidlo jako kartaZHlavicky() na serveru.
    @Test func popisAJmenoZBlokuAirine() throws {
        let d = try docasnyDomov(); let k = try kopie(d)
        let cesta = try soubor(d, "brief.md", "---\nairine:\n  name: brief-alfa\n  typ: brief\n  popis: Brief pro Alfu\n  fakta:\n    rozpocet: 120000\n    mena: CZK\n  vychazi_z: [a, b]\n---\nx\n")
        guard case .zarazeno = try Nahlasovani(kopie: k).nahlas(cesta: cesta) else { Issue.record("nezařazeno"); return }
        let h = try #require(try k.fronta().first?.hlaseni)
        #expect(h.name == "brief-alfa")
        #expect(h.popis == "Brief pro Alfu")
        #expect(h.fakta == ["rozpocet": "120000", "mena": "CZK"])
        #expect(h.vychazi_z == ["a", "b"])
    }

    @Test func blokMaPrednostPredHorniPoli() {
        let h = Hlavicka.precti("---\nname: horni\ndescription: Horní\nairine:\n  name: z-bloku\n  popis: Z bloku\n  typ: brief\n---\n")
        let k = h.karta(skillSouborem: false)
        #expect(k.name == "z-bloku"); #expect(k.popis == "Z bloku"); #expect(k.typ == "brief")
    }

    @Test func metadataAirineIdJeSkillIMimoSkillMd() {
        let h = Hlavicka.precti("---\nname: nabidka\ndescription: Nabídka\nmetadata:\n  airine-id: 11111111-1111-1111-1111-111111111111\n---\n")
        let k = h.karta(skillSouborem: false)
        #expect(k.skill); #expect(k.typ == "skill"); #expect(k.popis == "Nabídka")
    }

    @Test func kebab() {
        #expect(Nahlasovani.kebab("Zápis schůzky") == "zapis-schuzky")
        #expect(Nahlasovani.kebab("  --Brief_Alfa 2 ") == "brief-alfa-2")
        #expect(Nahlasovani.kebab("ěščř") == "escr")
        #expect(Nahlasovani.kebab("!!!") == nil)
        #expect(Nahlasovani.kebab(String(repeating: "a", count: 70))?.count == 64)
    }

    @Test func klientskaKartaPatriKProjektu() throws {
        let k = try kopie(try docasnyDomov())
        try k.ulozKarty([Karta(id: "a", name: "brief", klient_id: "c1", projekt_id: "p1"),
                         Karta(id: "b", name: "sazby-klienta", klient_id: "c1"),
                         Karta(id: "c", name: "cizi", klient_id: "c2")])
        #expect(Set(try Doporuceni(kopie: k, projekt: "p1").platne.map(\.id)) == ["a", "b"])
        #expect(try Doporuceni(kopie: k, projekt: "p9").platne.isEmpty)
    }
}

/// Sdílená sada s parsujHlavicku() na serveru (lib/katalog.js): obě strany
/// musí z téže hlavičky vyčíst totéž, jinak server hlásí falešný nesoulad.
@Suite struct HlavickaFixtureTests {
    struct Pripad: Decodable {
        let nazev: String; let hlavicka: String; let description: String?
        let name, id, typ, popis: String?; let fakta: [String: String]?
    }

    @Test func sadaHlavicek() throws {
        let url = try #require(Bundle.module.url(forResource: "hlavicky", withExtension: "json", subdirectory: "Fixtures"))
        for p in try JSONDecoder().decode([Pripad].self, from: Data(contentsOf: url)) {
            let h = Hlavicka.precti("---\n\(p.hlavicka)\n---\ntělo\n")
            let k = h.karta(skillSouborem: false)
            #expect(h.nahore["description"] == p.description, "\(p.nazev)")
            if let n = p.name { #expect(h.nahore["name"] == n, "\(p.nazev)") }
            if let i = p.id { #expect(h.airine["id"] == i, "\(p.nazev)") }
            if let t = p.typ { #expect(h.airine["typ"] == t, "\(p.nazev)") }
            if let o = p.popis { #expect(k.popis == o, "\(p.nazev)") }
            if let f = p.fakta { #expect(k.fakta == f, "\(p.nazev)") }
        }
    }
}

@Suite struct OdkazyTests {
    let idCile = "22222222-2222-2222-2222-222222222222"

    @Test func ctePouzeOdkazyNaMdBezTextu() {
        let t = """
        ---
        name: x
        airine:
          projekt: "[[Alfa]]"
          vychazi_z:
            - "[[Brief#Rozpočet]]"
        ---
        Viz [[Brief|tenhle brief]] a [[Brief]], [[Brief#^blok1]], ![[Sablona]] a ![[logo.png]].
        [nabídka](../klient/nabidka.md#cena), [web](https://airine.eu/x.md), [mail](mailto:a@b.cz),
        [abs](/etc/x.md), [kotva](#nahore), [obrázek](foto.jpg), [[#Jen nadpis]].
        `[[v kódu]]`
        ```
        [[v bloku]]
        ```
        """
        let s = Odkazy.vytahni(t)
        #expect(s.contains { $0.cil == "Alfa" && $0.zdroj == .hlavicka && $0.pole == "projekt" })
        #expect(s.contains { $0.cil == "Brief" && $0.kotva == "Rozpočet" && $0.zdroj == .hlavicka && $0.pole == "vychazi_z" })
        #expect(s.filter { $0.cil == "Brief" && $0.zdroj == .telo }.count == 3)
        #expect(s.contains { $0.cil == "Brief" && $0.kotva == "^blok1" })
        #expect(s.contains { $0.cil == "Sablona" && $0.druh == .vlozeni })
        #expect(s.contains { $0.cil == "../klient/nabidka.md" && $0.kotva == "cena" && !$0.wiki })
        #expect(!s.contains { $0.cil.contains("airine.eu") || $0.cil.contains("mailto") || $0.cil.hasPrefix("/") })
        #expect(!s.contains { $0.cil.contains("v kódu") || $0.cil.contains("v bloku") || $0.cil.contains("foto") })
        #expect(!s.contains { $0.cil.isEmpty })
        // Text za | se nikam nedostane.
        #expect(!s.contains { $0.cil.contains("tenhle") })
    }

    @Test func dohledaniCileIdANevyresene() throws {
        let d = try docasnyDomov()
        _ = try soubor(d, "klient/Brief.md", "---\nairine:\n  id: \(idCile)\n---\n")
        _ = try soubor(d, "klient/nabidka.md", "bez hlavičky\n")
        _ = try soubor(d, "archiv/hluboko/Brief.md", "starší\n")
        let cesta = try soubor(d, "projekt/poznamka.md", "[[Brief]] [[brief#Cena]] [[Neexistuje]] ![[logo.png]] [n](../klient/nabidka.md) [x](chybi.md) [[Brief]]\n")
        let url = URL(fileURLWithPath: cesta)
        let (o, oriznuto) = Odkazy.zeSouboru(try String(contentsOf: url, encoding: .utf8), url: url,
                                             koren: d.slozka.appendingPathComponent("prace"))
        #expect(!oriznuto)
        #expect(o.contains(Odkaz(druh: .odkaz, cil_id: idCile, cesta: "../klient/Brief.md", vyreseny: true, pocet: 2)))
        #expect(o.contains(Odkaz(druh: .odkaz, cil_id: idCile, cesta: "../klient/Brief.md", kotva: "Cena", vyreseny: true)))
        #expect(o.contains(Odkaz(druh: .odkaz, nazev: "Neexistuje", vyreseny: false)))
        #expect(o.contains(Odkaz(druh: .odkaz, cesta: "../klient/nabidka.md", vyreseny: true)))
        #expect(o.contains(Odkaz(druh: .odkaz, cesta: "chybi.md", vyreseny: false)))
        #expect(o.count == 5)
    }

    @Test func stropAOriznuti() throws {
        let d = try docasnyDomov()
        let cesta = try soubor(d, "a.md", (0..<520).map { "[[c\($0)]]" }.joined(separator: " "))
        let url = URL(fileURLWithPath: cesta)
        let (o, oriznuto) = Odkazy.zeSouboru(try String(contentsOf: url, encoding: .utf8), url: url, koren: nil)
        #expect(o.count == Odkazy.strop); #expect(oriznuto)
    }

    @Test func vychoziHlaseniOdkazyNeposila() throws {
        let d = try docasnyDomov(); let k = try kopie(d)
        let c = try soubor(d, "b.md", "---\nname: b\ndescription: B\nairine:\n  typ: brief\n---\n[[Jiny]]\n")
        _ = try Nahlasovani(kopie: k).nahlas(cesta: c)
        let h = try #require(try k.fronta().first?.hlaseni)
        #expect(h.odkazy == nil)
        let json = String(decoding: try JSONEncoder().encode(h), as: UTF8.self)
        #expect(!json.contains("odkazy"))
    }

    @Test func zapnuteHlaseniNeseOdkazy() throws {
        let d = try docasnyDomov(); let k = try kopie(d)
        let c = try soubor(d, "b.md", "---\nname: b\ndescription: B\nairine:\n  typ: brief\n---\nbez odkazů\n")
        _ = try Nahlasovani(kopie: k, odkazy: true).nahlas(cesta: c)
        #expect(try k.fronta().first?.hlaseni.odkazy == [])
    }

    @Test func klicJakoNaServeru() throws {
        let d = try docasnyDomov()
        // Kopie téhož souboru (stejné id) ve dvou složkách = jedna položka.
        _ = try soubor(d, "a/Alfa.md", "---\nairine:\n  id: \(idCile)\n---\n")
        _ = try soubor(d, "b/Alfa.md", "---\nairine:\n  id: \(idCile)\n---\n")
        let cesta = try soubor(d, "a/x.md", "[[Alfa]] [k](../b/Alfa.md) [n](./chybi//beta.md) [z](sl\\ozka.md)\n")
        let url = URL(fileURLWithPath: cesta)
        let (o, _) = Odkazy.zeSouboru(try String(contentsOf: url, encoding: .utf8), url: url, koren: d.slozka.appendingPathComponent("prace"))
        #expect(o.filter { $0.cil_id == idCile }.map(\.pocet) == [2])
        #expect(o.contains(Odkaz(druh: .odkaz, cesta: "chybi/beta.md", vyreseny: false)))
        #expect(!o.contains { $0.cesta?.contains("\\") == true })
        #expect(o.allSatisfy { $0.zdroj == .telo && $0.pole == nil })
    }

    @Test func relativniCesta() {
        #expect(Odkazy.relativni("/a/b/c.md", od: "/a/b") == "c.md")
        #expect(Odkazy.relativni("/a/x/c.md", od: "/a/b/d") == "../../x/c.md")
    }
}
