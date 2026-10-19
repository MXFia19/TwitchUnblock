import AVFoundation

// MARK: – Mode faible latence (direct)
//
// Avant, le seul rattrapage partait au-delà de 30 s de retard, au plus une
// fois par minute : en lecture normale (10-20 s de retard), le mode ne
// faisait donc rien. On tient maintenant le bord du direct en continu, mais
// uniquement par des sauts : un direct ne change JAMAIS de vitesse. Le
// rattrapage à ×1,1 (ajouté le 10/10, retiré le 14/10) est la piste principale des
// signalements de son décalé de l'image, que seul un saut (+10 s, « Direct »)
// remettait en place.
//   • démarrage lent (plus de cible + 3 s) → un seul recalage, dès que la
//     lecture part, avec la marge d'un segment (début du segment ≤ bord −
//     cible − 1 s) : recaler pile sur la cible faisait caler ;
//   • sortie de la fenêtre du direct → saut près du bord, même après un recul ;
//   • dérive durable (coupure, pause longue) → saut près du bord si le retard
//     dépasse la cible de 5 s pendant 4 s, au plus une fois toutes les 30 s
//     (un seuil plus bas suivait les dents de scie du bord et faisait caler) ;
//   • jamais après un recul voulu (barre, −10 s) : `holdingBehind`.
// La cible ne descend jamais sous le recul recommandé par le flux : plus près,
// AVPlayer joue dans des segments pas encore chargés et cale en boucle.
//
// Plancher : le retard affiché (heure − horodatage du segment lu) ne passe
// jamais sous 4 s — en dessous, la lecture cale (retour d'utilisateurs). Ce
// retard, c'est notre distance au bord jouable plus le délai de Twitch avant
// de publier un segment, qui change d'une chaîne à l'autre : la cible sur le
// bord est relevée d'autant, et un passage sous le seuil recule aussitôt.
// Une horloge d'appareil en retard (retard affiché inférieur à la distance au
// bord, impossible) fausserait ce calcul : le plancher l'ignore alors.
struct LiveLatencyController {
    private var lastSeek = Date.distantPast
    private var lastFloorSeek = Date.distantPast
    /// Dernier saut fait par le contrôleur (recalage, dérive, plancher) : le
    /// lecteur natif ne doit pas le prendre pour un recul de l'utilisateur.
    private(set) var lastJumpAt = Date.distantPast
    /// Recalage du démarrage fait (ou inutile) : il n'a lieu qu'une fois.
    private(set) var aligned = false
    /// Recul voulu (barre DVR, −10 s) : la dérive ne ramène plus au bord.
    private(set) var holdingBehind = false
    /// Début de la dérive en cours (nil : pas de dérive).
    private var driftSince: Date?
    /// Retard affiché minimal (s).
    static let minDelay: Double = 4
    /// Distance au bord jouable qu'il faut garder pour rester au-dessus de
    /// `minDelay`, d'après le dernier retard mesuré (0 tant qu'on ne sait pas).
    private(set) var floorBehind: Double = 0
    /// Avance gagnée après des calages (s) : chaque calage recule la cible de
    /// 4 s (16 au plus), rendues 2 s par 2 s après 2 min sans calage. Tenu à
    /// quelques secondes du bord, un débit qui faiblit (données mobiles)
    /// vidait la mémoire tampon, et le retour au bord la revidait : l'image
    /// gelait en boucle pendant que le chat continuait.
    private(set) var stallMargin: Double = 0
    private var lastStallAt = Date.distantPast
    /// Avance de plus en données mobiles : leur débit varie.
    static var cellularMargin: Double { NetworkStatus.shared.isCellular ? 4 : 0 }

    /// Nouvelle source (qualité, direct ↔ enregistrement, audio spatial) : on
    /// repart de zéro, recalage du démarrage compris. L'avance gagnée sur les
    /// calages reste : le débit, lui, n'a pas changé.
    mutating func reset() {
        lastSeek = .distantPast
        lastFloorSeek = .distantPast
        lastJumpAt = .distantPast
        aligned = false
        holdingBehind = false
        driftSince = nil
        floorBehind = 0
    }

    /// Calage du direct en cours : plus d'avance sur le bord, et pas de retour
    /// au bord tant que la dérive vient de là.
    mutating func noteStall() {
        stallMargin = min(16, stallMargin + 4)
        lastStallAt = Date()
        driftSince = nil
    }

