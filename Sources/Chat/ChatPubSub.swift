import Foundation
import SwiftUI

// MARK: – Message épinglé
/// Ce qu'il faut pour afficher le bandeau : qui, avec quels badges et quelle
/// couleur, le message découpé (emotes, liens, mentions), qui l'a épinglé et
/// jusqu'à quand.
struct PinnedChat: Equatable {
    let id: String
    let senderName: String
    let senderColor: Color
    let badges: [TwitchBadge]
    let tokens: [MessageToken]
    let text: String
    /// nil si l'auteur l'a épinglé lui-même : inutile de répéter son nom.
    let pinnedBy: String?
    let startsAt: Date?
    let endsAt: Date?

    static func == (a: PinnedChat, b: PinnedChat) -> Bool { a.id == b.id && a.endsAt == b.endsAt }

    /// Message factice pour le rendu en flux (WrappingHStack).
    var asMessage: ChatMessage {
        ChatMessage(id: "pinned-\(id)", userId: "", userName: senderName.lowercased(),
                    displayName: senderName, color: senderColor, badges: badges,
                    tokens: tokens, timestamp: startsAt ?? Date())
    }
}

// MARK: – Messages épinglés (via GraphQL)
//
// Les messages épinglés ne transitent pas par l'IRC. On interroge GQL (lecture
// publique : pas besoin d'être connecté) à l'ouverture puis toutes les 20 s.
@MainActor
final class ChatPubSub: ObservableObject {
    @Published var pinned: PinnedChat? = nil

    private var timer: Timer?
    private var expiryTask: Task<Void, Never>?
    private var channelId = ""
    private let pollInterval: TimeInterval = 20

