import Foundation

/// Odkaz z hlášeného souboru na jiný MD soubor. Airine z nich počítá zpětné
/// odkazy, sirotky a graf. Posílá se jen cíl, nikdy text odkazu ani okolí.
public struct Odkaz: Codable, Hashable, Sendable {
    public enum Druh: String, Codable, Sendable { case odkaz, vlozeni }
    public enum Zdroj: String, Codable, Sendable { case telo, hlavicka }

    public var druh: Druh
    public var cil_id: String?
    public var cesta: String?        // relativně ke složce hlášeného souboru
    public var nazev: String?        // jen nevyřešený wikilink
    public var kotva: String?
    public var vyreseny: Bool
    public var zdroj: Zdroj
    public var pole: String?         // klíč v hlavičce, kde odkaz stál
    public var pocet: Int

    public init(druh: Druh, cil_id: String? = nil, cesta: String? = nil, nazev: String? = nil, kotva: String? = nil,
                vyreseny: Bool, zdroj: Zdroj = .telo, pole: String? = nil, pocet: Int = 1) {
        self.druh = druh; self.cil_id = cil_id; self.cesta = cesta; self.nazev = nazev; self.kotva = kotva
        self.vyreseny = vyreseny; self.zdroj = zdroj; self.pole = pole; self.pocet = pocet
    }
}

public enum Odkazy {
    public static let strop = 500

    /// Odkaz tak, jak stojí v textu, ještě bez dohledání cíle.
    struct Surovy: Equatable {
        var druh: Odkaz.Druh
        var cil: String
        var kotva: String?
        var wiki: Bool
        var zdroj: Odkaz.Zdroj
        var pole: String?
    }

    // MARK: čtení

    static let wikiVzor = try! NSRegularExpression(pattern: #"(!?)\[\[([^\[\]\n|]+?)(?:\|[^\[\]\n]*)?\]\]"#)
    static let mdVzor = try! NSRegularExpression(pattern: #"(!?)\[[^\]\n]*\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"\n]*")?\s*\)"#)

    /// Přílohy, které Obsidian vkládá přes `![[…]]`. Nejsou MD, plugin je neposílá.
    static let prilohy: Set<String> = ["png", "jpg", "jpeg", "gif", "svg", "webp", "bmp", "pdf", "mp4", "mov", "webm",
                                       "mp3", "wav", "m4a", "ogg", "canvas", "base", "excalidraw", "zip", "csv", "json"]

    static func vytahni(_ obsah: String) -> [Surovy] {
        var r: [Surovy] = []
        let telo: String
        if let (blok, zbytek) = Hlavicka.rozdel(obsah) {
            var klic: String?
            for radek in blok.components(separatedBy: "\n") {
                let t = radek.trimmingCharacters(in: .whitespaces)
                if !t.hasPrefix("- "), let i = t.firstIndex(of: ":") { klic = String(t[..<i]).trimmingCharacters(in: .whitespaces) }
                for s in wiki(t) { r.append(Surovy(druh: s.druh, cil: s.cil, kotva: s.kotva, wiki: true, zdroj: .hlavicka, pole: klic)) }
            }
            telo = zbytek
        } else {
            telo = obsah
        }
        let cisty = bezKodu(telo)
        r += wiki(cisty)
        let ns = cisty as NSString
        for m in mdVzor.matches(in: cisty, range: NSRange(location: 0, length: ns.length)) {
            let surovy = ns.substring(with: m.range(at: 2))
            guard let c = relativniCil(surovy) else { continue }
            let (cil, kotva) = rozdelKotvu(c)
            r.append(Surovy(druh: ns.substring(with: m.range(at: 1)) == "!" ? .vlozeni : .odkaz,
                            cil: cil, kotva: kotva, wiki: false, zdroj: .telo))
        }
        return r
    }

    static func wiki(_ text: String) -> [Surovy] {
        let ns = text as NSString
        return wikiVzor.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let (cil, kotva) = rozdelKotvu(ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces))
            guard !cil.isEmpty else { return nil }   // [[#nadpis]] míří do téhož souboru
            return Surovy(druh: ns.substring(with: m.range(at: 1)) == "!" ? .vlozeni : .odkaz,
                          cil: cil, kotva: kotva, wiki: true, zdroj: .telo)
        }
    }

    static func rozdelKotvu(_ s: String) -> (String, String?) {
        guard let i = s.firstIndex(of: "#") else { return (s, nil) }
        let k = String(s[s.index(after: i)...]).trimmingCharacters(in: .whitespaces)
        return (String(s[..<i]).trimmingCharacters(in: .whitespaces), k.isEmpty ? nil : k)
    }

