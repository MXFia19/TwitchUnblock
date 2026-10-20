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
    /// Barre d'état au-dessus des messages. Sans elle (paysage), les bandeaux
    /// (épinglé, sondages, raid…) restent, repliables : voir ChatView.noticesArea.
    var showsChrome = true
    /// Horodatage devant chaque message.
    var showsTimestamp = true
    var fontSize: CGFloat = 13
    /// Moitié de l'espace entre deux messages (marge haute et basse de chacun).
    var rowPadding: CGFloat = 4
    /// Badges et emotes suivent la taille du texte, puis ces facteurs : on peut
    /// vouloir de grosses emotes avec du petit texte, ou l'inverse.
    var badgeScale: CGFloat = 1
    var emoteScale: CGFloat = 1
    /// Fond transparent et texte ombré, pour rester lisible sur l'image.
    var translucent = false

    /// Repli quand aucun réglage n'est à portée (aperçus, feuilles isolées).
    static let standard = ChatStyle()

    var badgeHeight: CGFloat { (fontSize + 3) * badgeScale }
    var emoteHeight: CGFloat { (fontSize + 11) * emoteScale }
}

// MARK: – Emote
struct TwitchEmote: Identifiable, Hashable {
    let id: String
    let name: String
    let url: String
    var source: EmoteSource = .twitch
    /// Emote personnelle d'un abonné BTTV Pro (utilisable partout par lui seul).
    var personal = false
    // Infos déjà téléchargées avec les emotes BTTV, FFZ et 7TV, pour leur
    // fiche. Valeurs par défaut : les emotes Twitch (tag IRC) et celles du
    // chat.json d'une VOD téléchargée n'en ont pas.
    var scope: EmoteScope = .unknown
    /// Créateur de l'emote (BTTV partagée, FFZ, 7TV) ou chaîne qui l'a mise en ligne.
    var author: String? = nil
    /// 7TV : nom de l'emote avant que la chaîne la renomme.
    var originalName: String? = nil
    /// 7TV seulement : se pose par-dessus l'emote précédente (flags & 1).
    var zeroWidth = false
    /// Champ `modifier` de BTTV et FFZ (w!, ffzW…) : modifie une autre emote.
    /// Ce n'est pas un zero-width.
    var isModifier = false
    /// Plus grande image servie (fiche) : BTTV 3x, FFZ 4, 7TV 4x.
    var largeURL: String? = nil
    /// Sélecteur : emote d'abonné de la chaîne hors des jeux d'emotes du
    /// compte — grisée, et un toucher ne l'insère pas (EmoteService).
    var locked = false
}

enum EmoteSource: String {
    case twitch, bttv, ffz, seventv
}

/// Portée d'une emote tierce : de la chaîne, globale, ou personnelle (BTTV Pro).
enum EmoteScope {
    case global, channel, personal, unknown
}

// MARK: – Modes du salon
/// Ce qui limite qui peut écrire dans un chat, et les règles à accepter.
struct ChatRoomModes: Equatable {
    /// Minutes de suivi exigées (0 : suivre suffit) ; nil : pas de mode followers.
    var followersMinutes: Int? = nil
    var subsOnly = false
    var emoteOnly = false
    var slowSeconds = 0
    var uniqueChat = false
    var verifiedOnly = false

    var isEmpty: Bool {
        followersMinutes == nil && !subsOnly && !emoteOnly && slowSeconds == 0 && !uniqueChat && !verifiedOnly
    }

    /// « 10 min », « 1 h 30 min », « 1 j » dans la langue de l'app.
    static func duration(_ minutes: Int, lang: Lang) -> String {
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        f.allowedUnits = minutes >= 1440 ? [.day, .hour] : (minutes >= 60 ? [.hour, .minute] : [.minute])
        f.maximumUnitCount = 2
        var calendar = Calendar.current
        calendar.locale = Locale(identifier: lang.rawValue)
        f.calendar = calendar
        return f.string(from: TimeInterval(minutes * 60)) ?? "\(minutes) min"
    }
}

