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
        if karty[h.id] == nil, let jine = prevzit[h.otisk] { return OdpovedHlaseni(stav: .uz_prijato, id: jine, otisk: h.otisk) }
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

    /// `/api/katalog/mista/zmizela`; `nil` = server ji ještě nemá (404).
    var zmizelaPrijata: [ZmizeleMisto]? = nil
    func prijimejZmizela() { zmizelaPrijata = [] }
    func zmizela(_ mista: [ZmizeleMisto]) async throws -> Int {
        guard online else { throw ChybaServeru.bezSpojeni }
        guard zmizelaPrijata != nil else { throw ChybaServeru.jine(404, "") }
        zmizelaPrijata! += mista
        return mista.count
    }
    /// Jako převzetí u `katalog_hlaseni` (243): neznámé id se stejným otiskem a cestou.
    var prevzit: [String: String] = [:]          // otisk → id existující karty
    func nastavPrevzeti(otisk: String, id: String) { prevzit[otisk] = id }

    /// Jako `/nahrat` + `/potvrdit`: bajty musí sedět s otiskem, pak se kartě
    /// té verze nastaví `ulozeny_otisk`. `odmitniObsah` = strop nebo kvóta.
    var obsah: [String: Data] = [:]              // "id:otisk" → bajty
    var odmitniObsah = false
    func nastav(odmitniObsah: Bool) { self.odmitniObsah = odmitniObsah }
    func maObsah(_ id: String) -> Bool { obsah.keys.contains { $0.hasPrefix(id + ":") } }

    func nahrajObsah(_ h: Hlaseni, data: Data, mime: String) async throws -> OdpovedHlaseni {
        jednotliveObsahu += 1
        return try await nahrajObsah(h, data: data, mime: mime, zarizeni: nil)
    }

    /// `/obsah-davka`: vypnutá = server ji nemá (404). `pretizit` = jména souborů,
    /// které dostanou poprvé `pretizeno`; `neplatne` / `chyba` = jména, která
    /// v dávce dostanou ten stav.
    var davky: [[String]]? = nil
    var pretizit: Set<String> = []
    var neplatneVDavce: Set<String> = []
    var chybaVDavce: Set<String> = []
    /// 413 pro dávky větší než tolik souborů; `pokusyDavek` = velikosti všech pokusů.
    var velkaNad: Int? = nil
    var pokusyDavek: [Int] = []
    func nastav(velkaNad n: Int?) { velkaNad = n }
    var jednotliveObsahu = 0
    func zapniDavky(pretizit: Set<String> = [], neplatne: Set<String> = [], chyba: Set<String> = []) {
        davky = []; self.pretizit = pretizit; neplatneVDavce = neplatne; chybaVDavce = chyba
    }
    var nastaveni = NastaveniImportu()
    func nastavPravidla(_ p: PravidlaSlozek?) { nastaveni.pravidla = p }
    func nastavStropy(_ s: StropyDavky?) { nastaveni.stropy = s }
    func nastaveniImportu() async throws -> NastaveniImportu { nastaveni }
    func nahrajDavku(_ soubory: [SouborDavky]) async throws -> [VysledekDavky] {
        guard online else { throw ChybaServeru.bezSpojeni }
        guard davky != nil else { throw ChybaServeru.jine(404, "") }
        pokusyDavek.append(soubory.count)
        if let n = velkaNad, soubory.count > n { throw ChybaServeru.davkaVelka }
        davky!.append(soubory.map { $0.hlaseni.name ?? "" })
        var v: [VysledekDavky] = []
        for f in soubory {
            let jmeno = f.hlaseni.name ?? ""
            if pretizit.remove(jmeno) != nil { v.append(VysledekDavky(id: f.hlaseni.id, stav: "pretizeno", retry_after: 0)); continue }
            if neplatneVDavce.contains(jmeno) { v.append(VysledekDavky(id: f.hlaseni.id, stav: "neplatne")); continue }
            if chybaVDavce.contains(jmeno) { v.append(VysledekDavky(id: f.hlaseni.id, stav: "chyba")); continue }
            do {
                let o = try await nahrajObsah(f.hlaseni, data: Data(f.obsah.utf8), mime: f.mime, zarizeni: nil)
                v.append(VysledekDavky(id: o.id, stav: o.stav.rawValue, otisk: o.otisk))
            } catch ChybaServeru.bezPravaKarty { v.append(VysledekDavky(id: f.hlaseni.id, stav: "bez_prava")) }
            catch { v.append(VysledekDavky(id: f.hlaseni.id, stav: "neplatne")) }
        }
        return v
    }

    func nahrajObsah(_ h: Hlaseni, data: Data, mime: String, zarizeni: String?) async throws -> OdpovedHlaseni {
        guard online else { throw ChybaServeru.bezSpojeni }
        if odmitniObsah || Otisk.sha256(data) != h.otisk { throw ChybaServeru.obsahNeprosel("mock") }
        if bezPrava.contains(h.id) { throw ChybaServeru.bezPravaKarty }
        var o = try await nahlas(h, zarizeni: zarizeni)
        obsah["\(h.id):\(h.otisk)"] = data
        if karty[h.id]?.otisk == h.otisk && karty[h.id]?.ulozeny_otisk != h.otisk {
            karty[h.id]!.ulozeny_otisk = h.otisk; zmena(h.id)
        }
        o.ulozeny_otisk = karty[h.id]?.ulozeny_otisk
        return o
    }

    /// Jako `katalog_archivuj()`: jen stav karty, hlášení archiv nemění.
    func archiv(karty ids: [String], archivovat: Bool) async throws -> Int {
        guard online else { throw ChybaServeru.bezSpojeni }
        guard ids.allSatisfy({ karty[$0] != nil && !bezPrava.contains($0) }) else { throw ChybaServeru.bezPravaKarty }
        var n = 0
        for id in ids where (karty[id]!.archivovano_at != nil) != archivovat {
            karty[id]!.archivovano_at = archivovat ? "2026-10-29T15:00:00Z" : nil
            zmena(id); n += 1
        }
        return n
    }
}

/// Klient jednoho zařízení: jako HttpAirine nese zařízení mimo tělo hlášení.
struct ZarizeniMock: AirineAPI {
    let server: MockServer
    let zarizeni: String
    func zmeny(od kurzor: String?, limit: Int) async throws -> Zmeny { try await server.zmeny(od: kurzor, limit: limit) }
    func nahlas(_ h: Hlaseni) async throws -> OdpovedHlaseni { try await server.nahlas(h, zarizeni: zarizeni) }
    func archiv(karty: [String], archivovat: Bool) async throws -> Int { try await server.archiv(karty: karty, archivovat: archivovat) }
    func nahrajObsah(_ h: Hlaseni, data: Data, mime: String) async throws -> OdpovedHlaseni {
        try await server.nahrajObsah(h, data: data, mime: mime, zarizeni: zarizeni)
    }
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
        guard case .zarazeno(let id, _, _) = try n.nahlas(cesta: cesta) else { Issue.record("nezařazeno"); return }
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
        guard case .zarazeno(_, let o1, _) = try n.nahlas(cesta: cesta) else { Issue.record(""); return }
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

@Suite struct ArchivTests {
    let hlavicka = "---\nname: styl\ndescription: d\nairine:\n  typ: pravidla\n  id: a2\n---\n"

