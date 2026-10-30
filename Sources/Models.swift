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
    /// Source qui a servi le direct (« account », « as », « al », « eu »,
    /// « twitch », « worker ») ; « account » : le compte, sans pub.
    var source: String? = nil
    /// Hauteur, cadence et débit de chaque qualité (mêmes clés que `links`) ;
    /// vide quand la source ne les donne pas.
    var variants: [String: VariantInfo] = [:]
    /// La session web donnée à getLive a été refusée par Twitch (401/403).
    var webSessionExpired: Bool = false
    /// Abonné à la chaîne d'après le jeton du compte (nil : pas demandé).
    var subscriber: Bool? = nil
    /// Qualités supérieures (HigherQualities) d'un compte que Twitch ne sert
    /// pas sans pub : sa liste maîtresse quand elle dépasse 1080p, à côté de
    /// la source habituelle (`links`), gardée pour ses pauses pub (iPhone,
    /// MainTabView). nil sinon.
    var hqAccountLinks: QualityLinks? = nil
    var hqAccountVariants: [String: VariantInfo] = [:]
    /// `links` vient du compte alors que Twitch lui sert des pubs (qualités
    /// supérieures, aucune source habituelle n'a répondu).
    var accountAds: Bool = false
}

/// Ce que la liste maîtresse dit d'une variante (RESOLUTION, FRAME-RATE,
/// BANDWIDTH), ou ce qu'en renvoie le Worker (`variants` : h, fps, bw).
/// « Source » ne dit pas sa hauteur dans son nom (1080p60, 720p60, 936p…) :
/// sans elle, une qualité préférée en 720p se tromperait de variante.
struct VariantInfo: Equatable {
    /// 0 pour l'audio seul.
    let height: Int
    let fps: Double
    let bandwidth: Int
}

struct VodData: Identifiable {
    let id: String
    let title: String
    let previewThumbnailURL: String
    let publishedAt: String
    let lengthSeconds: Int
}

/// Playlist (collection) d'une chaîne et ses vidéos.
struct PlaylistData: Identifiable {
    let id: String
    let title: String
    let description: String
    let total: Int
    let videos: [VodData]
}

/// Chapitre d'une VOD (changement de jeu).
struct VodChapter: Identifiable, Hashable {
    var id: Double { start }
    let start: Double      // secondes
    let duration: Double   // secondes
    let title: String
}

/// Passage d'une VOD dont Twitch a coupé le son (musique protégée).
struct MutedRange: Identifiable, Hashable {
    var id: Double { start }
    let start: Double      // secondes
    let end: Double

    func contains(_ t: Double) -> Bool { t >= start && t < end }
}

/// Repères d'une VOD : chapitres, passages coupés, date de diffusion.
struct VodMarkers {
    var chapters: [VodChapter] = []
    var muted: [MutedRange] = []
    var createdAt: Date? = nil
    /// Début de la diffusion, pour une archive de direct seulement (pas un
    /// highlight ni un upload) : l'heure réelle d'un instant de la VOD.
    var broadcastStart: Date? = nil
    /// Durée de la VOD au moment de la lecture (secondes, 0 si inconnue).
    var length: Double = 0
}

/// Clip du fil Découvrir : un clip populaire d'une chaîne du top.
struct FeedClip: Identifiable, Equatable {
    let id: String            // slug
    let title: String
    let thumbnailURL: String
    let viewCount: Int
    let durationSeconds: Int
    let game: String
    let login: String
    let channelId: String
    let channelName: String
    let avatar: String?
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

/// Fiche « À propos » d'une chaîne, comme sous le lecteur de Twitch :
/// description, followers, réseaux et panneaux (image, lien, texte).
struct ChannelAbout {
    struct Social: Identifiable {
        let id: String
        let name: String
        let title: String
        let url: URL
    }
    struct Panel: Identifiable {
        let id: String
        let title: String
        let imageURL: URL?
        let linkURL: URL?
        /// Markdown simple (liens, gras, titres, listes).
        let text: String
    }
    let description: String
    let followers: Int?
    let socials: [Social]
    let panels: [Panel]
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
    var variants: [String: VariantInfo] = [:]
}

struct TwitchStream: Identifiable {
    let id: String          // user_id
    let userLogin: String
    let userName: String
    let title: String
    let gameName: String
    let viewerCount: Int
    let thumbnailURL: String
    /// Tags de la chaîne, langue comprise (« English », « DropsEnabled »…).
    var tags: [String] = []
    /// Identifiant de la catégorie (game_id) : le nom vient de Helix ou de
    /// GQL selon le compte, seul l'identifiant sert à masquer une catégorie.
    /// Vide si la requête ne le demande pas (listes des suivis).
    var gameId: String = ""
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
    /// En live : nombre de spectateurs et jeu (nil hors live).
    var viewers: Int? = nil
    var game: String? = nil
    /// Nombre de followers (résultats de la recherche), nil s'il manque.
    var followers: Int? = nil
    var isLive: Bool { viewers != nil }
}

/// VOD trouvée par la recherche : la vidéo, et la chaîne qui l'a diffusée.
struct SearchVod: Identifiable {
    let vod: VodData
    let login: String
    let name: String
    /// Catégorie de la VOD (masquage), vide si Twitch ne la donne pas.
    var gameId: String = ""
    var id: String { vod.id }
}

/// Créneau du planning d'une chaîne.
struct ScheduleSegment: Identifiable {
    let id: String
    let start: Date
    /// nil : fin non précisée par le streamer.
    let end: Date?
    let title: String
    /// Catégorie prévue, vide si aucune.
    let category: String
    /// Créneau répété chaque semaine.
    var recurring: Bool
    /// Annulé (par le streamer, ou pendant ses vacances).
    var canceled = false
}

/// Vacances annoncées dans le planning d'une chaîne.
struct ScheduleVacation {
    let start: Date
    let end: Date
}

/// Planning d'une chaîne : ses prochains créneaux, et ses vacances si elle
/// en annonce. Vide : la chaîne n'a pas de planning.
struct ChannelSchedule {
    /// Du plus proche au plus lointain.
    let segments: [ScheduleSegment]
    var vacation: ScheduleVacation? = nil

