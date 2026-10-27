import Foundation

/// Doporučení na začátek práce složené z místní kopie, takže funguje
/// i bez spojení. PROZATÍMNÍ pravidla: srovnají se s pravidly serveru
/// podle sdílené sady vstup → výstup a shodu bude hlídat test nad ní.
public struct Doporuceni: Sendable {
    public let projekt: String?
    public let platne: [Karta]
    public let nahrazene: [Karta]
    public let bezPrava: [Karta]
    public let stavK: Date?
    public let navod: Navod?

    public init(kopie: Kopie, projekt: String?) throws {
        self.projekt = projekt
        let vse = try kopie.karty().filter { projekt == nil || $0.projekt_id == projekt }
        platne = vse.filter { $0.bez_prava != true && $0.platna }.sorted { ($0.zmeneno ?? "") > ($1.zmeneno ?? "") }
        nahrazene = vse.filter { $0.bez_prava != true && !$0.platna }
        bezPrava = vse.filter { $0.bez_prava == true }
        stavK = kopie.posledniSynchronizace
        navod = kopie.navod
    }

    static let cas: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "cs_CZ"); f.dateFormat = "d. M. H:mm"; return f
    }()

    /// Text pro kontext agenta. Jen karty, obsah si agent načte, až ho potřebuje
    /// (postupné odhalování). ~100 tokenů na kartu, proto jen projekt.
    public func text(fronta: Int = 0) -> String {
        var r: [String] = []
        r.append("# Airine: co platí" + (projekt == nil ? "" : " k projektu") + " (stav k \(stavK.map { Self.cas.string(from: $0) } ?? "nikdy, zatím bez synchronizace"))")
        if projekt == nil {
            r.append("Složka není propojená s projektem v Airine (`airine propoj <projekt_id>`). Ukazuju celý katalog.")
        }
        if platne.isEmpty { r.append("K projektu zatím nic nahlášeného.") }
        for k in platne.prefix(40) {
            var radek = "- \(k.name)"
            if let t = k.typ { radek += " [\(t)]" }
            if let p = k.popis { radek += ": \(p.prefix(300))" }
            r.append(radek)
            if let n = k.nahrazuje, let stara = nahrazene.first(where: { $0.id == n }) { r.append("  nahrazuje \(stara.name), starou verzi nepoužívat") }
            if let f = k.fakta, !f.isEmpty { r.append("  " + f.map { "\($0.klic): \($0.hodnota)" }.joined(separator: ", ")) }
            if k.rozpor == true { r.append("  ⚠ dvě verze v rozporu, rozhodne \(k.vlastnik_jmeno ?? k.vlastnik ?? "vlastník")") }
            if k.jenNaZarizeni { r.append("  ⚠ leží jen na jednom počítači, kolegové ho nevidí") }
            if let m = k.mista?.first(where: { $0.druh == "zarizeni" })?.cesta { r.append("  \(m)") }
        }
        if platne.count > 40 { r.append("… a dalších \(platne.count - 40), vypíše `airine doporuceni --vse`") }
        for k in bezPrava.prefix(10) { r.append("- \(k.name): bez přístupu, požádej o něj \(k.vlastnik_jmeno ?? k.vlastnik ?? "vlastníka")") }
        if fronta > 0 { r.append("Čeká na odeslání do Airine: \(fronta) hlášení.") }
        if let n = navod { r.append("\n## Návod firmy pro agenty (verze \(n.verze))\n\(n.obsah)") }
        return r.joined(separator: "\n")
    }
}
