import Foundation

/// Jeden běh synchronizace: nejdřív odešle frontu, pak stáhne změny.
/// Nikdy nehází kvůli výpadku — výsledek říká, co se povedlo (Airine
/// nesmí zastavit práci agenta).
public struct Synchronizace: Sendable {
    let kopie: Kopie
    let api: AirineAPI

    public init(kopie: Kopie, api: AirineAPI) { self.kopie = kopie; self.api = api }

    public struct Vysledek: Sendable, Equatable {
        public var odeslano = 0
        public var rozpory: [String] = []          // id karet, kde server uložil verzi v rozporu
        public var odmitnuto = 0
        public var stazeno = 0
        public var smazano = 0
        public var online = true
        public var neprihlasen = false
        public var ciziZarizeni = false          // volající si vezme nové uuid a spustí znovu
        public var smazanych = 0                 // hlášení karet, které jsou v Airine smazané
    }

    /// Běh se vším, co potřebuje lišta i příkaz: když server řekne, že uuid
    /// zařízení patří jinému členovi, vezme si nové, přepíše frontu a zkusí to jednou znovu.
    public static func spust(domov: Domov, kopie: Kopie, api: @Sendable (Nastaveni) -> AirineAPI) async throws -> Vysledek {
        var n = try Nastaveni.nacti(domov)
        try kopie.prepisZarizeni(n.zarizeni)     // hlášení z procesu, který měl ještě staré uuid
        var v = try await Synchronizace(kopie: kopie, api: api(n)).probehni()
        if v.ciziZarizeni {
            n.zarizeni = UUID().uuidString.lowercased()
            try n.uloz(domov)
            try kopie.prepisZarizeni(n.zarizeni)
            v = try await Synchronizace(kopie: kopie, api: api(n)).probehni()
        }
        return v
    }

    public func probehni() async throws -> Vysledek {
        var v = Vysledek()
        try await odesliFrontu(&v)
        if v.online && !v.neprihlasen { try await stahni(&v) }
        if v.online && !v.neprihlasen { try kopie.nastavStav("posledni_sync", Date()) }
        return v
    }

    func odesliFrontu(_ v: inout Vysledek) async throws {
        for p in try kopie.fronta() {
            do {
                let o = try await api.nahlas(p.hlaseni)
                if o.stav == .rozpor || o.karta?.rozpor == true { v.rozpory.append(p.hlaseni.id) }
                if let k = o.karta { try kopie.ulozKarty([k]) }
                try kopie.odeslano(p.hlaseni)
                v.odeslano += 1
            } catch ChybaServeru.odmitnuto(let o) {
                try kopie.odmitnuto(p.hlaseni, o)
                v.odmitnuto += 1
            } catch ChybaServeru.bezPravaKarty {
                try kopie.odmitnuto(p.hlaseni, Odmitnuti(chyby: [ChybaPole(
                    pole: "prava", zprava: "Tuhle kartu nesmíš měnit. Požádej vlastníka o právo, nebo ulož změnu jako nový soubor.", kod: "bez_prava")]))
                v.odmitnuto += 1
            } catch ChybaServeru.ciziId {
                try kopie.odmitnuto(p.hlaseni, Odmitnuti(chyby: [ChybaPole(
                    pole: "id", zprava: "Toto id už v Airine patří jinému workspace. Smaž z hlavičky airine.id (u SKILL.md metadata.airine-id) a ulož, plugin doplní nové.", kod: "cizi_id")]))
                v.odmitnuto += 1
            } catch ChybaServeru.smazano {
                try kopie.oznacSmazanou(p.hlaseni)
                v.smazanych += 1
            } catch ChybaServeru.ciziZarizeni {
                v.ciziZarizeni = true
                return
            } catch ChybaServeru.bezSpojeni {
                try kopie.pokusSelhal(p.hlaseni)
                v.online = false
                return                                   // zbytek fronty počká, pořadí zůstane
            } catch ChybaServeru.neprihlasen {
                v.neprihlasen = true
                return
            }
        }
    }

    func stahni(_ v: inout Vysledek) async throws {
        var kurzor = try kopie.stav("kurzor", String.self)
        var plna = false
        while true {
            let z: Zmeny
            do {
                z = try await api.zmeny(od: kurzor, limit: 500)
            } catch ChybaServeru.kurzorNeplatny where !plna {
                // 410: kopie se postaví znovu. Karty se mažou až po úspěšné první
                // stránce, aby výpadek uprostřed nenechal prázdný katalog.
                kurzor = nil; plna = true; continue
            } catch ChybaServeru.bezSpojeni { v.online = false; return }
            catch ChybaServeru.neprihlasen { v.neprihlasen = true; return }

            if plna { try kopie.vymazKatalog(); plna = false }
            try kopie.db.transakce {
                try kopie.ulozKarty(z.karty)
                try kopie.smazKarty(z.smazano)
                if let n = z.navod { try kopie.nastavStav("navod", n) }
                try kopie.nastavStav("kurzor", z.kurzor)
            }
            v.stazeno += z.karty.count
            v.smazano += z.smazano.count
            kurzor = z.kurzor
            if !z.dalsi { return }
        }
    }
}
