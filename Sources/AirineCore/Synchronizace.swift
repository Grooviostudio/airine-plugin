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
        let fronta = try kopie.fronta()
        var i = 0
        var poJednom = false        // server dávku nezná nebo ji odmítl celou
        while i < fronta.count {
            // Navazující hlášení s obsahem jdou jednou dávkou, do stropu serveru.
            if !poJednom {
                var davka: [(Kopie.Polozka, SouborDavky)] = []
                var bajty = 0, j = i
                while j < fronta.count, davka.count < VysledekDavky.souboru, let f = souborDavky(fronta[j].hlaseni),
                      bajty + f.obsah.utf8.count + 4096 <= VysledekDavky.bajtu {
                    davka.append((fronta[j], f)); bajty += f.obsah.utf8.count + 4096; j += 1
                }
                if davka.count > 1 {
                    switch try await posliDavku(davka, &v) {
                    case .hotovo: i = j; continue
                    case .konec: return
                    case .poJednom: poJednom = true
                    }
                }
            }
            guard try await odesliJedno(fronta[i], &v) else { return }
            i += 1
        }
    }

    /// Hlášení s obsahem do dávky: jen text v UTF-8, který sedí s otiskem.
    func souborDavky(_ h: Hlaseni) -> SouborDavky? {
        guard obsah, let cesta = h.cesta, !Obsah.vynechano(cesta, vynechat),
              let o = Obsah.nacti(cesta: cesta, otisk: h.otisk),
              let text = String(data: o.data, encoding: .utf8) else { return nil }
        return SouborDavky(hlaseni: h, mime: o.mime, obsah: text)
    }

    enum KonecDavky { case hotovo, konec, poJednom }

    /// Jedna dávka obsahu. Přetížené soubory pošle znovu po `retry_after`
    /// (nejvýš dvakrát), soubory odmítnuté bez podrobností po jednom.
    func posliDavku(_ davka: [(Kopie.Polozka, SouborDavky)], _ v: inout Vysledek) async throws -> KonecDavky {
        var zbyva = davka, kolo = 0
        var jednotlive: [Kopie.Polozka] = []
        while !zbyva.isEmpty {
            let vysledky: [VysledekDavky]
            do { vysledky = try await api.nahrajDavku(zbyva.map(\.1)) }
            catch ChybaServeru.bezSpojeni {
                try kopie.pokusSelhal(zbyva[0].0.hlaseni); v.online = false; return .konec
            } catch ChybaServeru.neprihlasen { v.neprihlasen = true; return .konec }
            catch ChybaServeru.ciziZarizeni { v.ciziZarizeni = true; return .konec }
            catch is ChybaServeru { return .poJednom }      // 404, 413, cokoli celé dávky
            var pretizene: [(Kopie.Polozka, SouborDavky)] = []
            var cekat = 0.0
            for (polozka, r) in zip(zbyva, vysledky) {
                let p = polozka.0
                switch r.stav {
                case "ok", "uz_prijato", "rozpor":
                    var o = OdpovedHlaseni(stav: StavHlaseni(rawValue: r.stav)!, id: r.id, otisk: r.otisk, rozpor: r.rozpor)
                    o.ulozeny_otisk = r.ulozeny_otisk
                    v.obsahu += 1
                    try vyrid(p, o, &v)
                case "pretizeno":
                    pretizene.append(polozka); cekat = max(cekat, r.retry_after ?? 2)
                case "smazano": _ = try vyridChybu(p, .smazano, &v)
                case "bez_prava": _ = try vyridChybu(p, .bezPravaKarty, &v)
                default: jednotlive.append(p)           // neplatne: podrobnosti řekne hlášení po jednom
                }
            }
            if pretizene.isEmpty { break }
            kolo += 1
            guard kolo <= 2 else { return .konec }      // počkají ve frontě do příště
            try await Task.sleep(for: .seconds(min(cekat, HttpAirine.nejdeleCekat)))
            zbyva = pretizene
        }
        for p in jednotlive { guard try await odesliJedno(p, &v) else { return .konec } }
        return .hotovo
    }

    /// `false` = zbytek fronty počká (výpadek, odhlášení, cizí zařízení).
    func odesliJedno(_ p: Kopie.Polozka, _ v: inout Vysledek) async throws -> Bool {
        do {
            try vyrid(p, try await odesli(p.hlaseni, &v), &v)
            return true
        } catch let e as ChybaServeru {
            return try vyridChybu(p, e, &v)
        }
    }

    func vyrid(_ p: Kopie.Polozka, _ o: OdpovedHlaseni, _ v: inout Vysledek) throws {
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
    }

    func vyridChybu(_ p: Kopie.Polozka, _ e: ChybaServeru, _ v: inout Vysledek) throws -> Bool {
        switch e {
        case .odmitnuto(let o):
            try kopie.odmitnuto(p.hlaseni, o)
            v.odmitnuto += 1
        case .bezPravaKarty:
            try kopie.odmitnuto(p.hlaseni, Odmitnuti(chyby: [ChybaPole(
                pole: "prava", zprava: "Tuhle kartu nesmíš měnit. Požádej vlastníka o právo, nebo ulož změnu jako nový soubor.", kod: "bez_prava")]))
            v.odmitnuto += 1
        case .ciziId:
            try kopie.odmitnuto(p.hlaseni, Odmitnuti(chyby: [ChybaPole(
                pole: "id", zprava: "Toto id už v Airine patří jinému workspace. Smaž z hlavičky airine.id (u SKILL.md metadata.airine-id) a ulož, plugin doplní nové.", kod: "cizi_id")]))
            v.odmitnuto += 1
        case .smazano:
            try kopie.oznacSmazanou(p.hlaseni)
            v.smazanych += 1
        case .ciziZarizeni:
            v.ciziZarizeni = true
            return false
        case .bezSpojeni:
            try kopie.pokusSelhal(p.hlaseni)
            v.online = false
            return false                                 // zbytek fronty počká, pořadí zůstane
        case .neprihlasen:
            v.neprihlasen = true
            return false
        default:
            throw e
        }
        return true
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
