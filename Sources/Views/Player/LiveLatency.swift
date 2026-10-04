import AVFoundation

// MARK: – Mode faible latence (direct)
//
// Avant, le seul rattrapage partait au-delà de 30 s de retard, au plus une
// fois par minute : en lecture normale (10-20 s de retard), le mode ne
// faisait donc rien. Comme Twitch, on tient maintenant le bord du direct en
// continu :
//   • retard un peu au-dessus de la cible → lecture à ×1,1 jusqu'à la cible
//     (imperceptible, et sans recharger quoi que ce soit) ;
//   • grosse dérive (coupure, pause longue) → saut près du bord ;
//   • sinon, vitesse normale.
// La cible ne descend jamais sous le recul recommandé par le flux : plus près,
// AVPlayer joue dans des segments pas encore chargés et cale en boucle.
struct LiveLatencyController {
    private var lastSeek = Date.distantPast
    private(set) var speedingUp = false

    /// Retard visé par rapport au bord jouable.
    static func target(for item: AVPlayerItem) -> Double {
        let rec = item.recommendedTimeOffsetFromLive
        let r = rec.isValid && rec.isNumeric ? rec.seconds : 6
        return min(8, max(4, r))
    }

    /// `behind` : secondes entre la position et le bord jouable (fin de la
    /// plage cherchable). À appeler deux fois par seconde environ.
    mutating func adjust(player: AVPlayer, item: AVPlayerItem, behind: Double, enabled: Bool) {
        guard enabled, player.timeControlStatus == .playing, behind.isFinite else {
            if speedingUp { speedingUp = false; if player.rate > 1.01 { player.rate = 1 } }
            return
        }
        let target = Self.target(for: item)
        if behind > target + 15, Date().timeIntervalSince(lastSeek) > 20 {
            // Grosse dérive : on recolle d'un coup, au recul recommandé.
            lastSeek = Date()
            speedingUp = false
            logger.debug("LIVE", "Rattrapage du direct", String(format: "%.0f s de retard", behind))
            if let edge = item.seekableTimeRanges.last?.timeRangeValue.end, edge.isNumeric {
                player.seek(to: edge - CMTime(seconds: target, preferredTimescale: 600),
                            toleranceBefore: .positiveInfinity, toleranceAfter: .positiveInfinity)
            }
            player.rate = 1
        } else if behind > target + 2.5 {
            if !speedingUp || abs(player.rate - 1.1) > 0.01 { player.rate = 1.1 }
            speedingUp = true
        } else if speedingUp && behind <= target + 0.5 {
            speedingUp = false
            player.rate = 1
        }
    }
}