    /// Recul voulu (vrai) ou retour près du bord (faux).
    mutating func hold(_ on: Bool) {
        holdingBehind = on
        driftSince = nil
    }

    /// Retard visé par rapport au bord jouable. Le recul recommandé par AVPlayer
    /// vaut trois fois la durée cible de la playlist : 18 s sur une playlist
    /// Twitch d'origine (cible plafonnée à 8 s), 6 s sur une playlist réécrite
    /// (LivePlaylistLoader, relue toutes les 2 s : cible 4 s).
    static func target(for item: AVPlayerItem) -> Double {
        let rec = item.recommendedTimeOffsetFromLive
        let r = rec.isValid && rec.isNumeric ? rec.seconds : 6
        return min(8, max(3.5, r - 2))
    }

    /// Recul à garder sur le bord jouable : la cible du flux, ou plus pour
    /// tenir le plancher du retard affiché. Jamais plus que la fenêtre du
    /// direct moins 8 s : avec l'avance des calages (16 s au plus) et celle
    /// des données mobiles, il atteignait toute la fenêtre (~30 s) — « Direct »
    /// posait la lecture à son tout début, et la sortie de fenêtre n'était
    /// plus surveillée.
    func minBehind(for item: AVPlayerItem) -> Double {
        let base = max(Self.target(for: item), floorBehind)
        let wanted = base + stallMargin + Self.cellularMargin
        guard let window = item.seekableTimeRanges.last?.timeRangeValue.duration.seconds,
              window.isFinite, window - 8 > base else { return wanted }
        return min(wanted, window - 8)
    }

    /// Après une coupure de `since` secondes (appel, Siri), le moment lu est-il
    /// encore dans la fenêtre du direct (les 30 dernières secondes chez
    /// Twitch), avec 6 s de marge pour repartir ? Son âge se lit à l'heure de
    /// l'image (EXT-X-PROGRAM-DATE-TIME) : la fenêtre connue a pu vieillir
    /// pendant la coupure (app suspendue, playlist plus relue), sa longueur
    /// non. Sans heure, ou avec une horloge en retard (âge inférieur à la
    /// distance au bord, impossible) : distance au bord connu plus la durée
    /// de la coupure, comptée deux fois au pire.
    static func stillInWindow(_ item: AVPlayerItem, after since: TimeInterval) -> Bool {
        guard let range = item.seekableTimeRanges.last?.timeRangeValue,
              range.duration.seconds.isFinite, range.duration.seconds > 0 else { return false }
        let behind = (range.end - item.currentTime()).seconds
        guard behind.isFinite else { return false }
        var age = max(0, behind) + since
        if let date = item.currentDate() {
            let measured = Date().timeIntervalSince(date)
            if measured >= behind { age = measured }
        }
        return range.duration.seconds - age >= 6
    }

