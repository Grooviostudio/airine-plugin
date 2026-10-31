import CryptoKit
import Foundation
import Network

/// Přihlášení bez terminálu: OAuth s PKCE přes prohlížeč a smyčku na
/// 127.0.0.1 (RFC 8252). Server vydá obyčejný osobní token `airine_…`
/// na hodinu a obnovovací token na 90 dní; obnova ho pokaždé vymění.
/// Token z terminálu (`airine prihlas`) platí dál, OAuth se ho netýká.
public struct OAuthUdaje: Codable, Sendable, Equatable {
    public var client_id: String
    public var refresh_token: String
    public var platiDo: Date
}

public enum ChybaPrihlaseni: Error, Equatable {
    case server(String)              // odpověď serveru bez tokenu (error z RFC 6749)
    case odmitnuto(String)           // člověk souhlas zamítl nebo vypršel
    case stav                        // state z prohlížeče nesedí
}

public enum Prihlaseni {
    public static let jmenoKlienta = "Airine pro Mac"
    public static let cesta = "/prihlaseni"
    /// Obnovit, když tokenu zbývá míň než tohle.
    static let rezerva: TimeInterval = 5 * 60

    public struct Pkce: Sendable {
        public let verifier: String
        public let challenge: String
        public let state: String
    }

    static func b64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func nahodne(_ n: Int) -> Data { Data((0..<n).map { _ in UInt8.random(in: .min ... .max) }) }

    public static func pkce() -> Pkce {
        let v = b64url(nahodne(32))
        return Pkce(verifier: v, challenge: b64url(Data(SHA256.hash(data: Data(v.utf8)))), state: b64url(nahodne(16)))
    }

    static func url(_ server: String, _ cesta: String) -> URL {
        URL(string: server)!.appendingPathComponent(cesta)
    }

    static func json(_ r: URLRequest, _ session: URLSession) async throws -> [String: Any] {
        let (data, odp): (Data, URLResponse)
        do { (data, odp) = try await session.data(for: r) } catch is URLError { throw ChybaServeru.bezSpojeni }
        let kod = (odp as? HTTPURLResponse)?.statusCode ?? 0
        if kod >= 500 || kod == 0 { throw ChybaServeru.bezSpojeni }
        let telo = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(kod) else { throw ChybaPrihlaseni.server(telo["error"] as? String ?? "http \(kod)") }
        return telo
    }

