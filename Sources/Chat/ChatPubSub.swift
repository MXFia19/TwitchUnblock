import Foundation
import SwiftUI

// MARK: – PubSub Twitch (messages épinglés)
// Les messages épinglés ne transitent PAS par l'IRC : ils arrivent via PubSub
// (topic `pinned-chat-updates-v1.<channelId>`). On maintient une petite connexion
// WebSocket dédiée pour les recevoir.
@MainActor
final class ChatPubSub: ObservableObject {
    @Published var pinnedText:   String? = nil
    @Published var pinnedAuthor: String? = nil

    private var ws: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .default)
    private var pingTimer: Timer?
    private var channelId = ""
    private var token = ""

    // MARK: Connect
    func connect(channelId: String, token: String) {
        disconnect()
        guard !channelId.isEmpty, !token.isEmpty,
              let url = URL(string: "wss://pubsub-edge.twitch.tv/v1") else { return }
        self.channelId = channelId
        self.token = token

        ws = session.webSocketTask(with: url)
        ws?.resume()
        logger.debug("PUBSUB", "Connexion épinglés", "canal \(channelId)")

        Task {
            await sendJSON([
                "type": "LISTEN",
                "nonce": UUID().uuidString,
                "data": [
                    "topics": ["pinned-chat-updates-v1.\(channelId)"],
                    "auth_token": token
                ]
            ])
            await receive()
        }
        pingTimer = Timer.scheduledTimer(withTimeInterval: 240, repeats: true) { [weak self] _ in
            Task { await self?.sendJSON(["type": "PING"]) }
        }
    }

    func disconnect() {
        pingTimer?.invalidate(); pingTimer = nil
        ws?.cancel(with: .normalClosure, reason: nil); ws = nil
        pinnedText = nil; pinnedAuthor = nil
    }

    // MARK: I/O
    private func sendJSON(_ obj: [String: Any]) async {
        guard let ws,
              let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return }
        try? await ws.send(.string(s))
    }

    private func receive() async {
        guard let ws else { return }
        do {
            let msg = try await ws.receive()
            switch msg {
            case .string(let text): handle(text)
            case .data(let d): if let t = String(data: d, encoding: .utf8) { handle(t) }
            @unknown default: break
            }
            if self.ws != nil { await receive() }
        } catch {
            logger.warn("PUBSUB", "Connexion perdue", error.localizedDescription)
        }
    }

    // MARK: Parsing
    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {
        case "PONG":
            return
        case "RECONNECT":
            connect(channelId: channelId, token: token)
        case "RESPONSE":
            // Réponse au LISTEN : error vide = accepté ; sinon ERR_BADAUTH / ERR_BADTOPIC…
            let err = json["error"] as? String ?? ""
            if err.isEmpty { logger.success("PUBSUB", "LISTEN accepté (épinglés)", nil) }
            else { logger.error("PUBSUB", "LISTEN refusé", err) }
        case "MESSAGE":
            guard let dataObj = json["data"]       as? [String: Any],
                  let inner   = dataObj["message"] as? String else { return }
            logger.debug("PUBSUB", "MESSAGE reçu", String(inner.prefix(400)))
            parsePinned(inner)
        default:
            logger.debug("PUBSUB", "Type reçu: \(type)", nil)
        }
    }

    private func parsePinned(_ inner: String) {
        guard let d = inner.data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let mtype = j["type"] as? String else { return }

        switch mtype {
        case "pin-message", "update-message":
            // La structure exacte peut varier : on tente plusieurs chemins.
            let data = j["data"] as? [String: Any]
            let m = (data?["message"] as? [String: Any])
                 ?? (data?["pinned_message"] as? [String: Any])
                 ?? ((data?["pinned_chat_message"] as? [String: Any])?["message"] as? [String: Any])
            if let m = m,
               let content = (m["content"] as? [String: Any]) ?? (m["message"] as? [String: Any]),
               let txt = (content["text"] as? String) ?? (m["text"] as? String) {
                pinnedText   = txt
                pinnedAuthor = (m["sender"] as? [String: Any])?["display_name"] as? String
                logger.success("PUBSUB", "📌 Message épinglé", txt)
            } else {
                logger.warn("PUBSUB", "pin-message non parsé", "structure inattendue")
            }
        case "unpin-message":
            pinnedText = nil; pinnedAuthor = nil
            logger.debug("PUBSUB", "Message désépinglé", nil)
        default:
            logger.debug("PUBSUB", "Type interne: \(mtype)", nil)
        }
    }
}