    private static let query = """
    query($id: ID!) { channel(id: $id) { pinnedChatMessages(first: 1) { edges { node {
      id startsAt endsAt
      pinnedBy { login displayName }
      pinnedMessage {
        content { text fragments { text content { __typename ... on Emote { id } } } }
        sender { login displayName chatColor displayBadges(channelID: $id) { setID version imageURL(size: DOUBLE) } }
      }
    } } } } }
    """

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
        expiryTask?.cancel(); expiryTask = nil
        pinned = nil
    }

    private func fetch() async {
        let cid = channelId
        guard !cid.isEmpty, let url = URL(string: "https://gql.twitch.tv/gql"),
              let payload = try? JSONSerialization.data(withJSONObject: [
                  "query": Self.query, "variables": ["id": cid]
              ]) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(kGQLClientID, forHTTPHeaderField: "Client-ID")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = payload

        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d     = json["data"] as? [String: Any],
              let chan  = d["channel"] as? [String: Any],
              let pin   = chan["pinnedChatMessages"] as? [String: Any],
              let edges = pin["edges"] as? [[String: Any]],
              cid == channelId else { return }

        guard let node = edges.first?["node"] as? [String: Any],
              let id = node["id"] as? String,
              let pm = node["pinnedMessage"] as? [String: Any],
              let content = pm["content"] as? [String: Any],
              let text = content["text"] as? String, !text.isEmpty else {
            if pinned != nil { logger.debug("PINNED", "Plus de message épinglé", nil) }
            setPinned(nil)
            return
        }
        let endsAt = Self.date(node["endsAt"])
        if let endsAt, endsAt < Date() { setPinned(nil); return }
        // Même épingle : rien à recalculer.
        if pinned?.id == id, pinned?.endsAt == endsAt { return }

        let sender = pm["sender"] as? [String: Any] ?? [:]
        let senderLogin = sender["login"] as? String ?? ""
        let name = (sender["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? senderLogin
        let hex = (sender["chatColor"] as? String) ?? ""
        let color = hex.isEmpty ? Color.tPurple : Color.readableChat(hex: hex)
        let badges: [TwitchBadge] = (sender["displayBadges"] as? [[String: Any]] ?? []).compactMap { b in
            guard let set = b["setID"] as? String, let v = b["version"] as? String,
                  let u = b["imageURL"] as? String, u.hasPrefix("https://") else { return nil }
            return TwitchBadge(id: "\(set)/\(v)", url: u)
        }

        // Emotes Twitch données par les fragments ; le reste passe par le
        // découpage habituel (liens, mentions, emotes BTTV/FFZ/7TV).
        var tokens: [MessageToken] = []
        for f in content["fragments"] as? [[String: Any]] ?? [] {
            let ftext = f["text"] as? String ?? ""
            if let c = f["content"] as? [String: Any], c["__typename"] as? String == "Emote",
               let eid = c["id"] as? String, !eid.isEmpty {
                tokens.append(.emote(TwitchEmote(
                    id: eid, name: ftext.trimmingCharacters(in: .whitespaces),
                    url: "https://static-cdn.jtvnw.net/emoticons/v2/\(eid)/default/dark/2.0")))
            } else if !ftext.isEmpty {
                tokens += await tokenizeChatSegment(ftext, channelId: cid)
            }
        }
        if tokens.isEmpty { tokens = await tokenizeChatSegment(text, channelId: cid) }

        let by = node["pinnedBy"] as? [String: Any]
        let byLogin = by?["login"] as? String
        let pinnedBy = (byLogin != nil && byLogin != senderLogin) ? by?["displayName"] as? String : nil

        guard cid == channelId else { return }
        setPinned(PinnedChat(id: id, senderName: name, senderColor: color, badges: badges,
                             tokens: tokens, text: text, pinnedBy: pinnedBy,
                             startsAt: Self.date(node["startsAt"]), endsAt: endsAt))
        logger.success("PINNED", "📌 Message épinglé", text)
    }

    /// Publie l'épingle et programme sa disparition à l'échéance, sans
    /// attendre la requête suivante.
    private func setPinned(_ p: PinnedChat?) {
        if pinned != p { pinned = p }
        expiryTask?.cancel(); expiryTask = nil
        guard let p, let ends = p.endsAt else { return }
        let delay = max(0, ends.timeIntervalSinceNow)
        expiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, self.pinned?.id == p.id else { return }
            self.pinned = nil
        }
    }

    private static func date(_ raw: Any?) -> Date? {
        guard let s = raw as? String, !s.isEmpty else { return nil }
        let df = ISO8601DateFormatter()
        df.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return df.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}

// MARK: – Bandeau
/// Bandeau compact façon Twitch : une ligne (badges, pseudo coloré, message),
/// « Épinglé par X · il y a N min », barre de durée, chevron pour déplier.
struct PinnedBanner: View {
    let pin: PinnedChat
    let width: CGFloat
    @Binding var expanded: Bool
    let onDismiss: () -> Void
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 11)).foregroundColor(.tPurple)
                    .padding(.top, 3)
                if expanded {
                    ScrollView {
                        WrappingHStack(message: pin.asMessage, timeString: "",
                                       availableWidth: max(40, width - 90))
                    }
                    .frame(maxHeight: 180)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(spacing: 3) {
                        ForEach(pin.badges) { badge in
                            CachedEmoteImage(url: badge.url, name: "", height: 14, showsNameFallback: false)
                        }
                        (Text(pin.senderName).fontWeight(.bold).foregroundColor(pin.senderColor)
                         + Text(": " + pin.text).foregroundColor(.tText))
                            .font(.system(size: 13))
                            .lineLimit(1).truncationMode(.tail)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.easeInOut(duration: 0.18)) { expanded = true } }
                }
                Spacer(minLength: 0)
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
                } label: {
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                        .font(.system(size: 11, weight: .bold)).foregroundColor(.tMuted)
                        .frame(width: 24, height: 22)
                }
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold)).foregroundColor(.tMuted)
                        .frame(width: 24, height: 22)
                }
            }
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                Text(meta(now: ctx.date))
                    .font(.system(size: 10)).foregroundColor(.tMuted)
                    .lineLimit(1)
                    .padding(.leading, 17)
            }
        }
        .onChange(of: pin.id) { _ in expanded = false }
        .padding(.leading, 10).padding(.trailing, 4).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.tCard)
        .overlay(alignment: .bottom) {
            if let start = pin.startsAt, let end = pin.endsAt, end > start {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let frac = max(0, min(1, end.timeIntervalSince(ctx.date) / end.timeIntervalSince(start)))
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.tPurple.opacity(0.15))
                        Rectangle().fill(Color.tPurple)
                            .scaleEffect(x: frac, y: 1, anchor: .leading)
                    }
                    .frame(height: 2)
                }
            } else {
                Divider().background(Color.tBorder)
            }
        }
    }

    private func meta(now: Date) -> String {
        var parts = [pin.pinnedBy.map { store.t("pinned_by").replacingOccurrences(of: "{u}", with: $0) }
                     ?? store.t("pinned")]
        if let s = pin.startsAt {
            let m = Int(now.timeIntervalSince(s) / 60)
            parts.append(m < 1 ? store.t("just_now")
                         : m < 60 ? store.t("minutes_ago").replacingOccurrences(of: "{n}", with: "\(m)")
                         : store.t("hours_ago").replacingOccurrences(of: "{n}", with: "\(m / 60)"))
        }
        if let e = pin.endsAt {
            let left = max(1, Int((e.timeIntervalSince(now) / 60).rounded(.up)))
            parts.append(store.t("pin_left").replacingOccurrences(of: "{n}", with: "\(left)"))
        }
        return parts.joined(separator: " · ")
    }
}
