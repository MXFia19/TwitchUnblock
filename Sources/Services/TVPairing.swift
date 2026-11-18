import Foundation
import CryptoKit

// MARK: – Connecter une TV LG (app TwitchUnblock pour webOS)
//
// La TV affiche un QR code « tupair://1?id=…&k=…&w=… » : un identifiant
// (16 octets) et une clé AES-256 (32 octets) tirés au hasard, en base64url
// sans « = », et l'adresse de son Worker (encodée). L'iPhone chiffre la
// session web (AES-256-GCM, données associées « tupair/1/<id> ») et dépose
// le paquet sur ce Worker (POST /api/pair) ; la TV le reprend une seule
// fois, 5 minutes au plus, et le déchiffre. Le Worker ne voit qu'un paquet
// chiffré : la clé n'existe que dans le QR code.
//
// Protocole v1, le même dans l'app TV et le Worker (dépôt du site) : ne
// jamais le changer d'un seul côté.
//
// Un QR code piégé ne doit pas pouvoir faire partir la session ailleurs :
// le paquet ne va qu'à un Worker que l'app connaît déjà (APIConfig), à
// l'adresse écrite dans l'app, jamais à celle lue dans le code.

enum TVPairing {

    // MARK: Code lu
    /// Code de TV lu et vérifié, prêt à recevoir la session.
    struct Request: Equatable {
        /// Identifiant tiré par la TV (22 caractères base64url).
        let id: String
        /// Clé AES-256 tirée par la TV (32 octets).
        let key: Data
        /// Worker où déposer le paquet : l'adresse de l'app (APIConfig).
        let worker: String
        /// Texte du QR code : un code refusé à la confirmation n'est pas reproposé.
        let raw: String
    }

    /// Pourquoi un QR code n'est pas pris.
    enum Refusal: Error, Equatable {
        /// Pas un code « tupair:// » (un QR code quelconque).
        case notPairCode
        /// « tupair://2… » : protocole d'une app TV plus récente.
        case newerVersion
        /// Identifiant, clé ou adresse absents ou mal formés.
        case malformed
        /// Worker hors de ceux de l'app, ou pas en https.
        case unknownWorker(host: String)
    }

    /// Lit un QR code : un code de TV v1 valable, vers un Worker connu.
    static func parse(_ text: String) -> Result<Request, Refusal> {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.lowercased().hasPrefix("tupair://") else { return .failure(.notPairCode) }
        guard let comps = URLComponents(string: raw),
              comps.scheme?.lowercased() == "tupair",
              let version = comps.host else { return .failure(.malformed) }
        guard version == "1" else {
            if let n = Int(version), n > 1 { return .failure(.newerVersion) }
            return .failure(.malformed)
        }
        guard comps.path.isEmpty || comps.path == "/" else { return .failure(.malformed) }
        let items = comps.queryItems ?? []
        // Valeur d'un paramètre présent une seule fois : deux « w » (ou deux
        // « id ») rendraient le code ambigu, il est refusé.
        func single(_ name: String) -> String? {
            let found = items.filter { $0.name == name }
            return found.count == 1 ? found[0].value : nil
        }
        guard let id = single("id"), id.unicodeScalars.count == 22, isBase64URL(id),
              let k = single("k"), isBase64URL(k),
              let key = base64URLDecode(k), key.count == 32,
              let w = single("w"), !w.isEmpty else { return .failure(.malformed) }
        guard let worker = knownWorker(w) else {
            let host = URLComponents(string: w)?.host ?? w
            return .failure(.unknownWorker(host: String(host.prefix(64))))
        }
        return .success(Request(id: id, key: key, worker: worker, raw: raw))
    }

