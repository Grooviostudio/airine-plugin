import Foundation

/// Místní MCP server přes stdio (JSON-RPC 2.0, jedna zpráva na řádek).
/// Claude Code i Cursor ho spouští jako `airine mcp`. Odpovídá z místní kopie,
/// takže funguje i při výpadku Airine; hlášení jde do fronty.
public final class MistniMcp: @unchecked Sendable {
    /// Otevře místní kopii. Server běží na pozadí a Klíčenku čte bez okna:
    /// když kopie nejde otevřít, server dál odpovídá a nástroje vrátí radu
    /// otevřít lištu. Další volání to zkusí znovu.
    let otevri: @Sendable () throws -> Kopie
    private var _kopie: Kopie?
    private let zamek = NSLock()
    let synchronizuj: (@Sendable (Kopie) async -> Void)?
    /// Složky pro Znalosti, čtené při každém hlášení (lišta je může změnit);
    /// `nil` = bez omezení.
    let slozky: @Sendable () -> [String]?
    let zarizeni: @Sendable () -> String?
    /// Jméno workspace do hlavičky `co_plati` (víc profilů na Macu).
    let workspace: String?
    /// Složka, ve které agent pracuje: `co_plati` bez argumentů podle ní
    /// najde propojený projekt.
    let vychoziCesta: String?

    public init(otevri: @escaping @Sendable () throws -> Kopie, synchronizuj: (@Sendable (Kopie) async -> Void)? = nil,
                slozky: @escaping @Sendable () -> [String]? = { nil }, zarizeni: @escaping @Sendable () -> String? = { nil },
                workspace: String? = nil, vychoziCesta: String? = nil) {
        self.workspace = workspace; self.vychoziCesta = vychoziCesta
        self.otevri = otevri; self.synchronizuj = synchronizuj; self.slozky = slozky; self.zarizeni = zarizeni
    }

    public convenience init(kopie: Kopie, synchronizuj: (@Sendable () async -> Void)? = nil, slozky: @escaping @Sendable () -> [String]? = { nil },
                            zarizeni: @escaping @Sendable () -> String? = { nil }) {
        self.init(otevri: { kopie }, synchronizuj: synchronizuj.map { s in { @Sendable _ in await s() } }, slozky: slozky, zarizeni: zarizeni)
    }

    /// Kopie, nebo nil, když ji zatím nejde otevřít bez okna.
    var kopie: Kopie? {
        zamek.lock(); defer { zamek.unlock() }
        if let k = _kopie { return k }
        _kopie = try? otevri()
        return _kopie
    }

    static let zamceno = "Místní kopie Airine je zamčená. Otevři lištu Airine (ta se smí zeptat Klíčenky) a zkus to znovu. Co platí zjistíš i ve vzdáleném konektoru Airine."

    nonisolated(unsafe) static let nastroje: [[String: Any]] = [
        ["name": "co_plati",
         "description": "Co k projektu v Airine platí: platné podklady a skills, co nahrazují, fakta, rozpory a soubory, ke kterým nemáš přístup. Zavolej na začátku práce na klientovi nebo projektu. Funguje i bez spojení (z místní kopie).",
         "inputSchema": ["type": "object", "properties": [
            "projekt_id": ["type": "string", "description": "Id projektu v Airine"],
            "cesta": ["type": "string", "description": "Pracovní složka; projekt se dohledá podle propojení složky"]]]],
        ["name": "nahlas_soubor",
         "description": "Nahlásí MD soubor nebo skill do Airine po vytvoření nebo změně. Údaje karty se berou z hlavičky souboru (name, description, blok airine:). Bez spojení se hlášení uloží do fronty a odešle později.",
         "inputSchema": ["type": "object", "required": ["cesta"], "properties": [
            "cesta": ["type": "string", "description": "Absolutní cesta k souboru"]]]],
    ]

    public func instrukce() -> String {
        var t = "Airine je katalog znalostí firmy. Na začátku práce na projektu zavolej co_plati, po vytvoření nebo změně MD souboru či skillu nahlas_soubor."
        if let n = kopie?.navod { t += "\n\n" + n.obsah }
        return t
    }

