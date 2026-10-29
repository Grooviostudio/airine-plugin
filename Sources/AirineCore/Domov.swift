import Foundation

/// Kde plugin drží svá data. Výchozí je ~/Library/Application Support/Airine;
/// `AIRINE_DOMOV` ho přesměruje (testy, izolované zkoušky). Čte: Kopie, Klic.
public struct Domov: Sendable {
    public let slozka: URL

    public init(slozka: URL? = nil) {
        if let slozka {
            self.slozka = slozka
        } else if let env = ProcessInfo.processInfo.environment["AIRINE_DOMOV"], !env.isEmpty {
            self.slozka = URL(fileURLWithPath: env, isDirectory: true)
        } else {
            let podpora = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.slozka = podpora.appendingPathComponent("Airine", isDirectory: true)
        }
    }

    public var databaze: URL { slozka.appendingPathComponent("kopie.sqlite") }
    public var nastaveni: URL { slozka.appendingPathComponent("nastaveni.json") }

    public func priprav() throws {
        try FileManager.default.createDirectory(at: slozka, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }
}

/// Nastavení, které není tajné: adresa serveru a id zařízení („leží jen na
/// jednom Macu" se pozná podle něj). Token tu není, ten je v Klíčence.
public struct Nastaveni: Codable, Sendable {
    public var server: String
    public var zarizeni: String
    public var nazevZarizeni: String
    /// Posílat s kartou i obsah souboru (MD do 1 MB). Výchozí zapnuto
    /// (rozhodnutí 29. 10. 2026); starší soubor nastavení klíč nemá.
    public var posilatObsah: Bool
    /// Složky a soubory, jejichž obsah nikdy neodejde, jen karta
    /// (`airine vynech`). Vzor bez „/“ na začátku sedí kdekoli v cestě.
    public var vynechatObsah: [String]

    public init(server: String, zarizeni: String, nazevZarizeni: String, posilatObsah: Bool = true, vynechatObsah: [String] = []) {
        self.server = server; self.zarizeni = zarizeni; self.nazevZarizeni = nazevZarizeni
        self.posilatObsah = posilatObsah; self.vynechatObsah = vynechatObsah
    }

    enum CodingKeys: String, CodingKey { case server, zarizeni, nazevZarizeni, posilatObsah, vynechatObsah }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        server = try c.decode(String.self, forKey: .server)
        zarizeni = try c.decode(String.self, forKey: .zarizeni)
        nazevZarizeni = try c.decode(String.self, forKey: .nazevZarizeni)
        posilatObsah = try c.decodeIfPresent(Bool.self, forKey: .posilatObsah) ?? true
        vynechatObsah = try c.decodeIfPresent([String].self, forKey: .vynechatObsah) ?? []
    }

    public static func nacti(_ domov: Domov) throws -> Nastaveni {
        if let data = try? Data(contentsOf: domov.nastaveni) {
            return try JSONDecoder().decode(Nastaveni.self, from: data)
        }
        let n = Nastaveni(server: "https://app.airine.eu", zarizeni: UUID().uuidString.lowercased(),
                          nazevZarizeni: Host.current().localizedName ?? "Mac")
        try n.uloz(domov)
        return n
    }

    public func uloz(_ domov: Domov) throws {
        try domov.priprav()
        let data = try JSONEncoder().encode(self)
        try data.write(to: domov.nastaveni, options: .atomic)
    }
}
