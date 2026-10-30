import Foundation

/// Složky pro Znalosti: plugin hlásí jen soubory uvnitř složek, které si
/// člověk vybral (`airine slozky`, dialog v liště). Dokud nevybere žádnou,
/// nehlásí nic. Pracovní kopie repozitářů a skryté složky nehlásí nikdy;
/// výjimkou jsou místa, kde leží skills a pravidla agentů.
public enum Slozky {
    /// Skryté složky, které se hlásí dál: skills, agenti a pravidla.
    static let povoleneSkryte = [".claude/skills", ".claude/agents", ".claude/commands", ".cursor/rules"]

    /// Knihovny, sestavení a prostředí nástrojů. Nehlásí se z nich nic, ani karta:
    /// jen v `node_modules` leží tisíce README cizích balíčků.
    public static let vzdyPreskocene: Set<String> = [
        "node_modules", "vendor", "bower_components",
        "dist", "build", ".next", ".nuxt", "out", "coverage",
        "Pods", "DerivedData", ".git", "venv", ".venv", "__pycache__",
    ]

    /// Leží cesta pod knihovnou nebo sestavením uvnitř některé vybrané složky?
    /// Hlídání podle toho zahodí událost dřív, než cokoli čte.
    public static func vKnihovne(_ cesta: String, _ slozky: [String]) -> Bool {
        guard let s = podSlozkou(normalizuj(cesta), slozky) else { return false }
        return s.contains(where: vzdyPreskocene.contains)
    }

    /// Složky mezi nejhlubší vybranou složkou a souborem; `nil` = mimo vybrané.
    static func podSlozkou(_ c: String, _ slozky: [String]) -> [String]? {
        guard let koren = slozky.map(normalizuj).filter({ $0 == "/" || c.hasPrefix($0 + "/") }).max(by: { $0.count < $1.count })
        else { return nil }
        return c.dropFirst(koren == "/" ? 1 : koren.count + 1).split(separator: "/").dropLast().map(String.init)
    }

    /// Absolutní cesta bez „~“, „..“ a koncového lomítka.
    public static func normalizuj(_ cesta: String) -> String {
        let p = URL(fileURLWithPath: (cesta as NSString).expandingTildeInPath).standardizedFileURL.path
        return p.count > 1 && p.hasSuffix("/") ? String(p.dropLast()) : p
    }

    /// Proč se soubor nehlásí; `nil` = hlásí se.
    public static func duvod(_ cesta: String, _ slozky: [String]) -> String? {
        let c = normalizuj(cesta)
        if c.contains("/.claude/worktrees/") { return "pracovní kopie repozitáře" }
        guard !slozky.isEmpty else { return "není vybraná žádná složka pro Znalosti (airine slozky pridej CESTA)" }
        // Nejhlubší vybraná složka: skryté složky se počítají až pod ní.
        guard let slozkySouboru = podSlozkou(c, slozky) else { return "mimo složky pro Znalosti" }
        if slozkySouboru.contains(where: vzdyPreskocene.contains) { return "knihovna nebo sestavení" }
        for (i, d) in slozkySouboru.enumerated() where d.hasPrefix(".") {
            let zbytek = slozkySouboru[i...].joined(separator: "/")
            if !povoleneSkryte.contains(where: { zbytek == $0 || zbytek.hasPrefix($0 + "/") }) { return "skrytá složka" }
        }
        return nil
    }
}
