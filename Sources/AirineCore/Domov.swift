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
