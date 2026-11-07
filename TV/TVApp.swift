import SwiftUI
import AVFoundation

// ═══════════════════════════════════════════════════════════════════════════
//  TwitchUnblock pour Apple TV (premier jet, branche de test).
//
//  Même récupération des lives et des VODs que l'app iPhone (TwitchAPI.swift,
//  chargeurs de playlists, sources sans pub), partagée par la cible tvOS ;
//  interface propre à la télécommande dans ce dossier. Pas de WebKit sur
//  tvOS : ni session web (points, drops, prédictions), ni connexion par page
//  web — la connexion Twitch passe par un code (TVSession).
// ═══════════════════════════════════════════════════════════════════════════

@main
struct TwitchUnblockTVApp: App {
    @StateObject private var session = TVSession.shared

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        // Audio spatial coupé par défaut (SpatialAudio lit « off ») : le son
        // reste en stéréo, comme dans l'app Twitch. Avec des écouteurs, tvOS
        // le spatialisait (effet de grande salle, retour du 06/11). Réglage
        // dans Compte → Réglages.
        UserDefaults.standard.register(defaults: [SpatialAudio.key: "off"])
        // Journal gardé entre les lancements, erreurs du lecteur comprises.
        logger.sessionStart()
        PlaybackDiagnostics.start()
    }

    var body: some Scene {
        WindowGroup {
            TVRootView()
                .environmentObject(session)
                .preferredColorScheme(.dark)
        }
    }
}
