import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// Tajemství pluginu: šifrovací klíč místní kopie a osobní token Airine.
/// Výchozí je Klíčenka; `AIRINE_KLICE=soubor` je drží v souboru v domově
/// (jen pro testy a izolované zkoušky, nikdy u zákazníka).
public protocol UlozisteTajemstvi: Sendable {
    func cti(_ jmeno: String) throws -> Data?
    func zapis(_ jmeno: String, _ data: Data) throws
    func smaz(_ jmeno: String) throws
}

public enum ChybaTajemstvi: Error {
    case klicenka(OSStatus)
    /// Proces na pozadí (hook, MCP, tichá synchronizace) do Klíčenky nepíše:
    /// zápis i založení položky umí ukázat okno.
    case bezOkna
    /// Klíč místní kopie neexistuje a proces na pozadí ho nezakládá.
    case klicChybi
}

/// `bezOkna`: proces na pozadí. Čtení nikdy neukáže okno Klíčenky; když by ho
/// potřebovalo (zamčená klíčenka, binárka mimo seznam povolených), skončí
/// chybou a proces tiše skončí. Okno smí ukázat jen lišta a ruční příkazy.
/// Důvod: hooky a MCP běží desítkykrát za hodinu, každý jako nový proces,
/// a ad hoc podepsaná binárka „Vždy povolit“ po aktualizaci ztratí.
public struct Klicenka: UlozisteTajemstvi {
    let sluzba: String
    let bezOkna: Bool
    public init(sluzba: String = "eu.airine.plugin", bezOkna: Bool = false) { self.sluzba = sluzba; self.bezOkna = bezOkna }

    private func dotaz(_ jmeno: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: sluzba,
         kSecAttrAccount as String: jmeno]
    }

    func dotazCteni(_ jmeno: String) -> [String: Any] {
        var q = dotaz(jmeno)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        if bezOkna {
            let lac = LAContext(); lac.interactionNotAllowed = true
            q[kSecUseAuthenticationContext as String] = lac
        }
        return q
    }

    public func cti(_ jmeno: String) throws -> Data? {
        let q = dotazCteni(jmeno)
        var vysledek: AnyObject?
        let s = SecItemCopyMatching(q as CFDictionary, &vysledek)
        if s == errSecItemNotFound { return nil }
        guard s == errSecSuccess else { throw ChybaTajemstvi.klicenka(s) }
        return vysledek as? Data
    }

    public func zapis(_ jmeno: String, _ data: Data) throws {
        if bezOkna { throw ChybaTajemstvi.bezOkna }
        let s = SecItemUpdate(dotaz(jmeno) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if s == errSecItemNotFound {
            var q = dotaz(jmeno)
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let p = SecItemAdd(q as CFDictionary, nil)
            guard p == errSecSuccess else { throw ChybaTajemstvi.klicenka(p) }
        } else if s != errSecSuccess {
            throw ChybaTajemstvi.klicenka(s)
        }
    }

    public func smaz(_ jmeno: String) throws {
        if bezOkna { throw ChybaTajemstvi.bezOkna }
        let s = SecItemDelete(dotaz(jmeno) as CFDictionary)
        guard s == errSecSuccess || s == errSecItemNotFound else { throw ChybaTajemstvi.klicenka(s) }
    }
}

/// Jen pro testy: tajemství v souborech s právy 0600 uvnitř domova.
public struct SouborTajemstvi: UlozisteTajemstvi {
    let slozka: URL
    public init(domov: Domov) { slozka = domov.slozka.appendingPathComponent("tajne", isDirectory: true) }

    public func cti(_ jmeno: String) throws -> Data? { try? Data(contentsOf: slozka.appendingPathComponent(jmeno)) }

    public func zapis(_ jmeno: String, _ data: Data) throws {
        try FileManager.default.createDirectory(at: slozka, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let url = slozka.appendingPathComponent(jmeno)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func smaz(_ jmeno: String) throws { try? FileManager.default.removeItem(at: slozka.appendingPathComponent(jmeno)) }
}

/// Tajemství čtené jednou za proces. Klíčenka se u ad hoc podepsané binárky
/// ptá při každém čtení, proto se hodnota drží v paměti. Lišta po 401
/// zavolá `zapomen("token")` a token přečte znovu.
public final class PametTajemstvi: UlozisteTajemstvi, @unchecked Sendable {
    let zdroj: UlozisteTajemstvi
    private var pamet: [String: Data?] = [:]
    private let zamek = NSLock()

    public init(_ zdroj: UlozisteTajemstvi) { self.zdroj = zdroj }

    public func cti(_ jmeno: String) throws -> Data? {
        zamek.lock(); defer { zamek.unlock() }
        if let d = pamet[jmeno] { return d }
        let d = try zdroj.cti(jmeno)
        pamet[jmeno] = .some(d)
        return d
    }

    public func zapis(_ jmeno: String, _ data: Data) throws {
        zamek.lock(); defer { zamek.unlock() }
        try zdroj.zapis(jmeno, data)
        pamet[jmeno] = .some(data)
    }

    public func smaz(_ jmeno: String) throws {
        zamek.lock(); defer { zamek.unlock() }
        try zdroj.smaz(jmeno)
        pamet[jmeno] = .some(nil)
    }

    /// Příští `cti` sáhne znovu do Klíčenky (token zrušený nebo vyměněný).
    public func zapomen(_ jmeno: String) {
        zamek.lock(); defer { zamek.unlock() }
        pamet[jmeno] = nil
    }
}

public enum Tajemstvi {
    /// Pro celý proces na pozadí: Klíčenka nesmí ukázat žádné okno, ani
    /// výzvu k odemčení. Volá jen `airine` v režimu hooku, MCP a tiché
    /// synchronizace, nikdy lišta. API je zastaralé, ale pro klíčenku přihlášení
    /// (kde plugin položky má) je jediné, které okno spolehlivě vypne.
    public static func zakazOkna() {
        SecKeychainSetUserInteractionAllowed(false)
    }

    private static let zamek = NSLock()
    nonisolated(unsafe) private static var sdilene: [String: PametTajemstvi] = [:]

    /// Jedno úložiště na domov a proces, takže každou položku přečte jednou.
    /// `bezOkna` pro procesy na pozadí (viz `Klicenka`).
    public static func vychozi(_ domov: Domov, bezOkna: Bool = false) -> PametTajemstvi {
        let soubor = ProcessInfo.processInfo.environment["AIRINE_KLICE"] == "soubor"
        let klic = (soubor ? "soubor:" : bezOkna ? "klicenka-bez-okna:" : "klicenka:") + domov.slozka.path
        zamek.lock(); defer { zamek.unlock() }
        if let u = sdilene[klic] { return u }
        let u = PametTajemstvi(soubor ? SouborTajemstvi(domov: domov) : Klicenka(bezOkna: bezOkna))
        sdilene[klic] = u
        return u
    }

    /// Klíč místní kopie. Vznikne při prvním spuštění a nikdy neopustí Mac.
    /// `zalozit: false` (procesy na pozadí): chybějící klíč nezakládá, jinak by
    /// hook při nečitelné Klíčence přepsal klíč a kopie by šla zahodit.
    public static func klicKopie(_ u: UlozisteTajemstvi, zalozit: Bool = true) throws -> SymmetricKey {
        if let data = try u.cti("klic-kopie"), data.count == 32 { return SymmetricKey(data: data) }
        guard zalozit else { throw ChybaTajemstvi.klicChybi }
        let klic = SymmetricKey(size: .bits256)
        try u.zapis("klic-kopie", klic.withUnsafeBytes { Data($0) })
        return klic
    }
}
