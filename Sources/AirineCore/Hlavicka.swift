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

    public static func precti(_ obsah: String) -> Hlavicka {
        var h = Hlavicka()
        guard let (blok, _) = rozdel(obsah) else { return h }
        h.text = blok
        var sekce: String?
        var posledniKlic: String?
        for radek in blok.components(separatedBy: "\n") {
            if radek.trimmingCharacters(in: .whitespaces).isEmpty || radek.trimmingCharacters(in: .whitespaces).hasPrefix("#") { continue }
            let odsazeni = radek.prefix { $0 == " " }.count
            let r = radek.trimmingCharacters(in: .whitespaces)
            if odsazeni == 0 {
                let (k, v) = klicHodnota(r)
                sekce = v.isEmpty ? k : nil
                if !v.isEmpty { h.nahore[k] = v }
                continue
            }
            guard let s = sekce, s == "airine" || s == "metadata" else { continue }
            if r.hasPrefix("- "), let k = posledniKlic {
                h.seznamy[k, default: []].append(odUvozovek(String(r.dropFirst(2))))
                continue
            }
            var (k, v) = klicHodnota(r)
            if s == "metadata" {
                guard k.hasPrefix("airine-") else { continue }
                k = String(k.dropFirst("airine-".count))
            }
            posledniKlic = k
            if v.hasPrefix("[") && v.hasSuffix("]") {
                h.seznamy[k] = v.dropFirst().dropLast().split(separator: ",").map { odUvozovek(String($0)) }.filter { !$0.isEmpty }
            } else if !v.isEmpty {
                h.airine[k] = v
            }
        }
        return h
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

    static func odUvozovek(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.count >= 2, (t.hasPrefix("\"") && t.hasSuffix("\"")) || (t.hasPrefix("'") && t.hasSuffix("'")) {
            return String(t.dropFirst().dropLast())
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
