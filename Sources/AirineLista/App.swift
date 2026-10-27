import AirineCore
import SwiftUI

// Aplikace v liště: drží synchronizaci (každou minutu a hned po hlášení),
// ukazuje stav a rozpory. KOSTRA — přihlášení, souhlas s měřením a připojení
// Cursoru přibudou v dalších krocích.

@MainActor
final class Stav: ObservableObject {
    @Published var posledni: Date?
    @Published var fronta = 0
    @Published var odmitnuto = 0
    @Published var online = true
    @Published var prihlasen = false
    @Published var rozpory: [String] = []

    let domov = Domov()
    var kopie: Kopie?
    var casovac: Timer?

    init() {
        kopie = try? Kopie.otevri(domov)
        obnov()
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
        let f = (try? kopie.fronta(vcetneOdmitnutych: true)) ?? []
        fronta = f.filter { $0.odmitnuto == nil }.count
        odmitnuto = f.count - fronta
    }

    func synchronizuj() async {
        guard let kopie else { return }
        guard let t = token() else { prihlasen = false; obnov(); return }
        prihlasen = true
        if let v = try? await Synchronizace.spust(domov: domov, kopie: kopie, api: { HttpAirine(nastaveni: $0, token: t) }) {
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
                Button("Synchronizovat teď") { Task { await stav.synchronizuj() } }
                Button("Ukončit") { NSApplication.shared.terminate(nil) }
            }
            .padding(8)
        } label: {
            Image(systemName: stav.online ? "books.vertical" : "books.vertical.circle")
        }
    }
}
