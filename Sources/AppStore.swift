import Foundation
import Combine
import UIKit

final class AppStore: ObservableObject {

    // MARK: – Language
    /// L'anglais par défaut : l'app n'est pas réservée à un public français.
    @Published var lang: Lang = .en {
        didSet { UserDefaults.standard.set(lang.rawValue, forKey: "lang") }
    }

    // MARK: – Twitch Auth
    @Published var twitchToken: String? {
        didSet {
            Keychain.storeToken(twitchToken, for: "twitch_token")
        }
    }
    /// Gardé entre deux lancements : l'envoi de la sauvegarde au passage en
    /// arrière-plan doit savoir pour qui écrire, même avant que l'accueil
    /// n'ait rechargé le profil.
    @Published var twitchUserId: String? {
        didSet {
            if let id = twitchUserId { UserDefaults.standard.set(id, forKey: "twitch_user_id") }
            else { UserDefaults.standard.removeObject(forKey: "twitch_user_id") }
            // Historique et progression d'ici rattachés à ce compte : ceux
            // d'un autre compte ne partent jamais sur le sien. Pas avant
            // qu'init ait lu ces données (il s'en charge lui-même).
            if syncLoaded, let id = twitchUserId, !id.isEmpty, id != oldValue { adoptSyncOwner(id) }
            // Compte de l'app connu ou changé : la session web doit être la sienne.
            if let id = twitchUserId, id != oldValue, twitchWebToken != nil {
                Task { @MainActor [weak self] in await self?.validateWebSession() }
            }
        }
    }

    /// Token de session web (cookie `auth-token` de twitch.tv).
    /// Distinct de `twitchToken` (OAuth/Helix) : indispensable pour l'API GQL
    /// « community points » (solde, coffres, rachats), qui rejette les tokens OAuth custom.
    @Published var twitchWebToken: String? {
        didSet {
            Keychain.storeToken(twitchWebToken, for: "twitch_web_token")
            // Session partie (déconnexion, refus, expiration) : ses catégories
            // suivies ne protègent plus rien du masquage.
            if twitchWebToken == nil { accountFollowedCategoryIds = [] }
            // Session changée (déconnexion, expiration, autre compte, nouvelle
            // connexion) : la progression des drops ne continue jamais avec
            // l'ancien jeton (minutes et réclamations pour l'ancien compte),
            // et l'inventaire affiché était le sien.
            if twitchWebToken != oldValue {
                let old = oldValue, new = twitchWebToken
                Task { @MainActor in
                    DropsHeartbeat.shared.sessionChanged(to: new)
                    DropsService.shared.sessionChanged(from: old, to: new)
                }
            }
        }
    }

    /// La session web a été rejetée par Twitch : elle a été effacée, il faut
    /// se reconnecter. Distinct de « absente » — on ne veut pas harceler
    /// quelqu'un qui ne s'en est jamais servi.
    @Published var webSessionExpired = false

    /// Pseudo du compte d'une session web refusée parce qu'elle n'était pas au
    /// compte de l'app (nil sinon). Les points, drops et prédictions seraient
    /// partis sur un autre compte que les suivis et le chat.
    @Published var webSessionMismatch: String? = nil

    /// Jeton OAuth refusé par Twitch (401) : l'invitation de l'accueil dit
    /// pourquoi on a été déconnecté. Gardé ici et pas dans l'accueil, recréé
    /// à chaque changement d'onglet : la raison s'effaçait au premier
    /// aller-retour. Oublié à la connexion suivante (adoptToken).
    @Published var oauthExpired = false

    /// Vérifie la session web : effacée si Twitch la refuse, ou si elle est à
    /// un autre compte que celui de l'app. Une panne réseau ne l'efface pas :
    /// couper la session sur un wifi capricieux serait pire que de la laisser
    /// mourir en silence.
    @MainActor
    func validateWebSession() async {
        guard let token = twitchWebToken, !token.isEmpty else { return }
        let check = await webSessionIdentity(token: token)
        // Autre session entre-temps (nouvelle connexion) : ce verdict-là ne
        // la concerne pas.
        guard twitchWebToken == token else { return }
        switch check {
        case .unknown:
            break
        case .invalid:
            twitchWebToken = nil
            webSessionExpired = true
            // Cookies effacés aussi : sinon « Rétablir la session » reprenait
            // aussitôt le cookie périmé, sans rien demander, et l'app se
            // croyait reconnectée.
            await TwitchWebSession.clear()
        case .valid(let id, let login):
            webSessionExpired = false
            if let mine = twitchUserId, !mine.isEmpty, id != mine {
                await refuseWebSession(of: login)
            }
        }
    }

    /// Session web obtenue par la connexion twitch.tv (accueil, réglages,
    /// points). Refusée si elle n'est pas au compte de l'app.
    /// - Returns: false si refusée.
    @MainActor
    @discardableResult
    func adoptWebToken(_ token: String, login webLogin: String?) async -> Bool {
        if let mine = twitchLogin?.lowercased(), !mine.isEmpty,
           let web = webLogin?.lowercased(), !web.isEmpty, web != mine {
            await refuseWebSession(of: webLogin ?? web)
            return false
        }
        if twitchLogin == nil, let l = webLogin { twitchLogin = l }
        webSessionMismatch = nil
        webSessionExpired = false
        twitchWebToken = token
        // Vérifiée auprès de Twitch avant d'être annoncée : un cookie périmé
        // repris par la page de connexion est refusé tout de suite (session
        // expirée, cookies effacés) au lieu de passer pour une reconnexion.
        // Pseudo absent du cookie : le compte est vérifié au passage.
        await validateWebSession()
        // Catégories suivies du compte : jamais masquées, sans attendre un
        // passage par l'accueil.
        if twitchWebToken != nil { Task { [weak self] in await self?.loadAccountFollowedCategories() } }
        return twitchWebToken != nil
    }

    /// Session web d'un autre compte : effacée (jeton et cookies twitch.tv),
    /// pour que la prochaine connexion demande le bon compte.
    @MainActor
    private func refuseWebSession(of login: String) async {
        logger.warn("AUTH/WEB", "Session web d'un autre compte refusée",
                    "@\(login) ≠ @\(twitchLogin ?? "?") (compte de l'app)")
        webSessionMismatch = login
        twitchWebToken = nil
        DropsHeartbeat.shared.stop()
        await TwitchWebSession.clear()
    }

    /// Photo de profil du compte connecté, affichée dans l'en-tête.
    @Published var twitchAvatar: String? {
        didSet {
            if let a = twitchAvatar { UserDefaults.standard.set(a, forKey: "twitch_avatar") }
            else { UserDefaults.standard.removeObject(forKey: "twitch_avatar") }
        }
    }

    /// Login IRC (ex: "squeezie") — indispensable pour envoyer des messages en chat
    @Published var twitchLogin: String? {
        didSet {
            if let l = twitchLogin { UserDefaults.standard.set(l, forKey: "twitch_login") }
            else { UserDefaults.standard.removeObject(forKey: "twitch_login") }
        }
    }

    // MARK: – Points
    /// Réclamer automatiquement les coffres bonus dès qu'ils sont disponibles.
    @Published var autoClaimChest: Bool = true {
        didSet { UserDefaults.standard.set(autoClaimChest, forKey: "auto_claim_chest") }
    }

    // MARK: – Personnalisation chat / lecteur
    /// Afficher le bandeau des messages épinglés.
    @Published var showPinnedMessages: Bool = true {
        didSet { UserDefaults.standard.set(showPinnedMessages, forKey: "cfg_pinned") }
    }
    /// Carte « Drops » en haut du chat quand la chaîne a des drops.
    @Published var showDropsNotice: Bool = true {
        didSet { UserDefaults.standard.set(showDropsNotice, forKey: "cfg_drops_notice") }
    }
    /// Sous la carte des drops : celles des campagnes de Twitch rangées dans
    /// la catégorie « Special Events » (« 1 Month of Apple TV »…), masquables
    /// sans perdre les drops de la chaîne. Coupées avec eux.
    @Published var showSpecialEvents: Bool = true {
        didSet { UserDefaults.standard.set(showSpecialEvents, forKey: "cfg_special_events") }
    }
    /// Afficher le bouton Suivre / Ne plus suivre.
    @Published var showFollowButton: Bool = true {
        didSet { UserDefaults.standard.set(showFollowButton, forKey: "cfg_follow") }
    }
    /// Cloche des notifications de live en haut à droite du chat. Masquée,
    /// celle de la page de la chaîne reste.
    @Published var showChatBell: Bool = true {
        didSet { UserDefaults.standard.set(showChatBell, forKey: "cfg_chat_bell") }
    }
    /// Pastilles des modes du salon (« Followers depuis 10 h », mode lent…)
    /// au-dessus du champ. Masquées, un message refusé dit toujours pourquoi.
    @Published var showChatModes: Bool = true {
        didSet { UserDefaults.standard.set(showChatModes, forKey: "cfg_chat_modes") }
    }
    /// Bouton couronne des points de la chaîne, à gauche du champ. Masqué,
    /// les points s'ouvrent depuis le menu ⋯ du chat.
    @Published var showChatPoints: Bool = true {
        didSet { UserDefaults.standard.set(showChatPoints, forKey: "cfg_chat_points") }
    }
    /// Afficher le badge de série de visionnage (streak).
    @Published var showWatchStreak: Bool = true {
        didSet { UserDefaults.standard.set(showWatchStreak, forKey: "cfg_streak") }
    }
    /// Afficher les événements live (sondages, prédictions, hype train).
    @Published var showLiveEvents: Bool = true {
        didSet { UserDefaults.standard.set(showLiveEvents, forKey: "cfg_events") }
    }
    /// Activer la détection des raids (bannière + auto-rejoindre).
    @Published var enableRaids: Bool = true {
        didSet { UserDefaults.standard.set(enableRaids, forKey: "cfg_raids") }
    }
    /// Sous « Événements live », chaque bandeau à part (Réglages →
    /// Personnaliser). Hype train coupé : il n'est plus relevé.
    @Published var showPolls: Bool = true {
        didSet { UserDefaults.standard.set(showPolls, forKey: "cfg_show_polls") }
    }
    @Published var showPredictions: Bool = true {
        didSet { UserDefaults.standard.set(showPredictions, forKey: "cfg_show_predictions") }
    }
    @Published var showHypeTrain: Bool = true {
        didSet { UserDefaults.standard.set(showHypeTrain, forKey: "cfg_show_hype") }
    }
    /// En paysage, bandeaux du chat (épinglé, drops, sondages, prédictions,
    /// raid) repliés en une ligne d'icônes au-dessus des messages.
    @Published var landscapeNoticesHidden: Bool = false {
        didSet { UserDefaults.standard.set(landscapeNoticesHidden, forKey: "cfg_land_notices_hidden") }
    }
    /// Vider le cache des emotes/badges en quittant le live (et l'app).
    @Published var autoPurgeImageCache: Bool = true {
        didSet { UserDefaults.standard.set(autoPurgeImageCache, forKey: "cfg_purge_cache") }
    }

    // MARK: – Lecteur
    /// Mode faible latence : demande le flux « low latency » à Twitch et garde
    /// la lecture au plus près du direct.
    @Published var lowLatency: Bool = false {
        didSet { UserDefaults.standard.set(lowLatency, forKey: "cfg_low_latency") }
    }

    /// Vitesse de lecture des VODs (pas des directs, ni des clips qui partent
    /// à 1×), gardée d'une VOD à l'autre. Une vitesse imposée par le lecteur
    /// immersif (refus, AirPlay, bord du DVR rattrapé) ne vaut que pour la
    /// lecture en cours (MainTabView.forcedVodSpeed). Même nom que le site
    /// dans la sauvegarde (« vodSpeed »).
    @Published var vodSpeed: Double = 1 {
        didSet { UserDefaults.standard.set(vodSpeed, forKey: "cfg_vod_speed") }
    }

