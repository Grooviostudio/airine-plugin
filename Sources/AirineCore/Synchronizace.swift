import Foundation

/// Jeden běh synchronizace: nejdřív odešle frontu, pak stáhne změny.
/// Nikdy nehází kvůli výpadku — výsledek říká, co se povedlo (Airine
/// nesmí zastavit práci agenta).
public struct Synchronizace: Sendable {
    let kopie: Kopie
    let api: AirineAPI
    /// Posílat s kartou i obsah souboru (`Nastaveni.posilatObsah`).
    let obsah: Bool
    /// Vzory, jejichž obsah neodejde (`Nastaveni.vynechatObsah`).
    let vynechat: [String]
    /// Pauza po každém nahraném obsahu: úložiště serveru při rychlé dávce
    /// vrací 429 (lišta po startu může mít ve frontě stovky souborů).
    let pauza: Duration

    public init(kopie: Kopie, api: AirineAPI, obsah: Bool = true, vynechat: [String] = [], pauza: Duration = .zero) {
        self.kopie = kopie; self.api = api; self.obsah = obsah; self.vynechat = vynechat; self.pauza = pauza
    }

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
        public var nesoulad: [String] = []       // id karet, kde se hlášení liší od hlavičky souboru
        public var obsahu = 0                    // hlášení, která odešla i s obsahem
        public var bezObsahu: [String] = []      // obsah neprošel (strop, kvóta), odešla jen karta
        public var zmizelo = 0                   // místa, která server přestal počítat
    }

    /// Běh se vším, co potřebuje lišta i příkaz: když server řekne, že uuid
    /// zařízení patří jinému členovi, vezme si nové a zkusí to jednou znovu.
    /// Zařízení jde v hlavičce požadavku, fronta se proto nepřepisuje.
    public static func spust(domov: Domov, kopie: Kopie, pauza: Duration = .zero,
                             api: @Sendable (Nastaveni) -> AirineAPI) async throws -> Vysledek {
        var n = try Nastaveni.nacti(domov)
        var v = try await Synchronizace(kopie: kopie, api: api(n), obsah: n.posilatObsah, vynechat: n.vynechatObsah, pauza: pauza).probehni()
        if v.ciziZarizeni {
            n.zarizeni = UUID().uuidString.lowercased()
            try n.uloz(domov)
            v = try await Synchronizace(kopie: kopie, api: api(n), obsah: n.posilatObsah, vynechat: n.vynechatObsah, pauza: pauza).probehni()
        }
        return v
    }

    public func probehni() async throws -> Vysledek {
        var v = Vysledek()
        try await odesliFrontu(&v)
        if v.online && !v.neprihlasen && !v.ciziZarizeni { try await odesliZmizela(&v) }
        if v.online && !v.neprihlasen { try await stahni(&v) }
        if v.online && !v.neprihlasen { try kopie.nastavStav("posledni_sync", Date()) }
        return v
    }

    func odesliFrontu(_ v: inout Vysledek) async throws {
        for p in try kopie.fronta() {
            do {
                let o = try await odesli(p.hlaseni, &v)
                // Server poznal týž soubor z jiného zařízení (import složky) a vrátil
                // id existující karty: soubor bez id v hlavičce se dál hlásí pod ním.
                if o.id != p.hlaseni.id { try kopie.prevezmi(p.hlaseni, id: o.id) }
                // Kartu samotnou přinese až kanál změn, tady jen příznak rozporu.
                if o.stav == .rozpor || o.rozpor == true {
                    v.rozpory.append(p.hlaseni.id)
                    try kopie.oznacRozpor(p.hlaseni.id, otisk: o.otisk)
                }
                if !(o.hlavicka ?? []).isEmpty { v.nesoulad.append(p.hlaseni.id) }
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

    /// Zmizelá místa po dávkách. Server bez téhle cesty (404) nebo výpadek:
    /// počkají do příště, karta se kvůli tomu nikdy nemění.
    func odesliZmizela(_ v: inout Vysledek) async throws {
        let f = try kopie.zmizela()
        for i in stride(from: 0, to: f.count, by: 500) {
            let davka = Array(f[i..<min(i + 500, f.count)])
            do {
                v.zmizelo += try await api.zmizela(davka)
                try kopie.odeslanaZmizela(davka)
            } catch ChybaServeru.neprihlasen {
                v.neprihlasen = true; return
            } catch ChybaServeru.jine(422, _) {
                try kopie.zahodZmizela(davka)
            } catch {
                return
            }
        }
    }

    /// Hlášení s obsahem, když na disku leží přesně nahlášená verze; jinak
    /// (soubor se mezitím změnil, zmizel, obsah neprošel) samotná karta.
    func odesli(_ h: Hlaseni, _ v: inout Vysledek) async throws -> OdpovedHlaseni {
        if obsah, let cesta = h.cesta, !Obsah.vynechano(cesta, vynechat), let o = Obsah.nacti(cesta: cesta, otisk: h.otisk) {
            do {
                let odp = try await api.nahrajObsah(h, data: o.data, mime: o.mime)
                v.obsahu += 1
                if pauza > .zero { try? await Task.sleep(for: pauza) }
                return odp
            } catch ChybaServeru.obsahNeprosel {
                v.bezObsahu.append(h.id)
            }
        }
        return try await api.nahlas(h)
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
            let smazane = z.karty.filter { $0.smazano == true }.map(\.id)
            let zive = z.karty.filter { $0.smazano != true }
            try kopie.db.transakce {
                try kopie.ulozKarty(zive)
                try kopie.smazKarty(smazane)
                if let n = z.navod { try kopie.nastavStav("navod", n) }
                try kopie.nastavStav("kurzor", z.kurzor)
            }
            v.stazeno += zive.count
            v.smazano += smazane.count
            kurzor = z.kurzor
            if !z.dalsi { return }
        }
    }
}
