import AirineCore
import Foundation

// Příkaz `airine`: hooky Claude Code a Cursoru, místní MCP server a ruční
// obsluha. Hooky nesmí čekat na síť — čtou místní kopii a frontu
// odesílá aplikace v liště, případně `airine sync` spuštěný na pozadí.

let napoveda = """
airine — plugin Airine pro Claude Code a Cursor

  airine prihlas [--server URL]   osobní token ze stdin do Klíčenky
  airine sync                     odešle frontu a stáhne změny katalogu
  airine stav                     poslední synchronizace, fronta, odmítnutá hlášení
  airine propoj <projekt_id> [--slozka CESTA]
  airine doporuceni [--cwd CESTA] [--vse] [--hook]
  airine nahlas <cesta> | --hook  zařadí soubor do fronty hlášení
  airine vyres <id>               po sloučení rozporu: další hlášení naváže na verzi v Airine
  airine vrat <id> [<id>…]        vrátí archivované karty mezi platné
  airine obsah [ano|ne]           posílat s kartou i obsah souboru (výchozí ano)
  airine vynech [VZOR…] [--zrus VZOR]
                                  složky, jejichž obsah nikdy neodejde (jen karta)
  airine nahraj-obsah [--koren CESTA]… [--vynech VZOR]… [--zkouska] [--vypis]
                                  pošle obsah karet, které ho v Airine nemají
  airine mcp                      místní MCP server přes stdio
"""

