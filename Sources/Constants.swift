import SwiftUI

// MARK: – API
let kAPIURL          = "https://test2.kurzmathis4.workers.dev"
let kHelixClientID   = "1e68ku2ehgzy5cy0di3xvfy82sxpf6"
let kGQLClientID     = "kimne78kx3ncx6brgo4mv6wki5h1ko"
let kRedirectURI     = "https://mxfia19.github.io/TwitchUnblock/auth.html"
let kDeepLinkScheme  = "twitchunblock://"

/// Miroirs Luminous (source « sans pub »), essayés dans l'ordre : si l'un est
/// indisponible on passe au suivant. as = Asie (historique),
/// eu/eu2/eu3 = Europe (recommandés pour le mobile).
let kLuminousHosts = [
    "as.luminous.dev",
    "eu.luminous.dev",
    "eu2.luminous.dev",
    "eu3.luminous.dev"
]

// MARK: – Colors
extension Color {
    static let tPrimary   = Color(hex: "9146ff")
    static let tDark      = Color(hex: "0e0e10")
    static let tCard      = Color(hex: "18181b")
    static let tSurface   = Color(hex: "26262c")
    static let tBorder    = Color(hex: "3a3a40")
    static let tText      = Color(hex: "efeff1")
    static let tMuted     = Color(hex: "888888")
    static let tDanger    = Color(hex: "ff4f4d")
    static let tLive      = Color(hex: "e91916")
    static let tSuccess   = Color(hex: "00ff88")
    static let tWarning   = Color(hex: "e6e619")
    static let tPurple    = Color(hex: "bf94ff")
    static let tVLC       = Color(hex: "ff8800")
    static let tOutplayer = Color(hex: "007aff")
    static let tInfuse    = Color(hex: "fc3c44")

    init(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h = String(h.dropFirst()) }
        var rgb: UInt64 = 0
        Scanner(string: h).scanHexInt64(&rgb)
        self.init(
            red:   Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8)  & 0xFF) / 255,
            blue:  Double(rgb         & 0xFF) / 255
        )
    }

    /// Couleur de pseudo lisible sur fond sombre : éclaircit les couleurs trop
    /// sombres/noires (sinon un pseudo noir est illisible).
    static func readableChat(hex: String) -> Color {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h = String(h.dropFirst()) }
        guard h.count == 6 else { return Color(hex: hex) }
        var rgb: UInt64 = 0
        Scanner(string: h).scanHexInt64(&rgb)
        var r = Double((rgb >> 16) & 0xFF) / 255
        var g = Double((rgb >> 8)  & 0xFF) / 255
        var b = Double(rgb         & 0xFF) / 255
        // Luminance perçue
        let lum = 0.299 * r + 0.587 * g + 0.114 * b
        let minLum = 0.45
        if lum < minLum {
            // Mélange vers le blanc pour remonter au seuil minimal
            let f = min(1, (minLum - lum) / minLum + 0.15)
            r += (1 - r) * f; g += (1 - g) * f; b += (1 - b) * f
        }
        return Color(red: r, green: g, blue: b)
    }
}

// MARK: – Language
enum Lang: String, CaseIterable, Identifiable {
    case fr, en, es
    var id: String { rawValue }
    var flag: String {
        switch self { case .fr: "🇫🇷"; case .en: "🇬🇧"; case .es: "🇪🇸" }
    }
    var label: String {
        switch self { case .fr: "Français"; case .en: "English"; case .es: "Español" }
    }
}

// ✨ NOUVEAU : Les sources se traduisent automatiquement !
enum LiveSource: String, CaseIterable, Identifiable, Codable {
    case auto, luminous, twitch, cloudflare
    var id: String { rawValue }

    // Lit la langue actuelle choisie par l'utilisateur
    private var currentLang: Lang {
        let saved = UserDefaults.standard.string(forKey: "lang") ?? "fr"
        return Lang(rawValue: saved) ?? .fr
    }

    var displayName: String {
        switch self {
        case .auto:       return translate("source_auto", currentLang)
        case .luminous:   return translate("source_luminous", currentLang)
        case .twitch:     return translate("source_twitch", currentLang)
        case .cloudflare: return translate("source_cloudflare", currentLang)
        }
    }
    
    var subtitle: String {
        switch self {
        case .auto:       return translate("source_auto_sub", currentLang)
        case .luminous:   return translate("source_luminous_sub", currentLang)
        case .twitch:     return translate("source_twitch_sub", currentLang)
        case .cloudflare: return translate("source_cloudflare_sub", currentLang)
        }
    }
    
    var emoji: String {
        switch self {
        case .auto:       return "✨"
        case .luminous:   return "💡"
        case .twitch:     return "🟣"
        case .cloudflare: return "☁️"
        }
    }
}

