import Foundation

/// Personnalisation de l'app (Réglages → Personnaliser) : onglets, accueil,
/// boutons du lecteur. Gardée en JSON (« cfg_customization ») et dans la
/// sauvegarde. Lue avec tolérance : un élément inconnu (version plus
/// récente) est ignoré, un nouvel élément s'ajoute à la fin, une clé absente
/// garde sa valeur par défaut — l'ordre choisi n'est jamais perdu.
struct UICustomization: Codable, Equatable {
    var tabOrder: [String] = UICustomization.defaultTabs
    var hiddenTabs: [String] = []
    var launchTab: String = "home"
    var homeOrder: [String] = UICustomization.defaultHome
    var hiddenHome: [String] = []
    var playerOrder: [String] = UICustomization.defaultPlayer
    /// Minuterie, multi-live et rembobiner : dans le menu ⋯ au départ,
    /// à faire apparaître dans la barre si on veut.
    var hiddenPlayer: [String] = ["sleep", "multi", "rewind"]

    static let defaultTabs = ["home", "discover", "search", "library"]
    /// Onglets des lives de l'accueil (Suivies, Top, Hors ligne).
    static let defaultHome = ["followed", "top", "offline"]
    /// Cartes du haut de l'accueil (« continue » : Continuer à regarder) et
    /// onglet Catégories : masquables.
    static let homeCards = ["announcement", "poll", "login", "web", "continue", "categories"]
    /// Boutons de la barre du bas du lecteur, dans l'ordre par défaut.
    /// AirPlay (« airplay », en haut) se masque seulement.
    static let defaultPlayer = ["mute", "pip", "refresh", "chat", "rotate", "sleep", "multi", "rewind"]

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
        playerOrder  = (try? c.decodeIfPresent([String].self, forKey: .playerOrder)) ?? Self.defaultPlayer
        hiddenPlayer = (try? c.decodeIfPresent([String].self, forKey: .hiddenPlayer)) ?? ["sleep", "multi", "rewind"]
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

    // MARK: Modifications
    mutating func set(_ key: String, hidden: Bool, in list: WritableKeyPath<UICustomization, [String]>) {
        self[keyPath: list].removeAll { $0 == key }
        if hidden { self[keyPath: list].append(key) }
    }
}