    /// Qualité préférée au lancement d'un direct, d'une VOD ou d'un clip
    /// (`kQualityPrefs` : « source », une hauteur, « audio ») ; si elle
    /// manque, la plus proche en dessous (preferredQualityKey). Une qualité
    /// choisie dans le lecteur la remplace, comme sur le site. Même nom que
    /// le site dans la sauvegarde (« qualityPref »).
    @Published var preferredQuality: String = "source" {
        didSet { UserDefaults.standard.set(preferredQuality, forKey: "cfg_quality_pref") }
    }
    /// Qualité au lancement en données mobiles (`kCellularQualityPrefs`) :
    /// « auto » par défaut, la qualité suit le débit (NetworkStatus).
    @Published var cellularQuality: String = "auto" {
        didSet { UserDefaults.standard.set(cellularQuality, forKey: "cfg_quality_cellular") }
    }
    /// Qualités supérieures (1440p et plus, HEVC ou AV1) demandées au direct
    /// par le compte, coupé par défaut ; lu par getLive (HigherQualities).
    @Published var higherQualities: Bool = false {
        didSet { UserDefaults.standard.set(higherQualities, forKey: HigherQualities.key) }
    }
    /// Audio seul préféré : ce que retenaient les versions d'avant (gardé
    /// dans la sauvegarde pour elles).
    var preferAudioOnly: Bool { preferredQuality == "audio" }
    /// Qualité choisie à la main dans le lecteur : elle devient la préférence
    /// (« Auto » ne change rien, l'app ne le propose pas en réglage).
    func rememberQualityChoice(_ q: String, among keys: [String], variants: [String: VariantInfo] = [:]) {
        guard let pref = qualityPreference(for: q, among: keys, variants: variants),
              pref != preferredQuality else { return }
        preferredQuality = pref
        logger.settingChanged("Qualité préférée", value: pref)
    }

    /// Multi-live : le chat du direct qui a le son, à droite de la mosaïque
    /// (écran assez large : iPad, grand iPhone en paysage).
    @Published var multiLiveChat: Bool = true {
        didSet { UserDefaults.standard.set(multiLiveChat, forKey: "cfg_multi_chat") }
    }

    /// Lecteur immersif : commandes par-dessus l'image, comme sur Twitch.
    /// Désactivé = lecteur natif Apple (PiP et plein écran système).
    /// Activé par défaut : c'est le lecteur de l'app, le natif est le repli.
    @Published var immersivePlayer: Bool = true {
        didSet { UserDefaults.standard.set(immersivePlayer, forKey: "cfg_immersive") }
    }

    /// Activité en direct du lecteur (écran verrouillé, Dynamic Island).
    /// Coupée, celle en cours disparaît aussitôt et aucune autre ne démarre.
    @Published var liveActivity: Bool = true {
        didSet {
            UserDefaults.standard.set(liveActivity, forKey: PlayerActivity.key)
            if !liveActivity { PlayerActivity.end(playerClosed: false) }
        }
    }

    /// Ordre des sources du direct (« as », « al », « eu », « twitch ») :
    /// getLive les essaie l'une après l'autre (liveSourceSteps, même clé).
    @Published var liveSourceOrder: [String] = kLiveSources {
        didSet { UserDefaults.standard.set(liveSourceOrder, forKey: "liveSourceOrder") }
    }

    /// Monte (−1) ou descend (+1) une source d'un cran.
    func moveLiveSource(_ id: String, by delta: Int) {
        guard let i = liveSourceOrder.firstIndex(of: id), liveSourceOrder.indices.contains(i + delta) else { return }
        liveSourceOrder.swapAt(i, i + delta)
    }

    /// En tête de l'ordre (choisie dans le menu du lecteur).
    func preferLiveSource(_ id: String) {
        liveSourceOrder = [id] + liveSourceOrder.filter { $0 != id }
    }

    /// Abonné : le direct passe par le compte (session web) quand Twitch le
    /// sert sans pub sur cette chaîne — plus de pauses pub. Twitch voit alors
    /// le compte regarder, d'où le réglage. Jamais pour une chaîne où le
    /// compte aurait des pubs (getLive), sauf qualités supérieures : au-dessus
    /// de 1080p seulement, la source sans pub pendant ses pauses pub.
    @Published var subAdFree: Bool = true {
        didSet { UserDefaults.standard.set(subAdFree, forKey: "cfg_sub_adfree") }
    }

    /// Chaînes où une source a été choisie à la main pendant une lecture par
    /// le compte : le compte n'y est plus essayé jusqu'au prochain lancement,
    /// sinon getLive le remettrait en tête et le menu ne servirait à rien.
    var accountPlaybackSkipped: Set<String> = []

    /// Session web à donner à getLive pour `channel` ; nil : jeton anonyme,
    /// comme avant (réglage coupé, pas de session, session d'un autre compte).
    func accountPlaybackWebToken(for channel: String) -> String? {
        guard subAdFree, webSessionMismatch == nil,
              let web = twitchWebToken, !web.isEmpty,
              !accountPlaybackSkipped.contains(channel.lowercased()) else { return nil }
        return web
    }

    /// Audio spatial (AirPods) : « auto » = choix d'iOS (Centre de contrôle),
    /// « off » = jamais spatialisé dans l'app (voir SpatialAudio).
    /// Drops : pendant un live qui en a, la session du compte charge le flux
    /// (voir DropsHeartbeat) ; sans ça, Twitch ne compte rien.
    @Published var dropsProgress: Bool = true {
        didSet { UserDefaults.standard.set(dropsProgress, forKey: "cfg_drops_progress") }
    }

    /// Drops terminés réclamés automatiquement (lu aussi par DropsHeartbeat).
    @Published var autoClaimDrops: Bool = true {
        didSet { UserDefaults.standard.set(autoClaimDrops, forKey: "cfg_drops_autoclaim") }
    }

    /// Notification quand un drop est prêt ou réclamé (lu par DropsService).
    @Published var dropsNotify: Bool = true {
        didSet { UserDefaults.standard.set(dropsNotify, forKey: "cfg_drops_notify") }
    }

    @Published var spatialAudio: String = "auto" {
        didSet {
            UserDefaults.standard.set(spatialAudio, forKey: SpatialAudio.key)
            if spatialAudio != oldValue {
                NotificationCenter.default.post(name: .tuSpatialAudioChanged, object: nil)
            }
        }
    }

    /// Recadrer la vidéo pour remplir l'écran, au lieu de laisser des bandes
    /// noires. Coupe le haut et le bas : du 16:9 dans un écran de téléphone en
    /// paysage (≈2.16) ne peut pas à la fois tout montrer et tout remplir.
    @Published var fillScreen: Bool = false {
        didSet { UserDefaults.standard.set(fillScreen, forKey: "cfg_fill_screen") }
    }

    /// Quitter le lecteur (glissé vers le bas, flèche) ouvre l'image dans
    /// l'image au lieu du mini-lecteur, quand c'est possible (lecteur
    /// immersif, vidéo en lecture). Coupé par défaut : le mini-lecteur reste
    /// la règle. Propre à l'appareil (pas synchronisé, voir SettingsSync).
    @Published var pipOnLeave: Bool = false {
        didSet { UserDefaults.standard.set(pipOnLeave, forKey: "cfg_pip_on_leave") }
    }

    /// Place du chat en paysage : colonne, superposé à l'image, ou replié.
    /// Mémorisé, parce qu'on choisit ça une fois puis on n'y revient plus.
    @Published var landscapeChat: LandscapeChat = .column {
        didSet {
            UserDefaults.standard.set(landscapeChat.rawValue, forKey: "cfg_landscape_chat")
            if landscapeChat != .hidden { lastShownLandscapeChat = landscapeChat }
        }
    }
    /// Dernière façon d'afficher le chat en paysage : le double-tap la remet.
    private(set) var lastShownLandscapeChat: LandscapeChat = .column

    /// Chat affiché ↔ masqué en paysage (double-tap sur un direct) ; rend le
    /// nouvel état.
    @discardableResult
    func toggleLandscapeChatVisibility() -> LandscapeChat {
        landscapeChat = landscapeChat == .hidden ? lastShownLandscapeChat : .hidden
        return landscapeChat
    }

    // MARK: – Apparence du chat
    // La bonne taille dépend de l'écran, de la distance de lecture et de la vue
    // de chacun : autant la laisser se régler plutôt que d'en imposer une.
    @Published var chatFontSize: Double = 13 {
        didSet { UserDefaults.standard.set(chatFontSize, forKey: "cfg_chat_font") }
    }
    /// Espace vertical entre deux messages, en points. Chaque message en porte
    /// la moitié en haut et en bas : 8 reproduit l'aspect d'origine.
    @Published var chatSpacing: Double = 8 {
        didSet { UserDefaults.standard.set(chatSpacing, forKey: "cfg_chat_spacing") }
    }
    @Published var chatBadgeScale: Double = 1 {
        didSet { UserDefaults.standard.set(chatBadgeScale, forKey: "cfg_chat_badge") }
    }
    @Published var chatEmoteScale: Double = 1 {
        didSet { UserDefaults.standard.set(chatEmoteScale, forKey: "cfg_chat_emote") }
    }
    @Published var chatTimestamps: Bool = true {
        didSet { UserDefaults.standard.set(chatTimestamps, forKey: "cfg_chat_time") }
    }
    /// Heure du chat et du journal : « auto » (celle de l'appareil), « 12 » ou « 24 ».
    @Published var timeFormat: String = "auto" {
        didSet { UserDefaults.standard.set(timeFormat, forKey: ClockFormat.key) }
    }
    var clock12h: Bool { ClockFormat.uses12h(timeFormat) }
    /// Part de la largeur prise par le chat en paysage (colonne ou calque).
    @Published var chatWidthRatio: Double = 0.32 {
        didSet { UserDefaults.standard.set(chatWidthRatio, forKey: "cfg_chat_width") }
    }

    /// Bornes des tailles du chat, communes aux curseurs des Réglages, à
    /// l'import d'une sauvegarde et aux valeurs enregistrées : une valeur
    /// importée hors bornes (largeur du chat à 85 %) mettait le curseur en
    /// butée sur un chiffre qu'il ne pouvait pas montrer.
    static let chatFontRange: ClosedRange<Double> = 10...20
    static let chatSpacingRange: ClosedRange<Double> = 0...16
    static let chatScaleRange: ClosedRange<Double> = 0.5...2
    static let chatWidthRange: ClosedRange<Double> = 0.20...0.60

    static func clamped(_ v: Double, to range: ClosedRange<Double>) -> Double {
        min(max(v, range.lowerBound), range.upperBound)
    }

    // MARK: – Comportement du chat
    /// Charger les derniers messages du canal à l'arrivée (API tierce
    /// recent-messages.robotty.de : Twitch n'envoie rien d'antérieur au JOIN).
    @Published var chatLoadRecent: Bool = true {
        didSet { UserDefaults.standard.set(chatLoadRecent, forKey: "cfg_chat_recent") }
    }
    /// Proposer emotes et pseudos pendant la frappe.
    @Published var chatAutocomplete: Bool = true {
        didSet { UserDefaults.standard.set(chatAutocomplete, forKey: "cfg_chat_autocomplete") }
    }
    /// Suggestions du clavier iOS (mots proposés au-dessus, correction) dans
    /// le chat. Coupées, iOS ne touche plus aux noms d'emotes.
    @Published var chatKeyboardSuggestions: Bool = true {
        didSet { UserDefaults.standard.set(chatKeyboardSuggestions, forKey: "cfg_chat_kbd_suggest") }
    }
    /// Entrée envoie le message. Coupé (par défaut) : Entrée ferme le
    /// clavier, le bouton ➤ envoie.
    @Published var chatReturnSends: Bool = false {
        didSet { UserDefaults.standard.set(chatReturnSends, forKey: "cfg_chat_return_sends") }
    }
    /// Garder les messages supprimés, barrés, au lieu de les faire disparaître.
    @Published var chatShowDeleted: Bool = false {
        didSet { UserDefaults.standard.set(chatShowDeleted, forKey: "cfg_chat_deleted") }
    }
    /// Zone d'envoi du chat (champ, emotes, envoyer, points, menu ⋯). Coupée,
    /// pour qui ne fait que lire : la place revient aux messages, en portrait
    /// comme en paysage ; le menu ⋯ (et les points) restent à portée par de
    /// petits boutons posés sur le bas du chat (ChatView).
    @Published var chatShowInput: Bool = true {
        didSet { UserDefaults.standard.set(chatShowInput, forKey: "cfg_chat_input") }
    }

