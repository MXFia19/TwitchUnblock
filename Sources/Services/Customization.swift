import Foundation

/// Personnalisation de l'app (Réglages → Personnaliser) : onglets, accueil,
/// boutons du lecteur, onglets de la page d'une chaîne. Gardée en JSON
/// (« cfg_customization ») et dans la sauvegarde. Lue avec tolérance : un
/// élément inconnu (version plus récente) est ignoré, un nouvel élément
/// s'ajoute à la fin, une clé absente garde sa valeur par défaut — l'ordre
/// choisi n'est jamais perdu.
struct UICustomization: Codable, Equatable {
    var tabOrder: [String] = UICustomization.defaultTabs
    var hiddenTabs: [String] = []
    var launchTab: String = "home"
    var homeOrder: [String] = UICustomization.defaultHome
    var hiddenHome: [String] = []
    /// Directs des chaînes épinglées (en tête des Suivies) triés entre eux
    /// par spectateurs ; sinon dans l'ordre d'épinglage.
    var pinnedByViewers: Bool = true
    var playerOrder: [String] = UICustomization.defaultPlayer
    /// Minuterie, multi-live et rembobiner : dans le menu ⋯ au départ,
    /// à faire apparaître dans la barre si on veut.
    var hiddenPlayer: [String] = ["sleep", "multi", "rewind"]
    var channelTabOrder: [String] = UICustomization.defaultChannelTabs
    var hiddenChannelTabs: [String] = []
    /// Catégories suivies (Accueil → Catégories → Suivies) : jaquettes plus
    /// petites, 3 par ligne (4 sur iPad) ; sinon 2, comme les autres grilles.
    var compactFollowedCategories: Bool = false
    /// Leur ordre : les plus regardées d'abord (comme Twitch), ou de A à Z.
    var followedCategoriesSort: FollowedCategorySort = .viewers
    /// « Sans compte Twitch » : ce qui demande un compte ou invite à se
    /// connecter est masqué (voir AppStore.accountHidden) — demande de joey.
    var hideAccount: Bool = false

    static let defaultTabs = ["home", "discover", "search", "library"]
    /// Onglets des lives de l'accueil (Suivies, Top, Hors ligne).
    static let defaultHome = ["followed", "top", "offline"]
    /// Cartes du haut de l'accueil (« continue » : Continuer à regarder) et
    /// onglet Catégories : masquables.
    static let homeCards = ["announcement", "poll", "login", "web", "continue", "categories"]
    /// Boutons de la barre du bas du lecteur, dans l'ordre par défaut.
    /// AirPlay (« airplay », en haut) se masque seulement.
    static let defaultPlayer = ["mute", "pip", "refresh", "chat", "rotate", "sleep", "multi", "rewind"]
    /// Onglets de la page d'une chaîne (VODs, Highlights, Playlists, Clips,
    /// Planning, À propos). Le planning n'apparaît que si la chaîne en a un.
    static let defaultChannelTabs = ["vods", "highlights", "playlists", "clips", "schedule", "about"]

    init() {}

