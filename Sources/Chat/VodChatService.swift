import Foundation
import SwiftUI

// MARK: – Chat de VOD (relecture des commentaires, synchronisée à la lecture)
//
// On interroge `video.comments` par position (en secondes). La pagination par
// curseur (`after:`) est refusée par Twitch (« failed integrity check ») : le
// chat se figeait après la première page. Comme le site (chat/vod.js), chaque
// page repart du dernier instant reçu ; les pages se chevauchent et les
// doublons sont écartés par identifiant. On garde une file tampon triée par
// offset et on libère les messages au fur et à mesure que la lecture avance,
// ce qui reproduit le défilement du chat d'origine.
@MainActor
final class VodChatService: ObservableObject {

    @Published var messages: [ChatMessage] = []      // plus récent en premier (comme le live)
    @Published var isLoading    = false
    @Published var ready        = false
    @Published var channelLogin = ""
    @Published var errorMsg: String? = nil

    private var videoId   = ""
    /// Chaîne de la VOD (badges d'abonné de la fiche d'un badge touché).
    private(set) var channelId: String? = nil

    /// Tampon des commentaires à venir, trié par offset croissant.
    private var buffer: [(offset: Double, msg: ChatMessage)] = []
    /// Identifiants déjà reçus → instant (les pages se chevauchent).
    private var seen: [String: Double] = [:]
    /// Plus grand instant reçu depuis le dernier saut (−1 : rien encore).
    private var fetchedUntil: Double = -1
    private var hasNext    = true
    private var lastOffset: Double = -1
    private var fetching   = false
    /// Change à chaque saut : une page arrivée trop tard est ignorée.
    private var generation = 0
    /// Après un échec, pas de nouvel essai avant cette date (3 s, puis jusqu'à 30 s).
    private var retryAt = Date.distantPast
    private var failures = 0

    private let maxMessages = 200
    private let lookahead: Double = 30  // charge la suite tant qu'on a moins de 30 s d'avance

    /// Hash de la persisted query utilisée par le site (capturé au cartographe).
    /// Si Twitch le fait tourner, on bascule automatiquement sur du GraphQL brut.
    static let commentsHash =
        "b70a3591ff0f4e0313d126c6a1502d79a1c02baebb288227c582044aa76adf6a"

