import Foundation
import SwiftUI

// MARK: – Models
struct ChannelReward: Identifiable, Equatable {
    let id: String
    let title: String
    let cost: Int
    let isEnabled: Bool
    let isInStock: Bool
    let isPaused: Bool
    let isUserInputRequired: Bool
    let prompt: String?
    let backgroundColor: String
    let imageURL: String?
    var canRedeem: Bool { isEnabled && isInStock && !isPaused }
}

// MARK: – Service
@MainActor
final class ChannelPointsService: ObservableObject {
    @Published var balance: Int = 0 { didSet { balanceKnown = true } }
    /// Solde lu au moins une fois pour ce compte et cette chaîne. Inconnu
    /// (sans session web, lecture ratée), toutes les récompenses passaient
    /// pour « Insuff. » avec un solde de 0.
    @Published private(set) var balanceKnown = false
    @Published var rewards: [ChannelReward] = []
    @Published var isLoading = false
    @Published var errorMsg: String? = nil
    @Published var pendingClaimId: String? = nil
    @Published var lastBalanceChange: Int = 0
    @Published var needsWebLogin = false   // true = token web absent/invalide → login WKWebView requis

    private var channelId    = ""
    private var channelLogin = ""
    private var token        = ""
    private var balanceTimer: Timer? = nil
    private var claimTimer:   Timer? = nil
    private let balancePollInterval: TimeInterval = 90
    private let claimPollInterval:   TimeInterval = 30

    // MARK: – Présence "minute-watched" (pour gagner des points passivement)
    // Twitch ne crédite les points passifs (~10/5min) et ne génère les coffres
    // (~15min) que s'il te considère comme spectateur. On lui envoie donc des
    // événements minute-watched toutes les 60s, comme le client web.
    private var viewerId    = ""
    private var spadeURL:    String? = nil
    private var broadcastId: String? = nil
    private var watchTimer:  Timer? = nil
    private let watchPollInterval: TimeInterval = 60
    /// Réclame automatiquement les coffres bonus dès qu'ils apparaissent.
    var autoClaim = true

    // MARK: – Anti-spam claim
    /// Coffres dont le claim a échoué → on ne réessaie pas en boucle (évite le spam).
    private var failedClaims: Set<String> = []
    /// Échecs passagers par coffre (voir claimBonus).
    private var claimAttempts: [String: Int] = [:]
    private var isClaiming = false

    // MARK: – Client-Integrity (token minté via WebView éphémère, réutilisé ~1h en natif)
    private var integrityTok:    String? = nil
    private var integrityDevice: String  = ""
    private var integrityExpiry: Date    = .distantPast
    private var integrityFor:    String  = ""

    /// Device-Id persistant (cohérence des requêtes GQL de lecture).
    private var deviceId: String {
        if let d = UserDefaults.standard.string(forKey: "twitch_device_id") { return d }
        let chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        let d = String((0..<32).map { _ in chars.randomElement()! })
        UserDefaults.standard.set(d, forKey: "twitch_device_id")
        return d
    }

    // MARK: – Load
    func load(channelLogin: String, channelId: String, token: String,
              userLogin: String? = nil, viewerId: String? = nil) async {
        guard !channelId.isEmpty else {
            logger.warn("POINTS", "Chargement annulé", "channelId manquant")
            return
        }
        // Avant le changement de chaîne : c'est la précédente qui s'arrête
        // (sa session de points se termine).
        stopPolling()
        let gen = presenceGeneration
        self.channelLogin = channelLogin
        self.channelId    = channelId
        self.token        = token
        self.viewerId     = viewerId ?? ""
        needsWebLogin     = false
        balanceKnown      = false

        isLoading = true; errorMsg = nil
        let start = Date()

        // Les récompenses sont publiques → toujours récupérables, même sans token web.
        let r = await fetchRewards()
        rewards = r.sorted { $0.cost < $1.cost }

        // Le solde est privé → nécessite le token de session web (cookie auth-token).
        guard !token.isEmpty else {
            balance = 0; pendingClaimId = nil
            balanceKnown = false
            needsWebLogin = true
            isLoading = false
            logger.info("POINTS", "Token web absent",
                        "\(rewards.count) récompenses affichées · solde indisponible (connexion requise)")
            return
        }

        logger.info("POINTS", "Chargement canal \(channelLogin)",
                    "compte: @\(userLogin ?? "?")")

        let b = await fetchBalance()
        let elapsed = String(format: "%.0f ms", Date().timeIntervalSince(start) * 1000)

        if let b {
            balance        = b.balance
            pendingClaimId = b.claimId
        }

        logger.success("POINTS", "Chargement terminé (\(elapsed))",
                       "\(formatted(balance)) pts · \(rewards.count) récompenses"
                       + (pendingClaimId != nil ? " · 🎁 coffre dispo" : ""))

        if rewards.isEmpty {
            logger.info("POINTS", "Aucune récompense", "canal sans custom rewards")
        }
        // Direct quitté pendant le chargement (stopPolling entre-temps) : rien
        // n'est relancé (minuteries orphelines, présence pour la chaîne quittée).
        guard gen == presenceGeneration else { isLoading = false; return }
        // On ne lance le polling et la présence que si le token web est valide.
        if !needsWebLogin {
            startPolling()
            startWatchPresence()
        }
        isLoading = false
        // Coffre déjà là à l'ouverture du direct : les sondages l'ignoraient
        // (il était déjà « en attente ») et il n'était jamais réclamé seul.
        if autoClaim, pendingClaimId != nil {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await claimBonus()
        }
    }

