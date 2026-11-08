import Foundation

/// Profil = jedno přihlášení = jeden workspace v Airine. Každý profil má vlastní
/// místní kopii (`profily/<id>/` v domově) a vlastní položky v Klíčence
/// (`token.<id>`, `klic-kopie.<id>`, `oauth.<id>`). Výchozí profil jsou data
/// v kořeni domova se jmény bez přípony, takže dosavadní instalace se nemění.
///
/// Které složce patří který profil, leží v `profily.json` v kořeni domova,
/// mimo šifrovanou kopii: hook to potřebuje vědět dřív, než ví, kterou kopii
/// otevřít. Soubor drží jen cesty, id a jména profilů, žádný obsah ani token.
public struct Profily: Codable, Sendable, Equatable {
    /// Id výchozího profilu (data v kořeni domova).
    public static let vychozi = "vychozi"

    public struct Profil: Codable, Sendable, Equatable {
        /// Jméno workspace, jak ho hlavička ukáže agentovi.
        public var nazev: String
        public init(nazev: String) { self.nazev = nazev }
    }

    public var profily: [String: Profil]
    /// Složka (normalizovaná cesta) → id profilu.
    public var slozky: [String: String]

    public init(profily: [String: Profil] = [:], slozky: [String: String] = [:]) {
        self.profily = profily; self.slozky = slozky
    }

    public static func soubor(_ koren: URL) -> URL { koren.appendingPathComponent("profily.json") }

    /// Chybějící soubor = jen výchozí profil (dosavadní chování).
    public static func nacti(_ koren: URL) -> Profily {
        guard let d = try? Data(contentsOf: soubor(koren)),
              let p = try? JSONDecoder().decode(Profily.self, from: d) else { return Profily() }
        return p
    }

    public func uloz(_ koren: URL) throws {
        try FileManager.default.createDirectory(at: koren, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = Self.soubor(koren)
        try e.encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Id smí mít jen malá písmena bez diakritiky, číslice a pomlčku: jde
    /// do jména složky i položky v Klíčence.
    public static func platneId(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 32 && id.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    /// Cesta pro porovnání: absolutní, bez „~“ a „..“, se symlinky rozvedenými
    /// (/tmp → /private/tmp) a v jednom unicode tvaru (Finder a terminál
    /// posílají „Plocha“ s diakritikou jednou složenou, jednou rozloženou).
    public static func klic(_ cesta: String) -> String {
        let u = URL(fileURLWithPath: (cesta as NSString).expandingTildeInPath).standardizedFileURL
        var p = u.resolvingSymlinksInPath().path
        // Neexistující cesta (smazaný soubor): rozvede se aspoň nejbližší existující rodič.
        if !FileManager.default.fileExists(atPath: u.path) {
            var rodic = u.deletingLastPathComponent(), zbytek = [u.lastPathComponent]
            while rodic.path != "/" && !FileManager.default.fileExists(atPath: rodic.path) {
                zbytek.insert(rodic.lastPathComponent, at: 0); rodic = rodic.deletingLastPathComponent()
            }
            p = zbytek.reduce(rodic.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }.path
        }
        if p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p.precomposedStringWithCanonicalMapping
    }

    /// Profil pro cestu: nejdelší přiřazená složka, ve které cesta leží.
    /// Bez shody výchozí profil. Profil, který v seznamu není, se nepoužije.
    public func profil(pro cesta: String) -> String {
        let c = Self.klic(cesta)
        let shoda = slozky.filter { c == $0.key || c.hasPrefix($0.key == "/" ? "/" : $0.key + "/") }
            .max { $0.key.count < $1.key.count }?.value
        guard let shoda, shoda == Self.vychozi || profily[shoda] != nil else { return Self.vychozi }
        return shoda
    }

    public func nazev(_ id: String) -> String? { profily[id]?.nazev }

    public mutating func pridej(_ id: String, nazev: String) throws {
        // „vychozi“ jde taky: jen pojmenuje výchozí profil pro hlavičku.
        guard Self.platneId(id) else { throw ChybaProfilu.neplatneId(id) }
        profily[id] = Profil(nazev: nazev)
    }

    /// Přiřadí složku profilu. `vychozi` vrátí podsložku výchozímu profilu,
    /// i když nadřazená složka patří jinému.
    public mutating func prirad(_ slozka: String, _ id: String) throws {
        guard id == Self.vychozi || profily[id] != nil else { throw ChybaProfilu.neznamy(id) }
        slozky[Self.klic(slozka)] = id
    }

    public mutating func zrus(_ slozka: String) { slozky[Self.klic(slozka)] = nil }
}

public enum ChybaProfilu: Error, CustomStringConvertible {
    case neplatneId(String)
    case neznamy(String)
    public var description: String {
        switch self {
        case .neplatneId(let id): "Id profilu „\(id)“ nejde: jen malá písmena, číslice a pomlčka, nejvýš 32 znaků."
        case .neznamy(let id): "Profil „\(id)“ neexistuje. Založ ho: airine profil pridej \(id) --nazev JMÉNO"
        }
    }
}

extension Domov {
    /// Domov profilu. Výchozí profil je kořen sám.
    public func profil(_ id: String) -> Domov {
        id == Profily.vychozi ? Domov(slozka: koren, profil: nil)
            : Domov(slozka: koren.appendingPathComponent("profily", isDirectory: true).appendingPathComponent(id, isDirectory: true), koren: koren, profil: id)
    }

    /// Domov profilu, kterému patří cesta.
    public func pro(cesta: String) -> Domov { profil(Profily.nacti(koren).profil(pro: cesta)) }

    /// Id profilu (výchozí = „vychozi“).
    public var idProfilu: String { profil ?? Profily.vychozi }
}
