import CryptoKit
import Foundation

/// Hlavička souboru (YAML mezi `---` na začátku). Plugin z ní
/// čte jen dvě úrovně: pole nahoře (`name`, `description`) a blok `airine:`
/// (u SKILL.md `metadata:` s klíči `airine-*`, protože standard Agent Skills
/// cizí pole nahoře nepovoluje). Celou YAML gramatiku plugin neumí a nepotřebuje:
/// hlavičku kontroluje server, plugin ji jen posílá jako text.
public struct Hlavicka: Sendable, Equatable {
    public var text: String?                       // celý blok bez oddělovačů
    public var nahore: [String: String] = [:]
    public var airine: [String: String] = [:]      // jednoduché hodnoty
    public var seznamy: [String: [String]] = [:]   // airine.vychazi_z apod.
    public var blok: [String: String] = [:]        // jen z `airine:`
    public var meta: [String: String] = [:]        // jen z `metadata:` (`airine-*` bez předpony)
    public var podmapy: [String: [String: String]] = [:]   // airine.fakta

    /// Pole karty z hlavičky stejně jako `kartaZHlavicky()` na serveru
    /// (lib/katalog.js): má-li `metadata` `airine-id`, je to skill a platí
    /// jen metadata + `name`/`description` nahoře; jinak blok `airine:`,
    /// kde `name` a `popis` mají přednost před polem nahoře.
    public struct Karta: Equatable, Sendable {
        public var skill: Bool
        public var id, name, popis, typ, klient, projekt, nahrazuje: String?
        public var fakta: [String: String]?
        public var vychazi_z: [String]?
    }

    public func karta(skillSouborem: Bool) -> Karta {
        if meta["id"] != nil || (skillSouborem && blok.isEmpty) {
            return Karta(skill: true, id: meta["id"], name: nahore["name"], popis: nahore["description"],
                         typ: meta["typ"] ?? "skill", klient: meta["klient"], projekt: meta["projekt"], nahrazuje: meta["nahrazuje"])
        }
        return Karta(skill: false, id: blok["id"], name: blok["name"] ?? nahore["name"], popis: blok["popis"] ?? nahore["description"],
                     typ: blok["typ"], klient: blok["klient"], projekt: blok["projekt"], nahrazuje: blok["nahrazuje"],
                     fakta: podmapy["fakta"].flatMap { $0.isEmpty ? nil : $0 }, vychazi_z: seznamy["vychazi_z"])
    }

    public static func precti(_ obsah: String) -> Hlavicka {
        var h = Hlavicka()
        guard let (blok, _) = rozdel(obsah) else { return h }
        h.text = blok
        var sekce: String?
        var posledniKlic: String?
        var urovenSekce: Int?
        let radky = blok.components(separatedBy: "\n")
        var i = 0
        while i < radky.count {
            let radek = radky[i]; i += 1
            if radek.trimmingCharacters(in: .whitespaces).isEmpty || radek.trimmingCharacters(in: .whitespaces).hasPrefix("#") { continue }
            let odsazeni = radek.prefix { $0 == " " }.count
            let r = radek.trimmingCharacters(in: .whitespaces)
            var (k, v) = klicHodnota(r)
            // Víceřádková hodnota: blok `>`/`|` nebo pokračování prostého textu
            // na odsazených řádcích (časté u `description` ve SKILL.md).
            if let styl = blokovyStyl(v) {
                (v, i) = blokovaHodnota(radky, od: i, nad: odsazeni, styl: styl)
            } else if !v.isEmpty && !jeVUvozovkach(r) {
                var j = i, dalsi: [String] = []
                while j < radky.count {
                    let t = radky[j].trimmingCharacters(in: .whitespaces)
                    guard radky[j].prefix(while: { $0 == " " }).count > odsazeni, !t.isEmpty, !t.hasPrefix("#") else { break }
                    dalsi.append(t); j += 1
                }
                if !dalsi.isEmpty { v = ([v] + dalsi).joined(separator: " "); i = j }
            }
            if odsazeni == 0 {
                sekce = v.isEmpty ? k : nil
                urovenSekce = nil; posledniKlic = nil
                if !v.isEmpty { h.nahore[k] = v }
                continue
            }
            guard let s = sekce, s == "airine" || s == "metadata" else { continue }
            if r.hasPrefix("- "), let k = posledniKlic {
                h.seznamy[k, default: []].append(odUvozovek(String(r.dropFirst(2))))
                continue
            }
            let uroven = urovenSekce ?? odsazeni; urovenSekce = uroven
            // Třetí úroveň (airine.fakta: { klic: hodnota }).
            if odsazeni > uroven, let rodic = posledniKlic, s == "airine" {
                if !v.isEmpty { h.podmapy[rodic, default: [:]][k] = v }
                continue
            }
            if s == "metadata" {
                guard k.hasPrefix("airine-") else { continue }
                k = String(k.dropFirst("airine-".count))
            }
            posledniKlic = k
            if v.hasPrefix("[") && v.hasSuffix("]") {
                h.seznamy[k] = v.dropFirst().dropLast().split(separator: ",").map { odUvozovek(String($0)) }.filter { !$0.isEmpty }
            } else if !v.isEmpty {
                h.airine[k] = v
                if s == "airine" { h.blok[k] = v } else { h.meta[k] = v }
            }
        }
        return h
    }

    /// `>` sloučí řádky mezerou (prázdný řádek = nový odstavec), `|` je nechá.
    /// Indikátory `-`, `+` a číslo odsazení plugin přijme; koncové konce řádků
    /// hodnota karty nikdy nenese (stejně jako server, viz KontraktTests).
    static func blokovyStyl(_ v: String) -> Character? {
        guard let p = v.first, p == ">" || p == "|",
              v.dropFirst().allSatisfy({ "+-123456789".contains($0) }) else { return nil }
        return p
    }