    // MARK: – Polling
    private func startPolling() {
        stopPolling()
        logger.debug("POINTS", "Polling démarré",
                     "balance: \(Int(balancePollInterval))s · claim: \(Int(claimPollInterval))s")
        balanceTimer = Timer.scheduledCommon(every: balancePollInterval) { [weak self] _ in
            Task { await self?.refreshBalance() }
        }
        claimTimer = Timer.scheduledCommon(every: claimPollInterval) { [weak self] _ in
            Task { await self?.checkForBonus() }
        }
    }

    /// Incrémenté à l'arrêt : une mise en route de la présence encore en
    /// cours (requêtes) n'arme pas sa minuterie pour une chaîne quittée.
    private var presenceGeneration = 0

    func stopPolling() {
        presenceGeneration &+= 1
        if balanceTimer != nil || claimTimer != nil || watchTimer != nil {
            logger.debug("POINTS", "Polling arrêté", "canal: \(channelLogin)")
        }
        balanceTimer?.invalidate(); balanceTimer = nil
        claimTimer?.invalidate();   claimTimer   = nil
        watchTimer?.invalidate();   watchTimer   = nil
        PointsTracker.shared.end(channelLogin)
    }

    // MARK: – Refresh balance (60s)
    private func refreshBalance() async {
        // Polling silencieux : on ne logge que les vrais changements (gains/pertes/coffre).
        guard let b = await fetchBalance(quiet: true) else { return }
        let delta = b.balance - balance
        if !balanceKnown {
            // Première lecture réussie (celle de l'ouverture du chat avait
            // échoué) : le solde est posé tel quel. Compté comme un gain, il
            // s'animait en entier (« +250 000 ») et faussait le suivi des points.
            balance = b.balance
        } else if delta > 0 {
            logger.success("POINTS", "Points passifs gagnés",
                           "+\(delta) pts · total: \(formatted(b.balance))")
            PointsTracker.shared.addGain(delta, channelLogin)
            balance = b.balance
            withAnimation { lastBalanceChange = delta }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            withAnimation { lastBalanceChange = 0 }
        } else if delta < 0 {
            logger.warn("POINTS", "Balance diminuée", "\(formatted(balance)) → \(formatted(b.balance))")
            balance = b.balance
        }
        // Plus annoncé par Twitch (réclamé ailleurs, expiré) : plus affiché.
        if b.claimId == nil, pendingClaimId != nil { pendingClaimId = nil }
        if pendingClaimId == nil, let cid = b.claimId, !failedClaims.contains(cid) {
            pendingClaimId = cid
            logger.success("POINTS", "🎁 Coffre détecté", "claimId: \(cid.prefix(8))…")
            if autoClaim { await claimBonus() }
        }
    }

    // MARK: – Check bonus (10s)
    private func checkForBonus() async {
        // Coffre resté affiché après un échec passager : nouvel essai ici
        // (réclamation automatique), au plus 4 en tout pour ce coffre.
        if let pending = pendingClaimId {
            if autoClaim, claimAttempts[pending] != nil { await claimBonus() }
            return
        }
        let query = """
        { channel(name: "\(gqlStr(channelLogin))") {
            self { communityPoints { availableClaim { id } } }
        } }
        """
        guard let json    = try? await gqlAuth(query, tag: "checkBonus", quiet: true) as? [String: Any],
              let data    = json["data"]                                   as? [String: Any],
              let channel = data["channel"]                                as? [String: Any],
              let selfObj = channel["self"]                                as? [String: Any],
              let pts     = selfObj["communityPoints"]                     as? [String: Any],
              let claim   = pts["availableClaim"]                          as? [String: Any],
              let cid     = claim["id"]                                    as? String,
              !failedClaims.contains(cid)
        else {
            return   // pas de coffre : silencieux (évite un log toutes les 30 s)
        }
        pendingClaimId = cid
        logger.success("POINTS", "🎁 Coffre bonus disponible !",
                       "claimId: \(cid.prefix(8))… · canal: \(channelLogin)")
        if autoClaim { await claimBonus() }
    }

