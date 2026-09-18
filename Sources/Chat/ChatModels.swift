import Foundation
import SwiftUI

// MARK: – Place du chat en paysage
/// Trois états, parcourus par le même bouton du lecteur.
enum LandscapeChat: String, CaseIterable {
    /// Colonne à droite : l'image rétrécit d'autant.
    case column
    /// Superposé à l'image, fond transparent : l'image garde toute la largeur.
    case overlay
    /// Replié : l'image seule.
    case hidden

    var next: LandscapeChat {
        switch self {
        case .column:  return .overlay
        case .overlay: return .hidden
        case .hidden:  return .column
        }
    }

    /// Trois symboles sûrs depuis iOS 13 : un nom inconnu ne planterait pas mais
    /// laisserait un bouton vide.
    var icon: String {
        switch self {
        case .column:  return "sidebar.right"
        case .overlay: return "rectangle.on.rectangle"
        case .hidden:  return "bubble.left"
        }
    }

    /// Clé de traduction du libellé affiché brièvement au changement.
    var labelKey: String {
        switch self {
        case .column:  return "chat_mode_column"
        case .overlay: return "chat_mode_overlay"
        case .hidden:  return "chat_mode_hidden"
        }
    }
}

// MARK: – Présentation du chat
/// Regroupe ce qui change entre le chat plein cadre, la colonne étroite du
/// paysage et le calque posé sur l'image. Passer un seul objet évite de
/// promener cinq drapeaux jusqu'aux lignes de message.
struct ChatStyle: Equatable {
    /// Barre d'état, épinglés, sondages, raids — tout le décor autour des messages.
    var showsChrome = true
    /// Horodatage devant chaque message.
    var showsTimestamp = true
    var fontSize: CGFloat = 13
    var rowPadding: CGFloat = 4
    /// Fond transparent et texte ombré, pour rester lisible sur l'image.
    var translucent = false

    static let standard = ChatStyle()

    /// Colonne étroite : le décor mange la moitié de la hauteur utile, on le
    /// retire et on resserre les lignes.
    static let compact = ChatStyle(showsChrome: false, showsTimestamp: false,
                                   fontSize: 12, rowPadding: 2)

    /// Posé sur la vidéo : compact, sans fond, avec une ombre portée.
    static let overlay = ChatStyle(showsChrome: false, showsTimestamp: false,
                                   fontSize: 12, rowPadding: 2, translucent: true)
}

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

    /// Pseudo extrait du préfixe IRC `nick!user@host` (JOIN / PART n'ont pas de tags).
    var prefixNick: String? {
        guard let prefix, !prefix.isEmpty else { return nil }
        let nick = prefix.split(separator: "!").first.map(String.init) ?? prefix
        return nick.contains("@") ? nil : nick.lowercased()
    }

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
