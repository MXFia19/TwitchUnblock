import Foundation
import Combine
import UIKit

// ═══════════════════════════════════════════════════════════════════════════
//  Synchro des réglages entre appareils (site et app), par le même Worker
//  que l'historique : un document « préférences » par compte, gardé à part
//  de la sauvegarde (GET/POST /api/sync/prefs, jeton Twitch du compte).
//  L'app 1.5.0 et l'app Android envoient /api/sync/post sans lui : elles ne
//  peuvent pas l'effacer.
//
//  Sections, chacune avec sa date de modification (`at`, en ms) ; la plus
//  récente gagne, section par section :
//    common : réglages communs avec le site (commonKeys), noms de la sauvegarde ;
//    pinned : chaînes épinglées ;
//    hidden : chaînes et catégories masquées (format de la sauvegarde) ;
//    ios    : personnalisation et réglages propres à l'app (iosKeys), que le
//             site laisse au Worker sans s'en servir.
//
//  Un changement se voit à l'empreinte de chaque section, recalculée quelques
//  secondes après le dernier changement du store : la section prend la date
//  du moment et part, après une relecture du serveur. Ce qui vient du serveur
//  prend sa date et devient l'empreinte : rien ne repart, pas de boucle. Une
//  section jamais changée ici pour ce compte (date 0) adopte celle du
//  serveur, en y ajoutant les listes d'ici (épinglées, masquées, mots et
//  personnes masqués du chat) ; aux valeurs par défaut, elle ne part jamais
//  d'elle-même. Les deux côtés changés depuis le dernier échange : fusion
//  pour les masquées et les épinglées (avec la liste du dernier échange, un
//  retrait fait d'un côté tient), la date la plus récente pour les réglages.
//  Mêmes règles et même format que le site (main.js, « Synchro des
//  réglages »).
//
//  Lecture au rythme de l'historique (au plus une fois par 10 min : ouverture,
//  retour au premier plan, accueil), envoi quelques secondes après le dernier
//  changement ou au passage en arrière-plan. « Synchroniser mes réglages »
//  coupé, ou sans compte : rien ne part ni n'arrive.
// ═══════════════════════════════════════════════════════════════════════════

enum SettingsSync {
    static let sections = ["common", "pinned", "hidden", "ios"]

    /// Réglages communs avec le site, sous leur nom de la sauvegarde.
    /// Ne sont PAS synchronisés, parce qu'ils dépendent de l'appareil :
    ///  - lang : langue de l'interface (par défaut, celle de chaque appareil) ;
    ///  - qualityPref : qualité, selon l'écran et la connexion ;
    ///  - shareUsage : comptage anonyme, consentement donné sur chaque appareil ;
    ///  - homeList : accueil en grille ou en liste, selon la taille de l'écran.
    /// « hiddenEmotes » : emotes masquées, codes exacts (200 au plus).
    static let commonKeys = ["topLang", "showRecent", "timestamps", "timeFormat", "keepDeleted",
                             "loadHistory", "hideBots", "hideCommands", "mutedWords", "blockedUsers",
                             "highlightWords", "vodSpeed", "hiddenEmotes"]

