import Foundation
import SwiftUI

// MARK: – Raid sortant (Hermes, topic raid.<channelID>)
// Détecte quand la chaîne regardée lance un raid vers une autre chaîne :
// bannière pendant le décompte, puis auto-bascule quand le raid part (raid_go).
//
// Hermes (wss://hermes.twitch.tv) remplace l'ancien PubSub côté site Twitch :
// même contenu, anonyme, avec keepalive. La connexion se relance seule si
// elle tombe (avant : plus aucun raid détecté jusqu'au prochain live).
@MainActor
final class RaidService: ObservableObject {
    struct RaidInfo { let id: String; let targetLogin: String; let targetName: String; let viewers: Int }

    @Published var raid: RaidInfo? = nil     // raid en préparation (bannière)
    @Published var joinTarget: String? = nil // login à rejoindre (raid parti)

    private var ws: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .default)
    private var watchdog: Timer?
    private var reconnectTask: Task<Void, Never>?
    private var channelId = ""
    private var token = ""
    private var subscriptionId = ""
    private var lastSeen = Date()
    private var keepalive: TimeInterval = 15
    private var retryDelay: Double = 2
    private static let endpoint = "wss://hermes.twitch.tv/v1?clientId=\(kGQLClientID)"

    func connect(channelId: String, token: String = "") {
        disconnect()
        guard !channelId.isEmpty else { return }
        self.channelId = channelId; self.token = token
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
}
