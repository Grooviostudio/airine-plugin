import CryptoKit
import Foundation
import Security

/// Tajemství pluginu: šifrovací klíč místní kopie a osobní token Airine.
/// Výchozí je Klíčenka; `AIRINE_KLICE=soubor` je drží v souboru v domově
/// (jen pro testy a izolované zkoušky, nikdy u zákazníka).
public protocol UlozisteTajemstvi: Sendable {
    func cti(_ jmeno: String) throws -> Data?
    func zapis(_ jmeno: String, _ data: Data) throws
    func smaz(_ jmeno: String) throws
}

public enum ChybaTajemstvi: Error { case klicenka(OSStatus) }

public struct Klicenka: UlozisteTajemstvi {
    let sluzba: String
    public init(sluzba: String = "eu.airine.plugin") { self.sluzba = sluzba }

    private func dotaz(_ jmeno: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: sluzba,
         kSecAttrAccount as String: jmeno]
    }

    public func cti(_ jmeno: String) throws -> Data? {
        var q = dotaz(jmeno)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var vysledek: AnyObject?
        let s = SecItemCopyMatching(q as CFDictionary, &vysledek)
        if s == errSecItemNotFound { return nil }
        guard s == errSecSuccess else { throw ChybaTajemstvi.klicenka(s) }
        return vysledek as? Data
    }

    public func zapis(_ jmeno: String, _ data: Data) throws {
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

public enum Tajemstvi {
    public static func vychozi(_ domov: Domov) -> UlozisteTajemstvi {
        ProcessInfo.processInfo.environment["AIRINE_KLICE"] == "soubor" ? SouborTajemstvi(domov: domov) : Klicenka()
    }

    /// Klíč místní kopie. Vznikne při prvním spuštění a nikdy neopustí Mac.
    public static func klicKopie(_ u: UlozisteTajemstvi) throws -> SymmetricKey {
        if let data = try u.cti("klic-kopie"), data.count == 32 { return SymmetricKey(data: data) }
        let klic = SymmetricKey(size: .bits256)
        try u.zapis("klic-kopie", klic.withUnsafeBytes { Data($0) })
        return klic
    }
}