    /// Propres à l'app : la personnalisation (onglets, accueil, boutons du
    /// lecteur, bandeaux du chat) et ce qui suit le compte plutôt que
    /// l'appareil. Ne sont PAS synchronisés, parce qu'ils dépendent de
    /// l'appareil :
    ///  - ios_cellularQuality, ios_preferAudioOnly : qualité, données mobiles ;
    ///  - ios_higherQualities : codecs que décode l'appareil ;
    ///  - ios_downloadWifiOnly : téléchargements ;
    ///  - ios_liveActivity : écran verrouillé et Dynamic Island ;
    ///  - ios_fillScreen, ios_landscapeChat, ios_landNoticesHidden et les
    ///    tailles du chat (ios_chatFontSize, ios_chatSpacing,
    ///    ios_chatBadgeScale, ios_chatEmoteScale, ios_chatWidthRatio) :
    ///    apparence, selon l'écran ;
    ///  - ios_immersivePlayer : le lecteur natif sert de repli sur un appareil ;
    ///  - ios_lowLatency : selon le réseau de l'appareil ;
    ///  - ios_chatSync : le retard du chat suit le lecteur de l'appareil ;
    ///  - ios_autoPurgeCache : stockage de l'appareil ;
    ///  - ios_chatReturnSends : selon le clavier (iPad avec clavier physique) ;
    ///  - ios_showDiscoverTab : déjà dans ios_customization ;
    ///  - ios_syncSettings : ce réglage même, propre à chaque appareil.
    /// Les notifications (lives, drops) ne sont pas dans la sauvegarde.
    static let iosKeys = ["ios_customization", "ios_autoClaimChest", "ios_showPinned",
                          "ios_showDropsNotice", "ios_showFollowButton", "ios_showWatchStreak",
                          "ios_showLiveEvents", "ios_showPolls", "ios_showPredictions",
                          "ios_showHypeTrain", "ios_enableRaids", "ios_subAdFree",
                          "ios_chatAutocomplete", "ios_chatKeyboardSuggestions",
                          "ios_chatShowInput"]

    /// Délai entre le dernier changement et l'envoi.
    static let delay: TimeInterval = 4
    /// Relecture au plus toutes les 10 minutes, comme l'historique.
    static let pullEvery: TimeInterval = 600
    /// Le Worker garde 64 Ko : au-delà, les masqués les plus anciens restent ici.
    static let maxBody = 60_000
    private static let stateKey = "prefs_sync"

    /// Compte, jeton et Worker d'un échange.
    struct Target {
        let userId: String
        let token: String
        let base: String
    }

    /// Par section : `at` (version d'ici, en ms ; 0 = jamais changée pour ce
    /// compte), `srv` (date du serveur au dernier échange), `sum`
    /// (empreinte), et pour les listes, celle du serveur au dernier échange
    /// (fusion suivante).
    struct Section: Codable {
        var at: Int64 = 0
        var srv: Int64 = 0
        var sum: String? = nil
        var basePinned: [String]? = nil
        var baseHidden: HiddenContent? = nil
    }

    /// Ce qui est gardé entre deux lancements (UserDefaults « prefs_sync ») :
    /// le compte des dates, et chaque section.
    struct Saved: Codable {
        var owner: String? = nil
        var sections: [String: Section] = [:]

        static func load() -> Saved {
            guard let data = UserDefaults.standard.data(forKey: SettingsSync.stateKey),
                  let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return Saved() }
            return saved
        }