/// Règles du chat acceptées, par chaîne, sur cet appareil ; redemandées si
/// la chaîne les change.
enum ChatRules {
    private static let key = "chat_rules_ok"

    static func accepted(_ channel: String, rules: [String]) -> Bool {
        let saved = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        return saved[channel.lowercased()] == rules.joined(separator: "\n")
    }

    static func accept(_ channel: String, rules: [String]) {
        var saved = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        if saved.count > 300 { saved.removeAll() }
        saved[channel.lowercased()] = rules.joined(separator: "\n")
        UserDefaults.standard.set(saved, forKey: key)
    }
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
    /// GIF du clavier GIF de Twitch (tag `gifs`) : adresse GIPHY telle que
    /// reçue, et le texte qu'il remplace (« [… GIF by …] »).
    case gif(url: String, alt: String)

    var id: String {
        switch self {
        case .text(let t):    return "t_\(t.hashValue)"
        case .emote(let e):   return "e_\(e.id)"
        case .mention(let m): return "m_\(m)"
        case .link(let l):    return "l_\(l.hashValue)"
        case .gif(let u, _):  return "g_\(u.hashValue)"
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
    /// Message repêché dans l'historique à l'arrivée, pas reçu en direct : une
    /// petite horloge le signale, sinon on croit avoir raté la conversation.
    var isHistorical: Bool = false
    /// Supprimé par un modérateur mais conservé à l'écran (réglage).
    var isDeleted: Bool = false
    /// USERNOTICE : "raid" (raid entrant), "sub", "announcement", ou autre.
    var noticeKind: String? = nil
    /// Raid entrant : chaîne d'où vient le raid (lien « Voir la chaîne »).
    var raider: String? = nil
    /// Annonce : couleur choisie par le modérateur.
    var accent: Color? = nil
}

// MARK: – Tokenisation d'un segment de texte
/// Découpe un texte en jetons : liens, mentions, emotes tierces (BTTV/FFZ/7TV), texte.
/// Partagé par le chat live (IRC) et le chat des VODs. `userId` : auteur du
/// message, pour ses emotes personnelles BTTV Pro.
func tokenizeChatSegment(_ segment: String, channelId: String?, userId: String? = nil) async -> [MessageToken] {
    var tokens: [MessageToken] = []
    for word in segment.components(separatedBy: " ") {
        guard !word.isEmpty else { continue }
        let lower = word.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("www.")
            || isBareLink(lower) {
            tokens.append(.link(word))
        } else if word.hasPrefix("@") && word.count > 1 {
            tokens.append(.mention(String(word.dropFirst())))
        } else if let emote = await EmoteService.shared.resolve(name: word, channelId: channelId, userId: userId) {
            tokens.append(.emote(emote))
        } else {
            tokens.append(.text(word))
        }
    }
    return tokens
}

/// Lien sans « https:// » (« t.me/x », « discord.gg/abc ») : seulement les
/// extensions courantes, pour ne pas transformer « lol.xd » en lien.
func isBareLink(_ lower: String) -> Bool {
    lower.range(of: #"^[a-z0-9][a-z0-9-]*(\.[a-z0-9-]+)*\.(com|net|org|tv|gg|me|io|fr|be|ch|de|es|it|uk|co|app|dev|ly|link|to|ru|eu|xyz|shop|store)(/\S*)?$"#,
                options: .regularExpression) != nil
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
    var gifsRaw: String { tags["gifs"] ?? "" }
    var isReply: Bool { tags["reply-parent-msg-id"] != nil }
    var replyUser: String? { tags["reply-parent-display-name"] }
    var replyParentMsgId: String? { tags["reply-parent-msg-id"] }
    var replyThreadRootId: String? { tags["reply-thread-parent-msg-id"] ?? tags["reply-parent-msg-id"] }

    /// Corps du message auquel on répond (Twitch échappe les espaces en \s)
    var replyParentBody: String? {
        tags["reply-parent-msg-body"].map(ircUnescape)
    }
}