    // MARK: Hors ligne (chat gardé avec une VOD téléchargée)
    private var offline: OfflineChat? = nil
    private var offlineFolder: URL? = nil
    /// Prochain commentaire à faire passer.
    private var offlineNext = 0

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
        messages = []; buffer = []; seen = [:]
        fetchedUntil = -1; hasNext = true; lastOffset = -1
        generation += 1; retryAt = .distantPast; failures = 0
        fetching = false; isLoading = false; ready = false; errorMsg = nil
        offline = nil; offlineFolder = nil; offlineNext = 0
    }

    /// Chat gardé avec une VOD téléchargée : lu sur le disque, sans réseau.
    func startOffline(file: URL) async {
        stop()
        guard let data = try? Data(contentsOf: file),
              var chat = try? JSONDecoder().decode(OfflineChat.self, from: data) else {
            errorMsg = "chat"
            ready = true
            return
        }
        chat.comments.sort { $0.o < $1.o }
        offline = chat
        offlineFolder = file.deletingLastPathComponent()
        videoId = file.path
        channelLogin = chat.channelLogin
        ready = true
    }

    /// À appeler quand la position de lecture change.
    func update(offset: Double) async {
        guard !videoId.isEmpty, offset.isFinite, offset >= 0 else { return }
        if offline != nil { releaseOffline(at: offset); return }
        // Pas avant que la chaîne (et ses emotes) soit connue : les premiers
        // commentaires restaient en texte (« KEKW ») pendant une à deux minutes.
        guard ready else { return }

        // Premier appel, retour en arrière, ou gros saut avant : on recharge la fenêtre.
        if lastOffset < 0 || offset < lastOffset - 2 || offset > lastOffset + 30 {
            lastOffset = offset
            await seek(to: offset)
            return
        }
        lastOffset = offset
        release(upTo: offset)
        if hasNext, !fetching, fetchedUntil < offset + lookahead, Date() >= retryAt {
            // Rien encore reçu depuis le saut (première page en échec) : on
            // repart de la position de lecture, pas du début de la vidéo.
            // Pas de sablier pour un nouvel essai : seule la page du saut
            // l'affiche (sinon il alternerait avec le message d'erreur).
            let first = fetchedUntil < 0
            await load(offset: Int(max(0, first ? offset : fetchedUntil)), firstPage: false)
        }
    }

    // MARK: Chargement
    private func seek(to offset: Double) async {
        generation += 1
        let gen = generation
        buffer = []; seen = [:]; fetchedUntil = -1; hasNext = true; messages = []
        retryAt = .distantPast; failures = 0; errorMsg = nil
        await load(offset: Int(offset), firstPage: true)
        guard gen == generation else { return }
        release(upTo: lastOffset)
    }

    /// Requête des commentaires à partir d'une position (GraphQL brut).
    private static func commentsQuery(videoId: String, offset: Int) -> String {
        return """
        query {
          video(id: "\(gqlStr(videoId))") {
            comments(contentOffsetSeconds: \(offset)) {
              edges {
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

    private func load(offset: Int, firstPage: Bool) async {
        let gen = generation
        let id = videoId
        fetching = true
        if firstPage { isLoading = true }
        // Après un saut, c'est la page du saut qui tient les drapeaux :
        // une page partie avant ne les touche plus.
        defer { if gen == generation { fetching = false; isLoading = false } }

        // 1) Persisted query (exactement ce que fait le site).
        var response = await TwitchGQL.shared.query("VideoCommentsByOffsetOrCursor",
                                                    variables: ["videoID": id, "contentOffsetSeconds": offset],
                                                    sha256: Self.commentsHash,
                                                    token: nil)
        // 2) Repli : si le hash a tourné côté Twitch, on repasse en GraphQL brut.
        if Self.isPersistedMiss(response) {
            logger.warn("VODCHAT", "Hash périmé → repli GraphQL brut", nil)
            response = await Self.rawGQL(Self.commentsQuery(videoId: id, offset: offset))
        }
        guard gen == generation else { return }
        guard let res = response else {
            failed("network")
            logger.warn("VODCHAT", "Requête commentaires échouée", nil)
            return
        }
        if let errs = res["errors"] as? [[String: Any]], !errs.isEmpty {
            let msgs = errs.compactMap { $0["message"] as? String }.joined(separator: " · ")
            // Le texte anglais de Twitch reste dans le journal ; l'écran dit
            // simplement que Twitch n'a pas rendu le chat.
            failed("twitch")
            logger.error("VODCHAT", "Erreur GQL commentaires", msgs)
            return
        }
        guard let data = res["data"] as? [String: Any] else {
            failed(nil)
            logger.warn("VODCHAT", "Structure de réponse inattendue", "\(res.keys.sorted())")
            return
        }
        guard let video    = data["video"]     as? [String: Any],
              let comments = video["comments"] as? [String: Any],
              let edges    = comments["edges"] as? [[String: Any]] else {
            // Réponse sans erreur mais sans commentaires (VOD supprimée, chat
            // indisponible) : rien à charger, comme le site. Un nouvel essai
            // toutes les 30 s n'y changerait rien.
            hasNext = false
            logger.warn("VODCHAT", "Pas de commentaires pour cette VOD", nil)
            return
        }
        failures = 0; retryAt = .distantPast; errorMsg = nil
        let more = (comments["pageInfo"] as? [String: Any])?["hasNextPage"] as? Bool ?? false

        // La page chevauche la précédente : on ne garde que les nouveaux.
        var fresh = 0, added = 0
        var newest = fetchedUntil
        for e in edges {
            guard let node = e["node"] as? [String: Any],
                  let cid = node["id"] as? String, seen[cid] == nil else { continue }
            let at = Self.offset(of: node)
            seen[cid] = at
            fresh += 1
            newest = max(newest, at)
            let built = await build(node)
            // Saut pendant la mise en forme : cette page ne sert plus.
            guard gen == generation else { return }
            if let built { buffer.append(built); added += 1 }
        }
        buffer.sort { $0.offset < $1.offset }
        // Une page sans rien de neuf ferait reboucler sur la même position :
        // on force l'avance de quelques secondes.
        fetchedUntil = fresh > 0 ? newest : max(fetchedUntil, Double(offset)) + 5
        hasNext = more || fresh > 0
        // Longue VOD : les pages ne reviennent que d'une ou deux minutes en
        // arrière, les identifiants plus anciens ne servent plus.
        if seen.count > 20_000 { seen = seen.filter { $0.value >= fetchedUntil - 600 } }
        logger.debug("VODCHAT", "Page chargée",
                     "@\(offset) · +\(added) · tampon:\(buffer.count) · jusqu'à:\(Int(fetchedUntil)) · suite:\(hasNext)")
    }

    /// Échec d'une page : nouvel essai au prochain tick après un délai
    /// (3 s, 6 s, 12 s… jusqu'à 30 s), au lieu de couper le chat pour de bon.
    private func failed(_ msg: String?) {
        if let msg { errorMsg = msg }
        failures += 1
        retryAt = Date().addingTimeInterval(min(30, 3 * Double(1 << min(failures - 1, 4))))
    }

    private static func offset(of node: [String: Any]) -> Double {
        (node["contentOffsetSeconds"] as? Double) ?? Double(node["contentOffsetSeconds"] as? Int ?? 0)
    }

    /// Une page de commentaires à partir d'une position : sert au chat gardé
    /// avec une VOD téléchargée (VodChatArchive).
    static func commentsPage(videoId: String, offset: Int) async -> (nodes: [[String: Any]], hasNext: Bool)? {
        var response = await TwitchGQL.shared.query("VideoCommentsByOffsetOrCursor",
                                                    variables: ["videoID": videoId, "contentOffsetSeconds": offset],
                                                    sha256: commentsHash, token: nil)
        if isPersistedMiss(response) {
            response = await rawGQL(commentsQuery(videoId: videoId, offset: offset))
        }
        guard let comments = ((response?["data"] as? [String: Any])?["video"] as? [String: Any])?["comments"] as? [String: Any],
              let edges = comments["edges"] as? [[String: Any]] else { return nil }
        let hasNext = (comments["pageInfo"] as? [String: Any])?["hasNextPage"] as? Bool ?? false
        return (edges.compactMap { $0["node"] as? [String: Any] }, hasNext)
    }

    /// La persisted query a-t-elle été rejetée (hash inconnu de Twitch) ?
    static func isPersistedMiss(_ res: [String: Any]?) -> Bool {
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

    /// Hors ligne : `t` est la position dans la vidéo téléchargée, qui
    /// commence à `base` dans la VOD.
    private func releaseOffline(at t: Double) {
        guard let chat = offline else { return }
        let time = chat.base + t
        if lastOffset < 0 || t < lastOffset - 2 || t > lastOffset + 30 {
            // Saut : les derniers messages d'avant cet instant, comme en ligne.
            messages = []
            let upTo = chat.comments.firstIndex { $0.o > time } ?? chat.comments.count
            offlineNext = max(0, upTo - 50)
        }
        lastOffset = t
        var out: [ChatMessage] = []
        while offlineNext < chat.comments.count, chat.comments[offlineNext].o <= time {
            out.append(offlineMessage(chat.comments[offlineNext], images: chat.images))
            offlineNext += 1
        }
        guard !out.isEmpty else { return }
        for m in out { messages.insert(m, at: 0) }
        if messages.count > maxMessages { messages = Array(messages.prefix(maxMessages)) }
    }

    private func offlineMessage(_ c: OfflineChat.Comment, images: [String: String]) -> ChatMessage {
        // Images gardées avec le chat : lues dans le dossier.
        let local = { (url: String) -> String in
            guard let file = images[url], let folder = self.offlineFolder else { return url }
            return folder.appendingPathComponent(VodChatArchive.imagesFolder)
                .appendingPathComponent(file).absoluteString
        }
        let badges = c.badges.compactMap { b in b.u.map { TwitchBadge(id: b.v, url: local($0)) } }
        let tokens: [MessageToken] = c.tokens.map { t in
            switch t.k {
            case "e":
                return .emote(TwitchEmote(id: t.id ?? t.v, name: t.v, url: local(t.u ?? ""),
                                          source: EmoteSource(rawValue: t.s ?? "") ?? .twitch))
            case "m": return .mention(t.v)
            case "l": return .link(t.v)
            default:  return .text(t.v)
            }
        }
        let color: Color = c.color.flatMap { $0.isEmpty ? nil : Color.readableChat(hex: $0) } ?? .tPurple
        return ChatMessage(
            id: c.id, userId: c.uid, userName: c.login, displayName: c.name,
            color: color, badges: badges, tokens: tokens,
            timestamp: Date(timeIntervalSince1970: c.o),
            isAction: false, isHighlight: false, isFirstMessage: false,
            replyTo: nil, replyBody: nil, systemMsg: nil,
            parentMsgId: nil, threadRootId: nil,
            vodOffsetLabel: Self.formatOffset(c.o)
        )
    }

    static func formatOffset(_ s: Double) -> String {
        let t = max(0, Int(s))
        let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                     : String(format: "%d:%02d", m, sec)
    }

    // MARK: Construction d'un message
    /// Les doublons sont écartés avant, dans load().
    private func build(_ node: [String: Any]) async -> (offset: Double, msg: ChatMessage)? {
        let id = node["id"] as? String ?? UUID().uuidString
        let offset = Self.offset(of: node)

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
    static func rawGQL(_ query: String) async -> [String: Any]? {
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
        let q = "query { video(id: \"\(gqlStr(videoId))\") { owner { id login } } }"
        guard let json  = await Self.rawGQL(q),
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

        // Emotes + badges du canal, comme en live : en parallèle, et 3,5 s au
        // plus. L'un après l'autre et sans délai propre, un 7TV, BTTV ou FFZ
        // qui ne répond pas laissait le chat vide 20 à 40 s ; le reste arrive
        // derrière.
        let cid = channelId, name = channelLogin
        // Jeton dans le trousseau (il n'est plus dans UserDefaults) ; sans
        // jeton, BadgeService passe par la requête GQL publique.
        let tok = Keychain.loadToken("twitch_token")
        let assets = Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await EmoteService.shared.loadGlobals() }
                guard let cid else { return }
                group.addTask { await EmoteService.shared.loadChannel(channelId: cid, channelName: name) }
                group.addTask { await BadgeService.shared.loadGlobal(token: tok) }
                group.addTask { await BadgeService.shared.loadChannel(channelId: cid, token: tok) }
            }
        }
        if !(await finishes(assets, within: 3.5)) {
            logger.warn("VODCHAT", "Emotes et badges encore en chargement après 3,5 s",
                        "commentaires affichés sans les attendre")
        }
    }
}
