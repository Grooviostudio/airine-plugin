import Foundation
import Testing
@testable import AirineCore

/// Skilly firmy: stažení do složky skillů, aktualizace podle otisku, místní
/// úprava jako nová verze, mazání jen vlastních a nezměněných.
@Suite struct SkillyTests {
    struct Prostredi {
        let d: Domov, k: Kopie, server: MockServer, slozka: URL
        func sync() async throws -> Skilly.Vysledek {
            try Nastaveni(server: "https://airine.test", zarizeni: "z1", nazevZarizeni: "Mac").uloz(d)
            let s = server
            let v = try await Synchronizace.spust(domov: d, kopie: k, skilly: slozka) { _ in s }
            return v.skilly ?? Skilly.Vysledek()
        }
        func soubor(_ jmeno: String) -> URL { slozka.appendingPathComponent(jmeno).appendingPathComponent("SKILL.md") }
        func text(_ jmeno: String) -> String? { try? String(contentsOf: soubor(jmeno), encoding: .utf8) }
    }

    func prostredi() throws -> Prostredi {
        let d = try docasnyDomov()
        let slozka = d.slozka.appendingPathComponent("claude-skills", isDirectory: true)
        return Prostredi(d: d, k: try kopie(d), server: MockServer(), slozka: slozka)
    }

    static let v1 = "---\nname: nabidka\ndescription: Jak psát nabídku\n---\n# Nabídka\nVerze 1\n"
    static let v2 = "---\nname: nabidka\ndescription: Jak psát nabídku\n---\n# Nabídka\nVerze 2\n"

    @Test func novySkillSeStahne() async throws {
        let p = try prostredi()
        await p.server.pridejSkill("s1", "nabidka", Self.v1)
        await p.server.pridej(Karta(id: "d1", name: "brief", typ: "poznamky"))
        let v = try await p.sync()
        #expect(v.nove == ["nabidka"])
        #expect(p.text("nabidka") == Self.v1)
        #expect(!FileManager.default.fileExists(atPath: p.slozka.appendingPathComponent("brief").path))
        #expect(try Skilly.evidence(p.k)["s1"]?.cesta == p.soubor("nabidka").path)
        // Druhý běh nic nestahuje.
        let w = try await p.sync()
        #expect(w.nic)
        #expect(await p.server.stazeniObsahu == 1)
    }

    @Test func novaVerzeZAirinePrepiseNeupraveny() async throws {
        let p = try prostredi()
        await p.server.pridejSkill("s1", "nabidka", Self.v1)
        _ = try await p.sync()
        await p.server.pridejSkill("s1", "nabidka", Self.v2)
        let v = try await p.sync()
        #expect(v.aktualizovane == ["nabidka"])
        #expect(p.text("nabidka") == Self.v2)
    }

    @Test func mistniUpravaOdejdeJakoNovaVerze() async throws {
        let p = try prostredi()
        await p.server.pridejSkill("s1", "nabidka", Self.v1)
        _ = try await p.sync()
        let upraveny = Self.v1 + "Doplněno místně.\n"
        try upraveny.write(to: p.soubor("nabidka"), atomically: true, encoding: .utf8)
        let v = try await p.sync()
        #expect(v.nahlasene == ["nabidka"])
        // Server verzi převzal bez rozporu (předchozí = stažená verze) i s obsahem.
        let k = await p.server.karty["s1"]
        #expect(k?.rozpor == nil && k?.otisk == Otisk.sha256(Data(upraveny.utf8)))
        #expect(k?.ulozeny_otisk == k?.otisk)
        #expect(p.text("nabidka") == upraveny)
        let w = try await p.sync()
        #expect(w.nic && p.text("nabidka") == upraveny)
        #expect(try Skilly.evidence(p.k)["s1"]?.otisk == k?.otisk)
    }

