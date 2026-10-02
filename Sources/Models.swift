import Foundation

// MARK: – API Models
typealias QualityLinks = [String: String]

struct LiveData {
    var title: String
    var game: String
    var thumbnail: String
    var avatar: String?
    var userId: String?          // ← NEW : ID Twitch du canal (pour charger les emotes)
    var links: QualityLinks?
    var viewerCount: Int = 0
    var startedAt: Date? = nil
    /// ID du VOD en cours d'enregistrement (DVR) : permet de rembobiner le live.
    /// nil si le streamer n'archive pas ses lives.
    var dvrVideoId: String? = nil
    var error: String?
}

struct VodData: Identifiable {
    let id: String
    let title: String
    let previewThumbnailURL: String
    let publishedAt: String
    let lengthSeconds: Int
}

/// Clip d'une chaîne (liste de la page chaîne).
struct ClipData: Identifiable {
    let id: String            // slug
    let title: String
    let thumbnailURL: String
    let viewCount: Int
    let durationSeconds: Int
    let createdAt: String
    let curator: String?
}

/// Clip prêt à lire : MP4 signés par qualité, et la VOD d'origine (chat).
struct ClipPlayback {
    let links: QualityLinks
    let title: String
    let broadcasterLogin: String?
    let broadcasterName: String?
    let vodId: String?
    let vodOffset: Double?
}

struct ChannelVideosData {
    let videos: [VodData]
    let avatar: String?
    let error: String?
}

struct M3U8Data {
    let links: QualityLinks
    let error: String?
}

struct TwitchStream: Identifiable {
    let id: String          // user_id
    let userLogin: String
    let userName: String
    let title: String
    let gameName: String
    let viewerCount: Int
    let thumbnailURL: String
}

/// Catégorie / jeu Twitch (onglet Catégories).
struct TwitchCategory: Identifiable, Hashable {
    let id: String          // game_id
    let name: String
    /// URL de la jaquette, avec les gabarits {width}/{height} déjà remplacés.
    let boxArtURL: String
    /// Audience totale de la catégorie. Absente à la première réponse : Helix
    /// ne la donne pas, elle est complétée par une requête GQL séparée.
    var viewers: Int? = nil
}

struct TwitchUser {
    let id: String
    let login: String
    let displayName: String
    let profileImageURL: String
}

struct AutocompleteSuggestion: Identifiable {
    let id = UUID()
    let login: String
    let name: String
    let avatar: String?
}

struct VodMeta {
    let title: String
    let streamer: String
    let thumb: String
    var lengthSeconds: Int = 0
    var viewCount: Int = 0
}

// MARK: – App Models
struct HistoryItem: Codable, Identifiable {
    var id: String { term }
    let term: String
    let type: HistoryType
    let display: String
    let thumb: String?
    let streamer: String?
    let addedAt: Double

    enum HistoryType: String, Codable { case vod, channel }
}

// Décodage tolérant : la sauvegarde est partagée avec le site, dont les
// anciens éléments n'ont pas de date d'ajout. Exiger `addedAt` faisait
// échouer le décodage de TOUTE la liste au premier élément venu du site.
// Placé en extension pour garder l'initialiseur par membres.
extension HistoryItem {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        term     = try c.decode(String.self, forKey: .term)
        type     = try c.decode(HistoryType.self, forKey: .type)
        display  = (try? c.decodeIfPresent(String.self, forKey: .display)) ?? term
        thumb    = try? c.decodeIfPresent(String.self, forKey: .thumb)
        streamer = try? c.decodeIfPresent(String.self, forKey: .streamer)
        addedAt  = (try? c.decodeIfPresent(Double.self, forKey: .addedAt)) ?? 0
    }
}

/// Élément de liste qui ne fait pas échouer toute la liste s'il est illisible.
struct LossyDecodable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

// MARK: – Player Mode
enum PlayerMode {
    case vod(id: String, title: String?, thumb: String?, streamer: String?)
    case live(channelName: String)
    case clip(slug: String, title: String?)
}

// MARK: – Log
enum LogLevel: String, CaseIterable {
    case info, success, warn, error, debug

    var icon: String {
        switch self {
        case .info:    return "ℹ"
        case .success: return "✓"
        case .warn:    return "⚠"
        case .error:   return "✕"
        case .debug:   return "◎"
        }
    }
    var color: String {
        switch self {
        case .info:    return "60a5fa"
        case .success: return "4ade80"
        case .warn:    return "fbbf24"
        case .error:   return "f87171"
        case .debug:   return "a78bfa"
        }
    }
}

struct LogEntry: Identifiable {
    let id: Int
    let timestamp: String
    let level: LogLevel
    let category: String
    let message: String
    let detail: String?
}