    static func formular(_ u: URL, _ pole: [String: String]) -> URLRequest {
        var r = URLRequest(url: u)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var c = URLComponents(); c.queryItems = pole.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        r.httpBody = Data((c.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        return r
    }

    /// Veřejný klient s přesnou adresou smyčky. Port je pokaždé jiný,
    /// proto se klient registruje při každém přihlášení.
    public static func registruj(server: String, redirect: String, session: URLSession = .shared) async throws -> String {
        var r = URLRequest(url: url(server, "oauth/register"))
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_name": jmenoKlienta, "redirect_uris": [redirect], "token_endpoint_auth_method": "none",
            "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"]])
        guard let id = try await json(r, session)["client_id"] as? String else { throw ChybaPrihlaseni.server("client_id") }
        return id
    }

    /// Stránka souhlasu v prohlížeči: člověk se přihlásí a vybere workspace.
    public static func adresa(server: String, clientId: String, redirect: String, pkce: Pkce) -> URL {
        var c = URLComponents(url: url(server, "oauth/authorize"), resolvingAgainstBaseURL: false)!
        c.queryItems = [
            URLQueryItem(name: "response_type", value: "code"), URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirect), URLQueryItem(name: "state", value: pkce.state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge), URLQueryItem(name: "code_challenge_method", value: "S256")]
        return c.url!
    }

    static func token(_ telo: [String: Any], clientId: String) throws -> (String, OAuthUdaje) {
        guard let t = telo["access_token"] as? String, t.hasPrefix("airine_"),
              let o = telo["refresh_token"] as? String else { throw ChybaPrihlaseni.server("access_token") }
        let za = (telo["expires_in"] as? Double) ?? 3600
        return (t, OAuthUdaje(client_id: clientId, refresh_token: o, platiDo: Date().addingTimeInterval(za)))
    }

    public static func vymen(server: String, clientId: String, kod: String, redirect: String, verifier: String,
                             session: URLSession = .shared) async throws -> (String, OAuthUdaje) {
        let r = formular(url(server, "oauth/token"), ["grant_type": "authorization_code", "code": kod, "client_id": clientId,
                                                     "redirect_uri": redirect, "code_verifier": verifier])
        return try token(try await json(r, session), clientId: clientId)
    }

    public static func obnov(server: String, udaje: OAuthUdaje, session: URLSession = .shared) async throws -> (String, OAuthUdaje) {
        let r = formular(url(server, "oauth/token"), ["grant_type": "refresh_token", "refresh_token": udaje.refresh_token,
                                                     "client_id": udaje.client_id])
        return try token(try await json(r, session), clientId: udaje.client_id)
    }

    public static func uloz(_ t: UlozisteTajemstvi, token: String, udaje: OAuthUdaje) throws {
        try t.zapis("oauth", try JSONEncoder().encode(udaje))
        try t.zapis("token", Data(token.utf8))
    }

    public static func udaje(_ t: UlozisteTajemstvi) -> OAuthUdaje? {
        (try? t.cti("oauth")).flatMap { $0 }.flatMap { try? JSONDecoder().decode(OAuthUdaje.self, from: $0) }
    }

    public static func odhlas(_ t: UlozisteTajemstvi) {
        try? t.smaz("oauth"); try? t.smaz("token")
    }

    /// Před požadavky na server: token z OAuth, kterému končí platnost
    /// (nebo `vynutit` po 401), se obnoví. Lišta i hook běží zvlášť a obnova
    /// token mění, proto pod zámkem souboru a s novým čtením po zámku.
    /// Zamítnutá obnova = odhlášení (token odvolaný v Airine). Výpadek nic nemění.
    public static func obnovJeTreba(domov: Domov, tajemstvi: PametTajemstvi, server: String, vynutit: Bool = false,
                                    session: URLSession = .shared) async {
        guard let pred = udaje(tajemstvi), vynutit || pred.platiDo.timeIntervalSinceNow < rezerva else { return }
        let zamek = domov.slozka.appendingPathComponent("prihlaseni.zamek").path
        FileManager.default.createFile(atPath: zamek, contents: nil)
        let fd = open(zamek, O_RDWR)
        guard fd >= 0 else { return }
        defer { flock(fd, LOCK_UN); close(fd) }
        flock(fd, LOCK_EX)
        tajemstvi.zapomen("oauth"); tajemstvi.zapomen("token")
        // Mezitím obnovil jiný proces: jeho token platí.
        guard let u = udaje(tajemstvi), u.refresh_token == pred.refresh_token else { return }
        do {
            let (t, nove) = try await obnov(server: server, udaje: u, session: session)
            try uloz(tajemstvi, token: t, udaje: nove)
        } catch ChybaPrihlaseni.server(let e) where e == "invalid_grant" || e == "invalid_client" {
            odhlas(tajemstvi)
        } catch {}
    }
}

/// Jednorázový posluchač na 127.0.0.1 pro návrat z prohlížeče: přijme
/// první požadavek na `Prihlaseni.cesta`, vrátí jeho parametry a skončí.
public final class Smycka: @unchecked Sendable {
    let listener: NWListener
    let fronta = DispatchQueue(label: "eu.airine.prihlaseni")
    private var hotovo: CheckedContinuation<[String: String], Error>?
    private var pripraven: CheckedContinuation<Void, Error>?
    public private(set) var port: UInt16 = 0