    // MARK: – Présence minute-watched
    private static let webUA =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1"

    private func startWatchPresence() {
        let gen = presenceGeneration
        Task {
            // broadcastId + spade en parallèle ; viewerId résolu si absent.
            async let bid   = fetchBroadcastId()
            async let spade = resolveSpadeURL()
            if viewerId.isEmpty { viewerId = (await fetchViewerId()) ?? "" }
            broadcastId = await bid
            spadeURL    = await spade

            guard let bcast = broadcastId, let url = spadeURL, !viewerId.isEmpty, !url.isEmpty else {
                logger.warn("POINTS/WATCH", "Présence désactivée",
                            "broadcast:\(broadcastId != nil) · spade:\(spadeURL != nil) · viewer:\(!viewerId.isEmpty)")
                return
            }
            logger.success("POINTS/WATCH", "Présence active",
                           "minute-watched /\(Int(watchPollInterval))s · broadcast: \(bcast.prefix(8))…")
            guard gen == presenceGeneration else { return }
            PointsTracker.shared.begin(channelLogin)
            await sendMinuteWatched()
            guard gen == presenceGeneration else { return }
            watchTimer?.invalidate()
            watchTimer = Timer.scheduledCommon(every: watchPollInterval) { [weak self] _ in
                Task { await self?.sendMinuteWatched() }
            }
        }
    }

    /// Envoi d'une minute en cours : une minute qui traîne (délais, repli par
    /// le Worker) ne se double pas de la suivante.
    private var sendingMinute = false

    /// Envoie un événement "minute-watched" à l'endpoint analytics Twitch (spade).
    /// C'est ce qui fait que Twitch te crédite des points passifs et génère les coffres.
    /// Adresse coupée sur l'appareil (bloqueur de pubs, DNS filtrant) : la
    /// requête n'aboutissait jamais, aucune minute n'était créditée. Elle
    /// passe alors par le Worker (/api/spade), qui la transmet à Twitch.
    private func sendMinuteWatched() async {
        guard !sendingMinute, let spade = spadeURL, let bcast = broadcastId,
              let uid = Int(viewerId), let url = URL(string: spade) else { return }
        let payload: [[String: Any]] = [[
            "event": "minute-watched",
            "properties": [
                "channel_id":   channelId,
                "broadcast_id": bcast,
                "channel":      channelLogin,
                "user_id":      uid,
                "player":       "site",
                "live":         true
            ]
        ]]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        let login = channelLogin
        sendingMinute = true
        defer { sendingMinute = false }
        // Rien n'est passé (ni en direct, ni par un Worker) : déjà au journal.
        guard let sent = await sendSpade(url, data.base64EncodedString()) else { return }
        logger.debug("POINTS/WATCH", "minute-watched envoyé",
                     "HTTP \(sent.status)" + (sent.relayed ? " · par le Worker" : ""))
        // Minute que Twitch compte pour les points (Réglages → Points de chaîne),
        // qu'elle soit partie en direct ou par le Worker.
        if (200..<300).contains(sent.status) { PointsTracker.shared.addMinute(login) }
    }

    // MARK: – Envoi au spade : en direct, ou par le Worker
    // Commun à toutes les chaînes (multi-live) et gardé pour la séance : un
    // bloqueur coupe l'adresse pour toutes.
    /// Échecs réseau d'affilée de l'envoi direct.
    private static var spadeDirectFailures = 0
    /// Minutes envoyées d'abord par le Worker : deux échecs directs d'affilée,
    /// et un Worker qui répond. L'envoi direct est retenté de temps en temps.
    private static var spadeViaWorker = false
    private static var spadeNextDirectTry = Date.distantPast
    private static let spadeDirectRetry: TimeInterval = 15 * 60
    private static var spadeWorkerNoted = false
    /// Erreurs déjà notées au journal : une fois chacune par séance, plus à
    /// chaque minute.
    private static var spadeLogged: Set<String> = []
    /// Workers mis de côté : route absente (Worker d'avant), trop d'envois.
    private static var spadeWorkerSkip: [String: Date] = [:]

