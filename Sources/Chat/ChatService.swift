import Foundation
import Combine
import SwiftUI

@MainActor
final class ChatService: NSObject, ObservableObject {

    @Published var messages: [ChatMessage] = []
    @Published var isConnected = false
    @Published var channelId: String? = nil

    private var webSocketTask: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .default)
    private var channelName = ""
    private var pingTimer: Timer?
    private let maxMessages = 200

    // MARK: – Connect
    func connect(channel: String, token: String? = nil) {
        disconnect()
        channelName = channel.lowercased()
        logger.info("CHAT", "Connexion IRC → #\(channelName)")

        guard let url = URL(string: "wss://irc-ws.chat.twitch.tv:443") else { return }
        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()

        Task {
            // Capability requests
            await send("CAP REQ :twitch.tv/tags twitch.tv/commands twitch.tv/membership")
            if let token = token {
                await send("PASS oauth:\(token)")
                await send("NICK justinfan\(Int.random(in: 10000...99999))")
            } else {
                await send("NICK justinfan\(Int.random(in: 10000...99999))")
            }
            await send("JOIN #\(channelName)")
            await receive()
        }

        // Ping every 4 min to keep alive
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
        isConnected = false
        logger.info("CHAT", "IRC déconnecté")
    }

    // MARK: – Send
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
            // Continue loop
            if webSocketTask != nil { await receive() }
        } catch {
            if isConnected {
                logger.error("CHAT", "Connexion IRC perdue", error.localizedDescription)
                isConnected = false
            }
        }
    }

    // MARK: – Handle raw lines
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
            case "CLEARCHAT":
                await handleClearChat(irc)
            case "CLEARMSG":
                await handleClearMsg(irc)
            case "USERSTATE", "ROOMSTATE", "NOTICE", "USERNOTICE":
                break
            default:
                break
            }
        }
    }

    // MARK: – PRIVMSG → ChatMessage
    private func handlePrivmsg(_ irc: IRCMessage) async {
        guard var text = irc.text else { return }

        // /me action
        var isAction = false
        if text.hasPrefix("\u{0001}ACTION ") && text.hasSuffix("\u{0001}") {
            text = String(text.dropFirst(8).dropLast(1))
            isAction = true
        }

        // User color
        let hexColor = irc.color.isEmpty ? "9146ff" : irc.color.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let userColor = Color(hex: hexColor)

        // Twitch emotes from IRC tag
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

        // Tokenize: split text into text+emote tokens
        let tokens = await tokenize(text: text, twitchRanges: twitchEmotesByRange, channelId: channelId)

        // Highlight: mentioned ?
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

    // MARK: – Tokenizer
    private func tokenize(
        text: String,
        twitchRanges: [Range<String.Index>: TwitchEmote],
        channelId: String?
    ) async -> [MessageToken] {
        var tokens: [MessageToken] = []
        var currentIndex = text.startIndex

        // Sort ranges
        let sortedRanges = twitchRanges.keys.sorted { $0.lowerBound < $1.lowerBound }

        for range in sortedRanges {
            guard range.lowerBound >= currentIndex else { continue }

            // Text before emote
            if range.lowerBound > currentIndex {
                let segment = String(text[currentIndex..<range.lowerBound])
                tokens += await tokenizeText(segment, channelId: channelId)
            }
            // Emote token
            if let emote = twitchRanges[range] {
                tokens.append(.emote(emote))
            }
            currentIndex = range.upperBound
        }

        // Remaining text
        if currentIndex < text.endIndex {
            let rest = String(text[currentIndex...])
            tokens += await tokenizeText(rest, channelId: channelId)
        }

        return tokens
    }

    // ✨ CORRECTION TOKENIZER : Oblige à séparer mot par mot pour que le Layout iOS 16 puisse retourner à la ligne !
    private func tokenizeText(_ segment: String, channelId: String?) async -> [MessageToken] {
        var tokens: [MessageToken] = []
        let words = segment.components(separatedBy: " ")

        for word in words {
            guard !word.isEmpty else { continue }
            
            if word.hasPrefix("@") && word.count > 1 {
                tokens.append(.mention(String(word.dropFirst())))
                continue
            }
            if let emote = await EmoteService.shared.resolve(name: word, channelId: channelId) {
                tokens.append(.emote(emote))
            } else {
                tokens.append(.text(word)) // Ajoute chaque mot séparément !
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
            let name = kv[0]
            let version = kv[1]
            // Standard Twitch badge URL (best effort without API call)
            let url = "https://static-cdn.jtvnw.net/badges/v1/\(name)/\(version)/2"
            return TwitchBadge(id: "\(name)/\(version)", url: url)
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
