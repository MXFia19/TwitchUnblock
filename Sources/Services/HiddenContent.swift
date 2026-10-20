import Foundation

// ═══════════════════════════════════════════════════════════════════════════
//  Chaînes et catégories masquées des listes de découverte (top, grille des
//  catégories, lives d'une catégorie).
//
//  Partagé avec l'Apple TV (project.yml) : ni UIKit ni AppStore ici. Les
//  chaînes sont retenues par pseudo (comme les suivis et les épingles), les
//  catégories par identifiant (le nom change selon la source). `at` en
//  millisecondes, comme sur le site : la sauvegarde passe de l'un à l'autre.
//  Synchronisées avec le compte sur l'iPhone (SettingsSync.swift, section
//  « hidden ») ; sur l'Apple TV, sur cet appareil seulement.
// ═══════════════════════════════════════════════════════════════════════════

struct HiddenChannel: Codable, Equatable, Identifiable {
    /// Pseudo en minuscules.
    let login: String
    var name: String
    /// Date du masquage, en millisecondes.
    var at: Int64
    var id: String { login }
}

struct HiddenCategory: Codable, Equatable, Identifiable {
    let id: String
    var name: String
    /// Jaquette (vide quand la catégorie a été masquée depuis un live).
    var box: String
    var at: Int64
}

struct HiddenContent: Codable, Equatable {
    static let maxChannels = 500
    static let maxCategories = 200
    private static let storageKey = "hidden_content"

    /// Les plus récents d'abord.
    private(set) var channels: [HiddenChannel] = []
    private(set) var categories: [HiddenCategory] = []

    var isEmpty: Bool { channels.isEmpty && categories.isEmpty }

    static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    /// Pseudo Twitch : lettres, chiffres et « _ », 25 au plus.
    static func validLogin(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 25 && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }
    /// Identifiant de catégorie : des chiffres seulement.
    static func validCategoryId(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 20 && s.allSatisfy { $0.isASCII && $0.isNumber }
    }

    // MARK: Lecture
    func hides(channel login: String) -> Bool {
        let l = login.lowercased()
        return channels.contains { $0.login == l }
    }
    /// Faux si l'identifiant manque (live d'une liste qui ne le demande pas).
    func hides(category id: String) -> Bool {
        !id.isEmpty && categories.contains { $0.id == id }
    }
    /// Ni la chaîne ni sa catégorie ne sont masquées (sans exception pour
    /// les suivis : l'Apple TV ne les connaît pas hors de son onglet).
    func allows(_ s: TwitchStream) -> Bool {
        !hides(channel: s.userLogin) && !hides(category: s.gameId)
    }

    // MARK: Changements
    mutating func hide(channel login: String, name: String) {
        let l = login.lowercased()
        guard Self.validLogin(l) else { return }
        channels.removeAll { $0.login == l }
        channels.insert(HiddenChannel(login: l, name: String((name.isEmpty ? l : name).prefix(100)), at: Self.now()), at: 0)
        if channels.count > Self.maxChannels { channels = Array(channels.prefix(Self.maxChannels)) }
    }

    mutating func hide(category id: String, name: String, box: String) {
        guard Self.validCategoryId(id) else { return }
        categories.removeAll { $0.id == id }
        categories.insert(HiddenCategory(id: id, name: String(name.prefix(100)),
                                         box: box.hasPrefix("https://") ? box : "", at: Self.now()), at: 0)
        if categories.count > Self.maxCategories { categories = Array(categories.prefix(Self.maxCategories)) }
    }

    mutating func unhide(channel login: String) {
        let l = login.lowercased()
        channels.removeAll { $0.login == l }
    }

    mutating func unhide(category id: String) {
        categories.removeAll { $0.id == id }
    }

    mutating func unhideAll() {
        channels = []
        categories = []
    }

