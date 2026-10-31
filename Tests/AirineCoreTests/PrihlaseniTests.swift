import CryptoKit
import Foundation
import Testing
@testable import AirineCore

/// Falešný server OAuth: odpovědi podle cesty, zapisuje, co přišlo.
final class OAuthStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var odpovedi: [String: (Int, [String: Any])] = [:]
    nonisolated(unsafe) static var prislo: [(String, String)] = []     // (cesta, tělo)
    static let zamek = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let cesta = request.url!.path
        var telo = request.httpBody ?? Data()
        if telo.isEmpty, let s = request.httpBodyStream {
            s.open(); var b = [UInt8](repeating: 0, count: 65_536)
            while s.hasBytesAvailable { let n = s.read(&b, maxLength: b.count); if n <= 0 { break }; telo.append(b, count: n) }
            s.close()
        }
        Self.zamek.lock()
        Self.prislo.append((cesta, String(decoding: telo, as: UTF8.self)))
        let (kod, json) = Self.odpovedi[cesta] ?? (404, [:])
        Self.zamek.unlock()
        let odp = HTTPURLResponse(url: request.url!, statusCode: kod, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: odp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: json))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [OAuthStub.self]
        return URLSession(configuration: c)
    }
}

@Suite(.serialized) struct PrihlaseniTests {
    let server = "https://airine.test"
    let token1 = "airine_" + String(repeating: "a", count: 40)
    let token2 = "airine_" + String(repeating: "b", count: 40)

    @Test func pkceJeS256BezVyplne() {
        let p = Prihlaseni.pkce()
        #expect(p.verifier.count == 43 && !p.verifier.contains("=") && !p.verifier.contains("+") && !p.verifier.contains("/"))
        #expect(p.challenge == Prihlaseni.b64url(Data(SHA256.hash(data: Data(p.verifier.utf8)))))
        #expect(p.state != Prihlaseni.pkce().state)
        let u = Prihlaseni.adresa(server: server, clientId: "k1", redirect: "http://127.0.0.1:5000/prihlaseni", pkce: p)
        let q = Dictionary(uniqueKeysWithValues: URLComponents(url: u, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        #expect(u.path == "/oauth/authorize")
        #expect(q == ["response_type": "code", "client_id": "k1", "redirect_uri": "http://127.0.0.1:5000/prihlaseni",
                      "state": p.state, "code_challenge": p.challenge, "code_challenge_method": "S256"])
    }

    @Test func smyckaVratiParametryNavratu() async throws {
        let s = try Smycka()
        try await s.spust()
        #expect(s.port > 0 && s.redirect.hasPrefix("http://127.0.0.1:"))
        let (_, jinde) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(s.port)/favicon.ico")!)
        #expect((jinde as! HTTPURLResponse).statusCode == 404, "cizí adresa přihlášení neukončí")
        let (data, odp) = try await URLSession.shared.data(from: URL(string: s.redirect + "?code=abc&state=xyz&iss=x")!)
        #expect((odp as! HTTPURLResponse).statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self).contains("Přihlášeno"))
        let p = try await s.cekej(limit: 5)
        #expect(p["code"] == "abc" && p["state"] == "xyz")
        #expect(Smycka.parametry("GET /jinde?code=1 HTTP/1.1\r\n") == nil)
        #expect(Smycka.parametry("POST /prihlaseni?code=1 HTTP/1.1\r\n") == nil)
    }

    @Test func vymenaAObnovaTokenu() async throws {
        let d = try docasnyDomov()
        let t = PametTajemstvi(SouborTajemstvi(domov: d))
        let sess = OAuthStub.session()
        OAuthStub.prislo = []
        OAuthStub.odpovedi = [
            "/oauth/register": (201, ["client_id": "k1"]),
            "/oauth/token": (200, ["access_token": token1, "token_type": "Bearer", "expires_in": 3600, "refresh_token": "r1"]),
        ]
        #expect(try await Prihlaseni.registruj(server: server, redirect: "http://127.0.0.1:1/prihlaseni", session: sess) == "k1")
        let reg = try JSONSerialization.jsonObject(with: Data(OAuthStub.prislo[0].1.utf8)) as! [String: Any]
        #expect(reg["token_endpoint_auth_method"] as? String == "none" && reg["client_name"] as? String == "Airine pro Mac")

        let (tok, u) = try await Prihlaseni.vymen(server: server, clientId: "k1", kod: "c+1", redirect: "http://127.0.0.1:1/prihlaseni",
                                                  verifier: "v", session: sess)
        #expect(tok == token1 && u.refresh_token == "r1" && u.platiDo > Date().addingTimeInterval(3500))
        #expect(OAuthStub.prislo[1].1.contains("code=c%2B1") && OAuthStub.prislo[1].1.contains("grant_type=authorization_code"))
        try Prihlaseni.uloz(t, token: tok, udaje: u)

        // Platný token se neobnovuje.
        await Prihlaseni.obnovJeTreba(domov: d, tajemstvi: t, server: server, session: sess)
        #expect(OAuthStub.prislo.count == 2)

        // Končící token se obnoví a uloží nový.
        try Prihlaseni.uloz(t, token: tok, udaje: OAuthUdaje(client_id: "k1", refresh_token: "r1", platiDo: Date().addingTimeInterval(60)))
        OAuthStub.odpovedi["/oauth/token"] = (200, ["access_token": token2, "expires_in": 3600, "refresh_token": "r2"])
        await Prihlaseni.obnovJeTreba(domov: d, tajemstvi: t, server: server, session: sess)
        #expect(OAuthStub.prislo.last!.1.contains("refresh_token=r1"))
        let po = try t.cti("token")
        #expect(po == Data(token2.utf8) && Prihlaseni.udaje(t)?.refresh_token == "r2")

        // Výpadek nic nemění.
        OAuthStub.odpovedi["/oauth/token"] = (503, [:])
        await Prihlaseni.obnovJeTreba(domov: d, tajemstvi: t, server: server, vynutit: true, session: sess)
        let vypadek = try t.cti("token")
        #expect(vypadek == Data(token2.utf8))

        // Odvolaný v Airine: obnova zamítnutá = odhlášení.
        OAuthStub.odpovedi["/oauth/token"] = (400, ["error": "invalid_grant"])
        await Prihlaseni.obnovJeTreba(domov: d, tajemstvi: t, server: server, vynutit: true, session: sess)
        let odvolany = try t.cti("token")
        #expect(odvolany == nil && Prihlaseni.udaje(t) == nil)
    }

    @Test func tokenZTerminaluSeNeobnovuje() async throws {
        let d = try docasnyDomov()
        let t = PametTajemstvi(SouborTajemstvi(domov: d))
        try t.zapis("token", Data(token1.utf8))
        OAuthStub.prislo = []
        await Prihlaseni.obnovJeTreba(domov: d, tajemstvi: t, server: server, vynutit: true, session: OAuthStub.session())
        let zustal = try t.cti("token")
        #expect(OAuthStub.prislo.isEmpty && zustal == Data(token1.utf8))
    }
}
