import AVFoundation

// MARK: – Vitesse réellement tenue
/// `player.rate` n'est que la vitesse demandée : « the effective rate of
/// playback may differ from the desired rate » (AVPlayer.h). Un lecteur peut
/// donc afficher 2× en lisant à 1× (bord d'un enregistrement en cours,
/// vitesse au-delà de ce que l'élément sait faire). La position lue est
/// comparée à l'horloge, sur des fenêtres de lecture continue : ni pause, ni
/// attente, ni saut (le lecteur remet la fenêtre à zéro à chacun).
/// Lecteurs de l'iPhone seulement (immersif et natif), hors direct.
struct EffectiveRateProbe {
    private var start: (uptime: TimeInterval, media: Double)?

    /// Saut, pause, attente, nouvel élément ou nouvelle vitesse : la fenêtre
    /// repart de zéro.
    mutating func reset() { start = nil }

    /// À chaque relevé de position. Rend la vitesse mesurée au bout d'une
    /// fenêtre d'au moins `window` secondes de lecture continue, nil sinon.
    mutating func sample(_ player: AVPlayer, window: TimeInterval = 4) -> Double? {
        let media = player.currentTime().seconds
        guard player.timeControlStatus == .playing, !player.isExternalPlaybackActive,
              media.isFinite else {
            start = nil
            return nil
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard let s = start else {
            start = (now, media)
            return nil
        }
        let wall = now - s.uptime
        guard wall >= window else { return nil }
        start = (now, media)
        let measured = (media - s.media) / wall
        // Relevés trop espacés (app suspendue) ou saut passé inaperçu : rien
        // à en conclure.
        guard wall < window * 3, measured > 0.05, measured < 8 else { return nil }
        return measured
    }
}
