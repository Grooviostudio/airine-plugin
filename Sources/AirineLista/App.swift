import AirineCore
import SwiftUI

// Aplikace v liště: drží synchronizaci (každou minutu a hned po hlášení),
// hlídá vybrané složky (FSEvents) a ukazuje stav a rozpory. KOSTRA —
// přihlášení, souhlas s měřením a připojení Cursoru přibudou v dalších krocích.

@MainActor
final class Stav: ObservableObject {
    @Published var posledni: Date?
    @Published var fronta = 0
    @Published var odmitnuto = 0
    @Published var online = true
    @Published var prihlasen = false
    @Published var rozpory: [String] = []
    @Published var posilatObsah = true
    @Published var slozky: [String] = []
    /// Dialog se složkami se po přihlášení ukáže jednou za běh, ne každou minutu.
    var dotazanoNaSlozky = false
    /// Jedna synchronizace naráz (časovač, hlídání a tlačítko se můžou potkat).
    var synchronizuje = false
    var znovu = false

    let domov = Domov()
    var kopie: Kopie?
    var casovac: Timer?
    var hlidac: Hlidac?
    var hlidaneSlozky: [String] = []

    init() {
        kopie = try? Kopie.otevri(domov)
        obnov()
        hlidej()
        casovac = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.synchronizuj() }
        }
        Task { await synchronizuj() }
    }

    func token() -> String? {
        guard let t = try? Tajemstvi.vychozi(domov).cti("token"),
              let token = String(data: t, encoding: .utf8), !token.isEmpty else { return nil }
        return token
    }

    func obnov() {
        guard let kopie else { return }
        posledni = kopie.posledniSynchronizace
        let n = try? Nastaveni.nacti(domov)
        posilatObsah = n?.posilatObsah ?? true
        slozky = n?.slozky ?? []
        hlidej()
        let f = (try? kopie.fronta(vcetneOdmitnutych: true)) ?? []
        fronta = f.filter { $0.odmitnuto == nil }.count
        odmitnuto = f.count - fronta
    }

    /// Přepínač v liště: posílat s kartou i obsah souboru.
    func nastavObsah(_ ano: Bool) {
        guard var n = try? Nastaveni.nacti(domov) else { return }
        n.posilatObsah = ano
        try? n.uloz(domov)
        posilatObsah = ano
    }

    /// Finder: ze kterých složek Airine bere MD a skills. Výběr nahradí
    /// dosavadní seznam; zrušený dialog nic nemění.
    func vyberSlozky() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = "Ze kterých složek má Airine brát MD dokumenty a skills? Mimo ně nepůjde do Airine nic."
        panel.prompt = "Brát z těchto složek"
        if let prvni = slozky.first { panel.directoryURL = URL(fileURLWithPath: prvni) }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, !panel.urls.isEmpty, var n = try? Nastaveni.nacti(domov) else { return }
        n.slozky = panel.urls.map { Slozky.normalizuj($0.path) }
        try? n.uloz(domov)
        slozky = n.slozky
        hlidej()
    }

    /// Hlídání vybraných složek. Po startu a po změně výběru jednou porovná
    /// otisky ve složkách (co se změnilo, když lišta neběžela), pak už jen
    /// události FSEvents. Všechno běží na hlavním vlákně, stejně jako
    /// synchronizace, ať se zápisy do místní kopie nepotkají.
    func hlidej() {
        guard slozky != hlidaneSlozky || hlidac == nil else { return }
        hlidac?.zastav()
        hlidaneSlozky = slozky
        hlidac = slozky.isEmpty ? nil : Hlidac(slozky: slozky) { [weak self] cesty, vse in
            self?.zpracuj(cesty, vse: vse)
        }
        if !slozky.isEmpty { Task { self.zpracuj([], vse: true) } }
    }

    func zpracuj(_ cesty: Set<String>, vse: Bool) {
        guard let kopie, let n = try? Nastaveni.nacti(domov) else { return }
        let h = Hlidani(kopie: kopie, slozky: n.slozky, zarizeni: n.zarizeni)
        guard let v = try? (vse ? h.porovnej() : h.zpracuj(cesty)) else { return }
        obnov()
        if v.zarazeno > 0 || v.zmizelo > 0 { Task { await synchronizuj() } }
    }

    func synchronizuj() async {
        guard let kopie else { return }
        guard let t = token() else { prihlasen = false; obnov(); return }
        prihlasen = true
        if slozky.isEmpty && !dotazanoNaSlozky {
            dotazanoNaSlozky = true
            vyberSlozky()
        }
        // Běží-li už jedna, proběhne ještě jednou hned po ní (nové hlášení nečeká minutu).
        guard !synchronizuje else { znovu = true; return }
        synchronizuje = true
        defer {
            synchronizuje = false
            if znovu { znovu = false; Task { await synchronizuj() } }
        }
        if let v = try? await Synchronizace.spust(domov: domov, kopie: kopie, pauza: .milliseconds(500),
                                                  api: { HttpAirine(nastaveni: $0, token: t) }) {
            online = v.online
            prihlasen = !v.neprihlasen
            rozpory = v.rozpory
        }
        obnov()
    }
}

@main
struct AirineLista: App {
    @StateObject private var stav = Stav()

    var body: some Scene {
        MenuBarExtra {
            VStack(alignment: .leading, spacing: 6) {
                Text(stav.prihlasen ? (stav.online ? "Airine: připojeno" : "Airine neodpovídá, pracuju z místní kopie") : "Nepřihlášeno")
                Text("Poslední synchronizace: " + (stav.posledni.map { $0.formatted(date: .omitted, time: .shortened) } ?? "nikdy"))
                if stav.fronta > 0 { Text("Čeká na odeslání: \(stav.fronta)") }
                if stav.odmitnuto > 0 { Text("Odmítnutá hlášení: \(stav.odmitnuto)") }
                if !stav.rozpory.isEmpty { Text("Rozpory: \(stav.rozpory.count)") }
                Divider()
                Text(stav.slozky.isEmpty ? "Airine zatím nebere z žádné složky"
                     : "Airine bere z: " + stav.slozky.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: ", "))
                Button(stav.slozky.isEmpty ? "Vybrat složky…" : "Změnit složky…") { stav.vyberSlozky() }
                Toggle("Posílat obsah souborů", isOn: Binding(get: { stav.posilatObsah }, set: { stav.nastavObsah($0) }))
                Button("Synchronizovat teď") { Task { await stav.synchronizuj() } }
                Button("Ukončit") { NSApplication.shared.terminate(nil) }
            }
            .padding(8)
        } label: {
            Image(systemName: stav.online ? "books.vertical" : "books.vertical.circle")
        }
    }
}