    /// Construit la présentation du chat : les réglages de l'utilisateur pour la
    /// taille, la disposition en cours pour le décor et la transparence.
    /// La taille du texte d'iOS (TType) s'applique par-dessus celle du chat,
    /// bornée à 30 pt : au-delà, une ligne ne tient plus que deux ou trois mots.
    func chatStyle(chrome: Bool, translucent: Bool) -> ChatStyle {
        ChatStyle(showsChrome: chrome,
                  showsTimestamp: chatTimestamps,
                  fontSize: min(max(CGFloat(chatFontSize), TType.scaled(CGFloat(chatFontSize))), 30),
                  rowPadding: CGFloat(chatSpacing) / 2,
                  badgeScale: CGFloat(chatBadgeScale),
                  emoteScale: CGFloat(chatEmoteScale),
                  translucent: translucent)
    }

    // MARK: – Comptage d'utilisation
    /// Signaler anonymement que cette installation est active.
    /// Voir Sources/Services/UsageService.swift pour ce qui part réellement.
    @Published var shareUsage: Bool = true {
        didSet { UserDefaults.standard.set(shareUsage, forKey: "cfg_share_usage") }
    }

    // MARK: – Synchro des réglages
    /// Synchroniser mes réglages avec le compte connecté (site, autres
    /// appareils) : voir SettingsSync.swift. Activé par défaut ; propre à cet
    /// appareil, jamais synchronisé lui-même. Coupé, rien ne part ni n'arrive ;
    /// réactivé, les réglages du compte sont relus tout de suite.
    @Published var syncSettings: Bool = true {
        didSet {
            UserDefaults.standard.set(syncSettings, forKey: "cfg_sync_settings")
            guard syncSettings != oldValue else { return }
            Task { @MainActor [weak self] in self?.settingsSyncToggled() }
        }
    }
    /// Dates, empreintes et file d'échanges de cette synchro.
    let prefsSync = SettingsSyncState()

    /// Chaîne à ouvrir dans l'onglet Recherche (depuis le lecteur, l'accueil…).
    /// L'onglet la consomme puis la remet à nil.
    @Published var pendingChannel: String? = nil
    func openChannelPage(_ login: String) {
        let l = login.trimmingCharacters(in: .whitespaces).lowercased()
        guard !l.isEmpty else { return }
        pendingChannel = l
    }

    /// Catégories suivies sur cet appareil (id, nom, jaquette).
    @Published var followedCategories: [TwitchCategory] = [] {
        didSet {
            let list = followedCategories.map { ["id": $0.id, "name": $0.name, "box": $0.boxArtURL] }
            UserDefaults.standard.set(list, forKey: "followed_categories")
        }
    }
    func isCategoryFollowed(_ id: String) -> Bool { followedCategories.contains { $0.id == id } }
    func toggleCategoryFollow(_ c: TwitchCategory) {
        if let i = followedCategories.firstIndex(where: { $0.id == c.id }) { followedCategories.remove(at: i) }
        else {
            followedCategories.insert(TwitchCategory(id: c.id, name: c.name, boxArtURL: c.boxArtURL), at: 0)
            // Suivre une catégorie masquée la réaffiche.
            if hidden.hides(category: c.id) { hidden.unhide(category: c.id) }
        }
    }

    /// Chaînes suivies par le compte Twitch, en minuscules (non enregistrées),
    /// lues au lancement, à la connexion et par l'accueil : jamais masquées,
    /// et l'export les ajoute aux suivis de l'appareil.
    var accountFollowLogins: [String] = []
    /// Catégories suivies sur Twitch (session web), lues au lancement, à la
    /// connexion de la session, par l'accueil et l'onglet Catégories (non
    /// enregistrées) : jamais masquées. Vidées quand la session web disparaît.
    var accountFollowedCategoryIds: Set<String> = []

    /// Suivis du compte, chaînes et catégories, quel que soit l'onglet
    /// affiché : seuls l'accueil et l'onglet Catégories les lisaient.
    @MainActor
    func loadAccountFollows() async {
        await loadAccountFollowLogins()
        await loadAccountFollowedCategories()
    }

    /// Chaînes suivies par le compte (Helix). En cas d'échec, la liste déjà
    /// connue est gardée ; sans compte, elle est vidée.
    @MainActor
    func loadAccountFollowLogins() async {
        guard let token = twitchToken else {
            accountFollowLogins = []
            return
        }
        // Connexion à l'instant : le compte n'est pas encore lu (l'accueil
        // s'en charge), son identifiant est demandé ici sans être gardé.
        var uid = twitchUserId ?? ""
        if uid.isEmpty, let user = await getTwitchUser(token: token) { uid = user.id }
        guard !uid.isEmpty, let logins = await getFollowedLogins(token: token, userId: uid),
              twitchToken == token else { return }
        accountFollowLogins = logins.map { $0.lowercased() }
    }

    /// Catégories suivies sur Twitch (session web). En cas d'échec, la liste
    /// déjà connue est gardée.
    @MainActor
    func loadAccountFollowedCategories() async {
        guard let web = twitchWebToken,
              let list = await getFollowedCategoriesGQL(webToken: web),
              twitchWebToken == web else { return }
        accountFollowedCategoryIds = Set(list.map(\.id))
    }

    /// Chaînes suivies sans compte Twitch (sur cet appareil), en minuscules.
    @Published var localFollows: [String] = [] {
        didSet { UserDefaults.standard.set(localFollows, forKey: "local_follows") }
    }
    func isLocallyFollowed(_ login: String) -> Bool { localFollows.contains(login.lowercased()) }
    func toggleLocalFollow(_ login: String) {
        let l = login.lowercased()
        if let i = localFollows.firstIndex(of: l) { localFollows.remove(at: i) }
        else if !l.isEmpty {
            localFollows.insert(l, at: 0)
            unhideChannel(l)
        }
    }

    /// Streamers épinglés (en minuscules) : en tête des suivis, en live comme
    /// hors ligne, dans l'ordre où on les a épinglés. Sur cet appareil.
    @Published var pinnedStreamers: [String] = [] {
        didSet { UserDefaults.standard.set(pinnedStreamers, forKey: "pinned_streamers") }
    }
    func isPinned(_ login: String) -> Bool { pinnedStreamers.contains(login.lowercased()) }
    /// Rang d'épinglage, nil si la chaîne n'est pas épinglée.
    func pinRank(_ login: String) -> Int? { pinnedStreamers.firstIndex(of: login.lowercased()) }
    func togglePin(_ login: String) {
        let l = login.lowercased()
        if let i = pinnedStreamers.firstIndex(of: l) { pinnedStreamers.remove(at: i) }
        else if !l.isEmpty { pinnedStreamers.append(l) }
    }

    // MARK: – Chaînes et catégories masquées (découverte)
    /// Masquées du top, de la grille des catégories et des lives d'une
    /// catégorie ; la recherche et les pages ouvertes directement montrent
    /// tout. Sur cet appareil, dans la sauvegarde (clé « hidden »).
    @Published var hidden = HiddenContent.load() {
        didSet { if hidden != oldValue { hidden.save() } }
    }

    /// Chaîne suivie (compte ou appareil) ou épinglée : jamais masquée.
    func isFollowedOrPinned(_ login: String) -> Bool {
        let l = login.lowercased()
        return isLocallyFollowed(l) || isPinned(l) || accountFollowLogins.contains(l)
    }
    /// Catégorie suivie, sur cet appareil ou sur Twitch : jamais masquée.
    func followsCategory(_ id: String) -> Bool {
        !id.isEmpty && (isCategoryFollowed(id) || accountFollowedCategoryIds.contains(id))
    }
    /// La chaîne passe le filtre, quelle que soit sa catégorie (lives d'une
    /// catégorie ouverte : elle est consultable même masquée).
    func showsChannel(_ login: String) -> Bool {
        isFollowedOrPinned(login) || !hidden.hides(channel: login)
    }
    /// Un live du top : ni sa chaîne ni sa catégorie ne sont masquées, sauf
    /// si on suit l'une ou l'autre.
    func showsStream(_ s: TwitchStream) -> Bool {
        isFollowedOrPinned(s.userLogin)
            || (!hidden.hides(channel: s.userLogin) && (followsCategory(s.gameId) || !hidden.hides(category: s.gameId)))
    }
    /// Une carte de la grille « Toutes » des catégories.
    func showsCategory(_ c: TwitchCategory) -> Bool {
        followsCategory(c.id) || !hidden.hides(category: c.id)
    }

    func hideChannel(login: String, name: String) {
        guard !isFollowedOrPinned(login) else { return }
        hidden.hide(channel: login, name: name)
        logger.info("MASQUÉS", "Chaîne masquée @\(login.lowercased())", nil)
    }
    func hideCategory(id: String, name: String, box: String) {
        guard !followsCategory(id) else { return }
        hidden.hide(category: id, name: name, box: box)
        logger.info("MASQUÉS", "Catégorie masquée \(id) (\(name))", nil)
    }
    func unhideChannel(_ login: String) {
        guard hidden.hides(channel: login) else { return }
        hidden.unhide(channel: login)
    }
    func unhideCategory(_ id: String) {
        guard hidden.hides(category: id) else { return }
        hidden.unhide(category: id)
    }
    func unhideAll() {
        hidden.unhideAll()
        logger.info("MASQUÉS", "Tout réaffiché", nil)
    }

    /// Accueil : chaînes en grille (cartes) ou en liste (façon Twitch).
    @Published var homeListLayout: Bool = false {
        didSet { UserDefaults.standard.set(homeListLayout, forKey: "cfg_home_list") }
    }
    /// Recherche : raccourcis vers les dernières chaînes ouvertes.
    @Published var showRecentChannels: Bool = true {
        didSet { UserDefaults.standard.set(showRecentChannels, forKey: "cfg_recent") }
    }
    /// Recherche : les 10 derniers textes cherchés (résultats en onglets), sur
    /// cet appareil. Effaçables d'un geste, ou avec l'historique (Réglages).
    @Published var searchHistory: [String] = [] {
        didSet { UserDefaults.standard.set(searchHistory, forKey: "search_history") }
    }
    func saveSearch(_ text: String) {
        let t = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        guard !t.isEmpty else { return }
        // La même recherche remonte en tête au lieu de se répéter.
        var list = searchHistory.filter { $0.lowercased() != t.lowercased() }
        list.insert(t, at: 0)
        searchHistory = Array(list.prefix(10))
    }
    func removeSearch(_ text: String) { searchHistory.removeAll { $0 == text } }
    func clearSearchHistory() { searchHistory = [] }
    /// Onglets, accueil et boutons du lecteur choisis dans Réglages →
    /// Personnaliser (voir Customization.swift), gardés en JSON.
    @Published var customization = UICustomization() {
        didSet {
            guard customization != oldValue,
                  let data = try? JSONEncoder().encode(customization) else { return }
            UserDefaults.standard.set(data, forKey: "cfg_customization")
        }
    }
    /// Onglet Découvrir dans la barre : l'ancien réglage, lu et écrit dans la
    /// personnalisation (sauvegardes d'avant elle).
    var showDiscoverTab: Bool {
        get { !customization.hiddenTabs.contains("discover") }
        set { customization.set("discover", hidden: !newValue, in: \.hiddenTabs) }
    }
    /// Réglages → Personnaliser → Rétablir : disposition et bandeaux du chat
    /// comme au premier lancement.
    func resetCustomization() {
        customization = UICustomization()
        showPinnedMessages = true; showDropsNotice = true; showSpecialEvents = true
        showLiveEvents = true; showPolls = true; showPredictions = true; showHypeTrain = true
        enableRaids = true; showWatchStreak = true; showFollowButton = true
        showChatBell = true; showChatModes = true; showChatPoints = true
    }