    /// Zpracuje jednu zprávu; nil = notifikace bez odpovědi.
    public func zpracuj(_ radek: String) async -> String? {
        guard let data = radek.data(using: .utf8),
              let zprava = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return odpoved(id: NSNull(), chyba: (-32700, "neplatný JSON"))
        }
        guard let id = zprava["id"] else { return nil }
        let metoda = zprava["method"] as? String ?? ""
        let parametry = zprava["params"] as? [String: Any] ?? [:]
        switch metoda {
        case "initialize":
            return odpoved(id: id, vysledek: [
                "protocolVersion": parametry["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "airine-mistni", "version": "0.1.0"],
                "instructions": instrukce(),
            ])
        case "ping": return odpoved(id: id, vysledek: [String: Any]())
        case "tools/list": return odpoved(id: id, vysledek: ["tools": Self.nastroje])
        case "tools/call":
            let jmeno = parametry["name"] as? String ?? ""
            let arg = parametry["arguments"] as? [String: Any] ?? [:]
            do {
                return odpoved(id: id, vysledek: ["content": [["type": "text", "text": try await zavolej(jmeno, arg)]]])
            } catch {
                return odpoved(id: id, vysledek: ["content": [["type": "text", "text": "Chyba: \(error)"]], "isError": true])
            }
        default:
            return odpoved(id: id, chyba: (-32601, "neznámá metoda \(metoda)"))
        }
    }

    func zavolej(_ jmeno: String, _ arg: [String: Any]) async throws -> String {
        guard Self.nastroje.contains(where: { $0["name"] as? String == jmeno }) else {
            throw NSError(domain: "airine", code: 1, userInfo: [NSLocalizedDescriptionKey: "neznámý nástroj \(jmeno)"])
        }
        guard let kopie else { return Self.zamceno }
        switch jmeno {
        case "co_plati":
            let projekt = try (arg["projekt_id"] as? String) ?? ((arg["cesta"] as? String) ?? vychoziCesta).flatMap { try kopie.projekt(pro: $0) }
            // Bez lišty kopii nikdo neobnoví: starší než 5 minut se nejdřív
            // zkusí stáhnout. Bez spojení odpoví kopie, jaká je (stav k … to řekne).
            if kopie.posledniSynchronizace.map({ Date().timeIntervalSince($0) > Self.cerstvost }) ?? true {
                await synchronizuj?(kopie)
            }
            return try Doporuceni(kopie: kopie, projekt: projekt).text(fronta: kopie.fronta().count, workspace: workspace)
        case "nahlas_soubor":
            guard let cesta = arg["cesta"] as? String else { return "Chybí cesta." }
            let v = try Nahlasovani(kopie: kopie, slozky: slozky(), zarizeni: zarizeni()).nahlas(cesta: cesta)
            if case .zarazeno = v { await synchronizuj?(kopie) }
            switch v {
            case .zarazeno(let id, let otisk, let rada):
                let odm = try kopie.fronta(vcetneOdmitnutych: true).filter { $0.hlaseni.id == id && $0.hlaseni.otisk == otisk }.compactMap(\.odmitnuto).flatMap(\.chyby)
                let ceka = try kopie.fronta().contains { $0.hlaseni.id == id }
                // Odmítnuté hlášení není nahlášené: dřív tu stálo „Nahlášeno“ i s výčtem odmítnutí.
                var t = !odm.isEmpty ? "Airine hlášení odmítla (karta \(id)), oprav hlavičku a nahlas znovu:\n"
                        + odm.map { "- \($0.pole): \($0.zprava)" }.joined(separator: "\n")
                    : ceka ? "Uloženo do fronty, odešle se při příští synchronizaci (karta \(id))."
                    : "Nahlášeno do Airine (karta \(id))."
                if let rada { t += "\n" + rada }
                return t
            case .beze_zmeny: return "Beze změny od posledního hlášení."
            case .preskoceno(let proc): return "Nehlásím: \(proc)."
            case .bezKarty: return v.proAgenta ?? ""
            }
        default:
            throw NSError(domain: "airine", code: 1, userInfo: [NSLocalizedDescriptionKey: "neznámý nástroj \(jmeno)"])
        }
    }

    /// Jak stará smí být místní kopie, než `co_plati` zkusí synchronizaci.
    static let cerstvost: TimeInterval = 300

    func odpoved(id: Any, vysledek: Any? = nil, chyba: (Int, String)? = nil) -> String {
        var o: [String: Any] = ["jsonrpc": "2.0", "id": id]
        if let chyba { o["error"] = ["code": chyba.0, "message": chyba.1] } else { o["result"] = vysledek ?? [:] }
        let d = (try? JSONSerialization.data(withJSONObject: o, options: [.withoutEscapingSlashes])) ?? Data()
        return String(decoding: d, as: UTF8.self)
    }
}
