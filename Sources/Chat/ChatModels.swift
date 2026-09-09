import Foundation
import SwiftUI

// MARK: – Emote
struct TwitchEmote: Identifiable, Hashable {
    let id: String
    let name: String
    let url: String
    var source: EmoteSource = .twitch
}

enum EmoteSource: String {
    case twitch, bttv, ffz, seventv
}

// MARK: – Badge
struct TwitchBadge: Identifiable, Hashable {
    let id: String   // e.g. "moderator/1"
    let url: String
}

// MARK: – Chat Message token
enum MessageToken: Identifiable {
    case text(String)
    case emote(TwitchEmote)
    case mention(String)
    case link(String)

    var id: String {
        switch self {
        case .text(let t):    return "t_\(t.hashValue)"
        case .emote(let e):   return "e_\(e.id)"
        case .mention(let m): return "m_\(m)"
        case .link(let l):    return "l_\(l.hashValue)"
        }
    }
}

// MARK: – Chat Message
struct ChatMessage: Identifiable {
    let id: String
    let userId: String
    let userName: String
    let displayName: String
    let color: Color
    let badges: [TwitchBadge]
    let tokens: [MessageToken]
    let timestamp: Date
    var isAction: Bool = false
    var isHighlight: Bool = false
    var isFirstMessage: Bool = false   // ← tag Twitch "first-msg=1"
    var replyTo: String? = nil         // display name de l'auteur du message parent
    var replyBody: String? = nil       // ← corps du message parent (reply-parent-msg-body)
    var systemMsg: String? = nil       // ← USERNOTICE (abonnement, série de visionnage…)
    // Threading (réponses)
    var parentMsgId: String? = nil     // reply-parent-msg-id (message auquel on répond)
    var threadRootId: String? = nil    // reply-thread-parent-msg-id (racine du fil)
    /// Chat de VOD : horodatage relatif à la vidéo (ex: "1:23:45") au lieu de l'heure.
    var vodOffsetLabel: String? = nil
}

// MARK: – Tokenisation d'un segment de texte
/// Découpe un texte en jetons : liens, mentions, emotes tierces (BTTV/FFZ/7TV), texte.
/// Partagé par le chat live (IRC) et le chat des VODs.
func tokenizeChatSegment(_ segment: String, channelId: String?) async -> [MessageToken] {
    var tokens: [MessageToken] = []
    for word in segment.components(separatedBy: " ") {
        guard !word.isEmpty else { continue }
        let lower = word.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("www.") {
            tokens.append(.link(word))
        } else if word.hasPrefix("@") && word.count > 1 {
            tokens.append(.mention(String(word.dropFirst())))
        } else if let emote = await EmoteService.shared.resolve(name: word, channelId: channelId) {
            tokens.append(.emote(emote))
        } else {
            tokens.append(.text(word))
        }
    }
    return tokens
}

// MARK: – Déséchappement IRCv3 (tags system-msg, etc.)
func ircUnescape(_ s: String) -> String {
    var out = ""
    var it = s.makeIterator()
    var pending: Character? = nil
    func next() -> Character? { pending != nil ? { let c = pending; pending = nil; return c }() : it.next() }
    while let c = next() {
        if c == "\\" {
            switch next() {
            case "s": out.append(" ")
            case ":": out.append(";")
            case "r": out.append("\r")
            case "n": out.append("\n")
            case "\\": out.append("\\")
            case let other?: out.append(other)
            case nil: break
            }
        } else { out.append(c) }
    }
    return out
}

// MARK: – IRC raw
struct IRCMessage {
    let raw: String
    let tags: [String: String]
    let command: String
    let params: [String]
    let prefix: String?

    var channel: String? { params.first?.hasPrefix("#") == true ? String(params[0].dropFirst()) : nil }
    var text: String? { params.count > 1 ? params[1] : nil }
    var displayName: String { tags["display-name"] ?? tags["login"] ?? "" }
    var userId: String { tags["user-id"] ?? "" }
    var msgId: String { tags["id"] ?? UUID().uuidString }
    var color: String { tags["color"] ?? "" }
    var badgesRaw: String { tags["badges"] ?? "" }
    var emotesRaw: String { tags["emotes"] ?? "" }
    var isReply: Bool { tags["reply-parent-msg-id"] != nil }
    var replyUser: String? { tags["reply-parent-display-name"] }
    var replyParentMsgId: String? { tags["reply-parent-msg-id"] }
    var replyThreadRootId: String? { tags["reply-thread-parent-msg-id"] ?? tags["reply-parent-msg-id"] }

    /// Corps du message auquel on répond (Twitch échappe les espaces en \s)
    var replyParentBody: String? {
        tags["reply-parent-msg-body"]?
            .replacingOccurrences(of: "\\s", with: " ")
            .replacingOccurrences(of: "\\:", with: ";")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }
}
