import Foundation
import SwiftUI

// MARK: – Messages épinglés (via GraphQL GetPinnedChat)
//
// Les messages épinglés ne transitent pas par l'IRC. Le PubSub `pinned-chat-updates-v1`
// n'envoie que les *changements* (pas l'état courant) et exige une auth fragile.
// On interroge donc directement la persisted query `GetPinnedChat` (publique) au
// chargement, puis on la re-poll périodiquement pour capter les épinglages/désépinglages.
@MainActor
final class ChatPubSub: ObservableObject {
    @Published var pinnedText:   String? = nil
    @Published var pinnedAuthor: String? = nil

    private var timer: Timer?
    private var channelId = ""
    private let pollInterval: TimeInterval = 30

    // Hash de la persisted query `GetPinnedChat` (capturé sur le client web).
    private static let queryHash = "2d099d4c9b6af80a07d8440140c4f3dbb04d516b35c401aab7ce8f60765308d5"

    // La signature garde `token` pour compatibilité (non requis : lecture publique).
    func connect(channelId: String, token: String = "") {
        disconnect()
        guard !channelId.isEmpty else { return }
        self.channelId = channelId
        logger.debug("PINNED", "Suivi des épinglés", "canal \(channelId)")
        Task { await fetch() }
        timer = Timer.scheduledCommon(every: pollInterval) { [weak self] _ in
            Task { await self?.fetch() }
        }
    }

    func disconnect() {
        timer?.invalidate(); timer = nil
        pinnedText = nil; pinnedAuthor = nil
    }

    private func fetch() async {
        let body: [[String: Any]] = [[
            "operationName": "GetPinnedChat",
            "variables": ["channelID": channelId, "count": 1],
            "extensions": ["persistedQuery": ["version": 1, "sha256Hash": Self.queryHash]]
        ]]
        guard let url = URL(string: "https://gql.twitch.tv/gql"),
              let payload = try? JSONSerialization.data(withJSONObject: body) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(kGQLClientID, forHTTPHeaderField: "Client-ID")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = payload

        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let arr   = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = arr.first,
              let d     = first["data"]    as? [String: Any],
              let chan  = d["channel"]     as? [String: Any],
              let pin   = chan["pinnedChatMessages"] as? [String: Any],
              let edges = pin["edges"]     as? [[String: Any]] else { return }

        guard let node = edges.first?["node"] as? [String: Any],
              !isExpired(node),
              let pm      = node["pinnedMessage"] as? [String: Any],
              let content = pm["content"] as? [String: Any],
              let text    = content["text"] as? String, !text.isEmpty else {
            if pinnedText != nil { logger.debug("PINNED", "Plus de message épinglé", nil) }
            pinnedText = nil; pinnedAuthor = nil
            return
        }
        let author = (pm["sender"] as? [String: Any])?["displayName"] as? String
        if pinnedText != text {
            pinnedText = text
            pinnedAuthor = author
            logger.success("PINNED", "📌 Message épinglé", text)
        }
    }

    /// Vrai si l'épingle a une date de fin passée.
    private func isExpired(_ node: [String: Any]) -> Bool {
        guard let ends = node["endsAt"] as? String, !ends.isEmpty else { return false }
        let df = ISO8601DateFormatter()
        df.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = df.date(from: ends) ?? ISO8601DateFormatter().date(from: ends)
        if let date { return date < Date() }
        return false
    }
}
