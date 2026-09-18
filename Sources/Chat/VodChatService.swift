import Foundation
import SwiftUI

// MARK: – Chat de VOD (relecture des commentaires, synchronisée à la lecture)
//
// On interroge `video.comments` en GraphQL brut : une position (en secondes)
// pour la première page, puis un curseur pour la suite. On garde une file tampon
// triée par offset et on libère les messages au fur et à mesure que la lecture
// avance, ce qui reproduit le défilement du chat d'origine.
@MainActor
final class VodChatService: ObservableObject {

    @Published var messages: [ChatMessage] = []      // plus récent en premier (comme le live)
    @Published var isLoading    = false
    @Published var ready        = false
    @Published var channelLogin = ""
    @Published var errorMsg: String? = nil

    private var videoId   = ""
    private var channelId: String? = nil

    /// Tampon des commentaires à venir, trié par offset croissant.
    private var buffer: [(offset: Double, msg: ChatMessage)] = []
    private var seen   = Set<String>()
    private var cursor: String? = nil
    private var hasNext    = true
    private var lastOffset: Double = -1
    private var fetching   = false

    private let maxMessages   = 200
    private let prefetchBelow = 30     // recharge quand le tampon descend sous ce seuil

    /// Hash de la persisted query utilisée par le site (capturé au cartographe).
    /// Si Twitch le fait tourner, on bascule automatiquement sur du GraphQL brut.
    private static let commentsHash =
        "b70a3591ff0f4e0313d126c6a1502d79a1c02baebb288227c582044aa76adf6a"

    // MARK: Cycle de vie
    func start(videoId: String) async {
        guard self.videoId != videoId else { return }
        stop()
        self.videoId = videoId
        logger.info("VODCHAT", "Démarrage chat VOD", "video \(videoId)")
        await resolveOwner()
        ready = true
    }

    func stop() {
        videoId = ""; channelId = nil; channelLogin = ""
        messages = []; buffer = []; seen = []
        cursor = nil; hasNext = true; lastOffset = -1
        fetching = false; isLoading = false; ready = false; errorMsg = nil
    }

    /// À appeler quand la position de lecture change.
    func update(offset: Double) async {
        guard !videoId.isEmpty, offset.isFinite, offset >= 0 else { return }

        // Premier appel, retour en arrière, ou gros saut avant : on recharge la fenêtre.
        if lastOffset < 0 || offset < lastOffset - 2 || offset > lastOffset + 30 {
            lastOffset = offset
            await seek(to: offset)
            return
        }
        lastOffset = offset
        release(upTo: offset)
        if buffer.count < prefetchBelow, hasNext, !fetching { await fetchMore() }
    }

    // MARK: Chargement
    private func seek(to offset: Double) async {
        buffer = []; seen = []; cursor = nil; hasNext = true; messages = []
        await load(offset: Int(offset), cursor: nil, firstPage: true)
        release(upTo: offset)
    }

    private func fetchMore() async {
        guard let c = cursor else { hasNext = false; return }
        await load(offset: nil, cursor: c, firstPage: false)
    }

    /// Requête des commentaires : par position (première page) ou par curseur (suite).
    private func commentsQuery(offset: Int?, cursor: String?) -> String {
        let arg = cursor.map { "after: \"\($0)\"" } ?? "contentOffsetSeconds: \(offset ?? 0)"
        return """
        query {
          video(id: "\(videoId)") {
            comments(\(arg)) {
              edges {
                cursor
                node {
                  id
                  contentOffsetSeconds
                  commenter { id login displayName }
                  message {
                    userColor
                    userBadges { setID version }
                    fragments { text emote { emoteID } }
                  }
                }
              }
              pageInfo { hasNextPage }
            }
          }
        }
        """
    }

    private func load(offset: Int?, cursor: String?, firstPage: Bool) async {
        fetching = true
        if firstPage { isLoading = true }
        defer { fetching = false; isLoading = false }

        // 1) Persisted query (exactement ce que fait le site).
        var vars: [String: Any] = ["videoID": videoId]
        if let c = cursor { vars["cursor"] = c }
        else { vars["contentOffsetSeconds"] = offset ?? 0 }
        var response = await TwitchGQL.shared.query("VideoCommentsByOffsetOrCursor",
                                                    variables: vars,
                                                    sha256: Self.commentsHash,
                                                    token: nil)
        // 2) Repli : si le hash a tourné côté Twitch, on repasse en GraphQL brut.
        if Self.isPersistedMiss(response) {
            logger.warn("VODCHAT", "Hash périmé → repli GraphQL brut", nil)
            response = await rawGQL(commentsQuery(offset: offset, cursor: cursor))
        }
        guard let res = response else {
            errorMsg = "network"
            logger.warn("VODCHAT", "Requête commentaires échouée", nil)
            return
        }
        if let errs = res["errors"] as? [[String: Any]], !errs.isEmpty {
            let msgs = errs.compactMap { $0["message"] as? String }.joined(separator: " · ")
            errorMsg = msgs
            logger.error("VODCHAT", "Erreur GQL commentaires", msgs)
            hasNext = false
            return
        }
        guard let data     = res["data"]       as? [String: Any],
              let video    = data["video"]     as? [String: Any],
              let comments = video["comments"] as? [String: Any],
              let edges    = comments["edges"] as? [[String: Any]] else {
            logger.warn("VODCHAT", "Structure de réponse inattendue", "\(res.keys.sorted())")
            hasNext = false
            return
        }

        hasNext = (comments["pageInfo"] as? [String: Any])?["hasNextPage"] as? Bool ?? false
        // self. explicite : le parametre `cursor` masque la propriete.
        if let last = edges.last?["cursor"] as? String { self.cursor = last }

        var added = 0
        for e in edges {
            guard let node = e["node"] as? [String: Any] else { continue }
            guard let built = await build(node) else { continue }
            buffer.append(built); added += 1
        }
        buffer.sort { $0.offset < $1.offset }
        logger.debug("VODCHAT", "Page chargée",
                     "+\(added) · tampon:\(buffer.count) · suite:\(hasNext)")
    }

