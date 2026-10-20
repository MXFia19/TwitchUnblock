import Foundation
import SwiftUI

// MARK: – Raid sortant (Hermes, topic raid.<channelID>)
// Détecte quand la chaîne regardée lance un raid vers une autre chaîne :
// bannière pendant le décompte, puis auto-bascule quand le raid part (raid_go).
// Lecteur principal avec session web : le raid annoncé est aussi rejoint
// (JoinRaid), pour le bonus de points comme sur twitch.tv.
//
// Hermes (wss://hermes.twitch.tv) remplace l'ancien PubSub côté site Twitch :
// même contenu, anonyme, avec keepalive. La connexion se relance seule si
// elle tombe (avant : plus aucun raid détecté jusqu'au prochain live).
@MainActor
final class RaidService: ObservableObject {
    struct RaidInfo { let id: String; let targetLogin: String; let targetName: String; let viewers: Int }

    @Published var raid: RaidInfo? = nil     // raid en préparation (bannière)
    private var expiry: Task<Void, Never>?
    @Published var joinTarget: String? = nil // login à rejoindre (raid parti)
    /// Raid rejoint avec la session web (JoinRaid accepté) : le bandeau
    /// annonce le bonus de points.
    @Published private(set) var bonusRaidID: String? = nil

    private var ws: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .default)
    private var watchdog: Timer?
    private var reconnectTask: Task<Void, Never>?
    private var channelId = ""
    private var token = ""   // session web (cookie auth-token), pour JoinRaid
    /// Lecteur principal (le raid y est suivi) : le raid annoncé est rejoint.
    /// Faux en multi-live.
    private var joinsRaids = false
    /// Raids déjà vus : un seul JoinRaid par raid, même si l'annonce revient
    /// (mise à jour, reconnexion).
    private var seenRaidIDs: Set<String> = []
    private var subscriptionId = ""
    private var lastSeen = Date()
    private var keepalive: TimeInterval = 15
    private var retryDelay: Double = 2
    private static let endpoint = "wss://hermes.twitch.tv/v1?clientId=\(kGQLClientID)"

    func connect(channelId: String, token: String = "", joinsRaids: Bool = false) {
        disconnect()
        guard !channelId.isEmpty else { return }
        self.channelId = channelId; self.token = token; self.joinsRaids = joinsRaids
        open(Self.endpoint)
        logger.debug("RAID", "Écoute des raids", "canal \(channelId)")
    }

    private func open(_ address: String) {
        ws?.cancel(with: .normalClosure, reason: nil)
        guard let url = URL(string: address) else { return }
        let socket = session.webSocketTask(with: url)
        ws = socket
        socket.resume()
        lastSeen = Date()
        Task { await receive(socket) }
        // Sans keepalive dans le délai prévu, la connexion est morte.
        watchdog?.invalidate()
        watchdog = Timer.scheduledCommon(every: 5) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.ws != nil else { return }
                if Date().timeIntervalSince(self.lastSeen) > self.keepalive * 2 + 5 { self.scheduleReconnect() }
            }
        }
    }

    func disconnect() {
        watchdog?.invalidate(); watchdog = nil
        reconnectTask?.cancel(); reconnectTask = nil
        ws?.cancel(with: .normalClosure, reason: nil); ws = nil
        raid = nil; joinTarget = nil
        expiry?.cancel(); expiry = nil
        retryDelay = 2
    }

    private func scheduleReconnect() {
        guard !channelId.isEmpty else { return }
        ws?.cancel(with: .normalClosure, reason: nil); ws = nil
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 60)
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, !self.channelId.isEmpty else { return }
            logger.debug("RAID", "Reconnexion Hermes", nil)
            self.open(Self.endpoint)
        }
    }

    // MARK: I/O
    private func sendJSON(_ obj: [String: Any]) async {
        guard let ws,
              let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return }
        try? await ws.send(.string(s))
    }

    private func receive(_ socket: URLSessionWebSocketTask) async {
        while self.ws === socket {   // s'arrête si le socket a été remplacé
            do {
                let msg = try await socket.receive()
                guard self.ws === socket else { return }
                switch msg {
                case .string(let t): await handleEnvelope(t)
                case .data(let d): if let t = String(data: d, encoding: .utf8) { await handleEnvelope(t) }
                @unknown default: break
                }
            } catch {
                guard self.ws === socket else { return }
                logger.warn("RAID", "Connexion perdue", error.localizedDescription)
                scheduleReconnect()
                return
            }
        }
    }

    /// Enveloppe Hermes : welcome → abonnement ; notification → message PubSub.
    private func handleEnvelope(_ text: String) async {
        lastSeen = Date()
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }
        switch type {
        case "welcome":
            retryDelay = 2
            if let k = (json["welcome"] as? [String: Any])?["keepaliveSec"] as? Double { keepalive = k }
            subscriptionId = UUID().uuidString
            await sendJSON([
                "type": "subscribe", "id": UUID().uuidString,
                "subscribe": ["id": subscriptionId, "type": "pubsub",
                              "pubsub": ["topic": "raid.\(channelId)"]],
                "timestamp": ISO8601DateFormatter().string(from: Date())
            ])
        case "subscribeResponse":
            let result = (json["subscribeResponse"] as? [String: Any])?["result"] as? String ?? "?"
            logger.debug("RAID", "Abonnement Hermes", result)
        case "notification":
            guard let n = json["notification"] as? [String: Any],
                  let inner = n["pubsub"] as? String else { return }
            handle(inner)
        case "reconnect":
            if let url = (json["reconnect"] as? [String: Any])?["url"] as? String { open(url) }
        default:
            break
        }
    }

    // MARK: Parsing
    private func handle(_ inner: String) {
        guard let innerD  = inner.data(using: .utf8),
              let innerJ  = try? JSONSerialization.jsonObject(with: innerD) as? [String: Any],
              let mtype   = innerJ["type"] as? String else { return }

        // Dump brut : à copier au premier vrai raid pour confirmer la structure.
        logger.debug("RAID", "Payload \(mtype)", inner)

        let r = innerJ["raid"] as? [String: Any]
        switch mtype {
        case "raid_update_v2", "raid_update":
            if let r = r, let login = r["target_login"] as? String {
                raid = RaidInfo(
                    id: (r["id"] as? String) ?? "",
                    targetLogin: login,
                    targetName: (r["target_display_name"] as? String) ?? login,
                    viewers: (r["viewer_count"] as? Int) ?? 0)
                logger.success("RAID", "🚀 Raid en préparation", "→ \(login) (\(raid?.viewers ?? 0) spect.)")
                // Un raid part en 90 s au plus : sans nouvelles 3 min plus tard
                // (message perdu), le bandeau restait affiché pour de bon.
                let id = raid?.id
                expiry?.cancel()
                expiry = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 180_000_000_000)
                    guard let self, !Task.isCancelled, self.raid?.id == id else { return }
                    self.raid = nil
                }
                // Comme « Rejoindre » sur twitch.tv : sans JoinRaid, le raid
                // était suivi mais son bonus de points perdu.
                if let raidID = id, !raidID.isEmpty { joinRaid(raidID, target: login) }
            }
        case "raid_go_v2", "raid_go":
            let login = (r?["target_login"] as? String) ?? raid?.targetLogin
            if let login = login {
                logger.success("RAID", "🚀 Raid parti → auto-rejoint", login)
                joinTarget = login
            }
        case "raid_cancel_v2", "raid_cancel":
            logger.warn("RAID", "Raid annulé", nil)
            raid = nil
        default:
            logger.debug("RAID", "Type inattendu: \(mtype)", nil)
        }
    }

    // MARK: Bonus de raid (JoinRaid)
    // Requête enregistrée de twitch.tv, reprise de TwitchChannelPointsMiner
    // (non vérifiée) ; requête écrite si Twitch ne la connaît pas.
    private static let joinRaidHash = "c6a332a86d1087fbbb1a8623aa01bd1313d2386e7c63be60fdb2d1901f01a4ae"
    private static let joinRaidQuery = "mutation JoinRaid($input: JoinRaidInput!) { joinRaid(input: $input) { raidID } }"

    /// Rejoint le raid annoncé au nom de la session web, une fois par raid.
    /// Mutation protégée comme le coffre (jeton d'intégrité gardé, régénéré
    /// s'il est refusé, un seul nouvel essai : TwitchGQL), lancée à part :
    /// la bascule (raid_go) ne l'attend jamais, un échec ne la bloque pas.
    private func joinRaid(_ raidID: String, target: String) {
        guard joinsRaids, seenRaidIDs.insert(raidID).inserted else { return }
        guard !token.isEmpty else {
            logger.info("RAID", "Raid pas rejoint", "pas de session web, pas de bonus")
            return
        }
        let webToken = token
        Task { [weak self] in
            let vars: [String: Any] = ["input": ["raidID": raidID]]
            var res = await TwitchGQL.shared.mutation("JoinRaid", variables: vars,
                                                      sha256: Self.joinRaidHash, token: webToken)
            // Hash périmé ou faux : même mutation, écrite en toutes lettres.
            let unknown = ((res?["errors"] as? [[String: Any]]) ?? []).contains {
                ($0["message"] as? String)?.contains("PersistedQueryNotFound") == true
            }
            if unknown {
                logger.info("RAID", "JoinRaid inconnu de Twitch", "nouvel essai en requête écrite")
                res = await TwitchGQL.shared.rawMutation("JoinRaid", query: Self.joinRaidQuery,
                                                         variables: vars, token: webToken)
            }
            guard let json = res else {
                logger.warn("RAID", "Pas de réponse de Twitch", "réseau ou jeton d'intégrité")
                return
            }
            // Accepté : `joinRaid` est un objet, sans `error` ni erreur GQL.
            let payload = (json["data"] as? [String: Any])?["joinRaid"] as? [String: Any]
            let refusal = (payload?["error"] as? [String: Any])?["code"] as? String
            let errors = ((json["errors"] as? [[String: Any]]) ?? []).compactMap { $0["message"] as? String }
            guard payload != nil, refusal == nil, errors.isEmpty else {
                let code = refusal ?? (errors.isEmpty ? "?" : errors.joined(separator: " · "))
                logger.warn("RAID", "Raid pas rejoint", "code: \(code)")
                return
            }
            logger.success("RAID", "🎁 Raid rejoint", "bonus de points → \(target)")
            self?.bonusRaidID = raidID
        }
    }
}