    @Test func archivovanaZustaneVKopiiANedoporucujeSe() async throws {
        let d = try docasnyDomov(); let k = try kopie(d); let server = MockServer()
        await server.pridej(Karta(id: "a1", name: "styl", typ: "pravidla", otisk: "o1"))
        await server.pridej(Karta(id: "a2", name: "styl", typ: "pravidla", otisk: "o1"))
        _ = try await server.archiv(karty: ["a2"], archivovat: true)
        _ = try await Synchronizace(kopie: k, api: server).probehni()

        #expect(try k.karta("a2")?.archivovana == true)
        let dop = try Doporuceni(kopie: k, projekt: nil)
        #expect(dop.platne.map(\.id) == ["a1"] && dop.archivovane.map(\.id) == ["a2"])
        #expect(dop.text().contains("Archivované") && dop.text().contains("airine vrat"))
    }

    @Test func zmenaSouboruKartuNeobnoviANezalozi() async throws {
        let d = try docasnyDomov(); let k = try kopie(d); let server = MockServer()
        let cesta = try soubor(d, "styl.md", hlavicka + "x\n")
        try Nahlasovani(kopie: k).nahlas(cesta: cesta)
        _ = try await Synchronizace(kopie: k, api: server).probehni()
        _ = try await server.archiv(karty: ["a2"], archivovat: true)
        _ = try await Synchronizace(kopie: k, api: server).probehni()

        try (hlavicka + "y\n").write(toFile: cesta, atomically: true, encoding: .utf8)
        guard case .zarazeno(let id, _, _) = try Nahlasovani(kopie: k).nahlas(cesta: cesta) else { Issue.record("nezařazeno"); return }
        #expect(id == "a2")                                   // stejná karta, ne nová
        _ = try await Synchronizace(kopie: k, api: server).probehni()
        #expect(await server.karty.count == 1)
        #expect(try k.karta("a2")?.archivovana == true)      // hlášení archiv nezruší
    }