    /// Code HTTP de Twitch, et si la minute est passée par le Worker ; nil si
    /// elle n'a pu partir ni en direct, ni par un Worker.
    private func sendSpade(_ url: URL, _ b64: String) async -> (status: Int, relayed: Bool)? {
        let directFirst = !Self.spadeViaWorker || Date() >= Self.spadeNextDirectTry
        if !directFirst, let code = await relaySpade(url, b64) { return (code, true) }
        do {
            let code = try await directSpade(url, b64)
            Self.spadeDirectFailures = 0
            if Self.spadeViaWorker {
                Self.spadeViaWorker = false
                logger.info("POINTS/WATCH", "Envoi direct rétabli", url.host ?? "")
            }
            return (code, false)
        } catch {
            Self.spadeDirectFailures += 1
            if Self.spadeViaWorker { Self.spadeNextDirectTry = Date().addingTimeInterval(Self.spadeDirectRetry) }
            let urlCode = (error as? URLError).map { " (URLError \($0.code.rawValue))" } ?? ""
            noteSpadeOnce("direct" + urlCode + error.localizedDescription, "minute-watched échoué",
                          error.localizedDescription + urlCode + " · hôte: \(url.host ?? "?")")
            // Le Worker vient déjà d'échouer pour cette minute.
            guard directFirst, let code = await relaySpade(url, b64) else { return nil }
            if Self.spadeDirectFailures >= 2, !Self.spadeViaWorker {
                Self.spadeViaWorker = true
                Self.spadeNextDirectTry = Date().addingTimeInterval(Self.spadeDirectRetry)
                if !Self.spadeWorkerNoted {
                    Self.spadeWorkerNoted = true
                    logger.info("POINTS/WATCH", "Minutes envoyées par le Worker",
                                "envoi direct impossible · nouvel essai direct toutes les 15 min")
                }
            }
            return (code, true)
        }
    }