    /// Celle gardée dans les réglages (« cfg_customization »), s'il y en a une.
    static func saved(_ ud: UserDefaults = .standard) -> UICustomization? {
        guard let data = ud.data(forKey: "cfg_customization") else { return nil }
        return try? JSONDecoder().decode(UICustomization.self, from: data)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tabOrder     = (try? c.decodeIfPresent([String].self, forKey: .tabOrder)) ?? Self.defaultTabs
        hiddenTabs   = (try? c.decodeIfPresent([String].self, forKey: .hiddenTabs)) ?? []
        launchTab    = (try? c.decodeIfPresent(String.self, forKey: .launchTab)) ?? "home"
        homeOrder    = (try? c.decodeIfPresent([String].self, forKey: .homeOrder)) ?? Self.defaultHome
        hiddenHome   = (try? c.decodeIfPresent([String].self, forKey: .hiddenHome)) ?? []
        pinnedByViewers = (try? c.decodeIfPresent(Bool.self, forKey: .pinnedByViewers)) ?? true
        playerOrder  = (try? c.decodeIfPresent([String].self, forKey: .playerOrder)) ?? Self.defaultPlayer
        hiddenPlayer = (try? c.decodeIfPresent([String].self, forKey: .hiddenPlayer)) ?? ["sleep", "multi", "rewind"]
        channelTabOrder   = (try? c.decodeIfPresent([String].self, forKey: .channelTabOrder)) ?? Self.defaultChannelTabs
        hiddenChannelTabs = (try? c.decodeIfPresent([String].self, forKey: .hiddenChannelTabs)) ?? []
        compactFollowedCategories = (try? c.decodeIfPresent(Bool.self, forKey: .compactFollowedCategories)) ?? false
        // Ordre inconnu (version plus récente) : celui par défaut.
        followedCategoriesSort = (try? c.decodeIfPresent(FollowedCategorySort.self, forKey: .followedCategoriesSort)) ?? .viewers
        hideAccount = (try? c.decodeIfPresent(Bool.self, forKey: .hideAccount)) ?? false
    }

    /// L'ordre choisi (éléments connus, sans doublon), puis les nouveaux.
    static func merged(_ order: [String], _ all: [String]) -> [String] {
        var seen = Set<String>()
        var out = order.filter { all.contains($0) && seen.insert($0).inserted }
        for x in all where !out.contains(x) { out.append(x) }
        return out
    }

    // MARK: Onglets
    var tabs: [String] { Self.merged(tabOrder, Self.defaultTabs) }
    /// Au moins un onglet : l'accueil si tout était masqué.
    var visibleTabs: [String] {
        let v = tabs.filter { !hiddenTabs.contains($0) }
        return v.isEmpty ? ["home"] : v
    }
    var startTab: String { visibleTabs.contains(launchTab) ? launchTab : visibleTabs[0] }

    // MARK: Accueil
    var homeChips: [String] { Self.merged(homeOrder, Self.defaultHome) }
    /// Au moins un onglet de lives : Suivies si tout était masqué.
    var visibleHomeChips: [String] {
        let v = homeChips.filter { !hiddenHome.contains($0) }
        return v.isEmpty ? ["followed"] : v
    }
    func shows(home key: String) -> Bool { !hiddenHome.contains(key) }

    // MARK: Lecteur
    var playerButtons: [String] { Self.merged(playerOrder, Self.defaultPlayer) }
    func shows(player key: String) -> Bool { !hiddenPlayer.contains(key) }

    // MARK: Page d'une chaîne
    var channelTabs: [String] { Self.merged(channelTabOrder, Self.defaultChannelTabs) }
    /// Au moins un onglet toujours là, sans compter le planning (seulement
    /// pour les chaînes qui en ont un) : les VODs si tout était masqué.
    var visibleChannelTabs: [String] {
        let v = channelTabs.filter { !hiddenChannelTabs.contains($0) }
        return v.contains(where: { $0 != "schedule" }) ? v : v + ["vods"]
    }

    // MARK: Modifications
    mutating func set(_ key: String, hidden: Bool, in list: WritableKeyPath<UICustomization, [String]>) {
        self[keyPath: list].removeAll { $0 == key }
        if hidden { self[keyPath: list].append(key) }
    }
}

/// Ordre des catégories suivies (Réglages → Personnaliser).
enum FollowedCategorySort: String, Codable, CaseIterable, Identifiable {
    /// Les plus regardées d'abord, comme Twitch (l'ordre de toujours).
    case viewers
    /// Alphabétique, de A à Z.
    case name

    var id: String { rawValue }
    /// Mêmes libellés que les tris des lives d'une catégorie.
    var labelKey: String { self == .viewers ? "sort_viewers_desc" : "sort_name" }

    func apply(_ list: [TwitchCategory]) -> [TwitchCategory] {
        switch self {
        case .viewers: return list.sorted { ($0.viewers ?? 0) > ($1.viewers ?? 0) }
        case .name:    return list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }
}
