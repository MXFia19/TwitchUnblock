import Foundation
import Combine
import SwiftUI

@MainActor
final class ChatService: NSObject, ObservableObject {

    @Published var messages: [ChatMessage] = []
    @Published var isConnected    = false
    @Published var isAuthenticated = false   // ← vrai quand connecté avec un vrai compte
    @Published var channelId: String? = nil

    private var webSocketTask: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .default)
    private var channelName = ""
    private var pingTimer: Timer?
    private let maxMessages = 200

    // MARK: – Connect
    /// - Parameters:
    ///   - token: OAuth token (oauth:xxx). Nil → connexion anonyme justinfan.
    ///   - login: Login Twitch lowercase (ex: "squeezie"). Requis pour envoyer des messages.
    func connect(channel: String, token: String? = nil, login: String? = nil) {
        disconnect()
        channelName = channel.lowercased()
        logger.info("CHAT", "Connexion IRC → #\(channelName)")

        guard let url = URL(string: "wss://irc-ws.chat.twitch.tv:443") else { return }
        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()

        Task {
            // Capabilities Twitch
            await send("CAP REQ :twitch.tv/tags twitch.tv/commands twitch.tv/membership")

            // Auth : on utilise le vrai login si disponible, sinon justinfan anonyme
            if let token = token, let login = login, !login.isEmpty {
                await send("PASS oauth:\(token)")
                await send("NICK \(login.lowercased())")
                isAuthenticated = true
                logger.success("CHAT", "Connecté en tant que \(login.lowercased())")
            } else {
                await send("NICK justinfan\(Int.random(in: 10000...99999))")
                isAuthenticated = false
                logger.info("CHAT", "Connecté en mode anonyme (justinfan)")
            }

            await send("JOIN #\(channelName)")
            await receive()
        }

        // Ping toutes les 4 min pour maintenir la connexion
        pingTimer = Timer.scheduledTimer(withTimeInterval: 240, repeats: true) { [weak self] _ in
            Task { await self?.send("PING :tmi.twitch.tv") }
        }
    }

    // MARK: – Disconnect
    func disconnect() {
        pingTimer?.invalidate()
        pingTimer = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        isConnected    = false
        isAuthenticated = false
        logger.info("CHAT", "IRC déconnecté")
    }

    // MARK: – Send a message to the channel
    func sendMessage(_ text: String) async {
        let sanitized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty,
              sanitized.count <= 500,
              isAuthenticated,
              isConnected else {
            logger.warn("CHAT", "sendMessage bloqué", "auth:\(isAuthenticated) connected:\(isConnected) len:\(text.count)")
            return
        }
        await send("PRIVMSG #\(channelName) :\(sanitized)")
        logger.info("CHAT", "Message envoyé → #\(channelName)", String(sanitized.prefix(80)))
    }

    // MARK: – Send raw IRC line
    private func send(_ text: String) async {
        guard let task = webSocketTask else { return }
        do {
            try await task.send(.string(text + "\r\n"))
        } catch {
            logger.warn("CHAT", "Erreur envoi IRC", error.localizedDescription)
        }
    }

    // MARK: – Receive loop
    private func receive() async {
        guard let task = webSocketTask else { return }
        do {
            let msg = try await task.receive()
            switch msg {
            case .string(let text):
                await handleRaw(text)
            case .data(let data):
                if let text = String(data: data, encoding: .utf8) {
                    await handleRaw(text)
                }
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
                logger.success("CHAT", "IRC connecté à #\(channelName)")
            case "PING":
                await send("PONG :tmi.twitch.tv")
            case "PRIVMSG":
                await handlePrivmsg(irc)
            case "NOTICE":
                await handleNotice(irc)
            case "CLEARCHAT":
                await handleClearChat(irc)
            case "CLEARMSG":
                await handleClearMsg(irc)
            case "USERSTATE", "GLOBALUSERSTATE", "ROOMSTATE", "USERNOTICE":
                break
            default:
                break
            }
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

        let hexColor = irc.color.isEmpty ? "9146ff" : irc.color.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let userColor = Color(hex: hexColor)

        let emoteRanges = IRCParser.parseEmoteRanges(raw: irc.emotesRaw, text: text)
        var twitchEmotesByRange: [Range<String.Index>: TwitchEmote] = [:]
        for (emoteId, range) in emoteRanges {
            let emoteName = String(text[range])
            let emote = TwitchEmote(
                id: emoteId,
                name: emoteName,
                url: "https://static-cdn.jtvnw.net/emoticons/v2/\(emoteId)/default/dark/2.0",
                source: .twitch
            )
            await EmoteService.shared.registerTwitchEmote(id: emoteId, name: emoteName)
            twitchEmotesByRange[range] = emote
        }

        let tokens = await tokenize(text: text, twitchRanges: twitchEmotesByRange, channelId: channelId)
        let isHighlight = irc.tags["msg-id"] == "highlighted-message"

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
            isHighlight: isHighlight,
            replyTo: irc.replyUser
        )

        messages.insert(message, at: 0)
        if messages.count > maxMessages {
            messages = Array(messages.prefix(maxMessages))
        }
    }

    // MARK: – NOTICE (ban, timeout, sub-only…)
    private func handleNotice(_ irc: IRCMessage) async {
        guard let msgId = irc.tags["msg-id"], let text = irc.text else { return }
        let chatErrorIds: Set<String> = [
            "msg_banned", "msg_timedout", "msg_subsonly", "msg_followersonly",
            "msg_verified_email", "msg_emotesonly", "msg_slowmode", "msg_duplicate",
            "no_permission", "unrecognized_cmd"
        ]
        if chatErrorIds.contains(msgId) {
            logger.warn("CHAT", "NOTICE \(msgId)", text)
            // On injecte le message d'erreur comme système dans le chat
            let sysMsg = ChatMessage(
                id: UUID().uuidString,
                userId: "system",
                userName: "system",
                displayName: "⚠️ Système",
                color: Color(hex: "fbbf24"),
                badges: [],
                tokens: [.text(text)],
                timestamp: Date(),
                isAction: false,
                isHighlight: false,
                replyTo: nil
            )
            messages.insert(sysMsg, at: 0)
        }
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
                let segment = String(text[currentIndex..<range.lowerBound])
                tokens += await tokenizeText(segment, channelId: channelId)
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