        func save() {
            if let data = try? JSONEncoder().encode(self) {
                UserDefaults.standard.set(data, forKey: SettingsSync.stateKey)
            }
        }
    }

    /// Section reçue du Worker.
    struct Remote {
        let at: Int64
        let data: Any
    }

    /// Sections valides d'une réponse du Worker ({ sections: { nom: { at, data } } }).
    static func remoteSections(_ json: [String: Any]) -> [String: Remote] {
        var out: [String: Remote] = [:]
        for (name, raw) in json["sections"] as? [String: Any] ?? [:] {
            guard let s = raw as? [String: Any], let at = s["at"] as? NSNumber,
                  at.doubleValue.isFinite, at.doubleValue > 0, let data = s["data"] else { continue }
            out[name] = Remote(at: at.int64Value, data: data)
        }
        return out
    }

    /// Empreinte d'un contenu JSON (FNV-1a, clés triées), stable d'un
    /// lancement à l'autre : de quoi voir qu'une section a changé.
    static func digest(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return "?" }
        var h: UInt64 = 0xcbf29ce484222325
        for b in data { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return "\(String(h, radix: 36)).\(data.count)"
    }

    /// Pseudos valides (minuscules), sans doublon, 300 au plus.
    static func logins(_ value: Any?) -> [String] {
        var seen = Set<String>()
        let list = ((value as? [Any]) ?? []).compactMap { ($0 as? String)?.lowercased() }
        return Array(list.filter { HiddenContent.validLogin($0) && seen.insert($0).inserted }.prefix(300))
    }

    /// Épinglées des deux côtés : fusion à trois avec la liste du dernier
    /// échange (`base`) ; sans elle, réunion. L'ordre du serveur, puis ce qui
    /// a été épinglé ici.
    static func mergePins(here: [String], there: [String], base: [String]?) -> [String] {
        let was = Set(base ?? []), mine = Set(here), theirs = Set(there)
        // Désépinglée ici depuis le dernier échange : pas reprise.
        var out = there.filter { mine.contains($0) || !was.contains($0) }
        // Désépinglée là-bas depuis : retirée ici aussi.
        for login in here where !theirs.contains(login) && !was.contains(login) { out.append(login) }
        return Array(out.prefix(300))
    }

    /// Première rencontre, section commune : celle du serveur, plus les
    /// listes du chat d'ici (mots et personnes masqués, mots surlignés,
    /// emotes masquées).
    static func firstCommon(here: [String: Any], there: Any) -> [String: Any] {
        var out = there as? [String: Any] ?? [:]
        for (key, max) in [("mutedWords", 50), ("highlightWords", 30), ("blockedUsers", 500),
                           ("hiddenEmotes", AppStore.maxHiddenEmotes)] {
            var seen = Set<String>()
            let theirs: [String] = ((out[key] as? [Any]) ?? []).compactMap { $0 as? String }
            let mine: [String] = (here[key] as? [String]) ?? []
            out[key] = Array((theirs + mine).filter { seen.insert($0).inserted }.prefix(max))
        }
        return out
    }

    /// Envoi borné (le Worker garde 64 Ko) : au-delà, les masqués les plus
    /// anciens restent sur cet appareil seulement.
    static func fit(_ send: [String: [String: Any]], userId: String) -> [String: [String: Any]] {
        var send = send
        func size() -> Int {
            let body: [String: Any] = ["userId": userId, "sections": send]
            guard JSONSerialization.isValidJSONObject(body) else { return 0 }
            return (try? JSONSerialization.data(withJSONObject: body))?.count ?? 0
        }
        guard var hidden = send["hidden"]?["data"] as? [String: Any] else { return send }
        while size() > maxBody {
            let channels = hidden["channels"] as? [Any] ?? [], categories = hidden["categories"] as? [Any] ?? []
            guard !channels.isEmpty || !categories.isEmpty else { break }
            hidden["channels"] = Array(channels.prefix(channels.count * 9 / 10))
            hidden["categories"] = Array(categories.prefix(categories.count * 9 / 10))
            send["hidden"]?["data"] = hidden
        }
        return send
    }

    /// Lecture du document du compte ; nil si elle a échoué (réseau, jeton
    /// refusé, Worker sans la route). Sur le fil principal, comme ceux qui
    /// l'appellent : le document n'y change pas d'acteur.
    @MainActor
    static func fetch(_ target: Target) async -> [String: Remote]? {
        guard let url = URL(string: "\(target.base)/api/sync/prefs?userId=\(target.userId)") else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("Bearer \(target.token)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: request) else {
            logger.warn("SYNC", "☁️ Relecture des réglages impossible", "réseau — rien n'est envoyé")
            return nil
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logger.warn("SYNC", "☁️ Relecture des réglages refusée", "HTTP \(status) — rien n'est envoyé")
            return nil
        }
        return remoteSections(json)
    }

    /// Envoi de sections ({ nom: { at, data } }) ; réponse du Worker
    /// ({ accepted, sections }), ou nil s'il a échoué.
    @MainActor
    static func push(_ target: Target, _ sections: [String: [String: Any]]) async -> [String: Any]? {
        let payload: [String: Any] = ["userId": target.userId, "sections": sections]
        guard JSONSerialization.isValidJSONObject(payload),
              let body = try? JSONSerialization.data(withJSONObject: payload),
              let url = URL(string: "\(target.base)/api/sync/prefs") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(target.token)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        let result = try? await URLSession.shared.data(for: request)
        let status = (result?.1 as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status), let data = result?.0,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Toujours « à envoyer » : le prochain échange réessaie.
            logger.warn("SYNC", "☁️ Envoi des réglages refusé", status == 0 ? "réseau" : "HTTP \(status)")
            return nil
        }
        return json
    }
}