    @Test func vraceniZArchivu() async throws {
        let d = try docasnyDomov(); let k = try kopie(d); let server = MockServer()
        await server.pridej(Karta(id: "a2", name: "styl", typ: "pravidla", otisk: "o1"))
        _ = try await server.archiv(karty: ["a2"], archivovat: true)
        _ = try await Synchronizace(kopie: k, api: server).probehni()
        #expect(try await server.archiv(karty: ["a2"], archivovat: false) == 1)
        _ = try await Synchronizace(kopie: k, api: server).probehni()
        #expect(try Doporuceni(kopie: k, projekt: nil).platne.map(\.id) == ["a2"])
        #expect(try await server.archiv(karty: ["a2"], archivovat: false) == 0)
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
           "vlastnik_jmeno":"Eva","mista":[{"zarizeni_id":"z1","cesta":"/x/brief.md","otisk":"o2","videno_at":"2026-10-27T09:00:00Z"}]},
          {"id":"a6","name":"brief","typ":"brief","otisk":"o2","archivovano_at":"2026-10-29T15:00:00Z","archivoval_id":"u1","cist":true,"menit":true,"mista":[]}
        ],"dalsi":false,"kurzor":"2026-10-27T09:00:00Z|a4","navod_zmenen":true,
         "navod":{"verze":2,"vlastni":false,"obsah":{"verze":1,"pravidla":["Hlas soubory po změně."],"typy":["brief","skill"]},"vychozi_prava":{}}}
        """#
        let z = try JSONDecoder().decode(Zmeny.self, from: Data(json.utf8))
        #expect(z.karty.count == 5 && z.karty[4].archivovana && !z.karty[3].archivovana)
        #expect(z.karty[0].smazano == true && z.karty[1].bez_prava == true)
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
    /// Soubor bez hlavičky dostane kartu jako u importu složky (29. 10. 2026):
    /// jméno ze souboru, typ z cesty, prázdný popis. Do souboru se nepíše.
    @Test func bezHlavickySeHlasiANicNepise() throws {
        let d = try docasnyDomov(); let k = try kopie(d)
        let telo = "---\ndescription: Cizí popis\n---\nx\n"
        let cesta = try soubor(d, "Schůzky/Zápis schůzky.md", telo)
        let v = try Nahlasovani(kopie: k).nahlas(cesta: cesta)
        guard case .zarazeno(let id, _, let rada) = v else { Issue.record("nezařazeno: \(v)"); return }
        #expect(try String(contentsOfFile: cesta, encoding: .utf8) == telo)
        let h = try #require(try k.fronta().first?.hlaseni)
        #expect(h.name == "zapis-schuzky" && h.typ == "zapis" && h.popis == "", "cizí description není naše")
        #expect(rada?.contains("bez popisu") == true && v.proAgenta == rada)
        // Druhé uložení beze změny = táž karta podle cesty, nic nového.
        #expect(try Nahlasovani(kopie: k).nahlas(cesta: cesta) == .beze_zmeny)
        try (telo + "y\n").write(toFile: cesta, atomically: true, encoding: .utf8)
        guard case .zarazeno(let id2, _, _) = try Nahlasovani(kopie: k).nahlas(cesta: cesta) else { Issue.record(""); return }
        #expect(id2 == id)
        #expect(try k.fronta().last?.hlaseni.otisk_predchozi == h.otisk)
    }

    @Test func zlyTvarJmenaSeNehlasi() throws {
        let d = try docasnyDomov(); let k = try kopie(d)
        let cesta = try soubor(d, "a.md", "---\nairine:\n  name: Zápis Schůzky\n---\nx\n")
        let v = try Nahlasovani(kopie: k).nahlas(cesta: cesta)
        #expect(v == .bezKarty(chybi: ["name"], navrhJmena: "zapis-schuzky"))
        #expect(try k.fronta().isEmpty)
    }

    @Test func popisAVazbyZKartyZustanou() async throws {
        let d = try docasnyDomov(); let k = try kopie(d); let server = MockServer()
        let cesta = try soubor(d, "brief.md", "jen text\n")
        guard case .zarazeno(let id, _, _) = try Nahlasovani(kopie: k).nahlas(cesta: cesta) else { Issue.record(""); return }
        _ = try await Synchronizace(kopie: k, api: server).probehni()
        // Popis doplněný v Revizi se novou verzí souboru nesmaže.
        var karta = try #require(try k.karta(id)); karta.popis = "Doplněno v Airine"; karta.typ = "postup"
        try k.ulozKarty([karta])
        try "jiný text\n".write(toFile: cesta, atomically: true, encoding: .utf8)
        guard case .zarazeno(_, _, let rada) = try Nahlasovani(kopie: k).nahlas(cesta: cesta) else { Issue.record(""); return }
        let h = try #require(try k.fronta().last?.hlaseni)
        #expect(h.popis == "Doplněno v Airine" && h.typ == "postup")
        #expect(rada == nil)
    }

    @Test func typZCestyJakoImport() {
        #expect(Nahlasovani.typZCesty("/G/Klienti/Brief webu.md", koren: "/G") == "brief")
        #expect(Nahlasovani.typZCesty("/G/Nabídky/2026/x.md", koren: "/G") == "nabidka")
        #expect(Nahlasovani.typZCesty("/G/Návody/a.md", koren: "/G") == "postup")
        #expect(Nahlasovani.typZCesty("/G/Briefing/a.md", koren: "/G") == "brief")
        #expect(Nahlasovani.typZCesty("/G/Debrief/a.md", koren: "/G") == "poznamky", "slovo musí začínat")
        #expect(Nahlasovani.typZCesty("/G/x/SKILL.md", koren: "/G") == "skill")
        #expect(Nahlasovani.typZCesty("/Brief/a.md", koren: "/Brief") == "poznamky", "název vybrané složky se nepočítá")
        #expect(Nahlasovani.jmenoZCesty("/G/nabidka/SKILL.md") == "nabidka")
        #expect(Nahlasovani.jmenoZCesty("/G/!!!.md") == "soubor")
    }

    @Test func dokumentSWatermarkemSePreskoci() throws {
        let d = try docasnyDomov(); let k = try kopie(d)
        let telo = "<!-- airine vlastnik=alfa psali=alfa zmeneno=2026-10-28 obsah=1234abcd -->\n# Roadmapa\n"
        let cesta = try soubor(d, "roadmap.md", telo)
        let v = try Nahlasovani(kopie: k).nahlas(cesta: cesta)
        #expect(v == .preskoceno("dokument s watermarkem"))
        #expect(v.proAgenta == nil)
        #expect(try String(contentsOfFile: cesta, encoding: .utf8) == telo)
        #expect(try k.fronta().isEmpty)
        // Komentář, který není watermark, hlášení nezastaví.
        let jiny = try soubor(d, "jiny.md", "<!-- poznamka -->\n# X\n")
        #expect(try Nahlasovani(kopie: k).nahlas(cesta: jiny) != .preskoceno("dokument s watermarkem"))
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

@Suite struct ObsahTests {
    let briefText = "---\nname: brief\ndescription: Brief\nairine:\n  typ: brief\n  id: ob1\n---\nTělo briefu\n"

    @Test func synchronizacePosleObsahSKartou() async throws {
        let d = try docasnyDomov(); let k = try kopie(d); let server = MockServer()
        let cesta = try soubor(d, "brief.md", briefText)
        try Nahlasovani(kopie: k).nahlas(cesta: cesta)
        let v = try await Synchronizace(kopie: k, api: server).probehni()
        #expect(v.odeslano == 1 && v.obsahu == 1 && v.bezObsahu.isEmpty)
        #expect(await server.maObsah("ob1"))
        #expect(try k.karta("ob1")?.neniVAirine == false, "kanál změn přinese ulozeny_otisk")
    }

    @Test func vypnutyObsahPosleJenKartu() async throws {
        let d = try docasnyDomov(); let k = try kopie(d); let server = MockServer()
        try Nahlasovani(kopie: k).nahlas(cesta: try soubor(d, "brief.md", briefText))
        let v = try await Synchronizace(kopie: k, api: server, obsah: false).probehni()
        #expect(v.odeslano == 1 && v.obsahu == 0)
        #expect(await !server.maObsah("ob1"))
        #expect(try k.karta("ob1")?.neniVAirine == true)
    }

    @Test func zmenenySouborPosleJenKartu() async throws {
        let d = try docasnyDomov(); let k = try kopie(d); let server = MockServer()
        let cesta = try soubor(d, "brief.md", briefText)
        try Nahlasovani(kopie: k).nahlas(cesta: cesta)
        try (briefText + "dopsáno\n").write(toFile: cesta, atomically: true, encoding: .utf8)
        let v = try await Synchronizace(kopie: k, api: server).probehni()
        #expect(v.odeslano == 1 && v.obsahu == 0, "jiné bajty než nahlášená verze nikdy neodejdou")
        #expect(await !server.maObsah("ob1"))
    }

    @Test func odmitnutyObsahNezastaviKartu() async throws {
        let d = try docasnyDomov(); let k = try kopie(d); let server = MockServer()
        try Nahlasovani(kopie: k).nahlas(cesta: try soubor(d, "brief.md", briefText))
        await server.nastav(odmitniObsah: true)
        let v = try await Synchronizace(kopie: k, api: server).probehni()
        #expect(v.odeslano == 1 && v.obsahu == 0 && v.bezObsahu == ["ob1"])
        #expect(try k.fronta().isEmpty)
        #expect(try k.karta("ob1")?.name == "brief")
    }

    @Test func dohnaniPosleJenPresneVerzeANicNemeni() async throws {
        let d = try docasnyDomov(); let k = try kopie(d); let server = MockServer()
        let koren = d.slozka.appendingPathComponent("prace")
        let shodny = try soubor(d, "a.md", "A\n")
        _ = try soubor(d, "b.md", "B změněno\n")
        _ = try soubor(d, "Klienti/c.md", "C\n")
        // Soubor vedle kořene: „../mimo.md“ by na něj dosáhl, kdyby se z kořene smělo vyjít.
        try "U\n".write(to: d.slozka.appendingPathComponent("mimo.md"), atomically: true, encoding: .utf8)
        let karty = [
            Karta(id: "a", name: "a", popis: "A", typ: "brief", otisk: Otisk.sha256(Data("A\n".utf8)), mista: [Misto(cesta: shodny)]),
            Karta(id: "b", name: "b", popis: "B", typ: "brief", otisk: Otisk.sha256(Data("B\n".utf8)), mista: [Misto(cesta: koren.appendingPathComponent("b.md").path)]),
            Karta(id: "c", name: "c", popis: "C", typ: "zapis", otisk: Otisk.sha256(Data("C\n".utf8)), mista: [Misto(cesta: "Klienti/c.md")]),
            Karta(id: "x", name: "x", popis: "X", typ: "zapis", otisk: Otisk.sha256(Data("X\n".utf8)), mista: [Misto(cesta: "/nikde/x.md")]),
            Karta(id: "u", name: "u", popis: "U", typ: "zapis", otisk: Otisk.sha256(Data("U\n".utf8)), mista: [Misto(cesta: "../mimo.md")]),
        ]
        for var c in karty { c.menit = true; await server.pridej(c) }
        _ = try await Synchronizace(kopie: k, api: server).probehni()

        let zk = try await Obsah.dohon(kopie: k, api: server, koreny: [koren], zkouska: true)
        var bezPoradi = zk; bezPoradi.soubory.sort()
        #expect(bezPoradi == Obsah.Dohnani(nahrano: 2, bezSouboru: 2, jinaVerze: 1,
                                           soubory: [shodny, koren.appendingPathComponent("Klienti/c.md").path].sorted()), "„../“ z kořene nevede")
        #expect(await !server.maObsah("a"), "zkouška nic neposílá")

        let v = try await Obsah.dohon(kopie: k, api: server, koreny: [koren])
        #expect(v.nahrano == 2 && v.jinaVerze == 1 && v.bezSouboru == 2 && v.chyby.isEmpty)
        let (ma, mc, mb) = (await server.maObsah("a"), await server.maObsah("c"), await server.maObsah("b"))
        #expect(ma && mc && !mb)
        #expect(await server.pocetVerzi("a") == 1, "dohnání nezakládá novou verzi")
        let a = await server.karty["a"]
        #expect(a?.popis == "A" && a?.typ == "brief" && a?.ulozeny_otisk == a?.otisk)

        // Podruhé už není co poslat.
        _ = try await Synchronizace(kopie: k, api: server).probehni()
        let znovu = try await Obsah.dohon(kopie: k, api: server, koreny: [koren])
        #expect(znovu.nahrano == 0)
    }

    @Test func dohnaniJdePoDavkachDoStropu() async throws {
        let d = try docasnyDomov(); let k = try kopie(d); let server = MockServer()
        for j in ["a", "b", "c", "e", "f"] {
            let c = try soubor(d, "\(j).md", "\(j)\n")
            var karta = Karta(id: j, name: j, popis: j, typ: "brief", otisk: Otisk.sha256(Data("\(j)\n".utf8)), mista: [Misto(cesta: c)])
            karta.menit = true
            await server.pridej(karta)
        }
        _ = try await Synchronizace(kopie: k, api: server).probehni()
        try k.nastavStav("stropy_davky", StropyDavky(souboru: 2, bajtu: 3_500_000))
        await server.zapniDavky(pretizit: ["b"], chyba: ["c"])
        let v = try await Obsah.dohon(kopie: k, api: server)
        #expect(v.nahrano == 5 && v.chyby.isEmpty && v.online)
        let davky = try #require(await server.davky)     // pořadí karet v kopii není dané
        #expect(davky.count == 4 && davky.allSatisfy { $0.count <= 2 }, "po dvou")
        #expect(davky.flatMap { $0 }.sorted() == ["a", "b", "b", "c", "e", "f"], "přetížený znovu sám")
        #expect(davky.contains(["b"]))
        #expect(await server.jednotliveObsahu == 1, "chyba jde ještě jednou po jednom")
        for j in ["a", "b", "c", "e", "f"] { #expect(try k.karta(j)?.ulozeny_otisk != nil) }
        _ = try await Synchronizace(kopie: k, api: server).probehni()
        #expect(try await Obsah.dohon(kopie: k, api: server).nahrano == 0)
    }

    @Test func dohnaniNa413Puli() async throws {
        let d = try docasnyDomov(); let k = try kopie(d); let server = MockServer()
        for j in ["a", "b", "c", "e"] {
            let c = try soubor(d, "\(j).md", "\(j)\n")
            var karta = Karta(id: j, name: j, popis: j, typ: "brief", otisk: Otisk.sha256(Data("\(j)\n".utf8)), mista: [Misto(cesta: c)])
            karta.menit = true
            await server.pridej(karta)
        }
        _ = try await Synchronizace(kopie: k, api: server).probehni()
        await server.zapniDavky(); await server.nastav(velkaNad: 1)
        let v = try await Obsah.dohon(kopie: k, api: server)
        #expect(v.nahrano == 4 && v.chyby.isEmpty && v.online)
        #expect(await server.pokusyDavek == [4, 2, 1, 1, 2, 1, 1])
        #expect(await server.jednotliveObsahu == 0)
    }

    @Test func stropyDavkyZeServeru() async throws {
        #expect(StropyDavky.zeServeru(["obsah_davka": 50, "obsah_davka_bajtu": 3_500_000]) == .vychozi)
        #expect(StropyDavky.zeServeru([:]) == nil)
        #expect(StropyDavky.zeServeru(["obsah_davka": 1, "obsah_davka_bajtu": 3_500_000]) == nil)
        let d = try docasnyDomov(); let k = try kopie(d); let server = MockServer()
        #expect(k.stropyDavky() == .vychozi)
        await server.nastavStropy(StropyDavky(souboru: 20, bajtu: 1_000_000))
        _ = try await Synchronizace(kopie: k, api: server).probehni()
        #expect(k.stropyDavky() == StropyDavky(souboru: 20, bajtu: 1_000_000))
    }

    @Test func dohnaniPreskociCiziKartyAVypadek() async throws {
        let d = try docasnyDomov(); let k = try kopie(d); let server = MockServer()
        let cesta = try soubor(d, "a.md", "A\n")
        var cizi = Karta(id: "cz", name: "cz", popis: "C", typ: "brief", otisk: Otisk.sha256(Data("A\n".utf8)), mista: [Misto(cesta: cesta)])
        cizi.menit = false
        await server.pridej(cizi)
        _ = try await Synchronizace(kopie: k, api: server).probehni()
        let v = try await Obsah.dohon(kopie: k, api: server)
        #expect(v.bezPrava == 1 && v.nahrano == 0)

        var moje = cizi; moje.id = "mj"; moje.menit = true
        await server.pridej(moje)
        _ = try await Synchronizace(kopie: k, api: server).probehni()
        await server.nastav(online: false)
        let w = try await Obsah.dohon(kopie: k, api: server)
        #expect(!w.online && w.zbyva == 1)
    }

    @Test func vynechaniPoCelychSlozkach() {
        let vz = ["Claude/Code/Aktivita/", "**/.claude/worktrees/", "/Users/o/Tajne"]
        #expect(Obsah.vynechano("/Users/o/Groovio/Claude/Code/Aktivita/2026-10-20.md", vz))
        #expect(Obsah.vynechano("/Users/o/Groovio/Web/.claude/worktrees/x/CLAUDE.md", vz))
        #expect(Obsah.vynechano("/Users/o/Tajne/a.md", vz))
        #expect(!Obsah.vynechano("/Users/o/Groovio/Claude/Code/Aktivita-stara/a.md", vz), "po složkách, ne po znacích")
        #expect(!Obsah.vynechano("/Users/o/Tajnejsi/a.md", vz))
        #expect(!Obsah.vynechano("/Users/o/Groovio/Web/.claude/CLAUDE.md", vz))
        #expect(!Obsah.vynechano("/a/b.md", ["", "/"]), "prázdný vzor nevynechá všechno")
    }

    @Test func vynechanySouborJdeJenJakoKarta() async throws {
        let d = try docasnyDomov(); let k = try kopie(d); let server = MockServer()
        let cesta = try soubor(d, "Aktivita/brief.md", briefText)
        try Nahlasovani(kopie: k).nahlas(cesta: cesta)
        let v = try await Synchronizace(kopie: k, api: server, vynechat: ["Aktivita"]).probehni()
        #expect(v.odeslano == 1 && v.obsahu == 0)
        #expect(await !server.maObsah("ob1"))

        let w = try await Obsah.dohon(kopie: k, api: server, vynechat: ["Aktivita/"])
        #expect(w.vynechano == 1 && w.nahrano == 0)
        let x = try await Obsah.dohon(kopie: k, api: server)
        #expect(x.nahrano == 1, "bez vynechání obsah dožene")

        let stare = #"{"server":"s","zarizeni":"z","nazevZarizeni":"Mac"}"#
        #expect(try JSONDecoder().decode(Nastaveni.self, from: Data(stare.utf8)).vynechatObsah.isEmpty)
    }

    @Test func nastaveniBezKliceZnamenaPosilat() throws {
        let stare = #"{"server":"https://app.airine.eu","zarizeni":"z1","nazevZarizeni":"Mac"}"#
        #expect(try JSONDecoder().decode(Nastaveni.self, from: Data(stare.utf8)).posilatObsah)
        var n = Nastaveni(server: "s", zarizeni: "z", nazevZarizeni: "Mac")
        n.posilatObsah = false
        let zpet = try JSONDecoder().decode(Nastaveni.self, from: JSONEncoder().encode(n))
        #expect(!zpet.posilatObsah)
    }

    @Test func soubory() throws {
        let d = try docasnyDomov()
        let c = try soubor(d, "x.md", "X\n")
        #expect(Obsah.nacti(cesta: c, otisk: Otisk.sha256(Data("X\n".utf8)))?.mime == "text/markdown")
        #expect(Obsah.nacti(cesta: c, otisk: Otisk.sha256(Data("Y\n".utf8))) == nil)
        let png = try soubor(d, "x.png", "X\n")
        #expect(Obsah.nacti(cesta: png, otisk: Otisk.sha256(Data("X\n".utf8))) == nil, "server bere jen text")
        let velky = try soubor(d, "v.md", String(repeating: "a ", count: Obsah.maxBajtu / 2 + 1))
        #expect(Obsah.nacti(cesta: velky, otisk: Otisk.sha256(try Data(contentsOf: URL(fileURLWithPath: velky)))) == nil)
        if case .failure(let duvod) = Obsah.zkontroluj(cesta: velky, otisk: "x") { #expect(duvod == .velky) } else { Issue.record("velký prošel") }
    }

    @Test func tajemstviNeodejdou() async throws {
        let tajne = [
            "OPENAI=sk-proj-abcdefghijklmnopqrstuv1234",
            "klic: airine_" + String(repeating: "a1", count: 20),
            "api_key = \"Zx81kQpLmN0vB7rT\"",
            "Heslo: Velbloud.2026.Praha",
            "-----BEGIN OPENSSH PRIVATE KEY-----",
            "Authorization: Bearer abcdefghijklmnopqrstuvwxyz012345",
            "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U",
            String(repeating: "QUJD", count: 25),
        ]
        for t in tajne { #expect(!Obsah.tajemstvi(Data(t.utf8)).isEmpty, "\(t)") }
        let nevinne = [
            "Design tokeny: barvy jsou token --blue a --ink.",
            "token: var(--blue)",
            "Heslo nikdy nepiš do briefu, patří do Klíčenky.",
            "Bearer token se posílá v hlavičce.",
            "otisk 3a7bd3e2360a3d29eea436fcfb7e44c735d117c42d1c1835420b6b9942dd4f1b",
        ]
        for t in nevinne { #expect(Obsah.tajemstvi(Data(t.utf8)).isEmpty, "\(t)") }

        // Dohnání soubor s tajemstvím vypíše a obsah nepošle; karta zůstane.
        let d = try docasnyDomov(); let k = try kopie(d); let server = MockServer()
        let text = "# Přístupy\napi_key: Zx81kQpLmN0vB7rT\n"
        let cesta = try soubor(d, "pristupy.md", text)
        var karta = Karta(id: "t", name: "t", popis: "T", typ: "zapis", otisk: Otisk.sha256(Data(text.utf8)), mista: [Misto(cesta: cesta)])
        karta.menit = true
        await server.pridej(karta)
        _ = try await Synchronizace(kopie: k, api: server).probehni()
        let v = try await Obsah.dohon(kopie: k, api: server)
        #expect(v.nahrano == 0 && v.tajne == [cesta])
        #expect(await !server.maObsah("t"))

        // Ani běžné hlášení z hooku obsah s tajemstvím nepošle.
        try Nahlasovani(kopie: k).nahlas(cesta: try soubor(d, "brief.md", briefText + "token = ghp_" + String(repeating: "A", count: 36) + "\n"))
        let s = try await Synchronizace(kopie: k, api: server).probehni()
        #expect(s.odeslano == 1 && s.obsahu == 0)
        #expect(await !server.maObsah("ob1"))
    }
}

/// Podstrčený server pro HttpAirine: zapisuje požadavky, odpovídá podle cesty.
final class Podstrceny: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var pozadavky: [URLRequest] = []
    nonisolated(unsafe) static var tela: [Data] = []
    nonisolated(unsafe) static var odpoved: (URLRequest) -> (Int, String) = { _ in (500, "") }
    nonisolated(unsafe) static var hlavicky: (URLRequest) -> [String: String]? = { _ in nil }
    static let zamek = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var telo = request.httpBody ?? Data()
        if let s = request.httpBodyStream {
            s.open(); var buf = [UInt8](repeating: 0, count: 4096)
            while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; telo.append(buf, count: n) }
            s.close()
        }
        Self.zamek.lock(); Self.pozadavky.append(request); Self.tela.append(telo); let (kod, json) = Self.odpoved(request); Self.zamek.unlock()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: kod, httpVersion: nil, headerFields: Self.hlavicky(request))!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct HttpObsahTests {
    func api() -> HttpAirine {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [Podstrceny.self]
        return HttpAirine(nastaveni: Nastaveni(server: "https://app.test", zarizeni: "z1", nazevZarizeni: "Mac"),
                          token: "airine_tajny", session: URLSession(configuration: cfg))
    }
    let h = Hlaseni(id: "k1", name: "brief", popis: "B", typ: "brief", cesta: "/x/brief.md", otisk: Otisk.sha256(Data("A\n".utf8)), radku: 1, bajty: 2)

    @Test func triKrokyATokenNejdeDoUloziste() async throws {
        Podstrceny.pozadavky = []; Podstrceny.tela = []
        Podstrceny.odpoved = { r in
            switch r.url!.path {
            case "/api/katalog/k1/nahrat": return (201, #"{"upload_url":"https://sb.test/storage/v1/object/upload/sign/b/ws/katalog/k1/o.md?token=t","method":"PUT","headers":{"Content-Type":"text/markdown"},"ulozeno":"ws/katalog/k1/o.md"}"#)
            case "/storage/v1/object/upload/sign/b/ws/katalog/k1/o.md": return (200, "{}")
            case "/api/katalog/k1/potvrdit": return (200, #"{"stav":"ok","id":"k1","otisk":"o","ulozeny_otisk":"o"}"#)
            default: return (404, "")
            }
        }
        let o = try await api().nahrajObsah(h, data: Data("A\n".utf8), mime: "text/markdown")
        #expect(o.stav == .ok && o.ulozeny_otisk == "o")
        let p = Podstrceny.pozadavky
        #expect(p.map { $0.url!.host! } == ["app.test", "sb.test", "app.test"])
        #expect(p[0].value(forHTTPHeaderField: "x-api-key") == "airine_tajny")
        #expect(p[1].value(forHTTPHeaderField: "x-api-key") == nil && p[1].value(forHTTPHeaderField: "x-airine-zarizeni") == nil)
        #expect(p[1].httpMethod == "PUT" && Podstrceny.tela[1] == Data("A\n".utf8))
        let potvrzeni = try #require(try JSONSerialization.jsonObject(with: Podstrceny.tela[2]) as? [String: Any])
        #expect(potvrzeni["ulozeno"] as? String == "ws/katalog/k1/o.md" && potvrzeni["name"] as? String == "brief")
    }

    @Test func na503SRetryAfterPockaAZkusiZnovu() async throws {
        Podstrceny.pozadavky = []; Podstrceny.tela = []
        Podstrceny.hlavicky = { _ in ["Retry-After": "0"] }
        defer { Podstrceny.hlavicky = { _ in nil } }
        Podstrceny.odpoved = { _ in Podstrceny.pozadavky.count < 2 ? (503, "{}") : (200, #"{"stav":"ok","id":"k1","otisk":"o"}"#) }
        #expect(try await api().nahlas(h).stav == .ok)
        #expect(Podstrceny.pozadavky.count == 2)
        // Přetížení trvá: po dvou pokusech se hlášení vrátí do fronty.
        Podstrceny.pozadavky = []
        Podstrceny.odpoved = { _ in (503, "{}") }
        await #expect(throws: ChybaServeru.bezSpojeni) { try await api().nahlas(h) }
        #expect(Podstrceny.pozadavky.count == 3)
        // 503 bez Retry-After se nezkouší znovu.
        Podstrceny.pozadavky = []
        Podstrceny.hlavicky = { _ in nil }
        await #expect(throws: ChybaServeru.bezSpojeni) { try await api().nahlas(h) }
        #expect(Podstrceny.pozadavky.count == 1)
    }

    @Test func davkaPosilaObsahA413JeDavkaVelka() async throws {
        Podstrceny.pozadavky = []; Podstrceny.tela = []
        Podstrceny.odpoved = { _ in (200, #"{"vysledky":[{"id":"k1","stav":"ok","otisk":"o"}]}"#) }
        let v = try await api().nahrajDavku([SouborDavky(hlaseni: h, mime: "text/markdown", obsah: "A\n")])
        #expect(v == [VysledekDavky(id: "k1", stav: "ok", otisk: "o")])
        #expect(Podstrceny.pozadavky.first?.url?.path == "/api/katalog/obsah-davka")
        let telo = try #require(try JSONSerialization.jsonObject(with: Podstrceny.tela[0]) as? [String: Any])
        let f = try #require((telo["soubory"] as? [[String: Any]])?.first)
        #expect(f["obsah"] as? String == "A\n" && f["mime"] as? String == "text/markdown" && f["otisk"] as? String == h.otisk && f["name"] as? String == "brief")
        Podstrceny.odpoved = { _ in (413, "{}") }
        await #expect(throws: ChybaServeru.davkaVelka) {
            try await api().nahrajDavku([SouborDavky(hlaseni: h, mime: "text/markdown", obsah: "A\n")])
        }
    }

    @Test func uzNahranoPreskociPutAKvotaJeObsahNeprosel() async throws {
        Podstrceny.pozadavky = []; Podstrceny.tela = []
        Podstrceny.odpoved = { r in
            r.url!.path.hasSuffix("/nahrat") ? (200, #"{"uz_nahrano":true,"ulozeno":"ws/k1/o.md"}"#) : (200, #"{"stav":"uz_prijato","id":"k1"}"#)
        }
        _ = try await api().nahrajObsah(h, data: Data("A\n".utf8), mime: "text/markdown")
        #expect(Podstrceny.pozadavky.count == 2 && Podstrceny.pozadavky.allSatisfy { $0.url!.host == "app.test" })

        Podstrceny.odpoved = { _ in (413, #"{"code":"uloziste_plne"}"#) }
        await #expect(throws: ChybaServeru.obsahNeprosel("nahrat 413")) {
            try await api().nahrajObsah(h, data: Data("A\n".utf8), mime: "text/markdown")
        }
        Podstrceny.odpoved = { r in
            r.url!.path.hasSuffix("/nahrat") ? (200, #"{"uz_nahrano":true,"ulozeno":"ws/k1/o.md"}"#) : (403, #"{"stav":"bez_prava","id":"k1"}"#)
        }
        await #expect(throws: ChybaServeru.bezPravaKarty) {
            try await api().nahrajObsah(h, data: Data("A\n".utf8), mime: "text/markdown")
        }
    }
}

@Suite struct SlozkyTests {
    let text = "---\nname: brief\ndescription: Brief\nairine:\n  typ: brief\n  id: sl1\n---\nTělo\n"

    @Test func pravidla() {
        let s = ["/Users/o/Groovio", "~/Desktop/Druha/"]
        #expect(Slozky.duvod("/Users/o/Groovio/Klienti/a.md", s) == nil)
        #expect(Slozky.duvod((("~/Desktop/Druha/b.md") as NSString).expandingTildeInPath, s) == nil)
        #expect(Slozky.duvod("/Users/o/Groovio-stare/a.md", s) == "mimo složky pro Znalosti", "po složkách, ne po znacích")
        #expect(Slozky.duvod("/Users/o/Jinde/a.md", s) == "mimo složky pro Znalosti")
        #expect(Slozky.duvod("/Users/o/Groovio/Web/.claude/worktrees/x/CLAUDE.md", s) == "pracovní kopie repozitáře")
        #expect(Slozky.duvod("/Users/o/Jinde/.claude/worktrees/x/a.md", []) == "pracovní kopie repozitáře")
        #expect(Slozky.duvod("/Users/o/Groovio/.git/a.md", s) == "knihovna nebo sestavení")
        #expect(Slozky.duvod("/Users/o/Groovio/Web/.obsidian/a.md", s) == "skrytá složka")
        #expect(Slozky.duvod("/Users/o/Groovio/.claude/skills/x/SKILL.md", s) == nil, "skills ve skryté složce se hlásí")
        #expect(Slozky.duvod("/Users/o/Groovio/.cursor/rules/a.mdc", s) == nil)
        #expect(Slozky.duvod("/Users/o/Groovio/.claude/settings/a.md", s) == "skrytá složka")
        #expect(Slozky.duvod("/Users/o/.claude/skills/x/SKILL.md", ["/Users/o/.claude"]) == nil, "skrytá vybraná složka sama nevadí")
        #expect(Slozky.duvod("/Users/o/Groovio/a.md", [])?.hasPrefix("není vybraná") == true)
    }

    @Test func hlasiJenVeVybranychSlozkach() throws {
        let d = try docasnyDomov(); let k = try kopie(d)
        let uvnitr = try soubor(d, "Znalosti/brief.md", text)
        let mimo = try soubor(d, "Jinde/brief.md", text.replacingOccurrences(of: "sl1", with: "sl2"))
        let bezHlavicky = try soubor(d, "Jinde/bez.md", "# Bez hlavičky\n")
        let vybrane = [d.slozka.appendingPathComponent("prace/Znalosti").path]

        #expect(try Nahlasovani(kopie: k, slozky: []).nahlas(cesta: uvnitr) == .preskoceno(Slozky.duvod(uvnitr, [])!), "nic, dokud nevybere")
        #expect(try Nahlasovani(kopie: k, slozky: vybrane).nahlas(cesta: mimo) == .preskoceno("mimo složky pro Znalosti"))
        #expect(try Nahlasovani(kopie: k, slozky: vybrane).nahlas(cesta: bezHlavicky) == .preskoceno("mimo složky pro Znalosti"),
                "mimo složky ani rada agentovi")
        guard case .zarazeno = try Nahlasovani(kopie: k, slozky: vybrane).nahlas(cesta: uvnitr) else { Issue.record("uvnitř se nenahlásil"); return }
        #expect(try k.fronta().map(\.hlaseni.id) == ["sl1"])
    }

    @Test func dohnaniJenVeVybranychSlozkach() async throws {
        let d = try docasnyDomov(); let k = try kopie(d); let server = MockServer()
        let a = try soubor(d, "Znalosti/a.md", "A\n"), b = try soubor(d, "Jinde/b.md", "B\n")
        for (id, c, t) in [("a", a, "A\n"), ("b", b, "B\n")] {
            var karta = Karta(id: id, name: id, popis: id, typ: "zapis", otisk: Otisk.sha256(Data(t.utf8)), mista: [Misto(cesta: c)])
            karta.menit = true
            await server.pridej(karta)
        }
        _ = try await Synchronizace(kopie: k, api: server).probehni()
        let v = try await Obsah.dohon(kopie: k, api: server, slozky: [d.slozka.appendingPathComponent("prace/Znalosti").path])
        #expect(v.nahrano == 1 && v.mimoSlozky == 1)
        let (ma, mb) = (await server.maObsah("a"), await server.maObsah("b"))
        #expect(ma && !mb)
    }

    @Test func nastaveniBezSlozekJePrazdne() throws {
        let stare = #"{"server":"s","zarizeni":"z","nazevZarizeni":"Mac"}"#
        #expect(try JSONDecoder().decode(Nastaveni.self, from: Data(stare.utf8)).slozky.isEmpty)
    }
}

@Suite struct HlidaniTests {
    let sHlavickou = "---\nname: brief\ndescription: Brief\nairine:\n  typ: brief\n---\nTělo\n"

    func slozky(_ d: Domov) -> [String] { [d.slozka.appendingPathComponent("prace/Znalosti").path] }

    @Test func zmenaNovySouborASmazani() async throws {
        let d = try docasnyDomov(); let k = try kopie(d); let server = MockServer()
        let h = Hlidani(kopie: k, slozky: slozky(d), zarizeni: "z1")
        let rucne = try soubor(d, "Znalosti/Poznámky/porada.md", "# Porada\n")
        let mimo = try soubor(d, "Jinde/a.md", "# A\n")
        let agent = try soubor(d, "Znalosti/brief.md", sHlavickou)
        var v = try h.zpracuj([rucne, mimo, agent])
        #expect(v.nove == 2 && v.preskoceno == 1)
        #expect(try String(contentsOfFile: agent, encoding: .utf8) == sHlavickou, "hlídání do souboru nepíše ani id")
        // Editor uloží dvakrát totéž: nic nového.
        v = try h.zpracuj([rucne])
        #expect(v.bezeZmeny == 1 && v.zarazeno == 0)
        _ = try await Synchronizace(kopie: k, api: server).probehni()
        #expect(try k.fronta().isEmpty)

        try FileManager.default.removeItem(atPath: rucne)
        v = try h.zpracuj([rucne])
        #expect(v.zmizelo == 1)
        #expect(try k.zmizela().map(\.cesta) == [rucne])
        // Server cestu ještě nemá: místo počká, karta zůstane.
        var s = try await Synchronizace(kopie: k, api: server).probehni()
        #expect(try s.online && s.zmizelo == 0 && k.zmizela().count == 1)
        #expect(try k.karty().count == 2)
        await server.prijimejZmizela()
        s = try await Synchronizace(kopie: k, api: server).probehni()
        #expect(try s.zmizelo == 1 && k.zmizela().isEmpty)
        #expect(await server.zmizelaPrijata?.map(\.cesta) == [rucne])
        // Druhá událost téže cesty ani porovnání po startu už nic nezařadí.
        #expect(try h.zpracuj([rucne]).zmizelo == 0)
        #expect(try h.porovnej().zmizelo == 0)
        // Soubor se vrátil: nahlásí se a místo zase hlídáme.
        try "# Porada\n".write(toFile: rucne, atomically: true, encoding: .utf8)
        _ = try h.zpracuj([rucne])
        try FileManager.default.removeItem(atPath: rucne)
        #expect(try h.zpracuj([rucne]).zmizelo == 1)
    }

    @Test func presunJeTataKarta() async throws {
        let d = try docasnyDomov(); let k = try kopie(d); let server = MockServer()
        let h = Hlidani(kopie: k, slozky: slozky(d), zarizeni: nil)
        let stara = try soubor(d, "Znalosti/a/porada.md", "# Porada\n")
        _ = try h.zpracuj([stara])
        let id = try #require(try k.fronta().first?.hlaseni.id)
        _ = try await Synchronizace(kopie: k, api: server).probehni()
        let nova = d.slozka.appendingPathComponent("prace/Znalosti/b/porada.md").path
        try FileManager.default.createDirectory(atPath: (nova as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try FileManager.default.moveItem(atPath: stara, toPath: nova)
        let v = try h.zpracuj([stara, nova])
        #expect(v.zmizelo == 1 && v.zmenene == 1 && v.nove == 0)
        let hl = try #require(try k.fronta().first?.hlaseni)
        #expect(hl.id == id && hl.cesta == nova)
    }

    @Test func smazanaSlozka() async throws {
        let d = try docasnyDomov(); let k = try kopie(d)
        let h = Hlidani(kopie: k, slozky: slozky(d), zarizeni: nil)
        let a = try soubor(d, "Znalosti/Stare/a.md", "A\n"), b = try soubor(d, "Znalosti/Stare/b.md", "B\n")
        _ = try h.zpracuj([a, b])
        try FileManager.default.removeItem(atPath: (a as NSString).deletingLastPathComponent)
        #expect(try h.zpracuj([(a as NSString).deletingLastPathComponent]).zmizelo == 2)
    }

    @Test func porovnaniPoStartu() throws {
        let d = try docasnyDomov(); let k = try kopie(d)
        _ = try soubor(d, "Znalosti/a.md", "A\n")
        _ = try soubor(d, "Znalosti/.git/x.md", "X\n")
        _ = try soubor(d, "Znalosti/.obsidian/x.md", "X\n")
        _ = try soubor(d, "Znalosti/.claude/worktrees/w/b.md", "B\n")
        _ = try soubor(d, "Znalosti/.claude/skills/nabidka/SKILL.md", "---\nname: nabidka\ndescription: Nabídka\n---\nx\n")
        _ = try soubor(d, "Znalosti/obrazek.png", "P")
        _ = try soubor(d, "Jinde/c.md", "C\n")
        let zkouska = try Hlidani(kopie: k, slozky: slozky(d), zarizeni: nil, zkouska: true).porovnej()
        #expect(try zkouska.nove == 2 && k.fronta().isEmpty, "zkouška nic nezařadí")
        let v = try Hlidani(kopie: k, slozky: slozky(d), zarizeni: nil).porovnej()
        #expect(v.nove == 2)
        #expect(Set(try k.fronta().map(\.hlaseni.name)) == ["a", "nabidka"])
        #expect(try Hlidani(kopie: k, slozky: slozky(d), zarizeni: nil).porovnej().bezeZmeny == 2)
        #expect(try Hlidani(kopie: k, slozky: [], zarizeni: nil).porovnej() == Hlidani.Vysledek())
    }

    @Test func prevzetiKartyZImportu() async throws {
        let d = try docasnyDomov(); let k = try kopie(d); let server = MockServer()
        let cesta = try soubor(d, "Znalosti/brief.md", "Text\n")
        let otisk = Otisk.sha256(Data("Text\n".utf8))
        await server.pridej(Karta(id: "z-importu", name: "brief", otisk: otisk))
        await server.nastavPrevzeti(otisk: otisk, id: "z-importu")
        let h = Hlidani(kopie: k, slozky: slozky(d), zarizeni: nil)
        _ = try h.zpracuj([cesta])
        #expect(try k.fronta().first?.hlaseni.id != "z-importu")
        _ = try await Synchronizace(kopie: k, api: server).probehni()
        try "Text 2\n".write(toFile: cesta, atomically: true, encoding: .utf8)
        _ = try h.zpracuj([cesta])
        #expect(try k.fronta().first?.hlaseni.id == "z-importu", "další verze jde pod převzatou kartu")
    }
}

@Suite struct KnihovnyTests {
    @Test func pravidlaZeServeruJenRozumna() {
        let ok: [String: Any] = ["preskocit_slozky": ["node_modules", ".git"], "skryte_povolene": [".claude/skills"]]
        #expect(PravidlaSlozek.zeServeru(ok) == PravidlaSlozek(preskocit: ["node_modules", ".git"], skryte: [".claude/skills"]))
        #expect(PravidlaSlozek.zeServeru([:]) == nil, "starý server: platí vestavěná")
        #expect(PravidlaSlozek.zeServeru(["preskocit_slozky": [String](), "skryte_povolene": [String]()]) == nil)
        #expect(PravidlaSlozek.zeServeru(["preskocit_slozky": ["a/b"], "skryte_povolene": [String]()]) == nil)
        #expect(PravidlaSlozek.zeServeru(["preskocit_slozky": ["x"], "skryte_povolene": ["skills"]]) == nil)
    }

    @Test func pravidlaSeUloziAPlatiPoOtevreniKopie() async throws {
        let d = try docasnyDomov(); let klic = SymmetricKey(size: .bits256)
        let k = try Kopie(domov: d, klic: klic)
        // Jméno, které žádný jiný test nepoužívá: pravidla platí pro celý proces.
        let p = PravidlaSlozek(preskocit: PravidlaSlozek.vestavena.preskocit + ["zz-jen-test"], skryte: PravidlaSlozek.vestavena.skryte)
        defer { Slozky.pouzij(.vestavena) }
        let server = MockServer(); await server.nastavPravidla(p)
        _ = try await Synchronizace(kopie: k, api: server).probehni()
        #expect(try k.stav("pravidla_slozek", PravidlaSlozek.self) == p)
        #expect(Slozky.duvod("/G/zz-jen-test/a.md", ["/G"]) == "knihovna nebo sestavení")
        Slozky.pouzij(.vestavena)
        #expect(Slozky.duvod("/G/zz-jen-test/a.md", ["/G"]) == nil)
        _ = try Kopie(domov: d, klic: klic)     // hook: nový proces vezme pravidla z kopie
        #expect(Slozky.duvod("/G/zz-jen-test/a.md", ["/G"]) == "knihovna nebo sestavení")
        // Do 6 hodin se server znovu neptá.
        await server.nastavPravidla(.vestavena)
        _ = try await Synchronizace(kopie: k, api: server).probehni()
        #expect(try k.stav("pravidla_slozek", PravidlaSlozek.self) == p)
    }

    @Test func knihovnyASestaveniSeNehlasi() {
        let s = ["/G"]
        for d in ["node_modules", "vendor", "bower_components", "dist", "build", ".next", ".nuxt", "out",
                  "coverage", "Pods", "DerivedData", ".git", "venv", ".venv", "__pycache__"] {
            #expect(Slozky.duvod("/G/web/\(d)/balik/README.md", s) == "knihovna nebo sestavení", "\(d)")
            #expect(Slozky.vKnihovne("/G/web/\(d)/balik/README.md", s))
        }
        #expect(Slozky.duvod("/G/web/builds/a.md", s) == nil, "po celých složkách")
        #expect(Slozky.duvod("/G/web/build.md", s) == nil, "soubor se jménem složky se hlásí")
        #expect(!Slozky.vKnihovne("/build/a.md", ["/build"]), "vybraná složka sama se nepočítá")
        #expect(!Slozky.vKnihovne("/H/node_modules/a.md", s), "mimo vybrané složky rozhoduje duvod")
    }

    @Test func hlidaniKnihovnyNecte() throws {
        let d = try docasnyDomov(); let k = try kopie(d)
        let koren = [d.slozka.appendingPathComponent("prace/Znalosti").path]
        let readme = try soubor(d, "Znalosti/web/node_modules/balik/README.md", "# Balík\n")
        _ = try soubor(d, "Znalosti/web/dist/README.md", "# Sestavení\n")
        _ = try soubor(d, "Znalosti/web/brief.md", "# Brief\n")
        let h = Hlidani(kopie: k, slozky: koren, zarizeni: nil)
        #expect(try h.zpracuj([readme]) == Hlidani.Vysledek(), "událost z node_modules se zahodí")
        let v = try h.porovnej()
        #expect(v.nove == 1 && v.preskoceno == 0)
        #expect(try k.fronta().map(\.hlaseni.name) == ["brief"])
    }
}

/// Počítá čtení, aby šlo ověřit „jedno čtení na položku za proces“.
final class PocitaneTajemstvi: UlozisteTajemstvi, @unchecked Sendable {
    var data: [String: Data] = [:]
    var cteni: [String: Int] = [:]
    func cti(_ jmeno: String) throws -> Data? { cteni[jmeno, default: 0] += 1; return data[jmeno] }
    func zapis(_ jmeno: String, _ d: Data) throws { data[jmeno] = d }
    func smaz(_ jmeno: String) throws { data[jmeno] = nil }
}

@Suite struct KlicenkaTests {
    @Test func jednoCteniNaPolozku() throws {
        let zdroj = PocitaneTajemstvi(); zdroj.data["token"] = Data("t1".utf8)
        let u = PametTajemstvi(zdroj)
        for _ in 0..<5 { _ = try u.cti("token"); _ = try u.cti("chybi") }
        _ = try Tajemstvi.klicKopie(u); _ = try Tajemstvi.klicKopie(u)
        #expect(zdroj.cteni == ["token": 1, "chybi": 1, "klic-kopie": 1])
        // Po 401 lišta token zapomene a přečte ho znovu, jednou.
        zdroj.data["token"] = Data("t2".utf8)
        u.zapomen("token")
        #expect(try u.cti("token") == Data("t2".utf8) && u.cti("token") == Data("t2".utf8))
        #expect(zdroj.cteni["token"] == 2)
        try u.zapis("token", Data("t3".utf8))
        #expect(try u.cti("token") == Data("t3".utf8) && zdroj.cteni["token"] == 2)
    }

    @Test func vychoziJeJednoNaProces() throws {
        let d = try docasnyDomov()
        #expect(Tajemstvi.vychozi(d) === Tajemstvi.vychozi(d))
    }
}

@Suite struct DavkaTests {
    @Test func obsahJdeDavkouSPretizenimANeplatnym() async throws {
        let d = try docasnyDomov(); let k = try kopie(d); let server = MockServer()
        await server.zapniDavky(pretizit: ["b"], neplatne: ["c"])
        for j in ["a", "b", "c", "d"] {
            let c = try soubor(d, "\(j).md", "---\nname: \(j)\ndescription: D\nairine:\n  typ: brief\n---\nText \(j)\n")
            _ = try Nahlasovani(kopie: k).nahlas(cesta: c)
        }
        let v = try await Synchronizace(kopie: k, api: server).probehni()
        #expect(v.odeslano == 4 && v.obsahu == 4 && v.online)
        #expect(try k.fronta().isEmpty)
        #expect(await server.davky == [["a", "b", "c", "d"], ["b"]], "přetížený soubor jde znovu sám")
        #expect(await server.jednotliveObsahu == 1, "odmítnutý v dávce jde po jednom")
        for id in try k.karty().map(\.id) { #expect(await server.maObsah(id)) }
    }

    @Test func chybaVDavceJdePoJednom() async throws {
        let d = try docasnyDomov(); let k = try kopie(d); let server = MockServer()
        await server.zapniDavky(chyba: ["b"])
        for j in ["a", "b", "c"] {
            let c = try soubor(d, "\(j).md", "---\nname: \(j)\ndescription: D\nairine:\n  typ: brief\n---\nText \(j)\n")
            _ = try Nahlasovani(kopie: k).nahlas(cesta: c)
        }
        let v = try await Synchronizace(kopie: k, api: server).probehni()
        #expect(v.odeslano == 3 && v.obsahu == 3 && v.online)
        #expect(try k.fronta().isEmpty)
        #expect(await server.davky == [["a", "b", "c"]], "zbytek dávky doběhne, chyba se v dávce neopakuje")
        #expect(await server.jednotliveObsahu == 1, "soubor s chybou jde ještě jednou po jednom")
    }

    @Test func na413SeDavkaPuli() async throws {
        let d = try docasnyDomov(); let k = try kopie(d); let server = MockServer()
        await server.zapniDavky(); await server.nastav(velkaNad: 2)
        for j in ["a", "b", "c", "e", "f"] {
            let c = try soubor(d, "\(j).md", "---\nname: \(j)\ndescription: D\nairine:\n  typ: brief\n---\nText \(j)\n")
            _ = try Nahlasovani(kopie: k).nahlas(cesta: c)
        }
        let v = try await Synchronizace(kopie: k, api: server).probehni()
        #expect(v.odeslano == 5 && v.obsahu == 5 && v.online)
        #expect(await server.pokusyDavek == [5, 2, 3, 1, 2], "půlí se, dokud dávka neprojde")
        #expect(await server.jednotliveObsahu == 0)
        #expect(try k.fronta().isEmpty)

        // Ani jeden soubor neprojde dávkou: ten jde po jednom.
        await server.nastav(velkaNad: 0)
        for j in ["g", "h"] {
            _ = try Nahlasovani(kopie: k).nahlas(cesta: try soubor(d, "\(j).md", "---\nname: \(j)\ndescription: D\nairine:\n  typ: brief\n---\nText \(j)\n"))
        }
        let w = try await Synchronizace(kopie: k, api: server).probehni()
        let jednotlive = await server.jednotliveObsahu
        #expect(w.odeslano == 2 && w.obsahu == 2 && jednotlive == 2)
    }

    @Test func bezDavkyPoJednom() async throws {
        let d = try docasnyDomov(); let k = try kopie(d); let server = MockServer()
        for j in ["a", "b"] { _ = try Nahlasovani(kopie: k).nahlas(cesta: try soubor(d, "\(j).md", "Text \(j)\n")) }
        let v = try await Synchronizace(kopie: k, api: server).probehni()
        let jednotlive = await server.jednotliveObsahu
        #expect(v.odeslano == 2 && v.obsahu == 2 && jednotlive == 2)
    }
}
