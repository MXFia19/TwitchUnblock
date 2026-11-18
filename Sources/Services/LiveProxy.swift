import Foundation

// ═══════════════════════════════════════════════════════════════════════════
//  « Mon proxy » (source « proxy », demande de bamy) : un proxy HTTP à soi
//  — hôte:port, identifiant et mot de passe facultatifs —, comme ceux de
//  TTV LOL PRO (github.com/younesaassila/ttv-lol-pro).
//
//  Twitch choisit ses pubs d'après l'adresse qui demande le direct : le
//  jeton de lecture (GQL), la liste maîtresse d'usher et les playlists de la
//  vidéo passent par le proxy, dans une session à part (requêtes https par
//  CONNECT) ; les segments vidéo restent lus en direct sur le CDN. C'est ce
//  que fait le tweak TwitchAdBlock (gunnerkidBT), qui fait passer GQL, usher,
//  *.playlist.ttvnw.net et video-weaver par son proxy.
//
//  Réglages → Lecteur, sous « Ma source » (LiveProxyRow). L'adresse et
//  l'identifiant sont des réglages (sauvegarde : « customProxy »,
//  « customProxyUser ») ; le mot de passe va dans le trousseau, jamais dans
//  la sauvegarde. Compilé aussi pour l'Apple TV (getLive), qui ne le règle pas.
// ═══════════════════════════════════════════════════════════════════════════
enum LiveProxy {
    /// « hôte:port » (vide : pas de proxy).
    static let addressKey = "cfg_live_proxy"
    /// Identifiant (vide : proxy sans identifiants).
    static let userKey = "cfg_live_proxy_user"
    /// Mot de passe, dans le trousseau (Keychain).
    private static let passwordKey = "live_proxy_password"

    // MARK: Adresse
    /// Adresse saisie → « hôte:port » (minuscules ; IPv6 entre crochets), ou
    /// nil si ce n'est pas celle d'un proxy. « http:// » et « / » final
    /// tolérés ; ni chemin ni identifiants dans l'adresse (ils ont leurs
    /// champs) ; port de 1 à 65535.
    static func normalized(_ raw: String) -> String? {
        var v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.lowercased().hasPrefix("http://") { v = String(v.dropFirst("http://".count)) }
        while v.hasSuffix("/") { v.removeLast() }
        guard let parts = split(v) else { return nil }
        return parts.host.contains(":") ? "[\(parts.host)]:\(parts.port)" : "\(parts.host):\(parts.port)"
    }

    /// Adresse collée avec ses identifiants, sous l'une des formes des
    /// fournisseurs : « identifiant:mot de passe@hôte:port » (celle de TTV LOL
    /// PRO) ou « hôte:port:identifiant:mot de passe ». Rend l'adresse et les
    /// identifiants à part (LiveProxyRow les remet dans leurs champs), nil
    /// pour une autre forme.
    static func credentialsSplit(_ raw: String) -> (address: String, user: String, password: String)? {
        var v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.lowercased().hasPrefix("http://") { v = String(v.dropFirst("http://".count)) }
        if let at = v.lastIndex(of: "@") {
            let creds = v[..<at]
            let address = String(v[v.index(after: at)...])
            guard let colon = creds.firstIndex(of: ":") else { return (address, String(creds), "") }
            return (address, String(creds[..<colon]), String(creds[creds.index(after: colon)...]))
        }
        let parts = v.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
        guard !v.hasPrefix("["), parts.count == 4, Int(parts[1]) != nil else { return nil }
        return ("\(parts[0]):\(parts[1])", String(parts[2]), String(parts[3]))
    }