    /// La persisted query a-t-elle été rejetée (hash inconnu de Twitch) ?
    private static func isPersistedMiss(_ res: [String: Any]?) -> Bool {
        guard let res = res else { return true }
        guard let errs = res["errors"] as? [[String: Any]] else { return false }
        return errs.contains {
            ($0["message"] as? String)?.contains("PersistedQueryNotFound") == true
        }
    }

    /// Fait passer dans `messages` tout ce qui est déjà passé dans la vidéo.
    private func release(upTo offset: Double) {
        var out: [ChatMessage] = []
        while let f = buffer.first, f.offset <= offset {
            out.append(f.msg)
            buffer.removeFirst()
        }
        guard !out.isEmpty else { return }
        for m in out { messages.insert(m, at: 0) }
        if messages.count > maxMessages { messages = Array(messages.prefix(maxMessages)) }
    }

    static func formatOffset(_ s: Double) -> String {
        let t = max(0, Int(s))
        let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                     : String(format: "%d:%02d", m, sec)
    }

    // MARK: Construction d'un message
    private func build(_ node: [String: Any]) async -> (offset: Double, msg: ChatMessage)? {
        let id = node["id"] as? String ?? UUID().uuidString
        guard !seen.contains(id) else { return nil }
        seen.insert(id)

        let offset = (node["contentOffsetSeconds"] as? Double)
                  ?? Double(node["contentOffsetSeconds"] as? Int ?? 0)

        let commenter = node["commenter"] as? [String: Any]
        let login   = commenter?["login"] as? String ?? "inconnu"
        let display = commenter?["displayName"] as? String ?? login
        let uid     = commenter?["id"] as? String ?? ""

        let body = node["message"] as? [String: Any]
        let color: Color = {
            if let hex = body?["userColor"] as? String, !hex.isEmpty {
                return Color.readableChat(hex: hex)
            }
            return .tPurple
        }()

        // Badges (setID/version : canal, puis global, puis CDN statique)
        var badges: [TwitchBadge] = []
        for b in (body?["userBadges"] as? [[String: Any]] ?? []) {
            guard let set = b["setID"] as? String, !set.isEmpty,
                  let ver = b["version"] as? String else { continue }
            let key = "\(set)/\(ver)"
            let url = await BadgeService.shared.resolve(badgeId: key, channelId: channelId)
            if !url.isEmpty { badges.append(TwitchBadge(id: key, url: url)) }
        }

        // Fragments : emote Twitch native, sinon texte (peut contenir des emotes tierces)
        var tokens: [MessageToken] = []
        for f in (body?["fragments"] as? [[String: Any]] ?? []) {
            let text = f["text"] as? String ?? ""
            if let emote = f["emote"] as? [String: Any],
               let eid = (emote["emoteID"] ?? emote["id"]) as? String, !eid.isEmpty {
                tokens.append(.emote(TwitchEmote(
                    id: eid, name: text,
                    url: "https://static-cdn.jtvnw.net/emoticons/v2/\(eid)/default/dark/2.0",
                    source: .twitch)))
            } else if !text.isEmpty {
                tokens += await tokenizeChatSegment(text, channelId: channelId)
            }
        }
        guard !tokens.isEmpty else { return nil }

        let msg = ChatMessage(
            id: id, userId: uid, userName: login, displayName: display,
            color: color, badges: badges, tokens: tokens,
            timestamp: Date(timeIntervalSince1970: offset),
            isAction: false, isHighlight: false, isFirstMessage: false,
            replyTo: nil, replyBody: nil, systemMsg: nil,
            parentMsgId: nil, threadRootId: nil,
            vodOffsetLabel: Self.formatOffset(offset)
        )
        return (offset, msg)
    }

    // MARK: GraphQL brut (pas de persisted query : aucun hash a maintenir)
    private func rawGQL(_ query: String) async -> [String: Any]? {
        guard let url = URL(string: "https://gql.twitch.tv/gql") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(kGQLClientID,       forHTTPHeaderField: "Client-ID")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["query": query])
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: Propriétaire de la VOD (pour charger les emotes/badges du canal)
    private func resolveOwner() async {
        let q = "query { video(id: \"\(videoId)\") { owner { id login } } }"
        guard let json  = await rawGQL(q),
              let d     = json["data"]   as? [String: Any],
              let video = d["video"]     as? [String: Any],
              let owner = video["owner"] as? [String: Any] else {
            logger.warn("VODCHAT", "Propriétaire de la VOD introuvable",
                        "emotes du canal indisponibles")
            return
        }
        channelId    = owner["id"]    as? String
        channelLogin = owner["login"] as? String ?? ""
        logger.success("VODCHAT", "VOD de @\(channelLogin)", "canal \(channelId ?? "?")")

        // Emotes + badges du canal, comme en live.
        await EmoteService.shared.loadGlobals()
        if let cid = channelId {
            await EmoteService.shared.loadChannel(channelId: cid, channelName: channelLogin)
            if let tok = UserDefaults.standard.string(forKey: "twitch_token") {
                await BadgeService.shared.loadGlobal(token: tok)
                await BadgeService.shared.loadChannel(channelId: cid, token: tok)
            }
        }
    }
}
