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

    var id: String {
        switch self {
        case .text(let t):    return "t_\(t.hashValue)"
        case .emote(let e):   return "e_\(e.id)"
        case .mention(let m): return "m_\(m)"
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

    /// Corps du message auquel on répond (Twitch échappe les espaces en \s)
    var replyParentBody: String? {
        tags["reply-parent-msg-body"]?
            .replacingOccurrences(of: "\\s", with: " ")
            .replacingOccurrences(of: "\\:", with: ";")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }
}