    /// « hôte:port » → hôte (sans crochets) et port, ou nil.
    private static func split(_ v: String) -> (host: String, port: Int)? {
        guard !v.isEmpty, v.count <= 260, let colon = v.lastIndex(of: ":"),
              let port = Int(v[v.index(after: colon)...]), (1...65535).contains(port) else { return nil }
        var host = String(v[..<colon]).lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
            guard host.contains(":"),
                  host.allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == "." }) else { return nil }
        } else {
            guard let first = host.first, first.isLetter || first.isNumber,
                  host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-._".contains($0)) })
            else { return nil }
        }
        return (host, port)
    }

    /// Proxy réglé et valable : hôte et port ; nil sans.
    static var endpoint: (host: String, port: Int)? {
        UserDefaults.standard.string(forKey: addressKey).flatMap { normalized($0) }.flatMap { split($0) }
    }

    static var isConfigured: Bool { endpoint != nil }

    /// « port 8080 » du proxy réglé, pour le journal (joint aux signalements) :
    /// ni l'hôte — un proxy payant peut n'être protégé que par son adresse —,
    /// ni les identifiants.
    static var logLabel: String { endpoint.map { "port \($0.port)" } ?? "" }

    // MARK: Identifiants
    static var user: String { UserDefaults.standard.string(forKey: userKey) ?? "" }
    static var password: String { Keychain.loadToken(passwordKey) ?? "" }

    /// Mot de passe rangé dans le trousseau ; vide ou nil : retiré.
    static func setPassword(_ value: String?) {
        Keychain.storeToken((value ?? "").isEmpty ? nil : value, for: passwordKey)
    }

    // MARK: Session
    private static let lock = NSLock()
    /// Session du proxy, et ce pour quoi elle a été faite (adresse, identifiants).
    private static var cached: (key: String, session: URLSession)?

    /// Session qui passe par le proxy réglé (nil sans proxy), refaite quand
    /// l'adresse ou les identifiants changent. L'ancienne n'est jamais
    /// invalidée : le chargeur des playlists garde celle d'un direct lancé
    /// avec elle (LivePlaylistLoader.route), et une session invalidée ne
    /// pourrait plus rien charger.
    static var session: URLSession? {
        guard let endpoint else { return nil }
        let key = "\(endpoint.host)|\(endpoint.port)|\(user)|\(password)"
        lock.lock(); defer { lock.unlock() }
        if let kept = cached, kept.key == key { return kept.session }
        let made = makeSession(host: endpoint.host, port: endpoint.port)
        cached = (key, made)
        return made
    }

    private static func makeSession(host: String, port: Int) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        // Sans cache : une playlist de direct change toutes les 2 s.
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        // Clés écrites en clair : les constantes HTTPS de CFNetwork
        // (kCFNetworkProxiesHTTPSEnable…) n'existent que sur macOS, mais iOS
        // et tvOS lisent ces clés ; les requêtes https passent alors par le
        // proxy avec CONNECT.
        config.connectionProxyDictionary = [
            "HTTPEnable": 1, "HTTPProxy": host, "HTTPPort": port,
            "HTTPSEnable": 1, "HTTPSProxy": host, "HTTPSPort": port,
        ]
        return URLSession(configuration: config, delegate: ProxyAuth.shared, delegateQueue: nil)
    }

    // MARK: Résultat
    /// Ce qu'a donné le dernier essai du proxy (direct ou « Tester ») : de
    /// quoi le dire dans les réglages.
    enum Status: Equatable {
        case ok
        /// Pas de réponse du proxy (adresse, port, réseau).
        case unreachable
        /// Identifiants absents ou refusés (407).
        case auth
        /// Twitch répond par le proxy, mais refuse (code HTTP).
        case refused(Int)

        /// Texte des réglages ({c} : `code`).
        var messageKey: String {
            switch self {
            case .ok:          return "src_proxy_ok"
            case .unreachable: return "src_proxy_unreachable"
            case .auth:        return "src_proxy_auth"
            case .refused:     return "src_proxy_failed"
            }
        }

        /// Code HTTP d'un refus de Twitch, vide sinon.
        var code: String {
            if case .refused(let status) = self { return String(status) }
            return ""
        }
    }

    private static var status: Status?

    /// Dernier résultat ; nil s'il n'y en a pas eu depuis le lancement.
    static var lastStatus: Status? {
        lock.lock(); defer { lock.unlock() }
        return status
    }

    static func record(_ value: Status) {
        lock.lock(); status = value; lock.unlock()
    }

    // MARK: Envoi
    /// Demande envoyée par le proxy (getLive : jeton, liste maîtresse ;
    /// « Tester ») : corps et code HTTP, ou nil si le proxy ne l'a pas menée
    /// au bout — injoignable, identifiants refusés (407) —, dit au journal et
    /// retenu pour les réglages. Une demande abandonnée (lecteur fermé pendant
    /// le chargement) ne compte pas.
    static func send(_ request: URLRequest, through session: URLSession) async -> (data: Data, status: Int)? {
        let refusals = ProxyAuth.shared.refusals
        do {
            let (data, resp) = try await session.data(for: request)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code != 407 else {
                record(.auth)
                logger.error("LIVE", "❌ Mon proxy : identifiants refusés (407)", logLabel)
                return nil
            }
            return (data, code)
        } catch {
            if ProxyAuth.shared.refusals != refusals {
                record(.auth)
                logger.error("LIVE", "❌ Mon proxy : identifiants refusés (407)", logLabel)
            } else if (error as? URLError)?.code == .cancelled || Task.isCancelled {
                return nil
            } else {
                record(.unreachable)
                logger.error("LIVE", "❌ Mon proxy injoignable", "\(logLabel) · \(error.localizedDescription)")
            }
            return nil
        }
    }

    /// « Tester » (réglages) : une petite demande publique à GQL par le proxy
    /// (`query { __typename }`), son résultat retenu comme celui d'un direct.
    static func check() async -> Status {
        guard let proxied = session, let url = URL(string: "https://gql.twitch.tv/gql") else { return .unreachable }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue(kGQLClientID, forHTTPHeaderField: "Client-ID")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(#"{"query":"query { __typename }"}"#.utf8)
        logger.info("LIVE", "Test de mon proxy…", logLabel)
        guard let res = await send(req, through: proxied) else { return lastStatus ?? .unreachable }
        let ok = res.status == 200 && String(decoding: res.data, as: UTF8.self).contains("Query")
        let result: Status = ok ? .ok : .refused(res.status)
        record(result)
        if ok {
            logger.success("LIVE", "✅ Mon proxy répond", logLabel)
        } else {
            logger.warn("LIVE", "⚠️ Twitch ne répond pas par mon proxy (\(res.status))", logLabel)
        }
        return result
    }
}

/// Identifiants du proxy, quand il répond 407 : donnés une fois par demande.
/// Absents ou refusés, la demande échoue (comptée : LiveProxy.send le dit)
/// et getLive passe à la source suivante.
private final class ProxyAuth: NSObject, URLSessionTaskDelegate {
    static let shared = ProxyAuth()
    private let lock = NSLock()
    private var refused = 0

    /// Identifiants refusés depuis le lancement.
    var refusals: Int {
        lock.lock(); defer { lock.unlock() }
        return refused
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Le reste (certificat de Twitch au bout du tunnel) : comme d'habitude.
        guard challenge.protectionSpace.isProxy() else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let user = LiveProxy.user
        guard challenge.previousFailureCount == 0, !user.isEmpty else {
            lock.lock(); refused += 1; lock.unlock()
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential,
                          URLCredential(user: user, password: LiveProxy.password, persistence: .forSession))
    }
}