    /// Envoi direct au spade (data= en base64, encodé pour l'adresse). Lève
    /// l'erreur réseau ; une réponse de Twitch, même refusée, rend son code.
    private func directSpade(_ url: URL, _ b64: String) async throws -> Int {
        let safe = b64.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? b64
        // 15 s au plus (au lieu de 60) : une minute par envoi au plus, repli compris.
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.webUA, forHTTPHeaderField: "User-Agent")
        req.httpBody = "data=\(safe)".data(using: .utf8)
        let (_, resp) = try await URLSession.shared.data(for: req)
        return (resp as? HTTPURLResponse)?.statusCode ?? 0
    }

    /// Envoi par le Worker (POST /api/spade { url, data }), dans l'ordre de la
    /// lecture : Worker personnel, principal, secours. Code HTTP de Twitch ;
    /// nil si aucun Worker n'a pu le transmettre.
    private func relaySpade(_ spade: URL, _ b64: String) async -> Int? {
        guard let body = try? JSONSerialization.data(withJSONObject: ["url": spade.absoluteString, "data": b64])
        else { return nil }
        for base in APIConfig.lookupBases where (Self.spadeWorkerSkip[base] ?? .distantPast) <= Date() {
            guard let url = URL(string: base + "/api/spade") else { continue }
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
            let data: Data, code: Int
            do {
                let (d, resp) = try await URLSession.shared.data(for: req)
                data = d
                code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            } catch {
                let urlCode = (error as? URLError).map { " (URLError \($0.code.rawValue))" } ?? ""
                noteSpadeOnce("worker " + base + urlCode, "Relais du Worker injoignable",
                              "\(base) — " + error.localizedDescription + urlCode)
                continue
            }
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            if code == 200, json?["ok"] as? Bool == true, let status = (json?["status"] as? NSNumber)?.intValue {
                return status
            }
            noteSpadeOnce("worker \(base) \(code)", "Relais du Worker refusé",
                          "HTTP \(code) · \(base)" + ((json?["error"] as? String).map { " · \($0)" } ?? ""))
            switch code {
            // Adresse ou données refusées : un autre Worker dirait pareil.
            case 400: return nil
            // Route absente : Worker d'avant (personnel pas à jour).
            case 404: Self.spadeWorkerSkip[base] = .distantFuture
            // Trop d'envois, ou quota du jour : le suivant, et celui-ci plus tard.
            case 429: Self.spadeWorkerSkip[base] = Date().addingTimeInterval(10 * 60)
            // Twitch injoignable depuis ce Worker, panne : le suivant.
            default: break
            }
        }
        return nil
    }

    /// Note au journal une fois par erreur distincte et par séance.
    private func noteSpadeOnce(_ key: String, _ message: String, _ detail: String) {
        guard Self.spadeLogged.insert(key).inserted else { return }
        logger.warn("POINTS/WATCH", message, detail)
    }

    /// Récupère l'ID du viewer connecté via le token web.
    private func fetchViewerId() async -> String? {
        guard let json = try? await gqlAuth("{ currentUser { id } }", tag: "viewerId") as? [String: Any],
              let data = json["data"]        as? [String: Any],
              let user = data["currentUser"] as? [String: Any],
              let id   = user["id"]          as? String else { return nil }
        return id
    }

    /// Récupère le broadcast_id du live en cours (nil si hors-ligne).
    private func fetchBroadcastId() async -> String? {
        let q = "{ user(login: \"\(gqlStr(channelLogin))\") { stream { id } } }"
        guard let json   = try? await gqlPublic(q, tag: "broadcastId") as? [String: Any],
              let data   = json["data"]   as? [String: Any],
              let user   = data["user"]   as? [String: Any],
              let stream = user["stream"] as? [String: Any],
              let id     = stream["id"]   as? String else { return nil }
        return id
    }

    /// Découvre l'URL "spade" (endpoint analytics) depuis la page du streamer.
    private func resolveSpadeURL() async -> String? {
        func body(_ urlStr: String) async -> String? {
            guard let u = URL(string: urlStr) else { return nil }
            var req = URLRequest(url: u)
            req.setValue(Self.webUA, forHTTPHeaderField: "User-Agent")
            guard let (d, _) = try? await URLSession.shared.data(for: req) else { return nil }
            return String(data: d, encoding: .utf8)
        }
        func match(_ s: String, _ pattern: String) -> String? {
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m  = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
                  m.numberOfRanges > 1,
                  let r  = Range(m.range(at: 1), in: s) else { return nil }
            return String(s[r]).replacingOccurrences(of: "\\/", with: "/")
        }
        guard let html = await body("https://www.twitch.tv/\(channelLogin)") else { return nil }
        // 1. spade_url parfois directement dans la page
        if let direct = match(html, #""spade_url"\s*:\s*"(https:[^"]+)""#) { return direct }
        // 2. sinon via le fichier settings.<hash>.js
        guard let settingsURL = match(html, #"(https://[^"']+?/config/settings\.[A-Za-z0-9]+\.js)"#),
              let js = await body(settingsURL) else { return nil }
        return match(js, #""spade_url"\s*:\s*"(https:[^"]+)""#)
    }

    // MARK: – Claim bonus
    // Hash de la persisted query `ClaimCommunityPoints` (capturé sur le client web).
    private static let claimQueryHash = "46aaeebe02c99afdf4fc97c7c0cba964124bf6b0af229395f1f6d1feed05b3d0"

    /// Une seule à la fois (minuteries et bouton pouvaient réclamer le même
    /// coffre en parallèle). Rend true si Twitch l'a accordé.
    @discardableResult
    func claimBonus() async -> Bool {
        guard !isClaiming, let claimId = pendingClaimId else { return false }
        isClaiming = true
        defer { isClaiming = false }
        logger.info("POINTS", "Réclamation du coffre…", "claimId: \(claimId.prefix(8))…")
        // Claim en NATIF avec le token integrity (persisted query identique au client web).
        let body: [[String: Any]] = [[
            "operationName": "ClaimCommunityPoints",
            "variables":     ["input": ["channelID": channelId, "claimID": claimId]],
            "extensions":    ["persistedQuery": ["version": 1, "sha256Hash": Self.claimQueryHash]]
        ]]
        guard let json  = await nativeMutation(body: body, tag: "claimBonus"),
              let data  = json["data"]                  as? [String: Any],
              let claim = data["claimCommunityPoints"]  as? [String: Any]
        else {
            // Échec passager (jeton, réseau, réponse inattendue) : le coffre
            // reste affiché et réclamable ; il était perdu pour la séance au
            // premier raté. Abandon au 4e essai.
            let n = (claimAttempts[claimId] ?? 0) + 1
            claimAttempts[claimId] = n
            logger.error("POINTS", "Claim coffre échoué", "essai \(n)/4")
            if n >= 4 { failedClaims.insert(claimId); pendingClaimId = nil }
            return false
        }

        if let err = claim["error"] as? [String: Any], let code = err["code"] as? String {
            logger.error("POINTS", "Claim refusé", "code: \(code)")
            failedClaims.insert(claimId); pendingClaimId = nil; return false
        }
        // Pas d'erreur → succès. Le selection-set de la persisted query ne renvoie pas
        // toujours `currentPoints` : on nettoie le coffre et on rafraîchit le solde.
        pendingClaimId = nil
        PointsTracker.shared.addChest(channelLogin)
        if let pts = claim["currentPoints"] as? Int, !balanceKnown {
            // Solde encore inconnu (lecture ratée à l'ouverture) : posé tel
            // quel, sans le compter comme gain du coffre.
            logger.success("POINTS", "🎉 Coffre réclamé !", "total: \(formatted(pts))")
            balance = pts
        } else if let pts = claim["currentPoints"] as? Int {
            let gained = pts - balance
            logger.success("POINTS", "🎉 Coffre réclamé !", "+\(gained) pts · total: \(formatted(pts))")
            PointsTracker.shared.addGain(gained, channelLogin)
            balance = pts
            withAnimation { lastBalanceChange = gained }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            withAnimation { lastBalanceChange = 0 }
        } else {
            logger.success("POINTS", "🎉 Coffre réclamé !", "rafraîchissement du solde…")
            await refreshBalance()
        }
        return true
    }

    // MARK: – Redeem
    @discardableResult
    func redeem(reward: ChannelReward, userInput: String? = nil) async -> Bool {
        logger.info("POINTS", "Tentative rachat « \(reward.title) »",
                    "coût: \(formatted(reward.cost)) · balance: \(formatted(balance))")
        // Solde inconnu : on le dit, plutôt que « il manque N points ».
        guard balanceKnown else {
            errorMsg = t(needsWebLogin ? "points_connect_title" : "points_network_error"); return false
        }
        guard balance >= reward.cost else {
            let missing = reward.cost - balance
            logger.warn("POINTS", "Solde insuffisant", "manque \(formatted(missing)) pts")
            errorMsg = "\(t("points_missing")) \(formatted(missing)) \(translatePlural("points_unit", missing, lang))"; return false
        }
        // Le vrai champ GQL Twitch est `redeemCommunityPointsCustomReward`.
        // ⚠️ Anti-triche `PROPERTIES_MISMATCH` : cost + title + prompt doivent
        // correspondre EXACTEMENT à la config serveur de la récompense.
        //   - reward SANS saisie → prompt = celui de la récompense (null si vide)
        //   - reward AVEC saisie requise → prompt = texte saisi par le viewer
        /// Chaîne GraphQL exacte, guillemets compris (mêmes échappements que
        /// JSON : retours à la ligne, tabulations…). Une invite sur deux lignes
        /// devenait une seule : refusée (PROPERTIES_MISMATCH) à chaque rachat.
        func gqlLiteral(_ s: String) -> String {
            (try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        }
        let txId      = UUID().uuidString
        let promptText = reward.isUserInputRequired ? (userInput ?? "") : (reward.prompt ?? "")
        let promptField = promptText.isEmpty ? "prompt: null" : "prompt: \(gqlLiteral(promptText))"
        let mutation = """
        mutation { redeemCommunityPointsCustomReward(input: {
            channelID: "\(gqlStr(channelId))", cost: \(reward.cost), \(promptField),
            rewardID: "\(gqlStr(reward.id))", title: \(gqlLiteral(reward.title)), transactionID: "\(txId)"
        }) { redemption { id } error { code } } }
        """
        // Rachat en NATIF avec le token integrity.
        guard let json   = await nativeMutation(body: ["query": mutation], tag: "redeem"),
              let data   = json["data"]                              as? [String: Any],
              let result = data["redeemCommunityPointsCustomReward"] as? [String: Any]
        else { logger.error("POINTS", "Rachat réseau échoué", nil); errorMsg = t("points_network_error"); return false }

        if let err = result["error"] as? [String: Any], let code = err["code"] as? String {
            logger.warn("POINTS", "Rachat refusé", "\(code)")
            errorMsg = redeemErrorLabel(code); return false
        }
        let newBalance = max(0, balance - reward.cost)
        logger.success("POINTS", "✅ Rachat confirmé !",
                       "« \(reward.title) » · reste: \(formatted(newBalance)) pts")
        balance = newBalance; errorMsg = nil
        return true
    }

    // MARK: – Fetch rewards (SANS auth — données publiques)
    private func fetchRewards() async -> [ChannelReward] {
        logger.debug("POINTS", "fetchRewards → channel(name:\(channelLogin))", nil)
        let query = """
        { channel(name: "\(gqlStr(channelLogin))") {
            communityPointsSettings {
                isEnabled
                customRewards {
                    id title cost isEnabled isPaused isInStock
                    isUserInputRequired prompt backgroundColor
                    image { url2x } defaultImage { url2x }
                }
            }
        } }
        """
        // ✅ Pas d'Authorization ici — données publiques, pas de 401 possible
        guard let json     = try? await gqlPublic(query, tag: "fetchRewards") as? [String: Any],
              let data     = json["data"]                                      as? [String: Any],
              let channel  = data["channel"]                                   as? [String: Any],
              let settings = channel["communityPointsSettings"]                as? [String: Any]
        else { logger.warn("POINTS", "fetchRewards : parsing échoué", nil); return [] }

        guard settings["isEnabled"] as? Bool == true else {
            logger.info("POINTS", "Points désactivés", nil); return []
        }
        guard let raw = settings["customRewards"] as? [[String: Any]] else {
            logger.info("POINTS", "Aucune custom reward", nil); return []
        }
        let parsed: [ChannelReward] = raw.compactMap { r in
            guard let id    = r["id"]    as? String,
                  let title = r["title"] as? String,
                  let cost  = r["cost"]  as? Int else { return nil }
            return ChannelReward(
                id: id, title: title, cost: cost,
                isEnabled:           r["isEnabled"]           as? Bool ?? false,
                isInStock:           r["isInStock"]           as? Bool ?? true,
                isPaused:            r["isPaused"]            as? Bool ?? false,
                isUserInputRequired: r["isUserInputRequired"] as? Bool ?? false,
                prompt:              r["prompt"]              as? String,
                backgroundColor:    (r["backgroundColor"]    as? String ?? "9147FF")
                                        .trimmingCharacters(in: CharacterSet(charactersIn: "#")),
                imageURL: (r["image"]        as? [String: Any])?["url2x"] as? String
                       ?? (r["defaultImage"] as? [String: Any])?["url2x"] as? String
            )
        }.filter { $0.isEnabled }
        logger.debug("POINTS", "Récompenses parsées",
                     "\(parsed.count) actives · \(parsed.filter { $0.isPaused }.count) en pause")
        return parsed
    }

    // MARK: – Fetch balance (AVEC auth OAuth)
    /// nil : Twitch n'a pas répondu (réseau, jeton) — l'appelant garde le solde
    /// affiché. Un échec rendait 0 : le solde tombait à 0, puis le sondage
    /// suivant affichait « +12000 » (tout le solde) comme un gain.
    private func fetchBalance(quiet: Bool = false) async -> (balance: Int, claimId: String?)? {
        if !quiet { logger.debug("POINTS", "fetchBalance → channel(name:\(channelLogin)).self", nil) }
        let query = """
        { channel(name: "\(gqlStr(channelLogin))") {
            self { communityPoints { balance availableClaim { id } } }
        } }
        """
        guard let json    = try? await gqlAuth(query, tag: "fetchBalance", quiet: quiet) as? [String: Any],
              let data    = json["data"]                                    as? [String: Any],
              let channel = data["channel"]                                 as? [String: Any],
              let selfObj = channel["self"]                                 as? [String: Any]
        else {
            logger.warn("POINTS", "fetchBalance : parsing échoué", nil)
            return nil
        }
        guard let pts = selfObj["communityPoints"] as? [String: Any] else {
            logger.info("POINTS", "communityPoints null — premier visionnage ou token incompatible",
                        "balance = 0")
            return (0, nil)
        }
        let bal     = pts["balance"] as? Int ?? 0
        let claimId = (pts["availableClaim"] as? [String: Any])?["id"] as? String
        if !quiet {
            logger.success("POINTS", "Balance récupérée",
                           "\(formatted(bal)) pts · claim: \(claimId != nil ? "🎁 OUI" : "non")")
        }
        return (bal, claimId)
    }

    // MARK: – GQL public (sans Authorization — pour les données publiques)
    private func gqlPublic(_ query: String, tag: String) async throws -> Any {
        return try await makeGQLRequest(query, tag: tag, withAuth: false)
    }

    // MARK: – GQL authentifié (Authorization: OAuth <token web> — données privées)
    // ✅ Token de session web (cookie auth-token) → communityPoints renvoyé correctement
    // ❌ Token OAuth custom (Helix) → communityPoints null (Client-ID incompatible avec GQL)
    private func gqlAuth(_ query: String, tag: String, quiet: Bool = false) async throws -> Any {
        return try await makeGQLRequest(query, tag: tag, withAuth: true, quiet: quiet)
    }

    private func makeGQLRequest(_ query: String, tag: String,
                                 withAuth: Bool, quiet: Bool = false) async throws -> Any {
        if !quiet { logger.debug("POINTS/GQL", "→ \(tag)", withAuth ? "OAuth" : "public") }
        guard let url = URL(string: "https://gql.twitch.tv/gql") else { throw URLError(.badURL) }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(kGQLClientID,       forHTTPHeaderField: "Client-ID")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(deviceId,           forHTTPHeaderField: "X-Device-Id")
        req.setValue(Self.webUA,         forHTTPHeaderField: "User-Agent")
        if withAuth {
            req.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: ["query": query])

        let start = Date()
        let (data, resp) = try await URLSession.shared.data(for: req)
        let ms     = String(format: "%.0f ms", Date().timeIntervalSince(start) * 1000)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0

        guard status == 200 else {
            if status == 401 && withAuth {
                logger.warn("POINTS/GQL", "401 — token web expiré ou invalide",
                            "tag: \(tag) · token: \(String(token.prefix(8)))… · \(ms)")
                stopPolling()
                needsWebLogin = true   // affiche le bouton de re-login dans la sheet points
            } else {
                logger.error("POINTS/GQL", "HTTP \(status) — \(tag)", ms)
            }
            throw URLError(.userAuthenticationRequired)
        }

        if let json   = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let errors = json["errors"] as? [[String: Any]], !errors.isEmpty {
            let msgs = errors.compactMap { $0["message"] as? String }.joined(separator: " · ")
            logger.warn("POINTS/GQL", "Erreurs GQL dans \(tag)", msgs + " (\(ms))")
        } else if !quiet {
            logger.debug("POINTS/GQL", "← \(tag) OK", ms)
        }

        return try JSONSerialization.jsonObject(with: data)
    }

    // MARK: – Mutations integrity (claim / redeem) — token minté via WebView, requête native
    /// Garantit un token Client-Integrity valide (le génère via WebView éphémère si besoin).
    private func validIntegrity() async -> Bool {
        // Lié au jeton web : après un changement de compte, celui de l'ancien
        // compte faisait échouer le premier coffre ou rachat.
        if let _ = integrityTok, integrityFor == token, integrityExpiry > Date().addingTimeInterval(60),
           !integrityDevice.isEmpty {
            return true
        }
        logger.info("POINTS", "Renouvellement du token integrity…", "WebView éphémère ~quelques s")
        guard let mint = await TwitchWebGQL.shared.mintIntegrity(token: token) else {
            logger.warn("POINTS", "Token integrity indisponible", "claim/redeem impossible pour l'instant")
            return false
        }
        integrityTok    = mint.token
        integrityDevice = mint.deviceId.isEmpty ? deviceId : mint.deviceId
        integrityExpiry = mint.expiry
        integrityFor    = token
        return true
    }

    /// Exécute une mutation EN NATIF avec le token Client-Integrity (pas de WebView).
    /// `body` = l'objet JSON GQL (persisted query en tableau, ou {query: ...}).
    /// Jeton refusé : régénéré et requête renvoyée une fois (même transaction).
    private func nativeMutation(body: Any, tag: String, retried: Bool = false) async -> [String: Any]? {
        guard await validIntegrity(), let it = integrityTok else { return nil }
        guard let url = URL(string: "https://gql.twitch.tv/gql") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(kGQLClientID,                forHTTPHeaderField: "Client-ID")
        req.setValue("OAuth \(token)",            forHTTPHeaderField: "Authorization")
        req.setValue(integrityDevice,             forHTTPHeaderField: "X-Device-Id")
        req.setValue(it,                          forHTTPHeaderField: "Client-Integrity")
        req.setValue(Self.webUA,                  forHTTPHeaderField: "User-Agent")
        req.setValue("text/plain;charset=UTF-8",  forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        logger.debug("POINTS/GQL", "→ \(tag) (natif + integrity)", nil)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) else {
            logger.warn("POINTS/GQL", "\(tag) : requête échouée", nil)
            return nil
        }
        // Réponse : objet pour {query}, tableau pour persisted query.
        let json = (obj as? [[String: Any]])?.first ?? (obj as? [String: Any])
        if let errors = json?["errors"] as? [[String: Any]], !errors.isEmpty {
            let msgs = errors.compactMap { $0["message"] as? String }.joined(separator: " · ")
            logger.warn("POINTS/GQL", "Erreurs GQL dans \(tag)", msgs)
            // Token integrity probablement expiré → on l'invalide pour re-mint au prochain coup.
            if msgs.lowercased().contains("integrity") {
                integrityTok = nil; integrityExpiry = .distantPast
                if !retried { return await nativeMutation(body: body, tag: tag, retried: true) }
            }
        } else {
            logger.debug("POINTS/GQL", "← \(tag) OK (natif)", nil)
        }
        return json
    }

    // MARK: – Helpers
    func formatted(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal; f.groupingSeparator = " "
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    /// Traduction côté service (pas de View) : lit la langue depuis UserDefaults.
    private var lang: Lang {
        Lang(rawValue: UserDefaults.standard.string(forKey: "lang") ?? "en") ?? .en
    }
    func t(_ key: String) -> String { translate(key, lang) }

    private func redeemErrorLabel(_ code: String) -> String {
        switch code.uppercased() {
        case "NOT_ENOUGH_POINTS":        return t("err_not_enough")
        case "REWARD_NOT_FOUND", "NOT_FOUND": return t("err_reward_not_found")
        case "CHANNEL_POINTS_DISABLED", "DISABLED": return t("err_points_disabled")
        case "REWARD_NOT_IN_STOCK", "OUT_OF_STOCK": return t("points_out_of_stock")
        case "ALREADY_CLAIMED":          return t("err_already_claimed")
        case "ON_COOLDOWN", "GLOBAL_COOLDOWN": return t("err_cooldown")
        case "PROPERTIES_MISMATCH":      return t("err_properties_mismatch")
        case "STREAM_NOT_LIVE":          return t("err_stream_offline")
        default:                          return "\(t("points_error")) : \(code)"
        }
    }
}