var argumenty = Array(CommandLine.arguments.dropFirst())
@MainActor func volba(_ jmeno: String) -> String? {
    guard let i = argumenty.firstIndex(of: jmeno), i + 1 < argumenty.count else { return nil }
    let v = argumenty[i + 1]; argumenty.removeSubrange(i...i + 1); return v
}
@MainActor func prepinac(_ jmeno: String) -> Bool {
    guard let i = argumenty.firstIndex(of: jmeno) else { return false }
    argumenty.remove(at: i); return true
}
func chyba(_ t: String) -> Never {
    FileHandle.standardError.write(Data((t + "\n").utf8)); exit(1)
}
func stdinJson() -> [String: Any] {
    let d = FileHandle.standardInput.readDataToEndOfFile()
    return (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
}

let domov = Domov()
let tajemstvi = Tajemstvi.vychozi(domov)

@MainActor func otevri() -> (Kopie, Nastaveni) {
    do { return (try Kopie(domov: domov, klic: Tajemstvi.klicKopie(tajemstvi)), try Nastaveni.nacti(domov)) }
    catch { chyba("Místní kopii nejde otevřít: \(error)") }
}

@MainActor func token() -> String? {
    guard let t = try? tajemstvi.cti("token"), let token = String(data: t, encoding: .utf8), !token.isEmpty else { return nil }
    return token
}
@MainActor func api(_ n: Nastaveni) -> AirineAPI? { token().map { HttpAirine(nastaveni: n, token: $0) } }

/// Spustí `airine sync` na pozadí a nečeká (hook musí doběhnout hned).
@MainActor func synchronizujNaPozadi() {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    p.arguments = ["sync", "--tise"]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
}

let prikaz = argumenty.isEmpty ? "" : argumenty.removeFirst()

switch prikaz {
case "prihlas":
    var (_, n) = otevri()
    if let s = volba("--server") { n.server = s; try? n.uloz(domov) }
    // Token jen ze stdin, nikdy z argumentu (ten je vidět v `ps` a v historii).
    let token = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard token.hasPrefix("airine_") else { chyba("Čekám osobní token Airine (airine_…) na stdin.") }
    do { try tajemstvi.zapis("token", Data(token.utf8)) } catch { chyba("Token nejde uložit: \(error)") }
    print("Token uložen. Server: \(n.server)")

case "sync":
    let tise = prepinac("--tise")
    let (kopie, _) = otevri()
    guard let t = token() else { if tise { exit(0) }; chyba("Nejsi přihlášený: airine prihlas") }
    do {
        let v = try await Synchronizace.spust(domov: domov, kopie: kopie) { HttpAirine(nastaveni: $0, token: t) }
        if !tise {
            print(v.online ? "Synchronizováno: odesláno \(v.odeslano) (s obsahem \(v.obsahu)), staženo \(v.stazeno), smazáno \(v.smazano)." : "Airine neodpovídá, fronta počká.")
            if !v.bezObsahu.isEmpty { print("Obsah neprošel, odešla jen karta: \(v.bezObsahu.joined(separator: ", "))") }
            if v.odmitnuto > 0 { print("Odmítnutá hlášení: \(v.odmitnuto) (airine stav)") }
            if v.smazanych > 0 { print("Karty smazané v Airine: \(v.smazanych), dál se nehlásí.") }
            if !v.rozpory.isEmpty { print("Rozpory: \(v.rozpory.joined(separator: ", "))") }
            if v.neprihlasen { print("Token neplatí nebo nemáš modul Znalosti.") }
        }
    } catch { if !tise { chyba("Synchronizace selhala: \(error)") } }

case "stav":
    let (kopie, n) = otevri()
    let f = (try? kopie.fronta(vcetneOdmitnutych: true)) ?? []
    print("Server: \(n.server)  zařízení: \(n.nazevZarizeni) (\(n.zarizeni))")
    print("Přihlášen: \(api(n) == nil ? "ne" : "ano")  posílat obsah: \(n.posilatObsah ? "ano" : "ne")")
    print("Poslední synchronizace: \(kopie.posledniSynchronizace.map { "\($0)" } ?? "nikdy")")
    print("Karet v kopii: \((try? kopie.karty().count) ?? 0)  ve frontě: \(f.filter { $0.odmitnuto == nil }.count)")
    for p in f where p.odmitnuto != nil {
        print("Odmítnuto \(p.hlaseni.cesta ?? p.hlaseni.id): " + p.odmitnuto!.chyby.map { "\($0.pole) \($0.zprava)" }.joined(separator: "; "))
    }

case "propoj":
    let slozka = volba("--slozka") ?? FileManager.default.currentDirectoryPath
    guard let projekt = argumenty.first else { chyba("airine propoj <projekt_id> [--slozka CESTA]") }
    let (kopie, _) = otevri()
    do { try kopie.propoj(slozka: slozka, projekt: projekt) } catch { chyba("\(error)") }
    print("\(slozka) → projekt \(projekt)")

case "doporuceni":
    let hook = prepinac("--hook")
    let vse = prepinac("--vse")
    var cwd = volba("--cwd") ?? FileManager.default.currentDirectoryPath
    if hook, let c = stdinJson()["cwd"] as? String { cwd = c }
    let (kopie, n) = otevri()
    let projekt = vse ? nil : (try? kopie.projekt(pro: cwd)) ?? nil
    let text: String
    do { text = try Doporuceni(kopie: kopie, projekt: projekt).text(fronta: kopie.fronta().count) }
    catch { if hook { exit(0) }; chyba("\(error)") }
    if hook {
        // SessionStart: text jde do kontextu agenta. Synchronizace běží vedle.
        let o: [String: Any] = ["hookSpecificOutput": ["hookEventName": "SessionStart", "additionalContext": text]]
        print(String(decoding: try! JSONSerialization.data(withJSONObject: o), as: UTF8.self))
        if api(n) != nil { synchronizujNaPozadi() }
    } else {
        print(text)
    }

case "nahlas":
    let hook = prepinac("--hook")
    var cesta = argumenty.first
    if hook {
        // Claude Code PostToolUse: tool_input.file_path; Cursor afterFileEdit: file_path.
        let j = stdinJson()
        cesta = ((j["tool_input"] as? [String: Any])?["file_path"] as? String) ?? (j["file_path"] as? String)
    }
    guard let cesta else { if hook { exit(0) }; chyba("airine nahlas <cesta>") }
    let (kopie, n) = otevri()
    do {
        let v = try Nahlasovani(kopie: kopie).nahlas(cesta: cesta)
        if case .zarazeno = v, api(n) != nil { synchronizujNaPozadi() }
        if hook, let t = v.proAgenta {
            // Claude Code dá text agentovi; ten hlavičku doplní, plugin soubor nepřepisuje.
            let o: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PostToolUse", "additionalContext": t]]
            print(String(decoding: try! JSONSerialization.data(withJSONObject: o), as: UTF8.self))
        }
        if !hook { print(v.proAgenta ?? "\(v)") }
    } catch {
        // Hook nikdy neblokuje práci agenta; chyba jde jen do stderr.
        FileHandle.standardError.write(Data("airine: \(error)\n".utf8))
        exit(hook ? 0 : 1)
    }

case "vyres":
    guard let id = argumenty.first else { chyba("airine vyres <id>") }
    let (kopie, _) = otevri()
    do { try Nahlasovani(kopie: kopie).vyresRozpor(id: id) } catch { chyba("\(error)") }
    print("Další hlášení \(id) naváže na verzi v Airine. Ulož sloučený soubor znovu.")

case "vrat":
    guard !argumenty.isEmpty else { chyba("airine vrat <id> [<id>…]") }
    let (kopie, n) = otevri()
    guard let a = api(n), let t = token() else { chyba("Nejsi přihlášený: airine prihlas") }
    do {
        let zmeneno = try await a.archiv(karty: argumenty, archivovat: false)
        _ = try await Synchronizace.spust(domov: domov, kopie: kopie) { HttpAirine(nastaveni: $0, token: t) }
        print(zmeneno == 0 ? "Nic k vrácení, karty nejsou archivované." : "Vráceno z archivu: \(zmeneno).")
    } catch ChybaServeru.bezPravaKarty {
        chyba("Některou z karet nesmíš měnit, nevrátilo se nic. Požádej vlastníka.")
    } catch ChybaServeru.bezSpojeni {
        chyba("Airine neodpovídá, zkus to znovu.")
    } catch { chyba("Vrácení selhalo: \(error)") }

case "obsah":
    var (_, n) = otevri()
    switch argumenty.first {
    case "ano": n.posilatObsah = true
    case "ne": n.posilatObsah = false
    case nil: break
    default: chyba("airine obsah [ano|ne]")
    }
    if argumenty.first != nil { do { try n.uloz(domov) } catch { chyba("Nastavení nejde uložit: \(error)") } }
    print("Posílat obsah souborů: \(n.posilatObsah ? "ano" : "ne")")

case "vynech":
    var n: Nastaveni
    do { n = try Nastaveni.nacti(domov) } catch { chyba("Nastavení nejde načíst: \(error)") }
    var zrusit: [String] = []
    while let z = volba("--zrus") { zrusit.append(z) }
    let zmena = !zrusit.isEmpty || !argumenty.isEmpty
    n.vynechatObsah.removeAll { zrusit.contains($0) }
    for v in argumenty where !n.vynechatObsah.contains(v) { n.vynechatObsah.append(v) }
    if zmena { do { try n.uloz(domov) } catch { chyba("Nastavení nejde uložit: \(error)") } }
    print(n.vynechatObsah.isEmpty ? "Nic se nevynechává." : "Obsah neodejde z:\n" + n.vynechatObsah.map { "  " + $0 }.joined(separator: "\n"))

case "nahraj-obsah":
    let zkouska = prepinac("--zkouska")
    let vypis = prepinac("--vypis")
    var nove: [String] = []
    while let v = volba("--vynech") { nove.append(v) }
    if !nove.isEmpty {
        // Vynechání platí trvale, i pro hook: ukládá se do nastavení.
        do {
            var m = try Nastaveni.nacti(domov)
            for v in nove where !m.vynechatObsah.contains(v) { m.vynechatObsah.append(v) }
            try m.uloz(domov)
        } catch { chyba("Nastavení nejde uložit: \(error)") }
    }
    var koreny: [URL] = []
    while let k = volba("--koren") { koreny.append(URL(fileURLWithPath: (k as NSString).expandingTildeInPath, isDirectory: true)) }
    let (kopie, n) = otevri()
    guard let t = token() else { chyba("Nejsi přihlášený: airine prihlas") }
    guard n.posilatObsah || zkouska else { chyba("Posílání obsahu je vypnuté (airine obsah ano).") }
    do {
        // Nejdřív čerstvá kopie: podle ní plugin pozná, co Airine už má.
        _ = try await Synchronizace.spust(domov: domov, kopie: kopie) { HttpAirine(nastaveni: $0, token: t) }
        let m = try Nastaveni.nacti(domov)
        let v = try await Obsah.dohon(kopie: kopie, api: HttpAirine(nastaveni: m, token: t),
                                      koreny: koreny, vynechat: m.vynechatObsah, zkouska: zkouska)
        print((zkouska ? "Zkouška, nic neodešlo. Poslal bych: " : "Nahráno: ") + "\(v.nahrano)")
        let pripony = Dictionary(grouping: v.soubory) { URL(fileURLWithPath: $0).pathExtension.lowercased() }
            .map { "\($0.key): \($0.value.count)" }.sorted().joined(separator: "  ")
        if !pripony.isEmpty { print("Podle přípony: \(pripony)") }
        print("Soubor na tomhle Macu není: \(v.bezSouboru)  na disku je jiná verze: \(v.jinaVerze)  nad 1 MB nebo prázdný: \(v.velke)  vynecháno: \(v.vynechano)  jiný typ: \(v.jinyTyp)  bez práva: \(v.bezPrava)")
        // Soubory s tajemstvím odejdou jen jako karta; vypíšou se vždy, ať o nich člověk ví.
        if !v.tajne.isEmpty { print("Vypadá na tajemství, obsah neodejde (\(v.tajne.count)):"); v.tajne.forEach { print("  \($0)") } }
        if vypis { print("Soubory:"); v.soubory.forEach { print("  \($0)") } }
        if !v.chyby.isEmpty { print("Neprošlo (\(v.chyby.count)): \(v.chyby.joined(separator: ", "))") }
        if !v.online { print("Airine přestala odpovídat, zbývá \(v.zbyva). Spusť znovu.") }
        if v.neprihlasen { print("Token neplatí nebo nemáš modul Znalosti.") }
        if !zkouska { _ = try await Synchronizace.spust(domov: domov, kopie: kopie) { HttpAirine(nastaveni: $0, token: t) } }
    } catch { chyba("Nahrání obsahu selhalo: \(error)") }

case "mcp":
    let (kopie, _) = otevri()
    let d = domov
    let server = MistniMcp(kopie: kopie, synchronizuj: token().map { t in
        { @Sendable in _ = try? await Synchronizace.spust(domov: d, kopie: kopie) { HttpAirine(nastaveni: $0, token: t) } }
    })
    while let radek = readLine(strippingNewline: true) {
        if radek.isEmpty { continue }
        if let odp = await server.zpracuj(radek) {
            FileHandle.standardOutput.write(Data((odp + "\n").utf8))
        }
    }

default:
    print(napoveda)
    exit(prikaz.isEmpty || prikaz == "help" ? 0 : 1)
}