/// État de la synchro des réglages, gardé par AppStore (une extension ne
/// peut pas avoir de propriétés). Lu et écrit sur le fil principal.
final class SettingsSyncState {
    var saved = SettingsSync.Saved.load()
    /// Changements du store, regroupés (SettingsSync.delay).
    var watcher: AnyCancellable?
    /// Échanges en file, un seul à la fois ; une demande pareille (ou une
    /// relecture) qui attend encore suffit.
    var chain: Task<Void, Never>?
    var pullQueued = false
    var pushQueued = false
    /// Dernière relecture réussie.
    var lastPullAt = Date.distantPast
}

extension AppStore {
    /// Compte, jeton et Worker d'un échange ; nil sans compte ou réglage coupé.
    private var settingsTarget: SettingsSync.Target? {
        guard syncSettings, let id = twitchUserId, !id.isEmpty,
              let token = twitchToken, !token.isEmpty else { return nil }
        return SettingsSync.Target(userId: id, token: token, base: APIConfig.base)
    }

    /// Une section changée ici depuis le dernier échange attend de partir.
    private var settingsDirty: Bool {
        prefsSync.saved.sections.values.contains { $0.at > $0.srv }
    }

    /// Fin d'init : empreinte de départ (ou changement fait juste avant la
    /// fermeture de l'app), puis, quelques secondes après le dernier
    /// changement du store, les sections comparées à leur empreinte.
    func startSettingsSync() {
        noteSettingsChanges()
        prefsSync.watcher = objectWillChange
            .debounce(for: .seconds(SettingsSync.delay), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.settingsMaybeChanged() }
            }
    }

    @MainActor
    private func settingsMaybeChanged() {
        guard noteSettingsChanges() else { return }
        requestSettingsSync(pull: false)
    }

    /// Relecture au rythme de l'historique : au plus une fois par 10 minutes.
    @MainActor
    func refreshSettingsIfStale() {
        guard settingsTarget != nil,
              Date().timeIntervalSince(prefsSync.lastPullAt) > SettingsSync.pullEvery else { return }
        requestSettingsSync(pull: true)
    }

    /// Nouveau compte : ses réglages sont relus tout de suite, pas 10 minutes
    /// plus tard.
    func settingsAccountChanged() {
        prefsSync.lastPullAt = .distantPast
    }

    /// « Synchroniser mes réglages » réactivé : relu tout de suite.
    @MainActor
    func settingsSyncToggled() {
        guard syncSettings else { return }
        prefsSync.lastPullAt = .distantPast
        requestSettingsSync(pull: true)
    }

    /// Passage en arrière-plan : ce qui attend part tout de suite (relecture,
    /// puis envoi), dans le temps qu'iOS laisse à l'app.
    @MainActor
    func flushSettingsSync() {
        noteSettingsChanges()
        guard settingsTarget != nil, settingsDirty else { return }
        let bg = BackgroundTaskBox()
        bg.id = UIApplication.shared.beginBackgroundTask(withName: "prefs") { bg.end() }
        let task = requestSettingsSync(pull: false)
        Task { @MainActor in
            await task.value
            bg.end()
        }
    }

    /// Le compte va perdre son jeton (déconnexion, autre jeton) : les
    /// réglages qui attendaient partent maintenant, avec ce jeton-là, sans
    /// relecture ; le Worker ne garde une section que si elle est plus
    /// récente que la sienne, la règle d'un échange. Pas les épinglées ni
    /// les masquées : elles se fusionnent avec celles du serveur, et envoyées
    /// telles quelles, elles effaçaient ce qu'un autre appareil y avait
    /// changé depuis le dernier échange. Elles partent au prochain échange
    /// de ce compte, après une relecture.
    func finalSettingsFlush() {
        noteSettingsChanges()
        guard let target = settingsTarget, prefsSync.saved.owner == target.userId, settingsDirty else { return }
        var send: [String: [String: Any]] = [:]
        var sentFrom: [String: Int64] = [:]
        for name in SettingsSync.sections where name == "common" || name == "ios" {
            let s = prefsSync.saved.sections[name] ?? SettingsSync.Section()
            guard s.at > s.srv else { continue }
            send[name] = ["at": NSNumber(value: s.at), "data": settingsSectionData(name)]
            sentFrom[name] = s.at
        }
        guard !send.isEmpty else { return }
        let payload = SettingsSync.fit(send, userId: target.userId)
        Task { @MainActor [weak self] in
            guard let res = await SettingsSync.push(target, payload) else { return }
            _ = self?.settingsAccepted(target.userId, sentFrom, res)
        }
    }

    /// Un échange à la fois, en file. `pull` : relire même sans rien à
    /// envoyer (ouverture, connexion, réglage réactivé).
    @MainActor
    @discardableResult
    func requestSettingsSync(pull: Bool, retry: Bool = false) -> Task<Void, Never> {
        if let chain = prefsSync.chain, prefsSync.pullQueued || (!pull && prefsSync.pushQueued) { return chain }
        if pull { prefsSync.pullQueued = true } else { prefsSync.pushQueued = true }
        let previous = prefsSync.chain
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            if pull { self.prefsSync.pullQueued = false } else { self.prefsSync.pushQueued = false }
            // Section refusée par le Worker (plus récente chez lui, envoi
            // croisé) : relue tout de suite, une fois.
            if await self.settingsExchange(pull: pull), !retry {
                self.requestSettingsSync(pull: true, retry: true)
            }
        }
        prefsSync.chain = task
        return task
    }

    // MARK: Contenu des sections

    /// Contenu d'une section, au format du document (celui de la sauvegarde).
    /// `settings` : Backup.settingsJSON déjà calculé, s'il l'est.
    private func settingsSectionData(_ name: String, _ settings: [String: Any]? = nil) -> Any {
        switch name {
        case "pinned": return pinnedStreamers
        case "hidden": return hidden.backupJSON()
        default:
            let keys = name == "ios" ? SettingsSync.iosKeys : SettingsSync.commonKeys
            return (settings ?? Backup.settingsJSON(self)).filter { keys.contains($0.key) }
        }
    }

    /// Section aux valeurs d'une installation neuve (celles de l'init
    /// d'AppStore) : jamais envoyée d'elle-même.
    private func settingsSectionIsDefault(_ name: String) -> Bool {
        switch name {
        case "pinned": return pinnedStreamers.isEmpty
        case "hidden": return hidden.isEmpty
        case "ios":
            return customization == UICustomization() && autoClaimChest && showPinnedMessages
                && showDropsNotice && showFollowButton && showWatchStreak && showLiveEvents
                && showPolls && showPredictions && showHypeTrain && enableRaids && subAdFree
                && chatAutocomplete && chatKeyboardSuggestions && chatShowInput
        default:
            return topLang == nil && showRecentChannels && chatTimestamps && timeFormat == "auto"
                && !chatShowDeleted && chatLoadRecent && !chatHideBots && !chatHideCommands
                && chatMutedWords.isEmpty && chatBlockedUsers.isEmpty && chatHighlightWords.isEmpty
                && vodSpeed == 1 && hiddenEmotes.isEmpty
        }
    }

    /// Section reçue appliquée ici, chaque valeur validée comme à l'import
    /// d'une sauvegarde (une valeur que l'app ne connaît pas est ignorée).
    private func applySettingsSection(_ name: String, _ data: Any) {
        switch name {
        case "pinned":
            let list = SettingsSync.logins(data)
            if list != pinnedStreamers { pinnedStreamers = list }
        case "hidden":
            var h = HiddenContent()
            h.merge(backup: data)
            if h != hidden { hidden = h }
        default:
            let keys = name == "ios" ? SettingsSync.iosKeys : SettingsSync.commonKeys
            guard let dict = data as? [String: Any] else { return }
            Backup.applySettings(dict.filter { keys.contains($0.key) }, to: self)
        }
    }

    /// Liste du serveur au dernier échange, pour la fusion suivante.
    private func setSettingsBase(_ s: inout SettingsSync.Section, _ name: String, _ data: Any) {
        switch name {
        case "pinned":
            s.basePinned = SettingsSync.logins(data)
        case "hidden":
            var h = HiddenContent()
            h.merge(backup: data)
            s.baseHidden = h
        default:
            break
        }
    }

    // MARK: Échange

    /// Sections changées ici depuis leur empreinte : datées de maintenant (la
    /// toute première empreinte n'est qu'un point de départ). true si l'une
    /// d'elles vient de prendre une date.
    @discardableResult
    private func noteSettingsChanges() -> Bool {
        let settings = Backup.settingsJSON(self)
        var touched = false
        var dated = false
        for name in SettingsSync.sections {
            var s = prefsSync.saved.sections[name] ?? SettingsSync.Section()
            let sum = SettingsSync.digest(settingsSectionData(name, settings))
            guard s.sum != sum else { continue }
            if s.sum != nil {
                s.at = max(HiddenContent.now(), s.srv + 1)
                dated = true
            }
            s.sum = sum
            prefsSync.saved.sections[name] = s
            touched = true
        }
        if touched { prefsSync.saved.save() }
        return dated
    }

    /// Dates gardées pour un autre compte, ou d'avant toute connexion : elles
    /// ne valent rien pour celui-ci, qui repart de ce qu'il a sur le serveur
    /// (première rencontre). Gardées pour la première connexion, un réglage
    /// changé avant elle faisait passer la section d'ici, presque toute aux
    /// valeurs par défaut, devant celle du compte (mots et personnes masqués
    /// du chat, personnalisation… effacés partout).
    private func adoptSettingsOwner(_ userId: String) {
        guard prefsSync.saved.owner != userId else { return }
        for name in SettingsSync.sections {
            var s = prefsSync.saved.sections[name] ?? SettingsSync.Section()
            s.at = 0
            s.srv = 0
            s.basePinned = nil
            s.baseHidden = nil
            prefsSync.saved.sections[name] = s
        }
        prefsSync.saved.owner = userId
        prefsSync.saved.save()
    }

    /// Ce que devient une section quand les deux côtés ont changé, ou à la
    /// première rencontre (`base` nil) : les listes fusionnées, la section
    /// commune avec les listes du chat d'ici en plus.
    private func mergedSettingsSection(_ name: String, _ mine: Any, _ theirs: Any,
                                       _ s: SettingsSync.Section, first: Bool) -> Any {
        switch name {
        case "pinned":
            return SettingsSync.mergePins(here: pinnedStreamers, there: SettingsSync.logins(theirs),
                                          base: first ? nil : s.basePinned)
        case "hidden":
            var h = hidden
            h.mergeSync(remote: theirs, base: first ? nil : s.baseHidden)
            return h.backupJSON()
        case "common":
            return SettingsSync.firstCommon(here: mine as? [String: Any] ?? [:], there: theirs)
        default:
            return theirs
        }
    }

    /// Un échange : relecture, puis chaque section appliquée ici ou envoyée.
    /// Rien ne part sans une relecture réussie juste avant. true si le Worker
    /// a refusé une section (plus récente chez lui entre-temps).
    @MainActor
    private func settingsExchange(pull: Bool) async -> Bool {
        noteSettingsChanges()
        guard let target = settingsTarget else { return false }
        adoptSettingsOwner(target.userId)
        guard pull || settingsDirty else { return false }
        guard let remote = await SettingsSync.fetch(target) else { return false }
        // Autre compte, déconnexion ou réglage coupé pendant la relecture.
        guard settingsTarget?.userId == target.userId else { return false }
        prefsSync.lastPullAt = Date()
        // Changé pendant la relecture : daté avant de décider.
        noteSettingsChanges()
        adoptSettingsOwner(target.userId)

        let settings = Backup.settingsJSON(self)
        var send: [String: [String: Any]] = [:]
        var sentFrom: [String: Int64] = [:]   // `at` d'ici au moment de l'envoi
        var applied: [String] = []
        for name in SettingsSync.sections {
            var s = prefsSync.saved.sections[name] ?? SettingsSync.Section()
            let mine = settingsSectionData(name, settings)
            guard let r = remote[name] else {
                // Rien au serveur : ce qui a une date part. Une section jamais
                // changée part aussi, sauf aux valeurs par défaut, avec la
                // date 1 : la moindre modification faite ailleurs l'emportera.
                if s.at > 0 || !settingsSectionIsDefault(name) {
                    send[name] = ["at": NSNumber(value: max(s.at, 1)), "data": mine]
                    sentFrom[name] = s.at
                }
                continue
            }
            let here = s.at > s.srv      // changée ici depuis le dernier échange
            let there = r.at != s.srv    // changée sur le serveur depuis
            let next: Any
            if s.at == 0 {
                // Jamais changée ici pour ce compte : ce qui existe d'abord.
                next = mergedSettingsSection(name, mine, r.data, s, first: true)
            } else if !here && there {
                next = r.data
            } else if here && !there {
                send[name] = ["at": NSNumber(value: s.at), "data": mine]
                sentFrom[name] = s.at
                continue
            } else if !here {
                continue
            } else if r.at == s.at {
                // La même version (envoi dont la réponse s'est perdue).
                s.srv = r.at
                setSettingsBase(&s, name, r.data)
                prefsSync.saved.sections[name] = s
                continue
            } else if name == "common" || name == "ios" {
                // Les deux ont changé : la plus récente.
                if r.at < s.at {
                    send[name] = ["at": NSNumber(value: s.at), "data": mine]
                    sentFrom[name] = s.at
                    continue
                }
                next = r.data
            } else {
                next = mergedSettingsSection(name, mine, r.data, s, first: false)
            }
            applySettingsSection(name, next)
            applied.append(name)
            let after = settingsSectionData(name)
            s.sum = SettingsSync.digest(after)
            s.srv = r.at
            setSettingsBase(&s, name, r.data)
            if SettingsSync.digest(next) == SettingsSync.digest(r.data) {
                s.at = r.at
            } else {
                // Ce qui vient d'ici s'y est ajouté (première rencontre,
                // fusion) : la section repart, plus récente que celle du serveur.
                s.at = max(HiddenContent.now(), r.at + 1)
                send[name] = ["at": NSNumber(value: s.at), "data": after]
                sentFrom[name] = s.at
            }
            prefsSync.saved.sections[name] = s
        }
        prefsSync.saved.save()
        if !applied.isEmpty {
            logger.info("SYNC", "☁️ Réglages repris du compte", applied.joined(separator: ", "))
        }
        guard !send.isEmpty else { return false }
        guard let res = await SettingsSync.push(target, SettingsSync.fit(send, userId: target.userId)) else { return false }
        return settingsAccepted(target.userId, sentFrom, res)
    }

    /// Réponse d'un envoi : les sections prises deviennent la version du
    /// serveur (date, liste de la prochaine fusion). true si l'une a été
    /// refusée (plus récente au serveur entre-temps).
    private func settingsAccepted(_ userId: String, _ sentFrom: [String: Int64], _ res: [String: Any]) -> Bool {
        guard prefsSync.saved.owner == userId else { return false }
        let accepted = Set(res["accepted"] as? [String] ?? [])
        let sections = SettingsSync.remoteSections(res)
        var refused = false
        for name in sentFrom.keys {
            guard accepted.contains(name), let r = sections[name] else { refused = true; continue }
            var s = prefsSync.saved.sections[name] ?? SettingsSync.Section()
            // Rechangée ici pendant l'envoi : elle repartira.
            if s.at == sentFrom[name] { s.at = r.at }
            s.srv = r.at
            setSettingsBase(&s, name, r.data)
            prefsSync.saved.sections[name] = s
        }
        prefsSync.saved.save()
        if !accepted.isEmpty {
            logger.debug("SYNC", "☁️ Réglages envoyés", accepted.sorted().joined(separator: ", "))
        }
        return refused
    }
}