    static let empty = ChannelSchedule(segments: [])

    /// Créneaux pas encore finis (une heure comptée sans fin connue).
    func upcoming(at now: Date = Date()) -> [ScheduleSegment] {
        segments.filter { ($0.end ?? $0.start.addingTimeInterval(3600)) > now }
    }
    /// Prochain live maintenu (ni annulé ni fini).
    func next(at now: Date = Date()) -> ScheduleSegment? {
        upcoming(at: now).first { !$0.canceled }
    }
    /// Vacances en cours ou à venir.
    func activeVacation(at now: Date = Date()) -> ScheduleVacation? {
        guard let v = vacation, v.end > now else { return nil }
        return v
    }
    /// Rien à montrer : ni créneau à venir, ni vacances.
    func isEmpty(at now: Date = Date()) -> Bool {
        upcoming(at: now).isEmpty && activeVacation(at: now) == nil
    }
}

struct VodMeta {
    let title: String
    let streamer: String
    let thumb: String
    var lengthSeconds: Int = 0
    var viewCount: Int = 0
    /// Login de la chaîne (vide si Twitch ne l'a pas donné) : `streamer` est
    /// le nom affiché.
    var login: String = ""
}

// MARK: – App Models
struct HistoryItem: Codable, Identifiable, Equatable {
    var id: String { term }
    let term: String
    let type: HistoryType
    let display: String
    let thumb: String?
    let streamer: String?
    let addedAt: Double
    /// Photo d'une chaîne, mise par le site : gardée et renvoyée telle
    /// quelle, sinon un envoi de l'app la faisait disparaître du site.
    var avatar: String? = nil

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
        avatar   = try? c.decodeIfPresent(String.self, forKey: .avatar)
    }
}

/// Élément de liste qui ne fait pas échouer toute la liste s'il est illisible.
struct LossyDecodable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

// MARK: – Récupération de VODs supprimées
/// Une diffusion passée listée par la source externe (voir VodRecoveryService).
/// `streamID` + `startedAt` suffisent à reconstruire le dossier CDN de sa VOD.
struct RecoverableStream: Identifiable {
    var id: String { streamID }
    let streamID: String
    let login: String
    let startedAt: Date
    let title: String
    let game: String
    let maxViews: Int
    /// Durée en secondes, 0 si inconnue (direct en cours, source muette).
    var duration: Int = 0
}

/// Une VOD supprimée dont les liens ont été reconstruits et validés : prête à lire.
struct RecoveredVod {
    let streamID: String
    let title: String
    let streamer: String
    let links: QualityLinks
}

// MARK: – Player Mode
enum PlayerMode {
    case vod(id: String, title: String?, thumb: String?, streamer: String?)
    case live(channelName: String)
    case clip(slug: String, title: String?)
    /// VOD supprimée récupérée : liens déjà résolus, aucune requête de lecture.
    case recovered(RecoveredVod)
}

// MARK: – Log
enum LogLevel: String, CaseIterable, Codable {
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

/// Une ligne du journal. Gardée dans un fichier (journal relu au lancement
/// suivant) ; `repeats` : même ligne arrivée plusieurs fois de suite.
struct LogEntry: Identifiable, Codable {
    let id: Int
    var timestamp: String
    let level: LogLevel
    let category: String
    let message: String
    let detail: String?
    var repeats = 1
}