    /// Langue du top des lives ; nil = celle de l'appareil.
    @Published var topLang: String? = nil {
        didSet { UserDefaults.standard.set(topLang, forKey: "cfg_top_lang") }
    }

    /// Langue des lives dans les catégories (« fr »…) ; nil = toutes. La
    /// même pour toutes les catégories.
    @Published var categoryLang: String? = nil {
        didSet { UserDefaults.standard.set(categoryLang, forKey: "cfg_category_lang") }
    }

    // MARK: – Apparence
    /// Couleur d'accent, fond, verre liquide : voir Theme.swift. La palette
    /// partagée est remplacée aussitôt, les vues suivent.
    @Published var accent: AccentTheme = Theme.storedAccent {
        didSet {
            UserDefaults.standard.set(accent.rawValue, forKey: Theme.accentKey)
            Theme.palette = Palette(accent: accent, background: background)
        }
    }
    @Published var background: BackgroundTheme = Theme.storedBackground {
        didSet {
            UserDefaults.standard.set(background.rawValue, forKey: Theme.backgroundKey)
            Theme.palette = Palette(accent: accent, background: background)
        }
    }
    @Published var liquidGlass: Bool = Theme.liquidGlass {
        didSet {
            UserDefaults.standard.set(liquidGlass, forKey: Theme.glassKey)
            Theme.liquidGlass = liquidGlass
        }
    }
    /// Change avec le thème : MainTabView reconstruit les onglets dessus.
    var themeID: String { "\(accent.rawValue)-\(background.rawValue)-\(liquidGlass)" }

    // MARK: – Débogage (section temporaire)
    /// Afficher la latence du direct par-dessus le lecteur.
    @Published var showLatency: Bool = false {
        didSet { UserDefaults.standard.set(showLatency, forKey: "dbg_latency") }
    }
    /// Chat du direct synchronisé avec la vidéo (ChatSync), activé par défaut.
    /// Nouvelle clé : l'ancienne synchro auto, en essai (« dbg_chat_delay »),
    /// était coupée par défaut.
    @Published var chatSync: Bool = true {
        didSet { UserDefaults.standard.set(chatSync, forKey: "cfg_chat_sync") }
    }
    /// VODs récentes : remettre le son des passages coupés par Twitch quand
    /// l'original est encore sur le CDN (VodUnmuteLoader).
    @Published var restoreMutedAudio: Bool = true {
        didSet { UserDefaults.standard.set(restoreMutedAudio, forKey: "cfg_restore_muted") }
    }
    /// Téléchargements de VODs en Wi-Fi seulement (VodDownloads le lit dans
    /// UserDefaults) : désactivé par défaut. Changé, ce qui attendait le
    /// Wi-Fi repart, ou ce qui passe par les données mobiles s'arrête.
    @Published var downloadWifiOnly: Bool = false {
        didSet {
            UserDefaults.standard.set(downloadWifiOnly, forKey: "cfg_dl_wifi_only")
            guard downloadWifiOnly != oldValue else { return }
            Task { @MainActor in VodDownloads.shared.networkChanged() }
        }
    }
    /// Retouche de la synchro auto, en secondes (+ = chat plus tard). Le bon
    /// décalage dépend aussi du retard des autres spectateurs, qu'on ne peut
    /// qu'estimer : on laisse corriger d'une seconde ou deux.
    @Published var chatSyncNudge: Double = 0 {
        didSet { UserDefaults.standard.set(chatSyncNudge, forKey: "chat_sync_nudge") }
    }

    // MARK: – History
    @Published var history: [HistoryItem] = [] {
        didSet {
            persistHistory()
            // Fusion venue du serveur : pas un changement d'ici à renvoyer.
            guard !applyingSync else { return }
            syncDirty = true
            localRevision &+= 1
        }
    }

    // MARK: – VOD Progress
    @Published private(set) var vodProgress: [String: Double] = [:]

    // MARK: – Filtres du chat
    @Published var chatHideBots = false {
        didSet { UserDefaults.standard.set(chatHideBots, forKey: "chat_hide_bots") }
    }
    @Published var chatHideCommands = false {
        didSet { UserDefaults.standard.set(chatHideCommands, forKey: "chat_hide_commands") }
    }
    /// Mots masqués (minuscules) : les messages qui les contiennent disparaissent.
    @Published var chatMutedWords: [String] = [] {
        didSet { UserDefaults.standard.set(chatMutedWords, forKey: "chat_muted_words") }
    }
    /// Personnes masquées (logins en minuscules).
    @Published var chatBlockedUsers: [String] = [] {
        didSet { UserDefaults.standard.set(chatBlockedUsers, forKey: "chat_blocked_users") }
    }

    static let knownBots: Set<String> = ["nightbot", "streamelements", "moobot", "fossabot", "streamlabs",
        "wizebot", "soundalerts", "sery_bot", "botisimo", "own3d", "kofistreambot",
        "pokemoncommunitygame", "deepbot", "coebot", "phantombot", "creatisbot", "blerp"]

    /// Vrai si le message doit être masqué (réglages de filtres).
    func isChatFiltered(_ m: ChatMessage) -> Bool {
        let login = m.userName.lowercased()
        guard !login.isEmpty, m.userId != "system" else { return false }
        if login == twitchLogin?.lowercased() { return false }
        if chatBlockedUsers.contains(login) { return true }
        if chatHideBots && Self.knownBots.contains(login) { return true }
        guard chatHideCommands || !chatMutedWords.isEmpty else { return false }
        let text = m.tokens.map { t -> String in
            switch t {
            case .text(let s), .link(let s): return s
            case .mention(let s): return "@" + s
            case .emote(let e): return e.name
            case .gif(_, let alt): return alt
            }
        }.joined(separator: " ")
        if chatHideCommands && text.hasPrefix("!") { return true }
        let low = text.lowercased()
        return chatMutedWords.contains { low.contains($0) }
    }

    func toggleBlocked(_ login: String) {
        let l = login.lowercased()
        if let i = chatBlockedUsers.firstIndex(of: l) { chatBlockedUsers.remove(at: i) }
        else { chatBlockedUsers = Array((chatBlockedUsers + [l]).suffix(500)) }
    }

    /// Mots surlignés dans le chat (en plus des mentions), en minuscules.
    @Published var chatHighlightWords: [String] = [] {
        didSet { UserDefaults.standard.set(chatHighlightWords, forKey: "chat_highlight_words") }
    }

    /// Emotes masquées, par leur code exact (la casse compte : « KEKW » et
    /// « kekw » sont deux emotes), 200 au plus, la plus récente à la fin :
    /// dans le chat, elles s'affichent comme le mot tapé. Toutes sources
    /// (Twitch, BTTV, FFZ, 7TV), direct, VODs et multi-live. Même clé que le
    /// site (« hiddenEmotes »), dans la synchro des réglages et la sauvegarde.
    @Published var hiddenEmotes: [String] = [] {
        didSet {
            UserDefaults.standard.set(hiddenEmotes, forKey: "chat_hidden_emotes")
            hiddenEmoteSet = Set(hiddenEmotes)
        }
    }
    /// Les mêmes, pour la recherche faite à chaque emote affichée.
    private(set) var hiddenEmoteSet: Set<String> = []
    static let maxHiddenEmotes = 200

    func hidesEmote(_ code: String) -> Bool { hiddenEmoteSet.contains(code) }

    /// Masque l'emote, ou la réaffiche si elle l'était déjà. Au-delà de 200,
    /// les plus anciennes repartent.
    func toggleHiddenEmote(_ code: String) {
        guard let c = Self.emoteCodes([code]).first else { return }
        if let i = hiddenEmotes.firstIndex(of: c) {
            hiddenEmotes.remove(at: i)
            logger.settingChanged("Emote réaffichée", value: c)
        } else {
            hiddenEmotes = Array((hiddenEmotes + [c]).suffix(Self.maxHiddenEmotes))
            logger.settingChanged("Emote masquée", value: c)
        }
    }