    /// Markdown cíl: jen relativní cesta na .md/.mdc. Web, mailto, absolutní
    /// cesty a kotvy do téhož souboru vypadnou.
    static func relativniCil(_ s: String) -> String? {
        guard !s.hasPrefix("/"), !s.hasPrefix("#"), !s.hasPrefix("~"),
              s.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) == nil else { return nil }
        let dekodovany = s.removingPercentEncoding ?? s
        let bezKotvy = rozdelKotvu(dekodovany).0.lowercased()
        guard bezKotvy.hasSuffix(".md") || bezKotvy.hasSuffix(".mdc") else { return nil }
        return dekodovany
    }

    /// Bloky ``` / ~~~ a `inline kód` nahradí mezerou: odkaz v ukázce kódu není odkaz.
    static func bezKodu(_ text: String) -> String {
        var ven: [String] = [], plot: String?
        for radek in text.components(separatedBy: "\n") {
            let t = radek.trimmingCharacters(in: .whitespaces)
            if let p = plot {
                if t.hasPrefix(p) { plot = nil }
                ven.append(""); continue
            }
            if t.hasPrefix("```") || t.hasPrefix("~~~") { plot = String(t.prefix(3)); ven.append(""); continue }
            ven.append(radek.replacingOccurrences(of: "`[^`\n]*`", with: " ", options: .regularExpression))
        }
        return ven.joined(separator: "\n")
    }

    // MARK: dohledání cíle

    /// Rejstřík MD souborů pod kořenem podle jména (bez přípony, malými
    /// písmeny). Wikilink se dohledá jako v Obsidianu: podle jména kdekoli
    /// v kořeni, při víc shodách nejkratší cesta.
    final class Rejstrik: @unchecked Sendable {
        let koren: URL
        private var podleJmena: [String: [String]]?
        static let stropSouboru = 20_000

        init(koren: URL) { self.koren = koren.standardizedFileURL }

        func najdi(_ cil: String) -> String? {
            let jmeno = (cil as NSString).lastPathComponent.lowercased()
            let kandidati = rejstrik()[jmeno] ?? []
            let s = cil.lowercased()
            let shody = s.contains("/") ? kandidati.filter { $0.lowercased().hasSuffix("/" + s) } : kandidati
            return shody.min { ($0.count, $0) < ($1.count, $1) }
        }

        private func rejstrik() -> [String: [String]] {
            if let p = podleJmena { return p }
            var r: [String: [String]] = [:], n = 0
            let fm = FileManager.default
            if let e = fm.enumerator(at: koren, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                for case let u as URL in e {
                    if u.lastPathComponent == "node_modules" { e.skipDescendants(); continue }
                    let ext = u.pathExtension.lowercased()
                    guard ext == "md" || ext == "mdc" else { continue }
                    n += 1; if n > Self.stropSouboru { break }
                    // Klíč bez přípony (.md), ale i s ní (.mdc i [[x.md]] se píšou celé).
                    let p = u.standardizedFileURL.path
                    r[u.deletingPathExtension().lastPathComponent.lowercased(), default: []].append(p)
                    r[u.lastPathComponent.lowercased(), default: []].append(p)
                }
            }
            podleJmena = r
            return r
        }
    }

    /// Odkazy souboru `url` s dohledanými cíli, sloučené a se stropem.
    public static func zeSouboru(_ obsah: String, url: URL, koren: URL?) -> (odkazy: [Odkaz], oriznuto: Bool) {
        let slozka = url.deletingLastPathComponent().standardizedFileURL
        let rejstrik = Rejstrik(koren: koren ?? slozka)
        var poradi: [Klic: Int] = [:], vse: [Odkaz] = []
        for s in vytahni(obsah) {
            var o = Odkaz(druh: s.druh, kotva: s.kotva, vyreseny: false, zdroj: s.zdroj, pole: s.pole)
            let cilCesta: String?
            if s.wiki {
                let ext = (s.cil as NSString).pathExtension.lowercased()
                if prilohy.contains(ext) { continue }
                cilCesta = rejstrik.najdi(s.cil)
            } else {
                let p = slozka.appendingPathComponent(s.cil).standardizedFileURL.path
                cilCesta = FileManager.default.fileExists(atPath: p) ? p : nil
            }
            if let c = cilCesta {
                o.vyreseny = true
                o.cesta = relativni(c, od: slozka.path)
                o.cil_id = idSouboru(c)
            } else if s.wiki {
                o.nazev = String(s.cil.prefix(256))
            } else {
                guard let c = normalizovana(s.cil) else { continue }
                o.cesta = c
            }
            // Meze serveru: cesta do 1024, kotva do 256 znaků.
            if (o.cesta?.count ?? 0) > 1024 { continue }
            o.kotva = o.kotva.map { String($0.prefix(256)) }
            // Klíč jako na serveru: (druh, cil_id ?? cesta ?? nazev, kotva, zdroj, pole).
            // Tentýž cíl pod dvěma cestami (kopie se stejným id) je jedna položka.
            let klic = Klic(druh: o.druh, cil: o.cil_id ?? o.cesta ?? o.nazev ?? "", kotva: o.kotva, zdroj: o.zdroj, pole: o.pole)
            if let i = poradi[klic] { vse[i].pocet += 1 } else { poradi[klic] = vse.count; vse.append(o) }
        }
        return (Array(vse.prefix(strop)), vse.count > strop)
    }

    struct Klic: Hashable { let druh: Odkaz.Druh; let cil: String; let kotva: String?; let zdroj: Odkaz.Zdroj; let pole: String? }

    /// Relativní cesta jen s `/`, bez `.` a prázdných segmentů; `..` zůstává.
    /// Se zpětným lomítkem nebo prázdná vypadne.
    static func normalizovana(_ c: String) -> String? {
        guard !c.contains("\\"), !c.contains("\0") else { return nil }
        let casti = c.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }
        return casti.isEmpty ? nil : casti.joined(separator: "/")
    }

    static func idSouboru(_ cesta: String) -> String? {
        let url = URL(fileURLWithPath: cesta)
        guard let a = try? FileManager.default.attributesOfItem(atPath: cesta),
              (a[.size] as? Int ?? .max) <= 1_048_576,
              let t = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Hlavicka.precti(t).karta(skillSouborem: url.lastPathComponent == "SKILL.md").id
    }

    /// Cesta `cil` relativně ke složce `od` (obě absolutní a standardizované).
    static func relativni(_ cil: String, od: String) -> String {
        let a = cil.split(separator: "/"), b = od.split(separator: "/")
        var i = 0
        while i < a.count - 1 && i < b.count && a[i] == b[i] { i += 1 }
        return (Array(repeating: "..", count: b.count - i) + a[i...].map(String.init)).joined(separator: "/")
    }
}