    /// `behind` : secondes entre la position et le bord jouable (fin de la
    /// plage cherchable). `total` : retard affiché (heure − horodatage du
    /// segment lu), nil sans horodatage. `settled` : le flux a eu le temps de
    /// démarrer (quelques secondes) ; seul le recalage du démarrage s'en passe.
    /// À appeler une ou deux fois par seconde.
    mutating func adjust(player: AVPlayer, item: AVPlayerItem, behind: Double, total: Double? = nil,
                         enabled: Bool, settled: Bool = true) {
        guard enabled, player.timeControlStatus == .playing, behind.isFinite else {
            driftSince = nil
            return
        }
        // Une vitesse restée au-dessus de 1 (ancienne tenue du direct) est
        // remise à la normale ; on n'en pose jamais d'autre.
        if player.rate > 1.01 { player.rate = 1 }
        // Plus de calage depuis 2 min : l'avance gagnée se rend peu à peu.
        if stallMargin > 0, Date().timeIntervalSince(lastStallAt) > 120 {
            stallMargin = max(0, stallMargin - 2)
            lastStallAt = Date()
        }

        // 1. Plancher. Une horloge en retard donne un retard affiché inférieur
        //    à la distance au bord : le calcul n'a alors plus de sens.
        if let total, total.isFinite, total > 0, total >= behind - 0.5 {
            // Délai de publication de Twitch = retard total − distance au bord.
            let publish = max(0, total - behind)
            floorBehind = min(10, max(0, Self.minDelay + 0.5 - publish))
            if settled, total < Self.minDelay - 0.2, Date().timeIntervalSince(lastFloorSeek) > 8 {
                // Trop près : on recule tout de suite au-dessus du plancher.
                // Tolérance avant seulement : on peut atterrir plus loin du
                // bord, jamais plus près.
                lastFloorSeek = Date()
                lastJumpAt = Date()
                driftSince = nil
                let back = CMTime(seconds: Self.minDelay + 0.5 - total, preferredTimescale: 600)
                player.seek(to: player.currentTime() - back,
                            toleranceBefore: .positiveInfinity, toleranceAfter: .zero)
                logger.debug("LIVE", "Plancher du direct", String(format: "%.1f s de retard", total))
                return
            }
        }

        let target = minBehind(for: item)
        // 2. Recalage du démarrage, une seule fois, dès que la lecture part.
        //    Le saut atterrit au début d'un segment (2 s), donc entre cible + 1
        //    et cible + 3 du bord : en deçà, il pourrait éloigner du bord. Un
        //    recul déjà posé (barre avant le premier tick, faible latence
        //    activée en cours de direct) n'est pas défait.
        if !aligned {
            aligned = true
            if !holdingBehind, behind > target + 3 {
                jumpToEdge(player: player, item: item, target: target, behind: behind,
                           total: total, reason: "Recalage du direct")
                return
            }
        }
        guard settled else { return }

        // 3. Sortie de la fenêtre du direct : les segments vont disparaître,
        //    on recolle même après un recul voulu.
        if let window = item.seekableTimeRanges.last?.timeRangeValue.duration.seconds,
           window.isFinite, window > target + 5, behind > window - 4 {
            holdingBehind = false
            jumpToEdge(player: player, item: item, target: target, behind: behind,
                       total: total, reason: "Sortie de la fenêtre du direct")
            return
        }

        // 4. Dérive durable, sauf après un recul voulu.
        guard !holdingBehind, behind > target + 5 else {
            driftSince = nil
            return
        }
        let since = driftSince ?? Date()
        driftSince = since
        if Date().timeIntervalSince(since) >= 4, Date().timeIntervalSince(lastSeek) > 30 {
            jumpToEdge(player: player, item: item, target: target, behind: behind,
                       total: total, reason: "Dérive du direct")
        }
    }

    /// Saut près du bord, avec la marge d'un segment : début du segment situé
    /// à bord − (cible + 1 s) ou avant, jamais plus près.
    private mutating func jumpToEdge(player: AVPlayer, item: AVPlayerItem, target: Double,
                                     behind: Double, total: Double?, reason: String) {
        guard let edge = item.seekableTimeRanges.last?.timeRangeValue.end, edge.isNumeric else { return }
        lastSeek = Date()
        lastJumpAt = Date()
        driftSince = nil
        player.seek(to: edge - CMTime(seconds: target + 1, preferredTimescale: 600),
                    toleranceBefore: .positiveInfinity, toleranceAfter: .zero)
        logger.debug("LIVE", reason,
                     String(format: "%.1f s du bord", behind)
                     + (total.map { String(format: " · %.1f s de retard", $0) } ?? ""))
    }
}

// MARK: – Journaux du direct
//
// De quoi départager sur appareil les causes d'un son décalé : changements de
// vitesse (et leur raison, donnée par AVPlayer), calages, accessLog, sortie
// audio (type et latence : Bluetooth, AirPods). Catégorie LIVE ; rien n'est
// journalisé hors direct.
final class LiveDiagnostics {
    private var tokens: [NSObjectProtocol] = []
    private var lastAccessLog = Date()