    /// Codes d'emotes valides (sauvegarde, synchro, site) : sans espace ni
    /// retour à la ligne, 100 caractères au plus, sans doublon, 200 au plus
    /// (les derniers, les plus récents).
    static func emoteCodes(_ list: [String]) -> [String] {
        var seen = Set<String>()
        let valid = list
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 100 && !$0.contains(where: \.isWhitespace) }
            .filter { seen.insert($0).inserted }
        return Array(valid.suffix(maxHiddenEmotes))
    }

    // MARK: – Init
    init() {
        let ud = UserDefaults.standard
        chatHighlightWords = ud.stringArray(forKey: "chat_highlight_words") ?? []
        // Assignations de l'init : didSet n'y est pas appelé, l'ensemble suit à la main.
        hiddenEmotes       = Self.emoteCodes(ud.stringArray(forKey: "chat_hidden_emotes") ?? [])
        hiddenEmoteSet     = Set(hiddenEmotes)
        chatHideBots       = ud.bool(forKey: "chat_hide_bots")
        chatHideCommands   = ud.bool(forKey: "chat_hide_commands")
        chatMutedWords     = ud.stringArray(forKey: "chat_muted_words") ?? []
        chatBlockedUsers   = ud.stringArray(forKey: "chat_blocked_users") ?? []
        if let l = ud.string(forKey: "lang"), let parsed = Lang(rawValue: l) { lang = parsed }
        twitchToken = Keychain.loadToken("twitch_token")
        twitchUserId = ud.string(forKey: "twitch_user_id")
        twitchWebToken = Keychain.loadToken("twitch_web_token")
        twitchLogin = ud.string(forKey: "twitch_login")
        twitchAvatar = ud.string(forKey: "twitch_avatar")
        autoClaimChest = ud.object(forKey: "auto_claim_chest") as? Bool ?? true
        showPinnedMessages = ud.object(forKey: "cfg_pinned") as? Bool ?? true
        showDropsNotice    = ud.object(forKey: "cfg_drops_notice") as? Bool ?? true
        showSpecialEvents  = ud.object(forKey: "cfg_special_events") as? Bool ?? true
        showFollowButton   = ud.object(forKey: "cfg_follow") as? Bool ?? true
        showChatBell       = ud.object(forKey: "cfg_chat_bell") as? Bool ?? true
        showChatModes      = ud.object(forKey: "cfg_chat_modes") as? Bool ?? true
        showChatPoints     = ud.object(forKey: "cfg_chat_points") as? Bool ?? true
        showWatchStreak    = ud.object(forKey: "cfg_streak") as? Bool ?? true
        showLiveEvents     = ud.object(forKey: "cfg_events") as? Bool ?? true
        enableRaids        = ud.object(forKey: "cfg_raids")  as? Bool ?? true
        showPolls          = ud.object(forKey: "cfg_show_polls") as? Bool ?? true
        showPredictions    = ud.object(forKey: "cfg_show_predictions") as? Bool ?? true
        showHypeTrain      = ud.object(forKey: "cfg_show_hype") as? Bool ?? true
        landscapeNoticesHidden = ud.bool(forKey: "cfg_land_notices_hidden")
        autoPurgeImageCache = ud.object(forKey: "cfg_purge_cache") as? Bool ?? true
        // Actif par défaut depuis la 1.2.21 (direct à quelques secondes au lieu
        // d'une vingtaine) ; qui l'a coupé à la main le garde coupé.
        lowLatency         = ud.object(forKey: "cfg_low_latency") as? Bool ?? true
        vodSpeed           = VodSpeed.nearestSafe(ud.object(forKey: "cfg_vod_speed") as? Double ?? 1)
        multiLiveChat      = ud.object(forKey: "cfg_multi_chat") as? Bool ?? true
        immersivePlayer    = ud.object(forKey: "cfg_immersive")   as? Bool ?? true
        liveActivity       = PlayerActivity.enabled
        // Ordre des sources ; avant lui, une seule source préférée
        // (« liveSource »), mise en tête. Réécrit pour getLive.
        liveSourceOrder    = liveSourceSteps().filter { $0 != "worker" }
        ud.set(liveSourceOrder, forKey: "liveSourceOrder")
        subAdFree          = ud.object(forKey: "cfg_sub_adfree") as? Bool ?? true
        spatialAudio       = ud.string(forKey: SpatialAudio.key) == "off" ? "off" : "auto"
        dropsProgress      = ud.object(forKey: "cfg_drops_progress")  as? Bool ?? true
        autoClaimDrops     = ud.object(forKey: "cfg_drops_autoclaim") as? Bool ?? true
        dropsNotify        = ud.object(forKey: "cfg_drops_notify")    as? Bool ?? true
        fillScreen         = ud.object(forKey: "cfg_fill_screen") as? Bool ?? false
        pipOnLeave         = ud.object(forKey: "cfg_pip_on_leave") as? Bool ?? false
        landscapeChat      = LandscapeChat(rawValue: ud.string(forKey: "cfg_landscape_chat") ?? "")
                             ?? .column
        if landscapeChat != .hidden { lastShownLandscapeChat = landscapeChat }
        // Ramenées dans les bornes des curseurs : un import d'avant pouvait
        // les en sortir.
        chatFontSize       = Self.clamped(ud.object(forKey: "cfg_chat_font")    as? Double ?? 13, to: Self.chatFontRange)
        chatSpacing        = Self.clamped(ud.object(forKey: "cfg_chat_spacing") as? Double ?? 8, to: Self.chatSpacingRange)
        chatBadgeScale     = Self.clamped(ud.object(forKey: "cfg_chat_badge")   as? Double ?? 1, to: Self.chatScaleRange)
        chatEmoteScale     = Self.clamped(ud.object(forKey: "cfg_chat_emote")   as? Double ?? 1, to: Self.chatScaleRange)
        chatTimestamps     = ud.object(forKey: "cfg_chat_time")    as? Bool   ?? true
        timeFormat         = ["auto", "12", "24"].contains(ud.string(forKey: ClockFormat.key) ?? "") ? ud.string(forKey: ClockFormat.key)! : "auto"
        chatWidthRatio     = Self.clamped(ud.object(forKey: "cfg_chat_width")   as? Double ?? 0.32, to: Self.chatWidthRange)
        chatLoadRecent     = ud.object(forKey: "cfg_chat_recent")       as? Bool ?? true
        chatAutocomplete   = ud.object(forKey: "cfg_chat_autocomplete") as? Bool ?? true
        chatKeyboardSuggestions = ud.object(forKey: "cfg_chat_kbd_suggest") as? Bool ?? true
        chatReturnSends = ud.object(forKey: "cfg_chat_return_sends") as? Bool ?? false
        chatShowDeleted    = ud.object(forKey: "cfg_chat_deleted")      as? Bool ?? false
        chatShowInput      = ud.object(forKey: "cfg_chat_input")        as? Bool ?? true
        shareUsage         = ud.object(forKey: "cfg_share_usage") as? Bool ?? true
        syncSettings       = ud.object(forKey: "cfg_sync_settings") as? Bool ?? true
        // « zh_hk » importé du site par une version d'avant : ramené à « zh-hk ».
        topLang            = ud.string(forKey: "cfg_top_lang")
            .map { $0.replacingOccurrences(of: "_", with: "-") }
            .flatMap { TopLanguage.codes.contains($0) ? $0 : nil }
        categoryLang       = ud.string(forKey: "cfg_category_lang").flatMap { TopLanguage.codes.contains($0) ? $0 : nil }
        localFollows       = ud.stringArray(forKey: "local_follows") ?? []
        pinnedStreamers    = ud.stringArray(forKey: "pinned_streamers") ?? []
        followedCategories = (ud.array(forKey: "followed_categories") as? [[String: String]] ?? []).compactMap { d in
            guard let id = d["id"] else { return nil }
            return TwitchCategory(id: id, name: d["name"] ?? "", boxArtURL: d["box"] ?? "")
        }
        // Le tutoriel est pour le tout premier lancement : une installation qui
        // a déjà servi (mise à jour) ne le voit pas.
        if ud.object(forKey: "onboarding_done") == nil && ud.integer(forKey: "launch_count") > 0 {
            ud.set(true, forKey: "onboarding_done")
        }
        homeListLayout     = ud.bool(forKey: "cfg_home_list")
        showRecentChannels = ud.object(forKey: "cfg_recent") as? Bool ?? true
        searchHistory      = Array((ud.stringArray(forKey: "search_history") ?? []).prefix(10))
        if let saved = UICustomization.saved(ud) {
            customization = saved
        } else if ud.object(forKey: "cfg_discover_tab") as? Bool == false {
            // Avant Personnaliser : Découvrir masqué par son propre réglage.
            customization.hiddenTabs = ["discover"]
        }
        // Qualité préférée ; avant elle, seul l'audio seul était retenu.
        if let pref = ud.string(forKey: "cfg_quality_pref"), kQualityPrefs.contains(pref) {
            preferredQuality = pref
        } else {
            preferredQuality = ud.bool(forKey: "cfg_audio_only") ? "audio" : "source"
            ud.set(preferredQuality, forKey: "cfg_quality_pref")
        }
        if let cell = ud.string(forKey: "cfg_quality_cellular"), kCellularQualityPrefs.contains(cell) {
            cellularQuality = cell
        }
        higherQualities    = ud.bool(forKey: HigherQualities.key)
        showLatency        = ud.object(forKey: "dbg_latency")    as? Bool ?? false
        chatSync           = ud.object(forKey: "cfg_chat_sync")  as? Bool ?? true
        chatSyncNudge      = ud.double(forKey: "chat_sync_nudge")
        restoreMutedAudio  = ud.object(forKey: "cfg_restore_muted") as? Bool ?? true
        downloadWifiOnly   = ud.bool(forKey: "cfg_dl_wifi_only")
        // Lu élément par élément : un seul illisible ne vide plus toute la
        // liste. S'il en manque, la base de la synchro n'est plus fiable (un
        // élément perdu ici passerait pour supprimé) : elle est oubliée.
        var localIntact = true
        if let data = ud.data(forKey: "twitch_vod_history") {
            let items = try? JSONDecoder().decode([LossyDecodable<HistoryItem>].self, from: data)
            let readable = items?.compactMap(\.value) ?? []
            history = readable
            localIntact = items?.count == readable.count
        }
        if let data = ud.data(forKey: "vod_progress_all") {
            if let decoded = try? JSONDecoder().decode([String: Double].self, from: data) {
                vodProgress = decoded
            } else {
                localIntact = false
            }
        }
        // Compte dont ces données sont la copie : celui de l'app quand on est
        // connecté (installations d'avant ce suivi comprises).
        let storedOwner = ud.string(forKey: "sync_owner")
        syncOwner = storedOwner
        if let data = ud.data(forKey: "sync_detached") {
            syncDetached = try? JSONDecoder().decode(SyncStash.self, from: data)
        }
        if localIntact, let data = ud.data(forKey: "sync_base"),
           let base = try? JSONDecoder().decode(SyncBase.self, from: data) {
            syncBase = base
        } else {
            ud.removeObject(forKey: "sync_base")
        }
        if let id = twitchUserId, !id.isEmpty {
            if storedOwner == nil {
                syncOwner = id
                ud.set(id, forKey: "sync_owner")
            } else if storedOwner != id || syncDetached != nil {
                // Données d'un autre compte : jamais envoyées sur celui-ci,
                // mises de côté pour lui. Ou son compte, encore noté comme
                // ayant perdu son jeton : sa copie d'alors est reprise, sinon
                // aucun échange ne s'appliquerait plus (isLive).
                adoptSyncOwner(id)
            }
        }
        syncLoaded = true
        // Le chargement initial n'est pas un changement à envoyer.
        syncDirty = false
        // Filet de sécurité pendant une longue lecture : au plus un envoi par
        // `syncEvery`, et seulement s'il y a du neuf.
        syncTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.flushToCloud() }
        }
        // Réglages du compte : changements suivis (SettingsSync.swift).
        startSettingsSync()
    }

    // MARK: – Translation
    func t(_ key: String) -> String { translate(key, lang) }
    /// Texte accordé au nombre `n` (voir `translatePlural`).
    func tn(_ key: String, _ n: Int, abbreviated: Bool = false) -> String {
        translatePlural(key, n, lang, abbreviated: abbreviated)
    }

    // MARK: – Auth
    /// Nouveau jeton après une connexion. S'il change, l'identité gardée
    /// (id, pseudo, avatar) est oubliée : sinon, en se connectant à un autre
    /// compte, le nouveau jeton partait avec l'ancien id — sauvegarde et chat
    /// visaient le mauvais compte.
    func adoptToken(_ token: String) {
        oauthExpired = false
        let isNew = token != twitchToken
        if isNew {
            // Ce qui restait à envoyer part sur le compte d'avant, avec son
            // jeton, avant que son identité ne soit oubliée (réglages compris).
            finalCloudFlush()
            finalSettingsFlush()
            // Vu d'ici à ce que le compte de ce jeton soit connu : à lui, pas
            // au compte d'avant (adoptSyncOwner).
            markSyncDetached()
            twitchUserId = nil
            twitchLogin  = nil
            twitchAvatar = nil
            // Le refus « session web de @x » reste tant que la session web
            // manque : il ne part que si un AUTRE compte se connecte
            // (adoptSyncOwner), pas quand le même renouvelle son jeton.
        }
        twitchToken = token
        // Compté tout de suite comme compte, sans attendre l'heure suivante :
        // le Worker reprend l'historique anonyme de l'appareil et l'efface.
        if isNew {
            let enabled = shareUsage
            Task { await UsageService.shared.ping(enabled: enabled, force: true) }
        }
        // Suivis du compte relus quel que soit l'onglet affiché : ceux du
        // compte d'avant ne protègent plus rien du masquage.
        if isNew {
            accountFollowLogins = []
            Task { @MainActor [weak self] in await self?.loadAccountFollowLogins() }
        }
    }

    /// L'historique d'ici reste celui du compte, et une copie en est prise
    /// (repris s'il se reconnecte, mis de côté pour lui si un autre compte se
    /// connecte : adoptSyncOwner). Ce qui est vu ensuite, sans compte, suivra
    /// le prochain compte connecté ; ce qui est retiré ensuite ne lui est pas
    /// retiré.
    func logout() {
        finalCloudFlush()
        finalSettingsFlush()
        markSyncDetached()
        twitchToken    = nil
        twitchWebToken = nil
        webSessionMismatch = nil
        // Sans compte, plus de session web à rétablir : sinon l'accueil
        // annonçait « session expirée » dès la reconnexion.
        webSessionExpired = false
        Task { await TwitchWebSession.clear() }
        twitchUserId   = nil
        twitchLogin    = nil   // ← nettoyage complet
        twitchAvatar   = nil
        accountFollowLogins = []
        // La prochaine connexion demandera le compte au lieu de reprendre
        // celui dont Safari se souvient (TwitchAuthManager).
        UserDefaults.standard.set(true, forKey: TwitchAuthManager.privateSessionKey)
    }

    // MARK: – History management
    func saveToHistory(_ item: HistoryItem) {
        var filtered = history.filter { $0.term.lowercased() != item.term.lowercased() }
        filtered.insert(item, at: 0)
        // 50 : l'historique mélange chaînes et VODs, 20 faisait disparaître les
        // VODs vues dès qu'on enchaînait quelques recherches de streamers.
        history = Array(filtered.prefix(50))
    }

    func removeFromHistory(term: String) {
        history.removeAll { $0.term == term }
        sendDeletion()
    }

    func clearChannelHistory() {
        history = history.filter { $0.type == .vod }
        sendDeletion()
    }

    /// Réglages → Effacer l'historique : chaînes, VODs, positions de reprise
    /// et recherches récentes.
    func clearHistory() {
        history = []
        searchHistory = []
        vodProgress = [:]
        progressChanged()
        sendDeletion()
    }

    /// Bibliothèque → Effacer : les VODs et leurs positions de reprise.
    func clearVodHistory() {
        let ids = Set(history.filter { $0.type == .vod }.map(\.term))
        history = history.filter { $0.type != .vod }
        vodProgress = vodProgress.filter { !ids.contains($0.key) }
        progressChanged()
        sendDeletion()
    }

    /// Une suppression part tout de suite (relecture et fusion d'abord) : le
    /// site et les autres appareils la voient sans attendre le prochain envoi.
    private func sendDeletion() {
        Task { @MainActor [weak self] in self?.flushToCloud(force: true) }
    }

    private func persistHistory() {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: "twitch_vod_history")
        }
    }

    // MARK: – VOD progress
    func getVodProgress(_ vodId: String) -> Double { vodProgress[vodId] ?? 0 }

    func setVodProgress(_ vodId: String, time: Double) {
        // Le lecteur appelle ceci toutes les 0,5 s : chaque appel réencodait
        // tout le dictionnaire dans UserDefaults et republiait le store (donc
        // redessinait l'interface). Écart de 5 s minimum, sauf saut (reprise
        // DVR, retour au début).
        guard time.isFinite, time >= 0 else { return }
        if let old = vodProgress[vodId], abs(time - old) < 5 { return }
        vodProgress[vodId] = time
        // Borné aux 500 VODs les plus récentes (identifiants croissants).
        if vodProgress.count > 500 { vodProgress = Self.cappedProgress(vodProgress) }
        progressChanged()
    }

    /// « Continuer à regarder » d'une sauvegarde (Backup) : les VODs absentes
    /// de l'historique y entrent à leur date (le plus récent d'abord, 50 au
    /// plus, comme saveToHistory), et la position la plus avancée l'emporte.
    /// Rend le nombre de VODs ajoutées ou avancées.
    func importContinueWatching(_ items: [HistoryItem], progress incoming: [String: Double]) -> Int {
        var changed = Set<String>()
        var list = history
        let known = Set(list.map { $0.term.lowercased() })
        for item in items where !known.contains(item.term.lowercased()) {
            list.append(item)
            changed.insert(item.term)
        }
        var positions = vodProgress
        for (id, t) in incoming where t.isFinite && t > (positions[id] ?? 0) + 1 {
            positions[id] = t
            changed.insert(id)
        }
        guard !changed.isEmpty else { return 0 }
        let sorted = Array(list.enumerated()
            .sorted { a, b in
                a.element.addedAt != b.element.addedAt
                    ? a.element.addedAt > b.element.addedAt
                    : a.offset < b.offset
            }
            .map(\.element)
            .prefix(50))
        if sorted != history { history = sorted }
        if positions != vodProgress {
            vodProgress = Self.cappedProgress(positions)
            progressChanged()
        }
        // Celles restées dans l'historique : la rangée de l'accueil en vient.
        let kept = Set(sorted.map(\.term))
        return changed.filter { kept.contains($0) }.count
    }

    /// « Continuer à regarder » → Retirer de la liste : la position de
    /// reprise de cette VOD est oubliée (elle reste dans l'historique et
    /// repart du début). Comme une suppression, elle part tout de suite ; la
    /// relecture ne la ramène pas tant que le serveur n'a pas bougé
    /// (mergeProgress).
    func forgetVodProgress(_ vodId: String) {
        guard vodProgress[vodId] != nil else { return }
        vodProgress[vodId] = nil
        progressChanged()
        sendDeletion()
    }

    private func progressChanged() {
        persistProgress()
        syncDirty = true
        localRevision &+= 1
    }

    private func persistProgress() {
        if let data = try? JSONEncoder().encode(vodProgress) {
            UserDefaults.standard.set(data, forKey: "vod_progress_all")
        }
    }

    /// Les 500 VODs les plus récentes (identifiants croissants).
    private static func cappedProgress(_ p: [String: Double]) -> [String: Double] {
        guard p.count > 500 else { return p }
        let keep = Set(p.keys.sorted { (Int($0) ?? 0) > (Int($1) ?? 0) }.prefix(500))
        return p.filter { keep.contains($0.key) }
    }

    // MARK: – Cloud Sync
    //
    // Sauvegarde partagée avec le site, sur le Worker. Les écritures gratuites
    // sont comptées : un changement ne fait que marquer la sauvegarde « à
    // envoyer », et l'envoi part à la fermeture d'une vidéo, au passage en
    // arrière-plan, après une suppression, sinon au plus toutes les
    // 10 minutes — jamais si le serveur a déjà tout.
    //
    // Le Worker garde l'historique reçu tel quel : chaque envoi relit donc
    // d'abord le serveur et fusionne (syncOnce). Sans ça, un envoi effaçait
    // ce que le site ou un autre appareil avait ajouté entre-temps, et une
    // relecture ratée (réinstallation hors ligne) laissait remplacer tout
    // l'historique du compte. Les échanges passent un par un, sur le fil
    // principal, et seulement pour le compte dont les données d'ici sont la
    // copie (syncOwner).
    //
    // Règle de la fusion : rien de ce qui est ici ne disparaît parce que le
    // serveur ne l'a pas. Le Worker n'a ni révision ni marqueur de
    // suppression, et un onglet du site ouvert avant, une app 1.3.0 ou un
    // autre appareil dont l'envoi croise celui-ci réécrivent la liste
    // entière avec ce qu'ils connaissent : une absence ne prouve rien. Seule
    // une suppression faite ici, compte connecté, se propage (mergeHistory) ;
    // faite sans compte, elle ne retire rien au compte parti (syncDetached).

    private var syncDirty = false
    /// Faux tant qu'init n'a pas lu les données de la synchro : le
    /// changement de compte (adoptSyncOwner) attend qu'elles soient là.
    private var syncLoaded = false
    /// Compte les changements d'ici (historique, progression) : un envoi
    /// réussi ne marque la sauvegarde « à jour » que s'il n'y en a pas eu
    /// pendant la requête.
    private var localRevision = 0
    /// Vrai pendant qu'une fusion venue du serveur s'applique.
    private var applyingSync = false
    private var lastSyncAt  = Date.distantPast
    /// Dernière relecture RÉUSSIE : une relecture ratée se retente au
    /// prochain passage au premier plan au lieu d'attendre 10 minutes.
    private var lastPullAt  = Date.distantPast
    private var syncTimer: Timer?
    private let syncEvery: TimeInterval = 600
    private let pullEvery: TimeInterval = 600
    /// Change avec le compte : un échange parti pour l'ancien ne touche plus
    /// aux données d'ici.
    private var syncGeneration = 0
    /// Échanges en file, un seul à la fois ; une demande identique déjà en
    /// attente suffit.
    private var syncChain: Task<Void, Never>?
    private var pullQueued = false
    private var pushQueued = false

    /// Compte dont l'historique et la progression d'ici sont la copie (nil :
    /// aucun compte encore, ils rejoindront le premier).
    private var syncOwner: String? {
        didSet {
            if let o = syncOwner { UserDefaults.standard.set(o, forKey: "sync_owner") }
            else { UserDefaults.standard.removeObject(forKey: "sync_owner") }
        }
    }

    /// Copie de l'historique et des positions d'ici, prise quand le compte en
    /// place a perdu son jeton (déconnexion, autre jeton) ; nil s'il n'en a
    /// pas perdu. C'est elle qu'il retrouve (adoptSyncOwner) : ce qui se fait
    /// ensuite sans lui n'y touche pas. Des vues qui poussent ses éléments
    /// hors des 50, « Effacer » ou une suppression sans compte ne passent
    /// donc jamais pour des suppressions de lui (la base les aurait retirées
    /// de sa sauvegarde), même pour ce qui n'était pas encore parti. Ce qui
    /// n'y figure pas, ou y a été revu depuis, a été vu sans ce compte : il
    /// suit le prochain compte connecté.
    private var syncDetached: SyncStash? {
        didSet {
            if let d = syncDetached, let data = try? JSONEncoder().encode(d) {
                UserDefaults.standard.set(data, forKey: "sync_detached")
            } else {
                UserDefaults.standard.removeObject(forKey: "sync_detached")
            }
        }
    }

    /// Ce que le serveur avait au dernier échange réussi, pour ce compte et
    /// ce Worker. Sert de marqueur des suppressions faites ici : un élément
    /// qu'elle contient et qui n'est plus ici a été retiré ici. Le marqueur
    /// tient tant que le serveur a encore l'élément (une relecture remet la
    /// liste du serveur) et tombe avec l'envoi qui le retire (la base devient
    /// la liste envoyée).
    private var syncBase: SyncBase? {
        didSet {
            if let b = syncBase, let data = try? JSONEncoder().encode(b) {
                UserDefaults.standard.set(data, forKey: "sync_base")
            } else {
                UserDefaults.standard.removeObject(forKey: "sync_base")
            }
        }
    }

    /// Compte, jeton et Worker d'un échange.
    private struct SyncTarget {
        let userId: String
        let token: String
        let base: String
        var key: String { "\(base)|\(userId)" }
    }

    /// Terme (minuscules) → date d'ajout, et VOD → position, tels que le
    /// serveur les avait.
    private struct SyncBase: Codable {
        let key: String
        var history: [String: Double]
        var progress: [String: Double]
    }

    /// Données d'un compte au moment d'un dernier envoi (déconnexion, autre
    /// jeton) : ce qui part si l'appareil a changé de compte entre-temps.
    private struct SyncSnapshot {
        let history: [HistoryItem]
        let progress: [String: Double]
        let base: SyncBase?
    }

    /// Copie d'ici d'un compte : prise quand il perd son jeton
    /// (syncDetached), mise de côté avec sa base (ses suppressions pas encore
    /// envoyées) quand il laisse l'appareil à un autre. Le dernier envoi peut
    /// avoir échoué, et un client périmé peut encore retirer un élément de
    /// son serveur : tant que cette copie existe, rien n'est perdu. Reprise
    /// quand le compte revient, puis fusionnée et renvoyée.
    private struct SyncStash: Codable {
        var history: [HistoryItem]
        var progress: [String: Double]
        var base: SyncBase?
        /// Pour ne garder que les comptes les plus récents.
        var savedAt: Double

        init(history: [HistoryItem], progress: [String: Double], base: SyncBase?, savedAt: Double) {
            self.history = history
            self.progress = progress
            self.base = base
            self.savedAt = savedAt
        }

        // Lu élément par élément, comme l'historique : un élément illisible
        // (écrit par une version plus récente) ne fait pas perdre le reste.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            history = ((try? c.decode([LossyDecodable<HistoryItem>].self, forKey: .history)) ?? [])
                .compactMap(\.value)
            progress = (try? c.decode([String: Double].self, forKey: .progress)) ?? [:]
            base = try? c.decodeIfPresent(SyncBase.self, forKey: .base)
            savedAt = (try? c.decode(Double.self, forKey: .savedAt)) ?? 0
        }
    }

    private static let stashesKey = "sync_stashes"
    /// Comptes dont une copie est gardée : 5 au plus, en jetant d'abord la
    /// plus ancienne de celles qui sont déjà sur leur serveur (isSent). Une
    /// copie qui a du neuf pas encore envoyé (dernier envoi raté) n'est
    /// jetée qu'au-delà de 10, pour borner la place prise.
    private static let stashesMax = 5
    private static let stashesHardMax = 10

    private static func loadStashes() -> [String: SyncStash] {
        guard let data = UserDefaults.standard.data(forKey: stashesKey),
              let stashes = try? JSONDecoder().decode([String: SyncStash].self, from: data) else { return [:] }
        return stashes
    }

    private static func saveStashes(_ stashes: [String: SyncStash]) {
        if stashes.isEmpty {
            UserDefaults.standard.removeObject(forKey: stashesKey)
        } else if let data = try? JSONEncoder().encode(stashes) {
            UserDefaults.standard.set(data, forKey: stashesKey)
        }
    }

    private var syncTarget: SyncTarget? {
        guard let id = twitchUserId, !id.isEmpty, id == syncOwner,
              let token = twitchToken, !token.isEmpty else { return nil }
        return SyncTarget(userId: id, token: token, base: APIConfig.base)
    }

    /// Compte de l'app connu (connexion, changement de compte) : les données
    /// d'ici deviennent les siennes.
    /// - Même compte (reconnexion) : ce qui a été vu sans compte entre-temps
    ///   part sur lui, et sa copie d'alors revient (syncDetached) : rien de
    ///   ce qui a été retiré sans lui ne lui est retiré.
    /// - AUTRE compte : les données du précédent quittent l'affichage, sinon
    ///   le premier envoi les écrivait sur la sauvegarde de celui-ci (et sur
    ///   le site). Elles ne sont pas effacées : sa copie d'alors est mise de
    ///   côté pour lui (dernier envoi peut-être raté), reprise s'il revient.
    ///   Ce qui a été vu depuis qu'il a perdu son jeton (sans compte, ou déjà
    ///   avec celui-ci) n'est pas à lui : ça reste ici et part sur le nouveau.
    /// - Aucun compte avant : tout le rejoint, comme avant.
    private func adoptSyncOwner(_ id: String) {
        // Nouvelle connexion : relue tout de suite, pas 10 minutes plus tard
        // (réglages compris).
        lastPullAt = .distantPast
        lastSyncAt = .distantPast
        settingsAccountChanged()
        let detached = syncDetached
        syncDetached = nil
        if syncOwner == id {
            if let detached {
                takeBack(detached)
                logger.info("SYNC", "☁️ Même compte : copie d'avant la déconnexion reprise",
                            "\(detached.history.count) élément(s)")
            }
            return
        }
        if let previous = syncOwner {
            // Absent de l'historique quand le jeton est parti, ou revu depuis.
            let was = detached.map { Self.terms($0.history) } ?? [:]
            let kept = detached == nil ? [] : history.filter { h in
                guard let at = was[h.term.lowercased()] else { return true }
                return h.addedAt > at + 1
            }
            let keptTerms = Set(kept.map { $0.term.lowercased() })
            stashLocalData(for: previous, copy: detached)
            logger.info("SYNC", "☁️ Autre compte : historique du précédent mis de côté",
                        kept.isEmpty ? nil : "\(kept.count) élément(s) vu(s) sans lui gardé(s)")
            applyingSync = true
            history = kept
            applyingSync = false
            vodProgress = vodProgress.filter { keptTerms.contains($0.key) }
            persistProgress()
            syncDirty = !kept.isEmpty
            // Refus propre au compte d'avant (« session web de @x ») : ne
            // vaut plus pour celui-ci.
            webSessionMismatch = nil
        }
        syncBase = nil
        syncOwner = id
        syncGeneration &+= 1
        restoreStash(for: id)
    }

    /// Le compte en place perd son jeton (déconnexion, autre jeton) : ce que
    /// l'historique et les positions contiennent maintenant est à lui (la
    /// copie syncDetached), ce qui viendra ensuite ne le sera pas. La
    /// première fois compte (déconnexion, puis connexion d'un autre compte).
    private func markSyncDetached() {
        guard syncDetached == nil, syncOwner != nil else { return }
        syncDetached = SyncStash(history: history, progress: vodProgress, base: nil,
                                 savedAt: Date().timeIntervalSince1970)
    }

    /// Copie de `owner` mise de côté jusqu'à son retour : celle prise quand
    /// il a perdu son jeton (`copy`), ou, sans elle (relance avec un autre
    /// compte enregistré), tout ce qui est ici ; avec sa base. Un élément
    /// revu sans lui y reste à sa date d'alors.
    private func stashLocalData(for owner: String, copy: SyncStash?) {
        let items = copy?.history ?? history
        let progress = copy?.progress ?? vodProgress
        // Rien ici mais une base : ce qu'elle contient a été retiré ici
        // (« Effacer ») sans être encore envoyé, à garder aussi.
        let removedHere = !(syncBase?.history.isEmpty ?? true) || !(syncBase?.progress.isEmpty ?? true)
        guard !items.isEmpty || !progress.isEmpty || removedHere else { return }
        var stashes = Self.loadStashes()
        stashes[owner] = SyncStash(history: items, progress: progress, base: syncBase,
                                   savedAt: Date().timeIntervalSince1970)
        while stashes.count > Self.stashesMax {
            // La plus ancienne des copies déjà sur leur serveur ; s'il n'y en a
            // pas, la plus ancienne tout court, mais au-delà du plafond dur
            // seulement : sinon, rien ne part.
            let sent = stashes.filter { Self.isSent($0.value) }
            let pool = sent.isEmpty && stashes.count > Self.stashesHardMax ? stashes : sent
            guard let oldest = pool.min(by: { $0.value.savedAt < $1.value.savedAt })?.key else { break }
            stashes.removeValue(forKey: oldest)
        }
        Self.saveStashes(stashes)
    }

    /// Tout ce que la copie contient était sur le serveur au dernier échange
    /// (sa base, à 1 ms près) : la jeter ne perd rien qu'il n'ait eu. Seules
    /// comptent les positions des VODs de son historique, les seules
    /// envoyées.
    private static func isSent(_ stash: SyncStash) -> Bool {
        guard let base = stash.base else { return stash.history.isEmpty && stash.progress.isEmpty }
        let vodIds = Set(stash.history.filter { $0.type == .vod }.map(\.term))
        let historySent = stash.history.allSatisfy { h in
            guard let at = base.history[h.term.lowercased()] else { return false }
            return abs(at - h.addedAt) <= 1
        }
        return historySent && stash.progress.allSatisfy {
            !vodIds.contains($0.key) || $0.value.rounded() <= (base.progress[$0.key] ?? 0)
        }
    }

    /// Copie d'un compte reprise ici : unie à ce qui est là (le plus récent,
    /// la position la plus avancée). Envoyée ensuite, après relecture, comme
    /// toujours.
    private func takeBack(_ copy: SyncStash) {
        let merged = Self.mergeHistory(local: history, remote: copy.history, base: nil)
        if merged != history { history = merged }
        vodProgress = Self.mergeProgress(local: vodProgress, remote: copy.progress, base: nil)
        progressChanged()
    }

    /// Ce qui avait été mis de côté pour ce compte revient (takeBack), avec
    /// sa base pour que ses suppressions pas encore envoyées tiennent.
    private func restoreStash(for owner: String) {
        var stashes = Self.loadStashes()
        guard let stash = stashes.removeValue(forKey: owner) else { return }
        takeBack(stash)
        syncBase = stash.base
        Self.saveStashes(stashes)
        logger.info("SYNC", "☁️ Historique mis de côté pour ce compte repris",
                    "\(stash.history.count) élément(s)")
    }

    /// Relit la sauvegarde si la dernière relecture réussie date de plus de
    /// 10 minutes. Une lecture ne coûte presque rien. Les réglages du compte
    /// suivent le même rythme, à part (SettingsSync.swift).
    @MainActor
    func refreshFromCloudIfStale(userId: String? = nil) async {
        refreshSettingsIfStale()
        guard let target = syncTarget, userId == nil || userId == target.userId,
              Date().timeIntervalSince(lastPullAt) > pullEvery else { return }
        await requestSync(push: false).value
    }

    /// Envoie la sauvegarde si elle a changé, après relecture et fusion.
    /// `force` ignore l'intervalle minimal (fermeture d'une vidéo,
    /// arrière-plan, suppression).
    @MainActor
    func flushToCloud(force: Bool = false) {
        guard syncDirty, syncTarget != nil,
              force || Date().timeIntervalSince(lastSyncAt) >= syncEvery else { return }
        lastSyncAt = Date()
        // Laisse à l'échange le temps de finir si l'app vient de passer en
        // arrière-plan : sans ça, iOS peut la suspendre en pleine requête.
        let bg = BackgroundTaskBox()
        bg.id = UIApplication.shared.beginBackgroundTask(withName: "sync") { bg.end() }
        let task = requestSync(push: true)
        Task { @MainActor in
            await task.value
            bg.end()
        }
    }

    /// Dernier envoi pour le compte en place, juste avant que son jeton ne
    /// parte (déconnexion, autre jeton) : compte, jeton et données pris
    /// maintenant.
    private func finalCloudFlush() {
        guard syncDirty, let target = syncTarget else { return }
        let snapshot = SyncSnapshot(history: history, progress: vodProgress,
                                    base: syncBase?.key == target.key ? syncBase : nil)
        let bg = BackgroundTaskBox()
        bg.id = UIApplication.shared.beginBackgroundTask(withName: "sync") { bg.end() }
        Task { @MainActor [weak self] in
            if let self {
                await self.enqueueSync { _ = await self.syncOnce(target, push: true, snapshot: snapshot) }.value
            }
            bg.end()
        }
    }

    @MainActor
    @discardableResult
    private func requestSync(push: Bool) -> Task<Void, Never> {
        if let chain = syncChain, pushQueued || (!push && pullQueued) { return chain }
        if push { pushQueued = true } else { pullQueued = true }
        return enqueueSync { [weak self] in
            guard let self else { return }
            if push { self.pushQueued = false } else { self.pullQueued = false }
            // Compte lu au moment de l'échange, pas à la demande.
            guard let target = self.syncTarget else { return }
            _ = await self.syncOnce(target, push: push)
        }
    }

    @MainActor
    private func enqueueSync(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = syncChain
        let task = Task { @MainActor in
            await previous?.value
            await work()
        }
        syncChain = task
        return task
    }

    /// Échange dont le résultat peut s'appliquer ici : même compte qu'à son
    /// départ, toujours connecté.
    private func isLive(_ target: SyncTarget, _ generation: Int) -> Bool {
        generation == syncGeneration && syncOwner == target.userId && syncDetached == nil
    }

    /// Un échange : relecture, fusion (appliquée ici si le compte n'a pas
    /// changé entre-temps), puis envoi si `push` et que le serveur n'a pas
    /// déjà tout. Rien ne part sans une relecture réussie juste avant.
    /// false si la relecture ou l'envoi a échoué.
    @MainActor
    @discardableResult
    private func syncOnce(_ target: SyncTarget, push: Bool, snapshot: SyncSnapshot? = nil) async -> Bool {
        let generation = syncGeneration
        guard let remote = await Self.fetchCloud(target) else { return false }
        // Même compte qu'à la demande, qui a toujours son jeton : la fusion
        // s'applique ici. Sinon (autre compte, ou déconnexion entre-temps),
        // seul l'instantané d'un dernier envoi part, et rien du serveur de ce
        // compte n'entre plus ici : ce qui arriverait passerait pour vu sans
        // lui et suivrait le compte suivant (adoptSyncOwner).
        let live = isLive(target, generation)
        guard live || snapshot != nil else { return false }
        let base = live ? (syncBase?.key == target.key ? syncBase : nil) : snapshot?.base
        let local = live ? history : (snapshot?.history ?? [])
        let merged = Self.mergeHistory(local: local, remote: remote.history, base: base?.history)
        let progress = Self.mergeProgress(local: live ? vodProgress : (snapshot?.progress ?? [:]),
                                          remote: remote.progress, base: base?.progress)
        // Seule la progression des VODs de l'historique part : le Worker garde
        // les autres (il fusionne en gardant la plus avancée).
        let vodIds = Set(merged.filter { $0.type == .vod }.map(\.term))
        let sent = progress.filter { vodIds.contains($0.key) && $0.value.isFinite }.mapValues { $0.rounded() }
        // Comparé en ensembles : l'ordre ne compte pas (l'app trie à la
        // lecture). Deux appareils qui rangent autrement des éléments sans
        // date (anciens, venus du site) réécrivaient sinon le serveur à
        // chaque échange.
        let changed = Set(Self.historyKeys(merged)) != Set(Self.historyKeys(remote.history))
            || sent.contains { $0.value > (remote.progress[$0.key] ?? 0) }
        if live {
            let known = Set(local.map { $0.term.lowercased() })
            applyFromCloud(history: merged, progress: progress)
            syncBase = SyncBase(key: target.key, history: Self.terms(remote.history),
                                progress: remote.progress)
            lastPullAt = Date()
            syncDirty = changed
            logger.syncPull(items: merged.filter { !known.contains($0.term.lowercased()) }.count)
        }
        guard push, changed else { return true }

        guard let body = Self.syncBody(userId: target.userId, history: merged, progress: sent),
              let url = URL(string: "\(target.base)/api/sync/post") else { return false }
        let revision = localRevision
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(target.token)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        let status = ((try? await URLSession.shared.data(for: request))?.1 as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            // Toujours « à envoyer » : le prochain passage réessaie.
            logger.warn("SYNC", "☁️ Envoi refusé", status == 0 ? "réseau" : "HTTP \(status)")
            return false
        }
        logger.syncPush(items: merged.count)
        // Le serveur a maintenant cette liste ; pour la progression, il garde
        // la plus avancée des deux. Seulement si elle est aussi celle d'ici :
        // après un instantané, la base dirait « supprimé ici » de ce que le
        // serveur avait en plus.
        if live, isLive(target, generation),
           var b = syncBase, b.key == target.key {
            b.history = Self.terms(merged)
            for (id, t) in sent { b.progress[id] = max(b.progress[id] ?? 0, t) }
            syncBase = b
            if localRevision == revision { syncDirty = false }
        }
        return true
    }

    /// Sauvegarde du compte sur le Worker ; nil si elle n'a pas pu être lue
    /// (réseau, jeton refusé, erreur du serveur).
    private static func fetchCloud(_ target: SyncTarget) async -> (history: [HistoryItem], progress: [String: Double])? {
        // Le Worker exige le jeton Twitch du propriétaire de la sauvegarde.
        guard let url = URL(string: "\(target.base)/api/sync/get?userId=\(target.userId)") else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("Bearer \(target.token)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: request) else {
            logger.warn("SYNC", "☁️ Relecture impossible", "réseau — rien n'est envoyé")
            return nil
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logger.warn("SYNC", "☁️ Relecture refusée", "HTTP \(status) — rien n'est envoyé")
            return nil
        }
        var history: [HistoryItem] = []
        if let raw = json["history"] as? [Any],
           let histData = try? JSONSerialization.data(withJSONObject: raw),
           let items = try? JSONDecoder().decode([LossyDecodable<HistoryItem>].self, from: histData) {
            history = items.compactMap(\.value)
        }
        var progress: [String: Double] = [:]
        for (id, value) in json["progress"] as? [String: Any] ?? [:] {
            // Borné : une valeur aberrante venue du serveur faisait planter
            // la conversion en Int de la bibliothèque.
            if let n = value as? NSNumber, n.doubleValue.isFinite, n.doubleValue > 0 {
                progress[id] = min(n.doubleValue, 7 * 24 * 3600)
            }
        }
        return (history, progress)
    }

    /// Fusion de l'historique d'ici et de celui du serveur.
    /// - Ici : tout reste. Absent du serveur ne veut pas dire supprimé
    ///   ailleurs (liste périmée du site, d'une app 1.3.0, envoi croisé d'un
    ///   autre appareil) : l'élément repart. Une suppression faite sur le
    ///   site ou un autre appareil n'est donc pas suivie ici, comme avant ;
    ///   au pire un élément revient, jamais un élément vu ici ne se perd.
    /// - Supprimé ici (connu de la base, absent d'ici, pas rajouté là-bas
    ///   depuis) : il ne revient pas, et l'envoi suivant le retire du
    ///   serveur. Avant, toute relecture le remettait.
    /// - Sans base (premier échange, autre compte, autre Worker) : union.
    /// Le plus récent d'abord, 50 au plus.
    private static func mergeHistory(local: [HistoryItem], remote: [HistoryItem],
                                     base: [String: Double]?) -> [HistoryItem] {
        func key(_ h: HistoryItem) -> String { h.term.lowercased() }
        // Connu de la base et pas rajouté depuis (1 ms de marge : dates
        // passées par le JSON du serveur).
        func deletedHere(_ r: HistoryItem) -> Bool {
            guard let b = base?[key(r)] else { return false }
            return r.addedAt <= b + 1
        }
        var remoteByKey: [String: HistoryItem] = [:]
        for r in remote where remoteByKey[key(r)] == nil { remoteByKey[key(r)] = r }
        var seen = Set<String>()
        var out: [HistoryItem] = []
        for l in local {
            let k = key(l)
            guard seen.insert(k).inserted else { continue }
            if let r = remoteByKey[k] {
                out.append(r.addedAt > l.addedAt ? r.filled(from: l) : l.filled(from: r))
            } else {
                out.append(l)
            }
        }
        for r in remote {
            // Supprimé ici depuis le dernier échange : il ne revient pas.
            guard seen.insert(key(r)).inserted, !deletedHere(r) else { continue }
            out.append(r)
        }
        // Le plus récent d'abord ; les éléments sans date (anciens, venus du
        // site) en fin de liste, dans leur ordre.
        return Array(out.enumerated()
            .sorted { a, b in
                a.element.addedAt != b.element.addedAt
                    ? a.element.addedAt > b.element.addedAt
                    : a.offset < b.offset
            }
            .map(\.element)
            .prefix(50))
    }

    /// Positions de reprise : la plus avancée l'emporte, comme sur le Worker,
    /// sauf un recul fait ici (VOD reprise du début) quand le serveur n'a pas
    /// bougé depuis le dernier échange : la position d'ici reste, au lieu de
    /// remonter dès l'envoi de la fermeture (le serveur, lui, garde la plus
    /// avancée). Seulement à 30 s ou plus : rien ne dit qu'un recul est
    /// voulu, et une position de passage (0 écrit avant que la reprise ne
    /// s'applique, lecteur fermé pendant le chargement) aurait figé la
    /// reprise ici tant que le serveur ne bouge pas ; elle remonte à la
    /// relecture suivante. Une position effacée ici (« Effacer », plafond de
    /// 500) que le serveur n'a pas bougée depuis le dernier échange ne
    /// revient pas.
    private static func mergeProgress(local: [String: Double], remote: [String: Double],
                                      base: [String: Double]?) -> [String: Double] {
        var out = local
        for (id, r) in remote {
            if let l = local[id] {
                if let b = base?[id], abs(r - b) < 1, abs(l - b) >= 1, l >= 30 {
                    out[id] = l
                } else {
                    out[id] = max(l, r)
                }
            } else if let b = base?[id], abs(r - b) < 1 {
                continue
            } else {
                out[id] = r
            }
        }
        return cappedProgress(out)
    }

    /// Résultat d'une fusion, sans le marquer « à envoyer » : syncOnce dit
    /// lui-même si le serveur l'a déjà.
    private func applyFromCloud(history newHistory: [HistoryItem], progress newProgress: [String: Double]) {
        if newHistory != history {
            applyingSync = true
            history = newHistory
            applyingSync = false
        }
        if newProgress != vodProgress {
            vodProgress = newProgress
            persistProgress()
        }
    }

    /// Ce que le serveur doit avoir de l'historique (terme, date) : une
    /// différence suffit à justifier un envoi.
    private static func historyKeys(_ h: [HistoryItem]) -> [String] {
        h.map { "\($0.term.lowercased())|\($0.addedAt.rounded())" }
    }

    private static func terms(_ h: [HistoryItem]) -> [String: Double] {
        Dictionary(h.map { ($0.term.lowercased(), $0.addedAt) }, uniquingKeysWith: { first, _ in first })
    }

    private static func syncBody(userId: String, history: [HistoryItem], progress: [String: Double]) -> Data? {
        guard let histData = try? JSONEncoder().encode(history),
              let histJSON = try? JSONSerialization.jsonObject(with: histData) else { return nil }
        return try? JSONSerialization.data(
            withJSONObject: ["userId": userId, "data": ["history": histJSON, "progress": progress]],
            options: [.sortedKeys])
    }
}