    // MARK: Workers connus
    /// Adresse comparable d'un Worker : https seulement, sans identifiants,
    /// paramètres ni ancre ; hôte en minuscules, sans port 443 ni « / » final.
    /// nil si elle n'est pas acceptable.
    static func canonicalWorker(_ s: String) -> String? {
        guard let c = URLComponents(string: s.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.scheme?.lowercased() == "https",
              c.user == nil, c.password == nil,
              c.query == nil, c.fragment == nil,
              let host = c.host?.lowercased(), !host.isEmpty else { return nil }
        var path = c.path
        while path.hasSuffix("/") { path.removeLast() }
        let port = c.port.map { $0 == 443 ? "" : ":\($0)" } ?? ""
        return "https://\(host)\(port)\(path)"
    }

    /// Le Worker du code s'il est l'un de ceux de l'app (officiel, secours,
    /// Worker personnel réglé) : rendu tel que l'app l'écrit.
    static func knownWorker(_ w: String) -> String? {
        guard let wanted = canonicalWorker(w) else { return nil }
        return APIConfig.lookupBases.first { canonicalWorker($0) == wanted }
    }

    // MARK: Base64url
    private static let base64URLAlphabet: Set<Unicode.Scalar> =
        Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".unicodeScalars)

    /// Que des caractères base64url (sans « = »), au moins un.
    static func isBase64URL(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy { base64URLAlphabet.contains($0) }
    }

    static func base64URLDecode(_ s: String) -> Data? {
        var b64 = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let rest = b64.count % 4
        if rest == 1 { return nil }
        if rest > 0 { b64 += String(repeating: "=", count: 4 - rest) }
        return Data(base64Encoded: b64)
    }

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: Chiffrement
    /// Texte clair chiffré pour la TV (protocole v1).
    private struct Payload: Encodable {
        let v: Int
        let token: String
        let login: String
        let userId: String
        let displayName: String
        let sentAt: Int64
    }

    /// `nonce ‖ texte chiffré ‖ étiquette` (AES.GCM.SealedBox.combined), en
    /// base64url sans « = ». Nonce de 12 octets tiré au hasard à chaque envoi.
    static func seal(_ plain: Data, id: String, key: Data) throws -> String {
        let box = try AES.GCM.seal(plain, using: SymmetricKey(data: key), nonce: AES.GCM.Nonce(),
                                   authenticating: Data("tupair/1/\(id)".utf8))
        guard let combined = box.combined else { throw CryptoKitError.incorrectParameterSize }
        return base64URLEncode(combined)
    }

    // MARK: Compte de la session
    enum Profile {
        case valid(id: String, login: String, displayName: String)
        /// Twitch refuse le jeton : rien ne part.
        case invalid
        /// Pas de réponse claire (réseau, panne de Twitch).
        case unknown
    }

    /// Compte de la session web, lu chez Twitch avec son jeton (comme
    /// webSessionIdentity, nom affiché en plus) : la TV reçoit un jeton
    /// vérifié et le compte qui va avec.
    static func webProfile(token: String) async -> Profile {
        guard let url = URL(string: "https://gql.twitch.tv/gql") else { return .unknown }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)
        req.httpMethod = "POST"
        req.setValue(kGQLClientID, forHTTPHeaderField: "Client-ID")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(
            withJSONObject: ["query": "query { currentUser { id login displayName } }"])
        guard let (data, resp) = try? await session.data(for: req) else { return .unknown }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { return .invalid }
        guard code == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = json["data"] as? [String: Any] else { return .unknown }
        // `currentUser` à null : jeton refusé, sauf si GQL joint des erreurs
        // (panne passagère de Twitch).
        guard let user = payload["currentUser"] as? [String: Any] else {
            if let errors = json["errors"] as? [Any], !errors.isEmpty { return .unknown }
            return .invalid
        }
        guard let id = user["id"] as? String, !id.isEmpty else { return .unknown }
        let login = user["login"] as? String ?? ""
        let name = (user["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? login
        return .valid(id: id, login: login, displayName: name)
    }

    // MARK: Envoi
    enum SendResult: Equatable {
        case sent
        /// 409 : code déjà utilisé (ou expiré).
        case alreadyUsed
        /// 400, 413 : paquet ou code refusé.
        case invalid
        /// 429 : trop de requêtes.
        case tooMany
        /// Pas de réponse du Worker.
        case network
        /// Pas de session web, ou Twitch la refuse.
        case noSession
        /// Autre réponse du Worker (route absente, panne).
        case server(Int)
    }

    /// Requêtes de l'appairage : 10 s au plus chacune, sans cache ni cookies.
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 10
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    /// Envoie la session web à la TV du code. Le jeton ne part que chiffré,
    /// et n'est jamais écrit dans le journal. `knownLogin` et `knownUserId` :
    /// ce que l'app sait du compte, si Twitch ne répond pas d'ici.
    static func send(_ request: Request, token: String,
                     knownLogin: String?, knownUserId: String?) async -> SendResult {
        guard !token.isEmpty else { return .noSession }
        let login: String, userId: String, displayName: String
        let profile = await webProfile(token: token)
        switch profile {
        case .valid(let id, let l, let name):
            userId = id
            login = l
            displayName = name
        case .invalid:
            logger.warn("AUTH/TV", "Session web refusée par Twitch", "rien n'a été envoyé à la TV")
            return .noSession
        case .unknown:
            // Twitch injoignable d'ici (réseau filtré) : le Worker peut
            // l'être quand même.
            login = knownLogin ?? ""
            userId = knownUserId ?? ""
            displayName = login
        }

        let payload = Payload(v: 1, token: token, login: login, userId: userId,
                              displayName: displayName,
                              sentAt: Int64((Date().timeIntervalSince1970 * 1000).rounded()))
        let blob: String
        do {
            let plain = try JSONEncoder().encode(payload)
            blob = try seal(plain, id: request.id, key: request.key)
        } catch {
            logger.error("AUTH/TV", "Chiffrement impossible", error.localizedDescription)
            return .invalid
        }
        guard let url = URL(string: request.worker + "/api/pair"),
              let body = try? JSONSerialization.data(withJSONObject: ["id": request.id, "blob": blob]) else {
            return .invalid
        }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let code: Int
        do {
            let (_, resp) = try await session.data(for: req)
            code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            logger.warn("AUTH/TV", "Envoi à la TV impossible", error.localizedDescription)
            return .network
        }
        let host = URL(string: request.worker)?.host ?? request.worker
        switch code {
        case 200..<300:
            logger.success("AUTH/TV", "Session envoyée à la TV", "@\(login) · \(host)")
            return .sent
        case 409:
            logger.warn("AUTH/TV", "Code de TV déjà utilisé ou expiré", "HTTP 409")
            return .alreadyUsed
        case 400, 413:
            logger.warn("AUTH/TV", "Code de TV refusé par le serveur", "HTTP \(code)")
            return .invalid
        case 429:
            logger.warn("AUTH/TV", "Trop d'envois à la TV", "HTTP 429")
            return .tooMany
        default:
            logger.warn("AUTH/TV", "Envoi à la TV refusé", "HTTP \(code) · \(host)")
            return .server(code)
        }
    }
}