    // MARK: Stockage (UserDefaults, en JSON)
    static func load() -> HiddenContent {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(HiddenContent.self, from: data) else { return HiddenContent() }
        return decoded
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    // MARK: Sauvegarde (clé racine « hidden », même format que le site)
    func backupJSON() -> [String: Any] {
        [
            "channels": channels.map { ["login": $0.login, "name": $0.name, "at": NSNumber(value: $0.at)] as [String: Any] },
            "categories": categories.map { ["id": $0.id, "name": $0.name, "box": $0.box, "at": NSNumber(value: $0.at)] as [String: Any] },
        ]
    }

    /// Ajoute les éléments valides d'une sauvegarde (rien n'est retiré). Pour
    /// un élément déjà là, le masquage le plus récent l'emporte.
    mutating func merge(backup: Any?) {
        guard let root = backup as? [String: Any] else { return }
        /// `at` en millisecondes ; une valeur absente ou aberrante vaut 0.
        func stamp(_ v: Any?) -> Int64 {
            guard let d = v as? Double, d.isFinite, d >= 0, d < 1e14 else { return 0 }
            return Int64(d)
        }
        func text(_ v: Any?) -> String { String((v as? String ?? "").prefix(100)) }

        var chans = Dictionary(channels.map { ($0.login, $0) }, uniquingKeysWith: { a, _ in a })
        for e in root["channels"] as? [[String: Any]] ?? [] {
            guard let raw = e["login"] as? String else { continue }
            let l = raw.lowercased()
            guard Self.validLogin(l) else { continue }
            let item = HiddenChannel(login: l, name: text(e["name"]).isEmpty ? l : text(e["name"]), at: stamp(e["at"]))
            if let old = chans[l], old.at >= item.at { continue }
            chans[l] = item
        }
        channels = Array(chans.values.sorted { $0.at > $1.at }.prefix(Self.maxChannels))

        var cats = Dictionary(categories.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for e in root["categories"] as? [[String: Any]] ?? [] {
            guard let id = e["id"] as? String, Self.validCategoryId(id) else { continue }
            let box = e["box"] as? String ?? ""
            let item = HiddenCategory(id: id, name: text(e["name"]),
                                      box: box.hasPrefix("https://") && box.count <= 500 ? box : "",
                                      at: stamp(e["at"]))
            if let old = cats[id], old.at >= item.at { continue }
            cats[id] = item
        }
        categories = Array(cats.values.sorted { $0.at > $1.at }.prefix(Self.maxCategories))
    }

    /// Synchro des réglages, quand les deux côtés ont changé : `remote`
    /// (format de la sauvegarde) réuni à ce qui est ici comme à l'import
    /// (merge(backup:) : le masquage le plus récent l'emporte), sauf ce que
    /// `base` — la liste du serveur au dernier échange — dit retiré d'un côté
    /// depuis : un élément qu'elle avait, absent d'un côté et pas remasqué de
    /// l'autre depuis, ne revient pas. Sans base : réunion simple.
    mutating func mergeSync(remote: Any?, base: HiddenContent?) {
        var incoming = HiddenContent()
        incoming.merge(backup: remote)
        if let base {
            let wasChannel = Dictionary(base.channels.map { ($0.login, $0.at) }, uniquingKeysWith: { a, _ in a })
            let wasCategory = Dictionary(base.categories.map { ($0.id, $0.at) }, uniquingKeysWith: { a, _ in a })
            let hereChannels = Set(channels.map(\.login)), thereChannels = Set(incoming.channels.map(\.login))
            let hereCategories = Set(categories.map(\.id)), thereCategories = Set(incoming.categories.map(\.id))
            // Réaffiché là-bas depuis le dernier échange : réaffiché ici.
            channels.removeAll { c in
                !thereChannels.contains(c.login) && (wasChannel[c.login].map { c.at <= $0 } ?? false)
            }
            categories.removeAll { c in
                !thereCategories.contains(c.id) && (wasCategory[c.id].map { c.at <= $0 } ?? false)
            }
            // Réaffiché ici depuis : ne revient pas.
            incoming.channels.removeAll { c in
                !hereChannels.contains(c.login) && (wasChannel[c.login].map { c.at <= $0 } ?? false)
            }
            incoming.categories.removeAll { c in
                !hereCategories.contains(c.id) && (wasCategory[c.id].map { c.at <= $0 } ?? false)
            }
        }
        merge(backup: incoming.backupJSON())
    }

    // MARK: Top filtré
    /// Lives à afficher : `top` puis `extra` (sa suite), dans l'ordre de
    /// Twitch, sans doublon de pseudo, ceux que `keep` refuse écartés, au
    /// plus `limit`. `hidden` : lives écartés parmi ceux parcourus, pour la
    /// ligne « N masqués ici ».
    static func fill(top: [TwitchStream], extra: [TwitchStream] = [],
                     keep: (TwitchStream) -> Bool, limit: Int? = nil) -> (streams: [TwitchStream], hidden: Int) {
        var seen = Set<String>()
        var shown: [TwitchStream] = []
        var hidden = 0
        for s in top + extra {
            if let limit, shown.count >= limit { break }
            guard seen.insert(s.userLogin.lowercased()).inserted else { continue }
            if keep(s) { shown.append(s) } else { hidden += 1 }
        }
        return (shown, hidden)
    }
}
