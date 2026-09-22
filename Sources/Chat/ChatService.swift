import Foundation
import Combine
import SwiftUI

@MainActor
final class ChatService: NSObject, ObservableObject {

    @Published var messages: [ChatMessage] = []
    @Published var isConnected     = false
    @Published var isAuthenticated = false
    @Published var channelId: String? = nil

    private var webSocketTask: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .default)
    private var channelName = ""
    private var pingTimer: Timer?
    private var connectionTimeoutTask: Task<Void, Never>?
    private let maxMessages = 200
    private let maxMessagesPaused = 600   // plafond dur quand la purge est en pause (lecture)
    /// Quand true (utilisateur remonté pour lire l'historique), on ne purge pas les
    /// plus anciens messages : ça éviterait de faire « descendre » la vue pendant la lecture.
    var pauseTrim = false

    /// Délai (s) appliqué à l'affichage des messages reçus, pour les recaler sur
    /// l'image (le chat arrive en temps réel, la vidéo a plusieurs secondes de retard).
    /// 0 = affichage immédiat. Piloté par la synchro auto du chat.
    var displayDelay: Double = 0

    /// Incrémenté à chaque (re)connexion : les messages en attente d'une session
    /// précédente sont abandonnés au lieu d'atterrir dans le nouveau canal.
    private var generation = 0

    /// Garder à l'écran les messages supprimés par la modération, barrés, au
    /// lieu de les faire disparaître. Piloté par les réglages.
    var keepDeleted = false
    /// Charger au démarrage les derniers messages du canal (API tierce).
    var loadRecent = false

    /// Personnes présentes dans le chat, tenues à jour depuis l'IRC.
    ///
    /// C'est la seule source qui reste : l'endpoint tmi.twitch.tv des chatters
    /// est fermé, la requête GQL exige un jeton d'intégrité signé, et Helix
    /// impose d'être modérateur du canal. Twitch n'envoie NAMES/JOIN/PART que
    /// pour les canaux de taille modeste — d'où `presenceSupported`.
    @Published private(set) var presentUsers: Set<String> = []
    /// Twitch a-t-il envoyé au moins une liste de noms pour ce canal ?
    @Published private(set) var presenceSupported = false

    private func trimIfNeeded() {
        let cap = pauseTrim ? maxMessagesPaused : maxMessages
        if messages.count > cap { messages = Array(messages.prefix(cap)) }
    }

    /// Insère un message reçu, immédiatement ou après le délai de synchro.
    private func publish(_ message: ChatMessage) {
        let delay = displayDelay
        guard delay >= 0.5 else { insert(message); return }
        let gen = generation
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, self.generation == gen else { return }
            self.insert(message)
        }
    }

    private func insert(_ message: ChatMessage) {
        // La liste est rangée du plus récent au plus ancien. Si le délai de synchro
        // vient de baisser, un message peut arriver après un plus récent : on le
        // replace alors à sa position chronologique au lieu de le coller en haut.
        if let first = messages.first, message.timestamp < first.timestamp {
            let idx = messages.firstIndex { $0.timestamp <= message.timestamp } ?? messages.count
            messages.insert(message, at: idx)
        } else {
            messages.insert(message, at: 0)
        }
        trimIfNeeded()
    }

    // Infos du compte connecté (GLOBALUSERSTATE / USERSTATE)
    private var localLogin       = ""
    private var localDisplayName = ""
    private var localColor       = Color(hex: "9146ff")
    private var localBadges: [TwitchBadge] = []

    // MARK: – Connect
    func connect(channel: String, token: String? = nil, login: String? = nil) {
        disconnect()
        channelName = channel.lowercased()
        logger.info("CHAT", "Connexion IRC → #\(channelName)")

        guard let url = URL(string: "wss://irc-ws.chat.twitch.tv:443") else { return }
        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()

        connectionTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let self, !Task.isCancelled, !self.isConnected else { return }
            logger.warn("CHAT", "Timeout IRC (10 s) — fallback anonyme")
            await self.reconnectAnonymously()
        }

        Task {
            await send("CAP REQ :twitch.tv/tags twitch.tv/commands twitch.tv/membership")
            if let token = token, let login = login, !login.isEmpty {
                await send("PASS oauth:\(token)")
                await send("NICK \(login.lowercased())")
                isAuthenticated = true
                localLogin = login.lowercased()
                logger.info("CHAT", "Auth IRC → \(login.lowercased())")
            } else {
                await send("NICK justinfan\(Int.random(in: 10000...99999))")
                isAuthenticated = false
            }
            await send("JOIN #\(channelName)")
            await receive()
        }

        // En parallèle de la connexion : l'historique n'a pas à attendre l'IRC,
        // et l'IRC n'a pas à attendre un service tiers.
        if loadRecent {
            let chan = channelName   // figé ici : une reconnexion le changerait
            Task { [weak self] in await self?.loadRecentMessages(channel: chan) }
        }

        pingTimer = Timer.scheduledCommon(every: 240) { [weak self] _ in
            Task { await self?.send("PING :tmi.twitch.tv") }
        }
    }

    /// Relance la connexion IRC sans quitter le direct (menu du chat).
    func reconnect(token: String?, login: String?) {
        guard !channelName.isEmpty else { return }
        logger.info("CHAT", "Reconnexion demandée → #\(channelName)")
        connect(channel: channelName, token: token, login: login)
    }

    /// Envoie une commande de chat telle quelle (/color, /me…).
    func sendCommand(_ command: String) async {
        guard isAuthenticated, isConnected, !channelName.isEmpty else { return }
        await send("PRIVMSG #\(channelName) :\(command)")
        logger.info("CHAT", "Commande envoyée", command)
    }

    // MARK: – Disconnect
    func disconnect() {
        generation &+= 1   // abandonne les messages encore en attente de synchro
        presentUsers.removeAll()
        presenceSupported = false
        connectionTimeoutTask?.cancel(); connectionTimeoutTask = nil
        pingTimer?.invalidate(); pingTimer = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil); webSocketTask = nil
        isConnected = false; isAuthenticated = false
        localLogin = ""; localDisplayName = ""; localBadges = []
        logger.info("CHAT", "IRC déconnecté")
    }

    // MARK: – Fallback anonyme
    private func reconnectAnonymously() async {
        connectionTimeoutTask?.cancel(); connectionTimeoutTask = nil
        pingTimer?.invalidate(); pingTimer = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil); webSocketTask = nil
        isAuthenticated = false

        guard !channelName.isEmpty,
              let url = URL(string: "wss://irc-ws.chat.twitch.tv:443") else { return }
        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()
        await send("CAP REQ :twitch.tv/tags twitch.tv/commands twitch.tv/membership")
        await send("NICK justinfan\(Int.random(in: 10000...99999))")
        await send("JOIN #\(channelName)")
        pingTimer = Timer.scheduledCommon(every: 240) { [weak self] _ in
            Task { await self?.send("PING :tmi.twitch.tv") }
        }
        await receive()
    }

    // MARK: – Send message
    func sendMessage(_ text: String,
                     replyParentId: String? = nil,
                     replyRootId: String? = nil,
                     replyToName: String? = nil) async {
        let sanitized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty, sanitized.count <= 500,
              isAuthenticated, isConnected else { return }

        if let pid = replyParentId {
            await send("@reply-parent-msg-id=\(pid) PRIVMSG #\(channelName) :\(sanitized)")
        } else {
            await send("PRIVMSG #\(channelName) :\(sanitized)")
        }
        logger.info("CHAT", "Message envoyé → #\(channelName)", String(sanitized.prefix(80)))

        let tokens = await tokenizeText(sanitized, channelId: channelId)
        let localMsg = ChatMessage(
            id: "local-\(UUID().uuidString)",
            userId: localLogin, userName: localLogin,
            displayName: localDisplayName.isEmpty ? localLogin : localDisplayName,
            color: localColor, badges: localBadges, tokens: tokens,
            timestamp: Date(), isAction: false, isHighlight: false,
            isFirstMessage: false,
            replyTo: replyToName, replyBody: nil,
            systemMsg: nil,
            parentMsgId: replyParentId,
            threadRootId: replyRootId ?? replyParentId
        )
        // Message envoyé par nous : affiché tout de suite, jamais retardé.
        insert(localMsg)
    }

    // MARK: – Fil de discussion (thread)
    /// Messages appartenant au fil dont la racine est `rootId`, du plus ancien au plus récent.
    func threadMessages(rootId: String) -> [ChatMessage] {
        messages
            .filter { $0.id == rootId || $0.threadRootId == rootId }
            .sorted { $0.timestamp < $1.timestamp }
    }

    /// Tout ce qu'une personne a écrit dans ce qu'on a en mémoire, du plus
    /// ancien au plus récent : ouvrir un message sert surtout à voir le fil de
    /// ce qu'elle raconte, pas ce seul message hors contexte.
    func messagesFrom(userName: String, limit: Int = 30) -> [ChatMessage] {
        let key = userName.lowercased()
        guard !key.isEmpty else { return [] }
        return messages
            .filter { $0.userName.lowercased() == key }
            .sorted { $0.timestamp < $1.timestamp }
            .suffix(limit)
            .map { $0 }
    }

    // MARK: – Send raw IRC
    private func send(_ text: String) async {
        guard let task = webSocketTask else { return }
        do { try await task.send(.string(text + "\r\n")) }
        catch { logger.warn("CHAT", "Erreur envoi IRC", error.localizedDescription) }
    }

    // MARK: – Receive loop
    private func receive() async {
        guard let task = webSocketTask else { return }
        do {
            let msg = try await task.receive()
            switch msg {
            case .string(let text):  await handleRaw(text)
            case .data(let data):
                if let text = String(data: data, encoding: .utf8) { await handleRaw(text) }
            @unknown default: break
            }
            if webSocketTask != nil { await receive() }
        } catch {
            if isConnected {
                logger.error("CHAT", "Connexion IRC perdue", error.localizedDescription)
                isConnected = false
            }
        }
    }

    // MARK: – Handle raw IRC lines
    private func handleRaw(_ text: String) async {
        let lines = text.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        for line in lines {
            guard let irc = IRCParser.parse(line) else { continue }
            switch irc.command {
            case "001":
                isConnected = true
                connectionTimeoutTask?.cancel(); connectionTimeoutTask = nil
                logger.success("CHAT", "IRC connecté à #\(channelName)")
            case "PING":
                await send("PONG :tmi.twitch.tv")
            case "PRIVMSG":
                await handlePrivmsg(irc)
            case "USERNOTICE":
                await handleUsernotice(irc)
            case "GLOBALUSERSTATE":
                handleUserInfo(irc)
            case "USERSTATE":
                handleUserInfo(irc)
                if let raw = irc.tags["badges"] {
                    // ← badges résolu via BadgeService (URLs Helix réelles)
                    localBadges = await parseBadges(raw, channelId: channelId)
                }
            case "353":
                // RPL_NAMREPLY : liste des présents, envoyée à l'arrivée.
                // Format : <nous> = #canal :nom1 nom2 nom3…
                // Le pseudo et le canal occupent params[0...2] : la liste est le
                // dernier paramètre, pas `text` (qui vaudrait « = » ici).
                if irc.params.count >= 4, let names = irc.params.last {
                    let logins = names.split(separator: " ").map { $0.lowercased() }
                    presentUsers.formUnion(logins)
                    presenceSupported = true
                }
            case "366":
                // RPL_ENDOFNAMES : Twitch a fini d'envoyer la liste (même vide).
                presenceSupported = true
            case "JOIN":
                if let who = irc.tags["login"] ?? irc.prefixNick { presentUsers.insert(who.lowercased()) }
            case "PART":
                if let who = irc.tags["login"] ?? irc.prefixNick { presentUsers.remove(who.lowercased()) }
            case "NOTICE":
                await handleNotice(irc)
            case "CLEARCHAT":
                await handleClearChat(irc)
            case "CLEARMSG":
                await handleClearMsg(irc)
            default: break
            }
        }
    }

    // MARK: – Mise à jour des infos locales
    private func handleUserInfo(_ irc: IRCMessage) {
        if let name = irc.tags["display-name"], !name.isEmpty { localDisplayName = name }
        if let hex  = irc.tags["color"], !hex.isEmpty {
            localColor = Color.readableChat(hex: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")))
        }
    }

    // MARK: – PRIVMSG → ChatMessage
    private func handlePrivmsg(_ irc: IRCMessage) async {
        guard let message = await buildMessage(irc, historical: false) else { return }
        publish(message)
    }

    /// Analyse commune au direct et à l'historique rejoué : même format IRC,
    /// donc même chemin — seule l'heure diffère (tag `tmi-sent-ts` pour le
    /// rejeu, l'heure d'arrivée pour le direct, sur laquelle repose la synchro).
    private func buildMessage(_ irc: IRCMessage, historical: Bool) async -> ChatMessage? {
        guard var text = irc.text else { return nil }

        var isAction = false
        if text.hasPrefix("\u{0001}ACTION ") && text.hasSuffix("\u{0001}") {
            text = String(text.dropFirst(8).dropLast(1))
            isAction = true
        }

        let hexColor = irc.color.isEmpty
            ? "9146ff"
            : irc.color.trimmingCharacters(in: CharacterSet(charactersIn: "#"))

        let emoteRanges = IRCParser.parseEmoteRanges(raw: irc.emotesRaw, text: text)
        var twitchEmotesByRange: [Range<String.Index>: TwitchEmote] = [:]
        for (emoteId, range) in emoteRanges {
            let emoteName = String(text[range])
            let emote = TwitchEmote(
                id: emoteId, name: emoteName,
                url: "https://static-cdn.jtvnw.net/emoticons/v2/\(emoteId)/default/dark/2.0",
                source: .twitch
            )
            await EmoteService.shared.registerTwitchEmote(id: emoteId, name: emoteName)
            twitchEmotesByRange[range] = emote
        }

        let tokens = await tokenize(text: text, twitchRanges: twitchEmotesByRange, channelId: channelId)

        // Le rejeu n'a pas de tag `login` fiable : on retombe sur le préfixe IRC.
        let login = irc.tags["login"] ?? irc.prefixNick ?? ""
        let sentAt: Date = {
            guard historical, let ms = irc.tags["tmi-sent-ts"], let n = Double(ms) else {
                return Date()
            }
            return Date(timeIntervalSince1970: n / 1000)
        }()

        return ChatMessage(
            id: irc.msgId,
            userId: irc.userId,
            userName: login,
            displayName: irc.displayName.isEmpty ? login : irc.displayName,
            color: Color.readableChat(hex: hexColor),
            // ← badges résolus via BadgeService
            badges: await parseBadges(irc.badgesRaw, channelId: channelId),
            tokens: tokens,
            timestamp: sentAt,
            isAction: isAction,
            isHighlight: irc.tags["msg-id"] == "highlighted-message",
            isFirstMessage: irc.tags["first-msg"] == "1",
            replyTo: irc.replyUser,
            replyBody: irc.replyParentBody,
            systemMsg: nil,
            parentMsgId: irc.replyParentMsgId,
            threadRootId: irc.replyThreadRootId,
            isHistorical: historical
        )
    }

    // MARK: – USERNOTICE (abonnements, séries de visionnage, raids…)
    private func handleUsernotice(_ irc: IRCMessage) async {
        let systemMsg = ircUnescape(irc.tags["system-msg"] ?? "")

        // Message écrit par l'utilisateur (resub avec texte), optionnel.
        var tokens: [MessageToken] = []
        if let text = irc.text, !text.isEmpty {
            let emoteRanges = IRCParser.parseEmoteRanges(raw: irc.emotesRaw, text: text)
            var byRange: [Range<String.Index>: TwitchEmote] = [:]
            for (emoteId, range) in emoteRanges {
                let name = String(text[range])
                byRange[range] = TwitchEmote(
                    id: emoteId, name: name,
                    url: "https://static-cdn.jtvnw.net/emoticons/v2/\(emoteId)/default/dark/2.0",
                    source: .twitch)
                await EmoteService.shared.registerTwitchEmote(id: emoteId, name: name)
            }
            tokens = await tokenize(text: text, twitchRanges: byRange, channelId: channelId)
        }

        guard !systemMsg.isEmpty || !tokens.isEmpty else { return }

        let hexColor = irc.color.isEmpty
            ? "9146ff"
            : irc.color.trimmingCharacters(in: CharacterSet(charactersIn: "#"))

        let message = ChatMessage(
            id: irc.msgId,
            userId: irc.userId,
            userName: irc.tags["login"] ?? "",
            displayName: irc.displayName,
            color: Color.readableChat(hex: hexColor),
            badges: await parseBadges(irc.badgesRaw, channelId: channelId),
            tokens: tokens,
            timestamp: Date(),
            isAction: false,
            isHighlight: true,
            isFirstMessage: false,
            replyTo: nil, replyBody: nil,
            systemMsg: systemMsg.isEmpty ? nil : systemMsg
        )
        publish(message)
        logger.debug("CHAT", "USERNOTICE \(irc.tags["msg-id"] ?? "")", systemMsg)
    }

    // MARK: – Badge parsing (async → BadgeService)
    /// Résout chaque badge via BadgeService pour obtenir l'URL Helix réelle.
    /// Fallback automatique vers CDN statique si les badges ne sont pas encore chargés.
    private func parseBadges(_ raw: String, channelId: String?) async -> [TwitchBadge] {
        guard !raw.isEmpty else { return [] }
        var result: [TwitchBadge] = []
        for part in raw.components(separatedBy: ",") {
            let kv = part.components(separatedBy: "/")
            guard kv.count == 2 else { continue }
            let id  = "\(kv[0])/\(kv[1])"
            let url = await BadgeService.shared.resolve(badgeId: id, channelId: channelId)
            guard !url.isEmpty else { continue }
            result.append(TwitchBadge(id: id, url: url))
        }
        return result
    }

    // MARK: – NOTICE
    private func handleNotice(_ irc: IRCMessage) async {
        guard let text = irc.text else { return }
        let msgId = irc.tags["msg-id"] ?? ""

        if msgId == "login_authentication_failed"
            || text.lowercased().contains("login authentication failed") {
            logger.warn("CHAT", "Auth IRC rejetée", "Passage en mode anonyme")
            isAuthenticated = false
            await reconnectAnonymously()
            insertSystemMessage("Reconnecté en lecture seule. Reconnecte-toi via Paramètres.")
            return
        }

        let chatErrorIds: Set<String> = [
            "msg_banned","msg_timedout","msg_subsonly","msg_followersonly",
            "msg_verified_email","msg_emotesonly","msg_slowmode",
            "msg_duplicate","no_permission","unrecognized_cmd"
        ]
        if chatErrorIds.contains(msgId) {
            logger.warn("CHAT", "NOTICE \(msgId)", text)
            insertSystemMessage(text)
        }
    }

    private func insertSystemMessage(_ text: String) {
        messages.insert(ChatMessage(
            id: UUID().uuidString,
            userId: "system", userName: "system",
            displayName: "⚠️ Système",
            color: Color(hex: "fbbf24"), badges: [],
            tokens: [.text(text)], timestamp: Date(),
            isAction: false, isHighlight: false,
            isFirstMessage: false, replyTo: nil, replyBody: nil
        ), at: 0)
    }

    // MARK: – Tokenizer
    private func tokenize(
        text: String,
        twitchRanges: [Range<String.Index>: TwitchEmote],
        channelId: String?
    ) async -> [MessageToken] {
        var tokens: [MessageToken] = []
        var currentIndex = text.startIndex
        let sortedRanges = twitchRanges.keys.sorted { $0.lowerBound < $1.lowerBound }

        for range in sortedRanges {
            guard range.lowerBound >= currentIndex else { continue }
            if range.lowerBound > currentIndex {
                tokens += await tokenizeText(String(text[currentIndex..<range.lowerBound]),
                                             channelId: channelId)
            }
            if let emote = twitchRanges[range] { tokens.append(.emote(emote)) }
            currentIndex = range.upperBound
        }
        if currentIndex < text.endIndex {
            tokens += await tokenizeText(String(text[currentIndex...]), channelId: channelId)
        }
        return tokens
    }

    private func tokenizeText(_ segment: String, channelId: String?) async -> [MessageToken] {
        await tokenizeChatSegment(segment, channelId: channelId)
    }

    // MARK: – Moderation
    private func handleClearChat(_ irc: IRCMessage) async {
        if let target = irc.params.last, !target.hasPrefix("#") {
            // Exclusion / bannissement : tous les messages de la personne.
            mark(where: { $0.userName == target })
        } else {
            // Purge complète du canal : même avec le réglage, garder l'écran
            // barré de bout en bout n'aurait aucun intérêt.
            messages.removeAll()
            logger.warn("CHAT", "Chat effacé par un modérateur")
        }
    }

    private func handleClearMsg(_ irc: IRCMessage) async {
        guard let targetId = irc.tags["target-msg-id"] else { return }
        mark(where: { $0.id == targetId })
    }

    /// Retire les messages visés, ou les barre si le réglage le demande.
    private func mark(where predicate: (ChatMessage) -> Bool) {
        guard keepDeleted else {
            messages.removeAll(where: predicate)
            return
        }
        for i in messages.indices where predicate(messages[i]) {
            messages[i].isDeleted = true
        }
    }

    // MARK: – Messages récents (avant notre arrivée)
    /// Twitch n'envoie rien de ce qui précède le JOIN : on arrive dans un chat
    /// vide même en plein débat. recent-messages.robotty.de rejoue les dernières
    /// lignes IRC brutes, qu'on fait passer par le même analyseur que le direct.
    ///
    /// Service tiers, hors de notre contrôle : un échec est silencieux, le chat
    /// démarre simplement vide comme avant.
    private func loadRecentMessages(channel: String, limit: Int = 60) async {
        let gen = generation
        guard let url = URL(string:
            "https://recent-messages.robotty.de/api/v2/recent-messages/\(channel)?limit=\(limit)")
        else { return }

        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw  = json["messages"] as? [String] else {
            logger.warn("CHAT", "Historique du chat indisponible", channel)
            return
        }

        var older: [ChatMessage] = []
        for line in raw {
            guard let irc = IRCParser.parse(line), irc.command == "PRIVMSG",
                  let msg = await buildMessage(irc, historical: true) else { continue }
            older.append(msg)
        }
        // La connexion a pu changer de canal pendant le téléchargement.
        guard generation == gen, !older.isEmpty else { return }

        // La liste va du plus récent au plus ancien ; on fusionne puis on retrie
        // plutôt que d'insérer un par un, l'ordre d'arrivée n'étant pas garanti.
        let known = Set(messages.map(\.id))
        messages.append(contentsOf: older.filter { !known.contains($0.id) })
        messages.sort { $0.timestamp > $1.timestamp }
        trimIfNeeded()
        logger.success("CHAT", "Historique chargé", "\(older.count) messages")
    }
}
