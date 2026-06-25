import SwiftUI

// MARK: – API
let kAPIURL          = "https://test2.kurzmathis4.workers.dev"
let kHelixClientID   = "1e68ku2ehgzy5cy0di3xvfy82sxpf6"
let kGQLClientID     = "kimne78kx3ncx6brgo4mv6wki5h1ko"
let kRedirectURI     = "https://mxfia19.github.io/TwitchUnblock/auth.html"
let kDeepLinkScheme  = "twitchunblock://"

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
        "tab_discovery": "🌟 Découverte", "tab_streamer": "Streamer",
        "tab_direct": "Lien / ID", "settings": "Paramètres",
        "tab_history": "VODs",
        "ph_streamer": "Streamer (ex: squeezie)", "ph_keyword": "Mot-clé (ex: horreur)",
        "ph_id": "ID ou Lien de la VOD",
        "btn_unlock": "Déverrouiller", "btn_search": "Chercher",
        "btn_watch_live": "▶️ Regarder le Live", "btn_copy": "Copier",
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
        "followed_channels": "💜 Vos Chaînes Suivies", "top_streams": "🔥 Top Streams",
        "top_fr": "🇫🇷 FR", "top_world": "🌍 Monde", "copied": "Lien copié !",
        "day": "j", "hour": "h", "min": "min", "offline_msg": "Pas de stream en cours.",
        "open_vlc": "Ouvrir dans VLC", "open_outplayer": "Ouvrir dans Outplayer",
        "open_infuse": "Ouvrir dans Infuse", "proxy": "Proxy",
        "reduce": "Réduire", "back": "← Retour", "live_badge": "🔴 EN DIRECT",
        "no_result": "Aucun résultat", "confirm_logout": "Êtes-vous sûr de vouloir vous déconnecter ?",
        "cancel": "Annuler", "clear_logs": "Effacer les logs", "confirm": "Confirmer ?",
        "erase": "Effacer", "export": "📤 Exporter", "logs_empty": "Aucun log",
        "logs_hint": "Lance une VOD ou un stream pour voir les logs",
        "about": "À propos", "version": "Version 1.0.0",
        "about_desc": "Regardez vos VODs et streams Twitch sans sub, avec accès aux qualités complètes via votre serveur proxy personnel.",
        "show_logs": "📋 Afficher les logs système",
        "connected": "✅ Connecté", "not_connected": "Non connecté",
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
        "err_stream_offline": "Le stream n'est pas en direct"
    ],
    .en: [
        "title": "Watch Twitch No Sub",
        "tab_discovery": "🌟 Discovery", "tab_streamer": "Streamer",
        "tab_direct": "Link / ID", "settings": "Settings",
        "tab_history": "VODs",
        "ph_streamer": "Streamer (ex: shroud)", "ph_keyword": "Keyword (ex: horror)",
        "ph_id": "VOD ID or Link",
        "btn_unlock": "Unlock", "btn_search": "Search",
        "btn_watch_live": "▶️ Watch Live", "btn_copy": "Copy",
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
        "followed_channels": "💜 Followed Channels", "top_streams": "🔥 Top Streams",
        "top_fr": "🇫🇷 FR", "top_world": "🌍 World", "copied": "Link copied!",
        "day": "d", "hour": "h", "min": "min", "offline_msg": "Stream is offline.",
        "open_vlc": "Open in VLC", "open_outplayer": "Open in Outplayer",
        "open_infuse": "Open in Infuse", "proxy": "Proxy",
        "reduce": "Reduce", "back": "← Back", "live_badge": "🔴 LIVE",
        "no_result": "No result", "confirm_logout": "Are you sure you want to log out?",
        "cancel": "Cancel", "clear_logs": "Clear logs", "confirm": "Confirm?",
        "erase": "Clear", "export": "📤 Export", "logs_empty": "No logs",
        "logs_hint": "Launch a VOD or stream to see logs",
        "about": "About", "version": "Version 1.0.0",
        "about_desc": "Watch Twitch VODs and streams without a subscription, with full quality access via your personal proxy server.",
        "show_logs": "📋 Show system logs",
        "connected": "✅ Connected", "not_connected": "Not connected",
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
        "err_stream_offline": "Stream is not live"
    ],
    .es: [
        "title": "Ver Twitch sin Sub",
        "tab_discovery": "🌟 Descubrir", "tab_streamer": "Streamer",
        "tab_direct": "Enlace / ID", "settings": "Ajustes",
        "tab_history": "VODs",
        "ph_streamer": "Streamer (ej: ibai)", "ph_keyword": "Palabra (ej: horror)",
        "ph_id": "ID o Enlace VOD",
        "btn_unlock": "Desbloquear", "btn_search": "Buscar",
        "btn_watch_live": "▶️ Ver Directo", "btn_copy": "Copiar",
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
        "followed_channels": "💜 Canales Seguidos", "top_streams": "🔥 Top Streams",
        "top_fr": "🇫🇷 FR", "top_world": "🌍 Mundo", "copied": "Enlace copiado!",
        "day": "d", "hour": "h", "min": "min", "offline_msg": "No hay directo en curso.",
        "open_vlc": "Abrir en VLC", "open_outplayer": "Abrir en Outplayer",
        "open_infuse": "Abrir en Infuse", "proxy": "Proxy",
        "reduce": "Reducir", "back": "← Volver", "live_badge": "🔴 EN VIVO",
        "no_result": "Sin resultado", "confirm_logout": "¿Seguro que quieres cerrar sesión?",
        "cancel": "Cancelar", "clear_logs": "Borrar logs", "confirm": "¿Confirmar?",
        "erase": "Borrar", "export": "📤 Exportar", "logs_empty": "Sin logs",
        "logs_hint": "Lanza un VOD o stream para ver los logs",
        "about": "Acerca de", "version": "Versión 1.0.0",
        "about_desc": "Ve VODs y streams de Twitch sin suscripción, con acceso a calidades completas a través de tu servidor proxy personal.",
        "show_logs": "📋 Mostrar logs del sistema",
        "connected": "✅ Conectado", "not_connected": "No conectado",
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
        "err_stream_offline": "El stream no está en directo"
    ],
]

func translate(_ key: String, _ lang: Lang) -> String {
    translations[lang]?[key] ?? key
}
