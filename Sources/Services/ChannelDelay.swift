import Foundation

// ═══════════════════════════════════════════════════════════════════════════
//  Ce que le lecteur explique d'un direct, comme le site (player.js :
//  channelDelay ; main.js : sourceOnly, relais bloqués) : le délai que la
//  chaîne ajoute elle-même, une chaîne sans autre qualité que la Source, et
//  la source Bulgarie bloquée par le réseau. Partagé avec l'Apple TV
//  (project.yml).
// ═══════════════════════════════════════════════════════════════════════════

/// Délai que la chaîne ajoute elle-même à sa diffusion (réglage du streamer,
/// contre le stream sniping ; hippxrr, 19/11). Twitch inscrit l'heure de
/// réception de chaque segment (EXT-X-PROGRAM-DATE-TIME) mais ne le publie
/// qu'après ce délai : retard affiché (heure − horodatage du segment lu)
/// moins distance au bord jouable = âge du bord de la playlist — moins d'une
/// à deux secondes sans délai (mesuré le 21/11), l'âge du délai avec. Le
/// champ GQL Stream.delayLengthSeconds existe mais reste vide pour les
/// spectateurs.
enum ChannelDelay {
    /// Délai en secondes, arrondi à 5 s ; 0 sous 10 s (une horloge un peu
    /// décalée ne fait rien croire) ou sans mesure.
    static func seconds(total: Double?, behind: Double) -> Int {
        guard let total, total.isFinite, behind.isFinite, behind >= 0 else { return 0 }
        let age = total - behind
        guard age >= 10, age <= 900 else { return 0 }
        return Int((age / 5).rounded()) * 5
    }

    /// Envoyée par les lecteurs quand le délai mesuré change (userInfo « s » :
    /// Int, 0 quand il n'y en a plus). L'iPhone le dit une fois par chaîne et
    /// l'écrit sous les qualités.
    static let changed = Notification.Name("tuChannelDelayChanged")

    static func post(_ s: Int) {
        NotificationCenter.default.post(name: changed, object: nil, userInfo: ["s": s])
    }
}

/// Liens d'un direct sans autre qualité vidéo que la Source (le son à part) :
/// Twitch ne transcode pas toutes les chaînes (souvent de petits affiliés),
/// sur twitch.tv non plus. jpuper (19/11) croyait à un bug de la source.
func isSourceOnly(_ keys: [String]) -> Bool {
    keys.filter { !isAudioQuality($0) && $0.lowercased() != "auto" }.count == 1
}

/// Relais de Sofia (source « bg ») refusé par le réseau : nom introuvable ou
/// connexion refusée d'emblée. C'est souvent un filtre DNS (NextDNS, AdGuard,
/// Pi-hole…) qui bloque sslip.io avec les autres noms de « DNS dynamique » —
/// sur le site, hippxrr (19/11). Le direct passe alors par la source
/// suivante sans un mot : dit une fois par lancement (MainTabView).
enum BulgariaRelayBlock {
    static let blocked = Notification.Name("tuBulgariaRelayBlocked")
    private static var told = false

    static func note(_ error: Error) {
        guard let code = (error as? URLError)?.code,
              [.cannotFindHost, .dnsLookupFailed, .cannotConnectToHost].contains(code), !told else { return }
        told = true
        logger.warn("LIVE", "Relais Bulgarie refusé par le réseau (filtre DNS ?)", "\(code.rawValue)")
        NotificationCenter.default.post(name: blocked, object: nil)
    }
}