    /// `isLive` est relu à chaque événement : le même lecteur peut passer du
    /// direct à l'enregistrement.
    init(player: AVPlayer, isLive: @escaping () -> Bool) {
        let center = NotificationCenter.default
        tokens.append(center.addObserver(
            forName: AVPlayer.rateDidChangeNotification, object: player, queue: .main
        ) { [weak player] note in
            guard isLive(), let player else { return }
            let raw = note.userInfo?[AVPlayer.rateDidChangeReasonKey]
            let reason = (raw as? AVPlayer.RateDidChangeReason)?.rawValue ?? (raw as? String) ?? "?"
            logger.debug("LIVE", "Vitesse du direct", String(format: "×%.2f · ", player.rate) + reason)
        })
        tokens.append(center.addObserver(
            forName: AVPlayerItem.playbackStalledNotification, object: nil, queue: .main
        ) { [weak player] note in
            guard isLive(), let item = note.object as? AVPlayerItem,
                  item === player?.currentItem else { return }
            let stalls = item.accessLog()?.events.last?.numberOfStalls ?? 0
            logger.debug("LIVE", "Calage du direct", "\(stalls) calage(s) sur cet élément")
        })
        tokens.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { _ in
            guard isLive() else { return }
            LiveDiagnostics.logAudioRoute("changement de sortie")
        })
    }

    deinit {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }

    /// Sortie audio en cours : type de port (haut-parleur, Bluetooth…) et
    /// latence annoncée. Pas le nom de l'appareil (souvent un prénom).
    static func logAudioRoute(_ why: String) {
        let session = AVAudioSession.sharedInstance()
        let port = session.currentRoute.outputs.first?.portType.rawValue ?? "?"
        logger.debug("LIVE", "Sortie audio", "\(why) · \(port) · "
                     + String(format: "%.0f ms", session.outputLatency * 1000))
    }

    /// Toutes les 60 s en direct : dernier événement de l'accessLog.
    func tick(item: AVPlayerItem) {
        guard Date().timeIntervalSince(lastAccessLog) >= 60 else { return }
        lastAccessLog = Date()
        guard let e = item.accessLog()?.events.last else { return }
        logger.debug("LIVE", "Bilan du direct",
                     "\(e.numberOfStalls) calage(s) · \(e.numberOfDroppedVideoFrames) image(s) perdue(s) · "
                     + String(format: "%.0f kb/s", e.indicatedBitrate / 1000))
    }
}

// MARK: – Synchro du chat
//
// Le retard à appliquer au chat, c'est notre retard sur le direct tel que le
// voient les autres spectateurs — ceux qui écrivent.
//
// La distance à la fin de la plage cherchable (`behind`) n'y suffisait pas.
// AVPlayer ne recharge la liste de lecture que toutes les quelques secondes
// (6 s sur Twitch) : entre deux rechargements, le bord qu'il connaît vieillit.
// Le retard mesuré dessinait donc des dents de scie de plusieurs secondes et
// restait en dessous de la réalité, les spectateurs de Twitch jouant les
// segments à mesure qu'ils sont produits. D'où un chat encore en avance.
//
// On part maintenant de la latence totale (heure − horodatage du segment lu,
// EXT-X-PROGRAM-DATE-TIME), qui reste lisse, et on en retire l'âge du bord le
// plus frais vu dans la dernière minute (mesuré juste après un rechargement).
// Le délai qu'une chaîne ajoute à sa diffusion, subi par tout le monde, est
// compté des deux côtés et s'annule dans la soustraction.
struct LiveSyncEstimator {
    private var samples: [(at: Date, edge: Double)] = []

    mutating func reset() { samples.removeAll() }

    /// `latency` : heure − horodatage du segment lu (nil sans horodatage).
    /// `behind` : secondes entre la position et la fin de la plage cherchable.
    mutating func offset(latency: Double?, behind: Double) -> Double {
        guard behind.isFinite else { return 0 }
        guard let latency, latency.isFinite, latency > 0 else { return max(0, behind) }
        let now = Date()
        // Âge du bord connu d'AVPlayer. Les valeurs absurdes (horodatage d'une
        // coupure pub, horloge qui saute) sont écartées.
        let edge = latency - behind
        if edge > -5, edge < 120 { samples.append((now, edge)) }
        samples.removeAll { now.timeIntervalSince($0.at) > 60 }
        // Pas encore assez de recul : l'ancien calcul, en attendant.
        guard samples.count >= 6 else { return max(0, behind) }
        // Bas de la fourchette plutôt que le minimum : une seule mesure
        // aberrante décalerait sinon le chat pendant une minute entière.
        let sorted = samples.map(\.edge).sorted()
        let freshest = sorted[sorted.count / 10]
        return max(0, latency - freshest)
    }
}

extension Notification.Name {
    /// Appui sur la latence affichée : le lecteur ouvert revient au bord du
    /// direct par un saut, sans recharger le flux (comme le bouton « Direct »).
    static let tuGoLive = Notification.Name("TUGoLive")
    /// Calages répétés (objet : « immersive » ou « native », le lecteur) : la
    /// qualité est trop haute pour le débit, on la baisse.
    static let tuPlaybackStalling = Notification.Name("TUPlaybackStalling")
}