// MARK: – Translations
private let translations: [Lang: [String: String]] = [
    .fr: [
        "title": "Regarder Twitch sans Sub",
        "tab_home": "Accueil", "tab_search": "Recherche", "tab_library": "Mes VODs",
        "tab_direct": "Lien / ID", "settings": "Paramètres",
        "tab_history": "VODs",
        "ph_streamer": "Streamer (ex: squeezie)", "ph_keyword": "Mot-clé (ex: horreur)",
        "ph_id": "ID ou Lien de la VOD",
        "btn_unlock": "Déverrouiller", "btn_search": "Chercher",
        "btn_watch_live": "Regarder le direct", "btn_copy": "Copier",
        "btn_pip": "PiP", "btn_refresh": "🔄 Actualiser",
        "btn_logout": "Déconnexion", "btn_login_twitch": "🟣 Se connecter avec Twitch",
        "btn_clear": "Effacer",
        "loading": "Chargement...", "loading_vod": "Lancement VOD...",
        "loading_channels": "Chargement de vos chaînes...", "loading_top": "Chargement du Top...",
        "vod_ready": "VOD en lecture !", "live_on": "EN DIRECT", "offline": "HORS LIGNE",
        "offline_since": "Hors ligne depuis : ", "no_vod": "Aucune VOD trouvée.",
        "no_live": "Aucune chaîne en live pour le moment.", "vods_found": "VODs trouvées.",
        "not_found": "❌ Streamer introuvable.", "err_missing": "Nom manquant.",
        "err_network": "Erreur réseau.", "err_live": "Erreur Live.",
        "err_conn": "Erreur connexion.", "err_loading": "Erreur lors du chargement.",
        "login_prompt": "Connectez-vous pour retrouver vos chaînes préférées.",
        "login_required": "Connectez-vous pour voir les streams en cours.",
        "session_expired": "Session expirée. Veuillez vous reconnecter.",
        "lbl_vod_history": "VODs récemment regardées", "lbl_channel_history": "Streamers récents",
        "followed_channels": "Vos chaînes suivies", "top_streams": "Top streams",
        "top_fr": "France", "top_world": "Monde", "copied": "Lien copié !",
        "day": "j", "hour": "h", "min": "min", "offline_msg": "Pas de stream en cours.",
        "open_vlc": "Ouvrir dans VLC", "open_outplayer": "Ouvrir dans Outplayer",
        "open_infuse": "Ouvrir dans Infuse", "proxy": "Proxy",
        "reduce": "Réduire", "back": "Retour", "live_badge": "EN DIRECT",
        "no_result": "Aucun résultat", "confirm_logout": "Êtes-vous sûr de vouloir vous déconnecter ?",
        "cancel": "Annuler", "clear_logs": "Effacer les logs", "confirm": "Confirmer ?",
        "erase": "Effacer", "export": "📤 Exporter", "logs_empty": "Aucun log",
        "logs_hint": "Lance une VOD ou un stream pour voir les logs",
        "about": "À propos", "version": "Version 1.0.0",
        "about_desc": "Regardez vos VODs et streams Twitch sans sub, avec accès aux qualités complètes via votre serveur proxy personnel.",
        "show_logs": "Afficher les logs système",
        "connected": "Connecté", "not_connected": "Non connecté",
        "history": "Historique", "vods": "VODs", "channels": "Chaînes",
        "proxy_sub": "Désactiver pour économiser le serveur (utile pour VLC)",
        "proxy_enable": "Activer le proxy", "twitch_account": "Compte Twitch",
        "language": "Langue",
        "settings_source": "Serveur / Source Vidéo",
        
        // Traductions sources
        "source_auto": "Auto",
        "source_auto_sub": "Meilleure source disponible",
        "source_luminous": "Luminous",
        "source_luminous_sub": "Sans publicité (recommandé)",
        "source_twitch": "Twitch Officiel",
        "source_twitch_sub": "Avec publicités",
        "source_cloudflare": "Cloudflare Worker",
        "source_cloudflare_sub": "Proxy personnel",

        // Chat & Points
        "chat_connected": "Chat connecté", "chat_connecting": "Connexion...",
        "chat_send_ph": "Envoyer un message…", "chat_connecting_ph": "Connexion en cours…",
        "chat_follow": "Suivre", "chat_first_message": "Premier message",
        "thread_title": "Fil", "thread_reply_to": "Réponse à",
        "follow": "Suivre", "following": "Suivi", "hype_level": "Niveau",
        "raid_to": "Raid vers", "join": "Rejoindre", "viewers": "spectateurs",
        "customize": "Personnalisation",
        "cfg_title": "Titre du live", "cfg_title_sub": "Afficher le titre au-dessus du chat",
        "cfg_pinned": "Messages épinglés", "cfg_pinned_sub": "Afficher le bandeau des messages épinglés",
        "cfg_follow": "Bouton suivre", "cfg_follow_sub": "Afficher le bouton Suivre / Ne plus suivre",
        "cfg_streak": "Série de visionnage", "cfg_streak_sub": "Afficher le badge 🔥 de ta série",
        "cfg_events": "Sondages & prédictions", "cfg_events_sub": "Afficher sondages, prédictions et hype train",
        "cfg_raids": "Système de raid", "cfg_raids_sub": "Bannière + rejoindre automatiquement la chaîne raidée",
        "cache_section": "Cache emotes & badges",
        "vod_chat": "Chat de la VOD",
        "rewind": "Rembobiner", "back_to_live": "Direct",
        "history_vods_title": "Vos dernières VODs",
        "history_vods_empty": "Aucune VOD dans votre historique pour le moment.",
        "vod_chat_loading": "Chargement du chat…",
        "vod_chat_empty": "Aucun message à cet instant de la VOD",
        "cache_size": "Espace utilisé", "cache_files": "fichiers",
        "cache_clear": "Vider",
        "cache_auto": "Vider en quittant",
        "cache_auto_sub": "Purge le cache en quittant le live ou l'application",
        "account_api": "Connexion API", "account_api_sub": "Chat, chaînes suivies et Top",
        "account_web": "Session web (points)", "account_web_sub": "Requise pour les points de chaîne",
        "login_points_hint": "Pour les points de chaîne, connecte-toi aussi en « Session web » depuis les Réglages ⚙️",
        "points_title": "Points de chaîne",
        "points_connect_title": "Connecte ton compte Twitch",
        "points_connect_desc": "Nécessaire pour afficher ton solde et réclamer les coffres.",
        "points_connect_btn": "Se connecter",
        "points_loading": "Chargement des récompenses…",
        "points_none": "Aucune récompense disponible",
        "points_claim_bonus": "Réclamer le bonus", "points_bonus_claimed": "Bonus réclamé ! 🎉",
        "points_redeem": "Racheter", "points_insufficient": "Insuff.",
        "points_out_of_stock": "Rupture de stock", "points_paused": "En pause",
        "points_input_ph": "Votre message…", "points_unit": "pts",
        "points_redeemed": "réclamé ✓", "points_error": "Erreur",
        "points_network_error": "Erreur réseau", "points_missing": "Il te manque",
        "points_by": "par",
        "err_not_enough": "Pas assez de points", "err_reward_not_found": "Récompense introuvable",
        "err_points_disabled": "Points désactivés", "err_already_claimed": "Déjà réclamé",
        "err_cooldown": "Attends un peu",
        "err_properties_mismatch": "Récompense modifiée, réessaie",
        "err_stream_offline": "Le stream n'est pas en direct",
        "auto_claim": "Réclamer les coffres auto",
        "auto_claim_sub": "Récupère les coffres de points dès qu'ils apparaissent.",
        "player_section": "Lecteur vidéo",
        "sec_general": "Général", "sec_player": "Lecteur", "sec_chat": "Chat", "sec_other": "À propos",
        "chat_behavior": "Comportement du chat",
        "cfg_recent": "Charger les messages récents",
        "cfg_recent_sub": "Twitch n'envoie rien d'antérieur à l'arrivée. Les dernières lignes sont récupérées auprès de recent-messages.robotty.de, un service tiers.",
        "cfg_autocomplete": "Autocomplétion",
        "cfg_autocomplete_sub": "Propose emotes et pseudos pendant la frappe.",
        "cfg_deleted": "Afficher les messages supprimés",
        "cfg_deleted_sub": "Garde barrés les messages retirés par la modération au lieu de les faire disparaître.",
        "copy_message": "Copier le message", "mention_user": "Mentionner",
        "msg_copied": "Message copié",
        "chat_sizing": "Taille du chat",
        "cfg_timestamps": "Horodatage", "cfg_timestamps_sub": "Affiche l'heure devant chaque message.",
        "cfg_font_size": "Taille du texte", "cfg_msg_spacing": "Espace entre messages",
        "cfg_badge_scale": "Taille des badges", "cfg_emote_scale": "Taille des emotes",
        "cfg_chat_width": "Largeur du chat",
        "cfg_chat_width_sub": "En paysage seulement, que le chat soit en colonne ou posé sur l'image.",
        "reset_defaults": "Rétablir les valeurs par défaut",
        "vlc_player": "Lecteur VLC",
        "vlc_player_sub": "Contrôles maison : double-tap ±10s, rembobinage live. (pas de PiP)",
        "go_live": "EN DIRECT",

        // Catégories
        "streams": "Streams", "categories": "Catégories",
        "cat_search_ph": "Rechercher une catégorie…",
        "load_more": "Charger plus",
        "sort_viewers_desc": "Plus de spectateurs",
        "sort_viewers_asc": "Moins de spectateurs",
        "sort_name": "Nom (A → Z)",

        // Minuteur de veille
        "sleep_timer": "Minuteur de veille",
        "sleep_timer_sub": "Coupe la lecture au bout du délai choisi.",
        "sleep_minutes": "min", "sleep_hour": "1 h", "sleep_2hours": "2 h",
        "sleep_remaining": "Temps restant",
        "sleep_cancel": "Annuler",
        "sleep_add": "+15 min",

        // Débogage
        "debug_section": "Débogage",
        "debug_note": "Section temporaire, pensée pour être retirée plus tard.",
        "dbg_latency": "Afficher la latence",
        "dbg_latency_sub": "Pastille sur le lecteur : retard du direct en secondes",
        "dbg_chat_delay": "Synchro auto du chat",
        "dbg_chat_delay_sub": "Retarde les messages de la latence mesurée pour les caler sur l'image",
        "sleep_custom_ph": "Durée", "sleep_start": "Démarrer",
        "sleep_set": "Régler", "sleep_edit": "Modifier",
        "low_latency": "Mode faible latence",
        "low_latency_sub": "Reste au plus près du direct (comme sur Twitch). Peut charger un peu plus souvent sur une connexion lente. S'applique au prochain direct lancé.",
        "delete_vod": "Retirer de l'historique",
        "usage_section": "Utilisation de l'app",
        "usage_returning": "Reviennent",
        "usage_loyalty_once": "1 seul jour", "usage_loyalty_few": "2 à 6 jours",
        "usage_loyalty_regular": "7 à 29 jours", "usage_loyalty_daily": "30 jours et +",
        "usage_avg_days": "moy.", "usage_since": "depuis le",
        "usage_today": "Aujourd'hui", "usage_week": "7 jours", "usage_month": "30 jours",
        "usage_versions": "Par version",
        "usage_refresh": "Actualiser",
        "usage_tap_refresh": "Appuie sur Actualiser pour relever les compteurs.",
        "usage_worker_missing": "Le serveur n'a pas encore les routes de comptage. Voir worker/README.md pour les déployer.",
        "usage_error": "Compteurs indisponibles pour le moment.",
        "usage_share": "Partager mon utilisation",
        "usage_share_sub": "Envoie un identifiant tiré au hasard à l'installation et la version de l'app, une fois par heure au plus. Ni compte Twitch, ni chaînes regardées, ni adresse IP. Couper efface l'identifiant du serveur.",
        "immersive_player": "Lecteur immersif",
        "immersive_player_sub": "Commandes et infos par-dessus l'image, qui s'effacent toutes seules. Désactivé : lecteur Apple avec ses contrôles, PiP et plein écran système.",
        "quality": "Qualité",
        "rewind_sub": "Revenir en arrière dans le direct",
        "menu_chat_only": "Chat seul",
        "chat_mode_column": "Chat : colonne",
        "chat_mode_overlay": "Chat : superposé",
        "chat_mode_hidden": "Chat : masqué",
        "menu_chat_only_sub": "Masque la vidéo et garde la conversation en plein écran.",
        "menu_reload_emotes": "Recharger emotes et badges",
        "menu_reload_emotes_sub": "Vide le cache et récupère tout à neuf.",
        "menu_reconnect": "Reconnecter le chat",
        "menu_reconnect_sub": "Relance la connexion sans quitter le direct.",
        "menu_color": "Couleur du pseudo",
        "menu_color_sub": "Change ta couleur dans le chat.",
        "menu_needs_login": "Connexion requise",
        "menu_chatters": "Chatteurs",
        "menu_chatters_sub": "Qui est présent dans le chat.",
        "menu_chatters_search": "Filtrer les pseudos…",
        "menu_chatters_empty": "Personne annoncé sur cette chaîne",
        "menu_chatters_waiting": "En attente de la liste du chat…",
        "menu_chatters_note": "Twitch a fermé son API de présence : seul le chat IRC annonce encore les arrivées, et uniquement sur les chaînes de taille modeste. La liste peut donc rester vide sur les gros directs.",
        "color_needs_relogin": "Déconnecte-toi puis reconnecte-toi : l'autorisation « changer la couleur » a été ajoutée après ta connexion.",
        "color_network": "Impossible de joindre Twitch.",
        "color_bad_request": "Couleur refusée par Twitch.",
        "color_failed": "Twitch a refusé le changement de couleur.",
        "role_broadcaster": "Streamer", "role_moderator": "Modérateurs",
        "ph_search": "Streamer, lien ou ID de VOD…",
        "btn_open": "Ouvrir",
        "hint_is_vod": "Ouvrira cette VOD",
        "hint_is_channel": "Cherchera cette chaîne",
        "err_bad_vod": "Lien ou ID de VOD invalide.",
        "search_empty_title": "Cherche une chaîne ou colle un lien",
        "search_empty_msg": "Tape un nom de streamer, ou colle le lien / l'ID d'une VOD : l'app reconnaît les deux.",
        "no_followed_live": "Aucune de vos chaînes n'est en direct",
        "no_followed_live_msg": "Jetez un œil au Top ou aux catégories en attendant.",
        "history_vods_empty_msg": "Les VODs que vous lancez apparaîtront ici, avec la reprise de lecture.",
    ],
    .en: [
        "title": "Watch Twitch No Sub",
        "tab_home": "Home", "tab_search": "Search", "tab_library": "My VODs",
        "tab_direct": "Link / ID", "settings": "Settings",
        "tab_history": "VODs",
        "ph_streamer": "Streamer (ex: shroud)", "ph_keyword": "Keyword (ex: horror)",
        "ph_id": "VOD ID or Link",
        "btn_unlock": "Unlock", "btn_search": "Search",
        "btn_watch_live": "Watch live", "btn_copy": "Copy",
        "btn_pip": "PiP", "btn_refresh": "🔄 Refresh",
        "btn_logout": "Logout", "btn_login_twitch": "🟣 Log in with Twitch",
        "btn_clear": "Clear",
        "loading": "Loading...", "loading_vod": "Loading VOD...",
        "loading_channels": "Loading your channels...", "loading_top": "Loading Top...",
        "vod_ready": "VOD Playing!", "live_on": "LIVE NOW", "offline": "OFFLINE",
        "offline_since": "Offline since: ", "no_vod": "No VODs found.",
        "no_live": "No live channels at the moment.", "vods_found": "VODs found.",
        "not_found": "❌ Streamer not found.", "err_missing": "Name missing.",
        "err_network": "Network error.", "err_live": "Live error.",
        "err_conn": "Connection error.", "err_loading": "Error loading data.",
        "login_prompt": "Log in to find your favorite channels.",
        "login_required": "Please log in to view live streams.",
        "session_expired": "Session expired. Please log in again.",
        "lbl_vod_history": "Recently watched VODs", "lbl_channel_history": "Recent Streamers",
        "followed_channels": "Followed channels", "top_streams": "Top streams",
        "top_fr": "France", "top_world": "World", "copied": "Link copied!",
        "day": "d", "hour": "h", "min": "min", "offline_msg": "Stream is offline.",
        "open_vlc": "Open in VLC", "open_outplayer": "Open in Outplayer",
        "open_infuse": "Open in Infuse", "proxy": "Proxy",
        "reduce": "Reduce", "back": "Back", "live_badge": "LIVE",
        "no_result": "No result", "confirm_logout": "Are you sure you want to log out?",
        "cancel": "Cancel", "clear_logs": "Clear logs", "confirm": "Confirm?",
        "erase": "Clear", "export": "📤 Export", "logs_empty": "No logs",
        "logs_hint": "Launch a VOD or stream to see logs",
        "about": "About", "version": "Version 1.0.0",
        "about_desc": "Watch Twitch VODs and streams without a subscription, with full quality access via your personal proxy server.",
        "show_logs": "Show system logs",
        "connected": "Connected", "not_connected": "Not connected",
        "history": "History", "vods": "VODs", "channels": "Channels",
        "proxy_sub": "Disable to save server resources (useful for VLC)",
        "proxy_enable": "Enable proxy", "twitch_account": "Twitch Account",
        "language": "Language",
        "settings_source": "Video Server / Source",
        
        // Traductions sources
        "source_auto": "Auto",
        "source_auto_sub": "Best available source",
        "source_luminous": "Luminous",
        "source_luminous_sub": "Ad-free (recommended)",
        "source_twitch": "Official Twitch",
        "source_twitch_sub": "With ads",
        "source_cloudflare": "Cloudflare Worker",
        "source_cloudflare_sub": "Personal proxy",

        // Chat & Points
        "chat_connected": "Chat connected", "chat_connecting": "Connecting...",
        "chat_send_ph": "Send a message…", "chat_connecting_ph": "Connecting…",
        "chat_follow": "Follow", "chat_first_message": "First message",
        "thread_title": "Thread", "thread_reply_to": "Reply to",
        "follow": "Follow", "following": "Following", "hype_level": "Level",
        "raid_to": "Raid to", "join": "Join", "viewers": "viewers",
        "customize": "Customization",
        "cfg_title": "Stream title", "cfg_title_sub": "Show the title above the chat",
        "cfg_pinned": "Pinned messages", "cfg_pinned_sub": "Show the pinned message banner",
        "cfg_follow": "Follow button", "cfg_follow_sub": "Show the Follow / Unfollow button",
        "cfg_streak": "Watch streak", "cfg_streak_sub": "Show your 🔥 streak badge",
        "cfg_events": "Polls & predictions", "cfg_events_sub": "Show polls, predictions and hype train",
        "cfg_raids": "Raid system", "cfg_raids_sub": "Banner + auto-join the raided channel",
        "cache_section": "Emote & badge cache",
        "vod_chat": "VOD chat",
        "rewind": "Rewind", "back_to_live": "Live",
        "history_vods_title": "Your recent VODs",
        "history_vods_empty": "No VOD in your history yet.",
        "vod_chat_loading": "Loading chat…",
        "vod_chat_empty": "No messages at this point of the VOD",
        "cache_size": "Storage used", "cache_files": "files",
        "cache_clear": "Clear",
        "cache_auto": "Clear on exit",
        "cache_auto_sub": "Purge the cache when leaving the stream or the app",
        "account_api": "API login", "account_api_sub": "Chat, followed channels and Top",
        "account_web": "Web session (points)", "account_web_sub": "Required for channel points",
        "login_points_hint": "For channel points, also connect the \"Web session\" from Settings ⚙️",
        "points_title": "Channel Points",
        "points_connect_title": "Connect your Twitch account",
        "points_connect_desc": "Required to show your balance and claim chests.",
        "points_connect_btn": "Log in",
        "points_loading": "Loading rewards…",
        "points_none": "No rewards available",
        "points_claim_bonus": "Claim bonus", "points_bonus_claimed": "Bonus claimed! 🎉",
        "points_redeem": "Redeem", "points_insufficient": "Low",
        "points_out_of_stock": "Out of stock", "points_paused": "Paused",
        "points_input_ph": "Your message…", "points_unit": "pts",
        "points_redeemed": "redeemed ✓", "points_error": "Error",
        "points_network_error": "Network error", "points_missing": "You need",
        "points_by": "by",
        "err_not_enough": "Not enough points", "err_reward_not_found": "Reward not found",
        "err_points_disabled": "Points disabled", "err_already_claimed": "Already claimed",
        "err_cooldown": "Wait a moment",
        "err_properties_mismatch": "Reward changed, try again",
        "err_stream_offline": "Stream is not live",
        "auto_claim": "Auto-claim chests",
        "auto_claim_sub": "Collects point chests as soon as they appear.",
        "player_section": "Video player",
        "sec_general": "General", "sec_player": "Player", "sec_chat": "Chat", "sec_other": "About",
        "chat_behavior": "Chat behaviour",
        "cfg_recent": "Load recent messages",
        "cfg_recent_sub": "Twitch sends nothing from before you join. Recent lines are fetched from recent-messages.robotty.de, a third-party service.",
        "cfg_autocomplete": "Autocomplete",
        "cfg_autocomplete_sub": "Suggests emotes and names while typing.",
        "cfg_deleted": "Show deleted messages",
        "cfg_deleted_sub": "Keeps moderated messages struck through instead of removing them.",
        "copy_message": "Copy message", "mention_user": "Mention",
        "msg_copied": "Message copied",
        "chat_sizing": "Chat sizing",
        "cfg_timestamps": "Timestamps", "cfg_timestamps_sub": "Shows the time in front of each message.",
        "cfg_font_size": "Font size", "cfg_msg_spacing": "Message spacing",
        "cfg_badge_scale": "Badge scale", "cfg_emote_scale": "Emote scale",
        "cfg_chat_width": "Chat width",
        "cfg_chat_width_sub": "Landscape only, whether the chat is a column or sits on the video.",
        "reset_defaults": "Reset to defaults",
        "vlc_player": "VLC player",
        "vlc_player_sub": "Custom controls: double-tap ±10s, live rewind. (no PiP)",
        "go_live": "LIVE",

        // Categories
        "streams": "Streams", "categories": "Categories",
        "cat_search_ph": "Search a category…",
        "load_more": "Load more",
        "sort_viewers_desc": "Most viewers",
        "sort_viewers_asc": "Fewest viewers",
        "sort_name": "Name (A → Z)",

        // Sleep timer
        "sleep_timer": "Sleep timer",
        "sleep_timer_sub": "Stops playback once the delay is over.",
        "sleep_minutes": "min", "sleep_hour": "1 h", "sleep_2hours": "2 h",
        "sleep_remaining": "Time left",
        "sleep_cancel": "Cancel",
        "sleep_add": "+15 min",

        // Debug
        "debug_section": "Debug",
        "debug_note": "Temporary section, meant to be removed later.",
        "dbg_latency": "Show latency",
        "dbg_latency_sub": "Player badge: how far behind live, in seconds",
        "dbg_chat_delay": "Auto chat sync",
        "dbg_chat_delay_sub": "Delays messages by the measured latency so they match the video",
        "sleep_custom_ph": "Duration", "sleep_start": "Start",
        "sleep_set": "Set", "sleep_edit": "Edit",
        "low_latency": "Low latency mode",
        "low_latency_sub": "Stays as close to live as possible (like on Twitch). May buffer a bit more on a slow connection. Applies to the next stream you open.",
        "delete_vod": "Remove from history",
        "usage_section": "App usage",
        "usage_returning": "Came back",
        "usage_loyalty_once": "1 day only", "usage_loyalty_few": "2 to 6 days",
        "usage_loyalty_regular": "7 to 29 days", "usage_loyalty_daily": "30 days and up",
        "usage_avg_days": "avg.", "usage_since": "since",
        "usage_today": "Today", "usage_week": "7 days", "usage_month": "30 days",
        "usage_versions": "By version",
        "usage_refresh": "Refresh",
        "usage_tap_refresh": "Tap Refresh to read the counters.",
        "usage_worker_missing": "The server does not have the counting routes yet. See worker/README.md to deploy them.",
        "usage_error": "Counters unavailable right now.",
        "usage_share": "Share my usage",
        "usage_share_sub": "Sends a randomly drawn install identifier and the app version, at most once an hour. No Twitch account, no channels watched, no IP address. Turning it off erases the identifier from the server.",
        "immersive_player": "Immersive player",
        "immersive_player_sub": "Controls and info over the picture, fading out on their own. Off: Apple's player with its own controls, PiP and system full screen.",
        "quality": "Quality",
        "rewind_sub": "Go back within the live stream",
        "menu_chat_only": "Chat only",
        "chat_mode_column": "Chat: column",
        "chat_mode_overlay": "Chat: overlay",
        "chat_mode_hidden": "Chat: hidden",
        "menu_chat_only_sub": "Hides the video and gives the chat the whole screen.",
        "menu_reload_emotes": "Refresh emotes and badges",
        "menu_reload_emotes_sub": "Clears the cache and fetches everything anew.",
        "menu_reconnect": "Reconnect chat",
        "menu_reconnect_sub": "Restarts the connection without leaving the stream.",
        "menu_color": "Username color",
        "menu_color_sub": "Change your colour in chat.",
        "menu_needs_login": "Login required",
        "menu_chatters": "Chatters",
        "menu_chatters_sub": "Who is in the chat right now.",
        "menu_chatters_search": "Filter names…",
        "menu_chatters_empty": "Nobody announced on this channel",
        "menu_chatters_waiting": "Waiting for the chat list…",
        "menu_chatters_note": "Twitch shut down its presence API: only IRC still announces people joining, and only on modestly sized channels. The list can therefore stay empty on big streams.",
        "color_needs_relogin": "Log out and back in: the “change colour” permission was added after you signed in.",
        "color_network": "Could not reach Twitch.",
        "color_bad_request": "Colour rejected by Twitch.",
        "color_failed": "Twitch refused the colour change.",
        "role_broadcaster": "Broadcaster", "role_moderator": "Moderators",
        "ph_search": "Streamer, link or VOD ID…",
        "btn_open": "Open",
        "hint_is_vod": "Will open this VOD",
        "hint_is_channel": "Will search this channel",
        "err_bad_vod": "Invalid VOD link or ID.",
        "search_empty_title": "Search a channel or paste a link",
        "search_empty_msg": "Type a streamer name, or paste a VOD link / ID — the app recognises both.",
        "no_followed_live": "None of your channels are live",
        "no_followed_live_msg": "Have a look at the Top or the categories meanwhile.",
        "history_vods_empty_msg": "VODs you play show up here, with resume playback.",
    ],
    .es: [
        "title": "Ver Twitch sin Sub",
        "tab_home": "Inicio", "tab_search": "Buscar", "tab_library": "Mis VODs",
        "tab_direct": "Enlace / ID", "settings": "Ajustes",
        "tab_history": "VODs",
        "ph_streamer": "Streamer (ej: ibai)", "ph_keyword": "Palabra (ej: horror)",
        "ph_id": "ID o Enlace VOD",
        "btn_unlock": "Desbloquear", "btn_search": "Buscar",
        "btn_watch_live": "Ver directo", "btn_copy": "Copiar",
        "btn_pip": "PiP", "btn_refresh": "🔄 Actualizar",
        "btn_logout": "Cerrar sesión", "btn_login_twitch": "🟣 Iniciar sesión con Twitch",
        "btn_clear": "Borrar",
        "loading": "Cargando...", "loading_vod": "Cargando VOD...",
        "loading_channels": "Cargando tus canales...", "loading_top": "Cargando Top...",
        "vod_ready": "VOD Reproduciendo!", "live_on": "EN VIVO", "offline": "DESCONECTADO",
        "offline_since": "Desconectado desde: ", "no_vod": "No se encontraron VODs.",
        "no_live": "No hay canales en vivo ahora.", "vods_found": "VODs encontrados.",
        "not_found": "❌ Streamer no encontrado.", "err_missing": "Falta el nombre.",
        "err_network": "Error de red.", "err_live": "Error de directo.",
        "err_conn": "Error de conexión.", "err_loading": "Error al cargar.",
        "login_prompt": "Inicia sesión para encontrar tus canales favoritos.",
        "login_required": "Inicia sesión para ver los streams.",
        "session_expired": "Sesión expirada. Inicia sesión de nuevo.",
        "lbl_vod_history": "VODs recientes", "lbl_channel_history": "Streamers recientes",
        "followed_channels": "Canales seguidos", "top_streams": "Top streams",
        "top_fr": "Francia", "top_world": "Mundo", "copied": "Enlace copiado!",
        "day": "d", "hour": "h", "min": "min", "offline_msg": "No hay directo en curso.",
        "open_vlc": "Abrir en VLC", "open_outplayer": "Abrir en Outplayer",
        "open_infuse": "Abrir en Infuse", "proxy": "Proxy",
        "reduce": "Reducir", "back": "Volver", "live_badge": "EN VIVO",
        "no_result": "Sin resultado", "confirm_logout": "¿Seguro que quieres cerrar sesión?",
        "cancel": "Cancelar", "clear_logs": "Borrar logs", "confirm": "¿Confirmar?",
        "erase": "Borrar", "export": "📤 Exportar", "logs_empty": "Sin logs",
        "logs_hint": "Lanza un VOD o stream para ver los logs",
        "about": "Acerca de", "version": "Versión 1.0.0",
        "about_desc": "Ve VODs y streams de Twitch sin suscripción, con acceso a calidades completas a través de tu servidor proxy personal.",
        "show_logs": "Mostrar logs del sistema",
        "connected": "Conectado", "not_connected": "No conectado",
        "history": "Historial", "vods": "VODs", "channels": "Canales",
        "proxy_sub": "Desactivar para ahorrar el servidor (útil para VLC)",
        "proxy_enable": "Activar proxy", "twitch_account": "Cuenta de Twitch",
        "language": "Idioma",
        "settings_source": "Servidor / Fuente de Video",
        
        // Traducciones fuentes
        "source_auto": "Auto",
        "source_auto_sub": "Mejor fuente disponible",
        "source_luminous": "Luminous",
        "source_luminous_sub": "Sin anuncios (recomendado)",
        "source_twitch": "Twitch Oficial",
        "source_twitch_sub": "Con anuncios",
        "source_cloudflare": "Cloudflare Worker",
        "source_cloudflare_sub": "Proxy personal",

        // Chat & Points
        "chat_connected": "Chat conectado", "chat_connecting": "Conectando...",
        "chat_send_ph": "Enviar un mensaje…", "chat_connecting_ph": "Conectando…",
        "chat_follow": "Seguir", "chat_first_message": "Primer mensaje",
        "thread_title": "Hilo", "thread_reply_to": "Responder a",
        "follow": "Seguir", "following": "Siguiendo", "hype_level": "Nivel",
        "raid_to": "Raid a", "join": "Unirse", "viewers": "espectadores",
        "customize": "Personalización",
        "cfg_title": "Título del directo", "cfg_title_sub": "Mostrar el título encima del chat",
        "cfg_pinned": "Mensajes fijados", "cfg_pinned_sub": "Mostrar el mensaje fijado",
        "cfg_follow": "Botón seguir", "cfg_follow_sub": "Mostrar el botón Seguir / Dejar de seguir",
        "cfg_streak": "Racha de visionado", "cfg_streak_sub": "Mostrar tu insignia 🔥 de racha",
        "cfg_events": "Encuestas y predicciones", "cfg_events_sub": "Mostrar encuestas, predicciones y hype train",
        "cfg_raids": "Sistema de raid", "cfg_raids_sub": "Banner + unirse automáticamente al canal raideado",
        "cache_section": "Caché de emotes y placas",
        "vod_chat": "Chat del VOD",
        "rewind": "Rebobinar", "back_to_live": "Directo",
        "history_vods_title": "Tus últimos VODs",
        "history_vods_empty": "Aún no hay ningún VOD en tu historial.",
        "vod_chat_loading": "Cargando el chat…",
        "vod_chat_empty": "Sin mensajes en este punto del VOD",
        "cache_size": "Espacio usado", "cache_files": "archivos",
        "cache_clear": "Vaciar",
        "cache_auto": "Vaciar al salir",
        "cache_auto_sub": "Purga el caché al salir del directo o de la app",
        "account_api": "Conexión API", "account_api_sub": "Chat, canales seguidos y Top",
        "account_web": "Sesión web (puntos)", "account_web_sub": "Necesaria para los puntos del canal",
        "login_points_hint": "Para los puntos del canal, conéctate también con la « Sesión web » en Ajustes ⚙️",
        "points_title": "Puntos del canal",
        "points_connect_title": "Conecta tu cuenta de Twitch",
        "points_connect_desc": "Necesario para ver tu saldo y reclamar cofres.",
        "points_connect_btn": "Iniciar sesión",
        "points_loading": "Cargando recompensas…",
        "points_none": "Sin recompensas disponibles",
        "points_claim_bonus": "Reclamar bono", "points_bonus_claimed": "¡Bono reclamado! 🎉",
        "points_redeem": "Canjear", "points_insufficient": "Insuf.",
        "points_out_of_stock": "Agotado", "points_paused": "En pausa",
        "points_input_ph": "Tu mensaje…", "points_unit": "pts",
        "points_redeemed": "canjeado ✓", "points_error": "Error",
        "points_network_error": "Error de red", "points_missing": "Te faltan",
        "points_by": "por",
        "err_not_enough": "No tienes suficientes puntos", "err_reward_not_found": "Recompensa no encontrada",
        "err_points_disabled": "Puntos desactivados", "err_already_claimed": "Ya reclamado",
        "err_cooldown": "Espera un poco",
        "err_properties_mismatch": "Recompensa modificada, reinténtalo",
        "err_stream_offline": "El stream no está en directo",
        "auto_claim": "Reclamar cofres auto",
        "auto_claim_sub": "Recoge los cofres de puntos en cuanto aparecen.",
        "player_section": "Reproductor de vídeo",
        "sec_general": "General", "sec_player": "Reproductor", "sec_chat": "Chat", "sec_other": "Acerca de",
        "chat_behavior": "Comportamiento del chat",
        "cfg_recent": "Cargar mensajes recientes",
        "cfg_recent_sub": "Twitch no envía nada anterior a tu llegada. Las últimas líneas se piden a recent-messages.robotty.de, un servicio de terceros.",
        "cfg_autocomplete": "Autocompletado",
        "cfg_autocomplete_sub": "Sugiere emotes y nombres mientras escribes.",
        "cfg_deleted": "Mostrar mensajes eliminados",
        "cfg_deleted_sub": "Mantiene tachados los mensajes retirados por moderación en lugar de borrarlos.",
        "copy_message": "Copiar mensaje", "mention_user": "Mencionar",
        "msg_copied": "Mensaje copiado",
        "chat_sizing": "Tamaño del chat",
        "cfg_timestamps": "Marca de tiempo", "cfg_timestamps_sub": "Muestra la hora delante de cada mensaje.",
        "cfg_font_size": "Tamaño del texto", "cfg_msg_spacing": "Espacio entre mensajes",
        "cfg_badge_scale": "Tamaño de las insignias", "cfg_emote_scale": "Tamaño de los emotes",
        "cfg_chat_width": "Ancho del chat",
        "cfg_chat_width_sub": "Solo en horizontal, ya sea en columna o sobre el vídeo.",
        "reset_defaults": "Restablecer valores por defecto",
        "vlc_player": "Reproductor VLC",
        "vlc_player_sub": "Controles propios: doble toque ±10s, rebobinar directo. (sin PiP)",
        "go_live": "EN VIVO",

        // Categorías
        "streams": "Streams", "categories": "Categorías",
        "cat_search_ph": "Buscar una categoría…",
        "load_more": "Cargar más",
        "sort_viewers_desc": "Más espectadores",
        "sort_viewers_asc": "Menos espectadores",
        "sort_name": "Nombre (A → Z)",

        // Temporizador
        "sleep_timer": "Temporizador",
        "sleep_timer_sub": "Detiene la reproducción al terminar el tiempo.",
        "sleep_minutes": "min", "sleep_hour": "1 h", "sleep_2hours": "2 h",
        "sleep_remaining": "Tiempo restante",
        "sleep_cancel": "Cancelar",
        "sleep_add": "+15 min",

        // Depuración
        "debug_section": "Depuración",
        "debug_note": "Sección temporal, pensada para quitarse más adelante.",
        "dbg_latency": "Mostrar la latencia",
        "dbg_latency_sub": "Insignia en el reproductor: retraso del directo en segundos",
        "dbg_chat_delay": "Sincronía automática del chat",
        "dbg_chat_delay_sub": "Retrasa los mensajes según la latencia medida para cuadrar con la imagen",
        "sleep_custom_ph": "Duración", "sleep_start": "Iniciar",
        "sleep_set": "Ajustar", "sleep_edit": "Modificar",
        "low_latency": "Modo de baja latencia",
        "low_latency_sub": "Se mantiene lo más cerca posible del directo (como en Twitch). Puede cargar más a menudo con conexión lenta. Se aplica al próximo directo.",
        "delete_vod": "Quitar del historial",
        "usage_section": "Uso de la app",
        "usage_returning": "Han vuelto",
        "usage_loyalty_once": "1 solo día", "usage_loyalty_few": "2 a 6 días",
        "usage_loyalty_regular": "7 a 29 días", "usage_loyalty_daily": "30 días o más",
        "usage_avg_days": "med.", "usage_since": "desde el",
        "usage_today": "Hoy", "usage_week": "7 días", "usage_month": "30 días",
        "usage_versions": "Por versión",
        "usage_refresh": "Actualizar",
        "usage_tap_refresh": "Pulsa Actualizar para leer los contadores.",
        "usage_worker_missing": "El servidor aún no tiene las rutas de conteo. Consulta worker/README.md para desplegarlas.",
        "usage_error": "Contadores no disponibles ahora mismo.",
        "usage_share": "Compartir mi uso",
        "usage_share_sub": "Envía un identificador aleatorio de la instalación y la versión de la app, como mucho una vez por hora. Ni cuenta de Twitch, ni canales vistos, ni dirección IP. Al desactivarlo se borra el identificador del servidor.",
        "immersive_player": "Reproductor inmersivo",
        "immersive_player_sub": "Controles e info sobre la imagen, que se ocultan solos. Desactivado: reproductor de Apple con sus controles, PiP y pantalla completa del sistema.",
        "quality": "Calidad",
        "rewind_sub": "Retroceder dentro del directo",
        "menu_chat_only": "Solo chat",
        "chat_mode_column": "Chat: columna",
        "chat_mode_overlay": "Chat: superpuesto",
        "chat_mode_hidden": "Chat: oculto",
        "menu_chat_only_sub": "Oculta el vídeo y deja el chat a pantalla completa.",
        "menu_reload_emotes": "Recargar emotes e insignias",
        "menu_reload_emotes_sub": "Vacía la caché y lo descarga todo de nuevo.",
        "menu_reconnect": "Reconectar el chat",
        "menu_reconnect_sub": "Reinicia la conexión sin salir del directo.",
        "menu_color": "Color del nombre",
        "menu_color_sub": "Cambia tu color en el chat.",
        "menu_needs_login": "Requiere iniciar sesión",
        "menu_chatters": "Espectadores del chat",
        "menu_chatters_sub": "Quién está en el chat ahora.",
        "menu_chatters_search": "Filtrar nombres…",
        "menu_chatters_empty": "Nadie anunciado en este canal",
        "menu_chatters_waiting": "Esperando la lista del chat…",
        "menu_chatters_note": "Twitch cerró su API de presencia: solo el IRC sigue anunciando las llegadas, y únicamente en canales de tamaño modesto. La lista puede quedarse vacía en directos grandes.",
        "color_needs_relogin": "Cierra sesión y vuelve a entrar: el permiso «cambiar el color» se añadió después de tu conexión.",
        "color_network": "No se pudo contactar con Twitch.",
        "color_bad_request": "Color rechazado por Twitch.",
        "color_failed": "Twitch rechazó el cambio de color.",
        "role_broadcaster": "Streamer", "role_moderator": "Moderadores",
        "ph_search": "Streamer, enlace o ID de VOD…",
        "btn_open": "Abrir",
        "hint_is_vod": "Abrirá este VOD",
        "hint_is_channel": "Buscará este canal",
        "err_bad_vod": "Enlace o ID de VOD no válido.",
        "search_empty_title": "Busca un canal o pega un enlace",
        "search_empty_msg": "Escribe el nombre de un streamer o pega el enlace / ID de un VOD: la app reconoce ambos.",
        "no_followed_live": "Ninguno de tus canales está en directo",
        "no_followed_live_msg": "Echa un vistazo al Top o a las categorías mientras tanto.",
        "history_vods_empty_msg": "Los VODs que reproduzcas aparecerán aquí, con reanudación.",
    ],
]

func translate(_ key: String, _ lang: Lang) -> String {
    translations[lang]?[key] ?? key
}