    static func blokovaHodnota(_ radky: [String], od: Int, nad odsazeni: Int, styl: Character) -> (String, Int) {
        var j = od, casti: [String] = [], odsazeniBloku: Int?
        while j < radky.count {
            let radek = radky[j]
            if radek.trimmingCharacters(in: .whitespaces).isEmpty { casti.append(""); j += 1; continue }
            let o = radek.prefix { $0 == " " }.count
            guard o > odsazeni else { break }
            let b = odsazeniBloku ?? o; odsazeniBloku = b
            casti.append(String(radek.dropFirst(min(o, b)))); j += 1
        }
        while casti.last == "" { casti.removeLast() }
        // Prázdné řádky na konci patří až za blok, ne do něj.
        var konec = j
        while konec > od, radky[konec - 1].trimmingCharacters(in: .whitespaces).isEmpty { konec -= 1 }
        if styl == "|" { return (casti.joined(separator: "\n"), konec) }
        var r = "", predchozi: String?
        for c in casti {
            if c.isEmpty { r += "\n" }
            else if let p = predchozi, !p.isEmpty, !r.hasSuffix("\n") { r += " " + c }
            else { r += c }
            predchozi = c
        }
        return (r, konec)
    }

    static func jeVUvozovkach(_ r: String) -> Bool {
        let v = klicSurovy(r)
        return v.hasPrefix("\"") || v.hasPrefix("'")
    }

    static func klicSurovy(_ r: String) -> String {
        guard let i = r.firstIndex(of: ":") else { return "" }
        return String(r[r.index(after: i)...]).trimmingCharacters(in: .whitespaces)
    }

    /// Vrátí (blok hlavičky, tělo), nebo nil, když soubor hlavičku nemá.
    static func rozdel(_ obsah: String) -> (String, String)? {
        guard obsah.hasPrefix("---\n") || obsah.hasPrefix("---\r\n") else { return nil }
        let radky = obsah.components(separatedBy: "\n")
        guard let konec = radky.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "---" }) else { return nil }
        return (radky[1..<konec].joined(separator: "\n"), radky[(konec + 1)...].joined(separator: "\n"))
    }

    static func klicHodnota(_ r: String) -> (String, String) {
        guard let i = r.firstIndex(of: ":") else { return (r, "") }
        let k = String(r[..<i]).trimmingCharacters(in: .whitespaces)
        let v = String(r[r.index(after: i)...]).trimmingCharacters(in: .whitespaces)
        return (k, odUvozovek(v))
    }

    /// Hodnota v uvozovkách: u `"…"` escapy (`\"`, `\\`, `\n`, `\t`), u `'…'`
    /// zdvojený apostrof. Prostý text bez komentáře za ` #`.
    static func odUvozovek(_ s: String) -> String {
        let t = bezKomentareZaUvozovkami(s.trimmingCharacters(in: .whitespaces))
        if t.count >= 2, t.hasPrefix("\""), t.hasSuffix("\"") {
            var r = "", esc = false
            for ch in t.dropFirst().dropLast() {
                if esc {
                    switch ch { case "n": r += "\n"; case "t": r += "\t"; case "0": r += "\0"; default: r.append(ch) }
                    esc = false
                } else if ch == "\\" { esc = true } else { r.append(ch) }
            }
            return r
        }
        if t.count >= 2, t.hasPrefix("'"), t.hasSuffix("'") {
            return t.dropFirst().dropLast().replacingOccurrences(of: "''", with: "'")
        }
        if let k = t.range(of: " #") { return String(t[..<k.lowerBound]).trimmingCharacters(in: .whitespaces) }
        return t
    }

    /// `"…" # poznámka` → `"…"`: komentář za uzavírací uvozovkou do hodnoty nepatří.
    static func bezKomentareZaUvozovkami(_ t: String) -> String {
        guard let q = t.first, q == "\"" || q == "'" else { return t }
        let znaky = Array(t)
        var i = 1
        while i < znaky.count {
            if q == "\"" && znaky[i] == "\\" { i += 2; continue }
            if znaky[i] == q {
                if q == "'" && i + 1 < znaky.count && znaky[i + 1] == "'" { i += 2; continue }
                let zbytek = String(znaky[(i + 1)...]).trimmingCharacters(in: .whitespaces)
                return zbytek.isEmpty || zbytek.hasPrefix("#") ? String(znaky[...i]) : t
            }
            i += 1
        }
        return t
    }

    /// Vloží trvalé id do hlavičky (krok 1: id generuje plugin offline). Mění
    /// jen hlavičku, tělo souboru zůstane bajt po bajtu stejné.
    public static func vlozId(_ obsah: String, id: String, skill: Bool) -> String {
        let radkyId = skill ? ["  airine-id: \(id)", "  airine-schema: 1"] : ["  id: \(id)", "  schema: 1"]
        let blokKlic = skill ? "metadata:" : "airine:"
        guard let (blok, telo) = rozdel(obsah) else {
            return (["---", blokKlic] + radkyId + ["---"]).joined(separator: "\n") + "\n" + obsah
        }
        var radky = blok.components(separatedBy: "\n")
        if let i = radky.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == blokKlic && !$0.hasPrefix(" ") }) {
            radky.insert(contentsOf: radkyId, at: i + 1)
        } else {
            radky += [blokKlic] + radkyId
        }
        return (["---"] + radky + ["---"]).joined(separator: "\n") + "\n" + telo
    }
}

public enum Otisk {
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