private extension HistoryItem {
    /// Champs absents de cette version repris de l'autre version du même
    /// élément (la photo d'une chaîne, mise par le site, par exemple).
    func filled(from other: HistoryItem) -> HistoryItem {
        HistoryItem(term: term, type: type, display: display,
                    thumb: thumb ?? other.thumb, streamer: streamer ?? other.streamer,
                    addedAt: addedAt, avatar: avatar ?? other.avatar)
    }
}

/// Tâche d'arrière-plan à clore une seule fois, quel que soit le premier
/// des deux à finir : la requête, ou le délai accordé par iOS.
final class BackgroundTaskBox {
    var id: UIBackgroundTaskIdentifier = .invalid
    // Pas d'annotation d'acteur : appelé depuis le délai d'expiration d'iOS,
    // dont l'isolation varie selon la version du SDK. Toujours sur le fil
    // principal en pratique (délai d'expiration, MainActor.run).
    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

/// Vitesses de lecture proposées pour les VODs : la même liste que le site.
/// Plafond à 2× : sans playlist I-frame (Twitch n'en publie pas),
/// `canPlayFastForward` est faux et AVPlayer ne garantit que 1× à 2×
/// (AVPlayerItem.h). Au-delà, `experimental` : proposées à part dans le menu
/// ⋯ du lecteur immersif, pour la lecture en cours seulement (jamais dans la
/// préférence, la sauvegarde ni la synchro), et ramenées à 2× dès que la
/// vitesse n'est pas tenue (ImmersivePlayerModel).
enum VodSpeed {
    static let all: [Double] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]
    static let experimental: [Double] = [2.25, 2.5, 3]
    /// Plus haute vitesse garantie par AVPlayer sans playlist I-frame.
    static let maxSafe: Double = 2

    /// Au-delà de 2× : une vitesse expérimentale.
    static func isExperimental(_ v: Double) -> Bool { v > maxSafe + 0.01 }

    /// Cran le plus proche (valeur venue d'une sauvegarde, d'AirPlay…),
    /// vitesses expérimentales comprises : une vitesse de 3× tenue par le
    /// lecteur ne doit pas passer pour un 2× imposé.
    static func nearest(_ v: Double) -> Double {
        guard v.isFinite, v > 0 else { return 1 }
        return (all + experimental).min { abs($0 - v) < abs($1 - v) } ?? 1
    }

    /// Cran le plus proche jusqu'à 2× : la préférence retenue, et le lecteur
    /// natif, dont le menu d'Apple n'a que ces crans.
    static func nearestSafe(_ v: Double) -> Double {
        min(maxSafe, nearest(v))
    }

    /// « 1,5× » : virgule en français, espagnol, russe et italien, point en
    /// anglais, en japonais et en chinois (Taïwan écrit « 1.5 »).
    static func label(_ v: Double, _ lang: Lang) -> String {
        var s = String(format: "%g", v)
        if lang != .en && lang != .ja && lang != .zhHant { s = s.replacingOccurrences(of: ".", with: ",") }
        return s + "×"
    }
}
