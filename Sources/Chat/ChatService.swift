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

    // Infos du compte connecté (remplies via GLOBALUSERSTATE / USERSTATE)
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
                logger.info("CHAT", "Connexion anonyme justinfan")
            }
            await send("JOIN #\(channelName)")
            await receive()
        }

        pingTimer = Timer.scheduledTimer(withTimeInterval: 240, repeats: true) { [weak self] _ in
            Task { await self?.send("PING :tmi.twitch.tv") }
        }
    }

    // MARK: – Disconnect
    func disconnect() {
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
        pingTimer = Timer.scheduledTimer(withTimeInterval: 240, repeats: true) { [weak self] _ in
            Task { await self?.send("PING :tmi.twitch.tv") }
        }
        await receive()
    }

    // MARK: – Send message
    func sendMessage(_ text: String) async {
        let sanitized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty, sanitized.count <= 500,
              isAuthenticated, isConnected else { return }

        await send("PRIVMSG #\(channelName) :\(sanitized)")
        logger.info("CHAT", "Message envoyé → #\(channelName)", String(sanitized.prefix(80)))

        // Insertion locale immédiate (Twitch n'échoue pas notre propre PRIVMSG)
        let tokens = await tokenizeText(sanitized, channelId: channelId)
        let localMsg = ChatMessage(
            id: "local-\(UUID().uuidString)",
            userId: localLogin,
            userName: localLogin,
            displayName: localDisplayName.isEmpty ? localLogin : localDisplayName,
            color: localColor,
            badges: localBadges,
            tokens: tokens,
            timestamp: Date(),
            isAction: false,
            isHighlight: false,
            isFirstMessage: false,
            replyTo: nil,
            replyBody: nil
        )
        messages.insert(localMsg, at: 0)
        if messages.count > maxMessages { messages = Array(messages.prefix(maxMessages)) }
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
            case "GLOBALUSERSTATE":
                handleUserInfo(irc)
            case "USERSTATE":
                handleUserInfo(irc)
                if let badges = irc.tags["badges"] { localBadges = parseBadges(badges) }
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
            localColor = Color(hex: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")))
        }
    }

    // MARK: – PRIVMSG → ChatMessage
    private func handlePrivmsg(_ irc: IRCMessage) async {
        guard var text = irc.text else { return }

        var isAction = false
        if text.hasPrefix("\u{0001}ACTION ") && text.hasSuffix("\u{0001}") {
            text = String(text.dropFirst(8).dropLast(1))
            isAction = true
        }

        let hexColor = irc.color.isEmpty
            ? "9146ff"
            : irc.color.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let userColor = Color(hex: hexColor)

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

        // ── Nouveaux champs ──────────────────────────────────────────
        let isFirstMessage = irc.tags["first-msg"] == "1"
        let replyBody      = irc.replyParentBody   // nil si pas une réponse

        let message = ChatMessage(
            id: irc.msgId,
            userId: irc.userId,
            userName: irc.tags["login"] ?? "",
            displayName: irc.displayName,
            color: userColor,
            badges: parseBadges(irc.badgesRaw),
            tokens: tokens,
            timestamp: Date(),
            isAction: isAction,
            isHighlight: irc.tags["msg-id"] == "highlighted-message",
            isFirstMessage: isFirstMessage,
            replyTo: irc.replyUser,
            replyBody: replyBody
        )

        messages.insert(message, at: 0)
        if messages.count > maxMessages { messages = Array(messages.prefix(maxMessages)) }
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
            insertSystemMessage("Reconnecté en lecture seule. Déconnecte-toi et reconnecte-toi pour écrire.")
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
        let msg = ChatMessage(
            id: UUID().uuidString,
            userId: "system", userName: "system",
            displayName: "⚠️ Système",
            color: Color(hex: "fbbf24"), badges: [],
            tokens: [.text(text)],
            timestamp: Date(),
            isAction: false, isHighlight: false,
            isFirstMessage: false, replyTo: nil, replyBody: nil
        )
        messages.insert(msg, at: 0)
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
                tokens += await tokenizeText(String(text[currentIndex..<range.lowerBound]), channelId: channelId)
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
        var tokens: [MessageToken] = []
        for word in segment.components(separatedBy: " ") {
            guard !word.isEmpty else { continue }
            if word.hasPrefix("@") && word.count > 1 {
                tokens.append(.mention(String(word.dropFirst())))
            } else if let emote = await EmoteService.shared.resolve(name: word, channelId: channelId) {
                tokens.append(.emote(emote))
            } else {
                tokens.append(.text(word))
            }
        }
        return tokens
    }

    // MARK: – Badge parsing
    private func parseBadges(_ raw: String) -> [TwitchBadge] {
        guard !raw.isEmpty else { return [] }
        return raw.components(separatedBy: ",").compactMap { part in
            let kv = part.components(separatedBy: "/")
            guard kv.count == 2 else { return nil }
            return TwitchBadge(id: "\(kv[0])/\(kv[1])",
                               url: "https://static-cdn.jtvnw.net/badges/v1/\(kv[0])/\(kv[1])/2")
        }
    }

    // MARK: – Moderation
    private func handleClearChat(_ irc: IRCMessage) async {
        if let target = irc.params.last, !target.hasPrefix("#") {
            messages.removeAll { $0.userName == target }
            logger.warn("CHAT", "Messages supprimés pour \(target)")
        } else {
            messages.removeAll()
            logger.warn("CHAT", "Chat effacé par un modérateur")
        }
    }

    private func handleClearMsg(_ irc: IRCMessage) async {
        if let targetId = irc.tags["target-msg-id"] {
            messages.removeAll { $0.id == targetId }
        }
    }
}
