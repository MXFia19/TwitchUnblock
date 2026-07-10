import Foundation
import SwiftUI

// MARK: – Raid sortant (PubSub raid.<channelID>)
// Détecte quand la chaîne regardée lance un raid vers une autre chaîne :
// bannière pendant le décompte, puis auto-bascule quand le raid part (raid_go).
@MainActor
final class RaidService: ObservableObject {
    struct RaidInfo { let targetLogin: String; let targetName: String; let viewers: Int }

    @Published var raid: RaidInfo? = nil     // raid en préparation (bannière)
    @Published var joinTarget: String? = nil // login à rejoindre (raid parti)

    private var ws: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .default)
    private var pingTimer: Timer?
    private var channelId = ""
    private var token = ""

    func connect(channelId: String, token: String = "") {
        disconnect()
        guard !channelId.isEmpty,
              let url = URL(string: "wss://pubsub-edge.twitch.tv/v1") else { return }
        self.channelId = channelId; self.token = token
        ws = session.webSocketTask(with: url); ws?.resume()
        logger.debug("RAID", "Écoute des raids", "canal \(channelId)")
        Task {
            var data: [String: Any] = ["topics": ["raid.\(channelId)"]]
            if !token.isEmpty { data["auth_token"] = token }
            await sendJSON(["type": "LISTEN", "nonce": UUID().uuidString, "data": data])
            await receive()
        }
        pingTimer = Timer.scheduledTimer(withTimeInterval: 240, repeats: true) { [weak self] _ in
            Task { await self?.sendJSON(["type": "PING"]) }
        }
    }

    func disconnect() {
        pingTimer?.invalidate(); pingTimer = nil
        ws?.cancel(with: .normalClosure, reason: nil); ws = nil
        raid = nil; joinTarget = nil
    }

    // MARK: I/O
    private func sendJSON(_ obj: [String: Any]) async {
        guard let ws,
              let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return }
        try? await ws.send(.string(s))
    }

    private func receive() async {
        let socket = ws
        while let ws = socket, self.ws === ws {   // s'arrête si le socket a été remplacé (RECONNECT)
            do {
                let msg = try await ws.receive()
                switch msg {
                case .string(let t): handle(t)
                case .data(let d): if let t = String(data: d, encoding: .utf8) { handle(t) }
                @unknown default: break
                }
            } catch {
                logger.warn("RAID", "Connexion perdue", error.localizedDescription)
                return
            }
        }
    }

    // MARK: Parsing
    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        if type == "RECONNECT" { connect(channelId: channelId, token: token); return }
        guard type == "MESSAGE",
              let dataObj = json["data"]      as? [String: Any],
              let inner   = dataObj["message"] as? String,
              let innerD  = inner.data(using: .utf8),
              let innerJ  = try? JSONSerialization.jsonObject(with: innerD) as? [String: Any],
              let mtype   = innerJ["type"]    as? String else { return }

        let r = innerJ["raid"] as? [String: Any]
        switch mtype {
        case "raid_update_v2", "raid_update":
            if let r = r, let login = r["target_login"] as? String {
                raid = RaidInfo(
                    targetLogin: login,
                    targetName: (r["target_display_name"] as? String) ?? login,
                    viewers: (r["viewer_count"] as? Int) ?? 0)
                logger.success("RAID", "🚀 Raid en préparation", "→ \(login)")
            }
        case "raid_go_v2", "raid_go":
            let login = (r?["target_login"] as? String) ?? raid?.targetLogin
            if let login = login {
                logger.success("RAID", "🚀 Raid parti", "→ \(login)")
                joinTarget = login
            }
        case "raid_cancel_v2", "raid_cancel":
            logger.debug("RAID", "Raid annulé", nil)
            raid = nil
        default:
            logger.debug("RAID", "Type: \(mtype)", nil)
        }
    }
}