    public init() throws {
        let p = NWParameters.tcp
        p.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: p)
    }

    public var redirect: String { "http://127.0.0.1:\(port)\(Prihlaseni.cesta)" }

    /// Začne poslouchat a vrátí, až port zná.
    public func spust() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            fronta.async { [self] in
                pripraven = c
                listener.stateUpdateHandler = { [weak self] s in
                    guard let self, let c = self.pripraven else { return }
                    switch s {
                    case .ready: self.pripraven = nil; self.port = self.listener.port?.rawValue ?? 0; c.resume()
                    case .failed(let e): self.pripraven = nil; c.resume(throwing: e)
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] spojeni in self?.obsluz(spojeni) }
                listener.start(queue: fronta)
            }
        }
    }

    /// Parametry návratu (`code`, `state`, nebo `error`). Po `limit` sekundách chyba.
    public func cekej(limit: Double = 600) async throws -> [String: String] {
        fronta.asyncAfter(deadline: .now() + limit) { [weak self] in self?.dokonci(.failure(ChybaPrihlaseni.odmitnuto("timeout"))) }
        return try await withCheckedThrowingContinuation { c in
            fronta.async {
                if let v = self.vysledek { self.vysledek = nil; c.resume(with: v) } else { self.hotovo = c }
            }
        }
    }

    public func zastav() { listener.cancel() }

    /// Návrat, který přišel dřív, než se na něj začalo čekat.
    private var vysledek: Result<[String: String], Error>?

    private func dokonci(_ r: Result<[String: String], Error>) {
        guard let c = hotovo else { if vysledek == nil { vysledek = r }; return }
        hotovo = nil
        c.resume(with: r)
        listener.cancel()
    }

    static func parametry(_ zacatek: String) -> [String: String]? {
        let radek = zacatek.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let casti = radek.split(separator: " ")
        guard casti.count >= 2, casti[0] == "GET", let c = URLComponents(string: String(casti[1])),
              c.path == Prihlaseni.cesta else { return nil }
        var p: [String: String] = [:]
        for q in c.queryItems ?? [] { p[q.name] = q.value ?? "" }
        return p
    }

    private func obsluz(_ spojeni: NWConnection) {
        spojeni.start(queue: fronta)
        spojeni.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { return }
            let p = data.flatMap { Self.parametry(String(decoding: $0, as: UTF8.self)) }
            let ok = p?["code"] != nil
            let text = p == nil ? "Tady nic není."
                : ok ? "Přihlášeno. Airine na Macu už má přístup, okno můžeš zavřít."
                : "Přihlášení se nepovedlo. Zkus to znovu z lišty."
            let html = "<!doctype html><meta charset=utf-8><title>Airine</title><body style=\"font:16px -apple-system,sans-serif;padding:48px\">\(text)</body>"
            let odp = "HTTP/1.1 \(p == nil ? "404 Not Found" : "200 OK")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
            spojeni.send(content: Data(odp.utf8), completion: .contentProcessed { _ in spojeni.cancel() })
            if let p { self.dokonci(.success(p)) }
        }
    }
}

extension Prihlaseni {
    /// Celé přihlášení: smyčka, registrace, prohlížeč (`otevri`), výměna kódu.
    public static func prihlas(server: String, tajemstvi: UlozisteTajemstvi, session: URLSession = .shared,
                               otevri: @Sendable (URL) -> Void) async throws {
        let s = try Smycka()
        defer { s.zastav() }
        try await s.spust()
        let klient = try await registruj(server: server, redirect: s.redirect, session: session)
        let p = pkce()
        otevri(adresa(server: server, clientId: klient, redirect: s.redirect, pkce: p))
        let navrat = try await s.cekej()
        guard navrat["state"] == p.state else { throw ChybaPrihlaseni.stav }
        guard let kod = navrat["code"] else { throw ChybaPrihlaseni.odmitnuto(navrat["error"] ?? "?") }
        let (t, u) = try await vymen(server: server, clientId: klient, kod: kod, redirect: s.redirect, verifier: p.verifier, session: session)
        try uloz(tajemstvi, token: t, udaje: u)
    }
}