    @Test func soubeznaZmenaJeRozporANeprepisuje() async throws {
        let p = try prostredi()
        await p.server.pridejSkill("s1", "nabidka", Self.v1)
        _ = try await p.sync()
        await p.server.pridejSkill("s1", "nabidka", Self.v2)          // v Airine nová verze
        let mistni = Self.v1 + "Místní změna.\n"
        try mistni.write(to: p.soubor("nabidka"), atomically: true, encoding: .utf8)
        _ = try await p.sync()                                          // místní odejde, server hlásí rozpor
        #expect(await p.server.karty["s1"]?.rozpor == true)
        let v = try await p.sync()
        #expect(v.rozpory == ["nabidka"])
        #expect(p.text("nabidka") == mistni)
    }

    @Test func odebranePravoSmazeJenNeupraveny() async throws {
        let p = try prostredi()
        await p.server.pridejSkill("s1", "nabidka", Self.v1)
        await p.server.pridejSkill("s2", "faktura", "---\nname: faktura\ndescription: x\n---\nA\n")
        _ = try await p.sync()
        try "upraveno".write(to: p.soubor("faktura"), atomically: true, encoding: .utf8)
        await p.server.odeberPravo("s1")
        await p.server.odeberPravo("s2")
        let v = try await p.sync()
        #expect(v.smazane == ["nabidka"])
        #expect(v.ponechane == ["faktura"])
        #expect(!FileManager.default.fileExists(atPath: p.slozka.appendingPathComponent("nabidka").path))
        #expect(p.text("faktura") == "upraveno")
    }

    @Test func nahrazenyAJinyTyp() async throws {
        let p = try prostredi()
        await p.server.pridejSkill("s1", "nabidka", Self.v1)
        await p.server.pridejSkill("s3", "postup", "---\nname: postup\ndescription: x\n---\nB\n")
        _ = try await p.sync()
        await p.server.pridejSkill("s2", "nabidka-v2", "---\nname: nabidka-v2\ndescription: x\n---\nC\n", nahrazuje: "s1")
        await p.server.zmenTyp("s3", "postup")
        let v = try await p.sync()
        #expect(v.nove == ["nabidka-v2"])
        #expect(Set(v.smazane) == ["nabidka", "postup"])
    }

    @Test func ciziSlozkaStejnehoJmenaZustane() async throws {
        let p = try prostredi()
        try FileManager.default.createDirectory(at: p.soubor("nabidka").deletingLastPathComponent(), withIntermediateDirectories: true)
        try "můj vlastní".write(to: p.soubor("nabidka"), atomically: true, encoding: .utf8)
        await p.server.pridejSkill("s1", "nabidka", Self.v1)
        let v = try await p.sync()
        #expect(v.kolize == ["nabidka"] && v.nove.isEmpty)
        #expect(p.text("nabidka") == "můj vlastní")
        // Ani odebrání ho nesmaže: plugin ho nevytvořil.
        await p.server.odeberPravo("s1")
        _ = try await p.sync()
        #expect(p.text("nabidka") == "můj vlastní")
    }

    @Test func vypnuteAOfflineNicNemeni() async throws {
        let p = try prostredi()
        await p.server.pridejSkill("s1", "nabidka", Self.v1)
        _ = try await p.sync()
        await p.server.nastav(online: false)
        await p.server.odeberPravo("s1")
        let off = try await Synchronizace.spust(domov: p.d, kopie: p.k, skilly: p.slozka) { [s = p.server] _ in s }
        #expect(off.skilly == nil && p.text("nabidka") == Self.v1)
        await p.server.nastav(online: true)
        var n = try Nastaveni.nacti(p.d); n.skilly = false; try n.uloz(p.d)
        let vyp = try await Synchronizace.spust(domov: p.d, kopie: p.k, skilly: p.slozka) { [s = p.server] _ in s }
        #expect(vyp.skilly == nil && p.text("nabidka") == Self.v1)
    }

    @Test func zmizelySouborSeVrati() async throws {
        let p = try prostredi()
        await p.server.pridejSkill("s1", "nabidka", Self.v1)
        _ = try await p.sync()
        try FileManager.default.removeItem(at: p.soubor("nabidka"))
        let v = try await p.sync()
        #expect(v.aktualizovane == ["nabidka"] && p.text("nabidka") == Self.v1)
    }
}
