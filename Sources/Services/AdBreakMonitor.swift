import AVFoundation
import Combine

// ═══════════════════════════════════════════════════════════════════════════
//  Pauses pub cousues par Twitch dans le direct.
//
//  Pendant une pause pub de la chaîne (et au lancement : pré-roll), Twitch
//  remplace le direct, dans la playlist elle-même, par un encart violet
//  « Commercial break in progress » ou par une vraie pub. Aucune source n'y
//  échappe (Luminous et le proxy albanais compris) ; seul un compte sans pub
//  sur la chaîne n'en reçoit pas (getLive, source « account »).
//
//  La playlist l'annonce : #EXT-X-DATERANGE CLASS="twitch-stitched-ad", avec
//  START-DATE et DURATION. AdBreakMonitor les recueille sur chaque élément de
//  lecture (VodUnmuteLoader.playerItem, par où passent tous les lecteurs) ;
//  AdBreakWatcher dit, d'après l'heure de l'image affichée (currentDate,
//  EXT-X-PROGRAM-DATE-TIME), si une pause est à l'écran et pour combien de
//  temps, et coupe le son le temps qu'elle dure. La playlist a jusqu'à une
//  vingtaine de secondes d'avance sur l'image : se caler sur sa lecture
//  annoncerait la pause trop tôt.
//  Le chargeur filtre aussi les identifiants stitched-ad-* et les titres
//  EXTINF Amazon. Ses instantanés alimentent le compteur pendant les GAP,
//  avant qu'AVPlayer ait une image ou des métadonnées à présenter.
//
//  Les autres classes sont ignorées, `twitch-maf-ad` en tête : présente dans
//  toutes les sessions quelques minutes après l'ouverture, c'est une pub que
//  dessine le lecteur de Twitch, sans rien changer à l'image d'AVPlayer.
//
//  Compilé aussi pour l'Apple TV (VodUnmute.swift y fait appel) : rien
//  d'UIKit ni d'AppStore ici.
// ═══════════════════════════════════════════════════════════════════════════

final class AdBreakMonitor: NSObject, AVPlayerItemMetadataCollectorPushDelegate {
    static let adClass = TwitchAdPlaylist.adClass
    /// Plus longue pause plausible : une durée absurde ne doit pas couper le
    /// son pour de bon (Twitch plafonne une pause à 3 min).
    private static let maxLength = TwitchAdPlaylist.maxAdLength
    private static var key: UInt8 = 0

    private let collector = AVPlayerItemMetadataCollector(identifiers: nil,
                                                          classifyingLabels: nil)
    /// Pauses connues, par identifiant (file principale seulement).
    private var breaks: [String: AdBreak] = [:]

    private var playlistObserver: NSObjectProtocol?
    private var playlist: TwitchAdPlaylist?
    private var playlistReceived = Date.distantPast
    private var filtered = false

    /// A fresh all-ad edge is intentional waiting, not a dead source. Used by
    /// the startup watchdog, including title-only ads without a wall clock.
    var waitingForAds: Bool {
        filtered && Date().timeIntervalSince(playlistReceived) < 12 && playlist?.segments.last?.ad == true
    }

    deinit {
        if let playlistObserver { NotificationCenter.default.removeObserver(playlistObserver) }
    }

    /// Metadata isn't emitted while an all-ad playlist is waiting on GAPs.
    /// The loader supplies its latest view; buffered clean content still wins.
    private func followPlaylist(of item: AVPlayerItem) {
        guard let asset = item.asset as? AVURLAsset, LivePlaylistRewriter.isWrapped(asset.url),
              let url = LivePlaylistLoader.unwrap(asset.url) else { return }
        filtered = true
        playlistObserver = NotificationCenter.default.addObserver(
            forName: LivePlaylistLoader.playlistNotification, object: nil, queue: .main
        ) { [weak self] note in
            // Sa propre liste, ou une variante de sa liste maîtresse (Auto) ;
            // la maîtresse elle-même n'a pas de segments.
            guard let self, note.object as? URL == url || note.userInfo?["owner"] as? URL == url,
                  let snapshot = note.userInfo?["playlist"] as? TwitchAdPlaylist,
                  !snapshot.segments.isEmpty else { return }
            self.playlist = snapshot
            self.playlistReceived = Date()
            for brk in snapshot.breaks { self.breaks[brk.id] = brk }
            self.breaks = self.breaks.filter { $0.value.end > Date().addingTimeInterval(-3600) }
        }
    }

    func playbackBreak(on player: AVPlayer) -> (brk: AdBreak, clock: Date)? {
        guard let item = player.currentItem else { return nil }
        let date = item.currentDate()
        if filtered, player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
            guard Date().timeIntervalSince(playlistReceived) < 12, let playlist,
                  let brk = playlist.waitingBreak(after: date, knownBreaks: Array(breaks.values)),
                  let edge = playlist.segments.last?.end else { return nil }
            // Advance the countdown while the last clean video frame is held.
            // Keep a one-second indication until a clean playlist arrives.
            let clock = min(brk.end.addingTimeInterval(-0.1),
                            edge.addingTimeInterval(Date().timeIntervalSince(playlistReceived)))
            return (brk, clock)
        }
        guard let date, let brk = active(at: date) else { return nil }
        return (brk, date)
    }

    /// Recueille les pauses pub de cet élément (une seule fois par élément).
    static func attach(to item: AVPlayerItem) {
        guard objc_getAssociatedObject(item, &key) == nil else { return }
        let monitor = AdBreakMonitor()
        monitor.collector.setDelegate(monitor, queue: .main)
        item.add(monitor.collector)
        monitor.followPlaylist(of: item)
        // Le collecteur ne retient pas son délégué : l'élément le garde.
        objc_setAssociatedObject(item, &key, monitor, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    static func monitor(of item: AVPlayerItem) -> AdBreakMonitor? {
        objc_getAssociatedObject(item, &key) as? AdBreakMonitor
    }

    func metadataCollector(_ metadataCollector: AVPlayerItemMetadataCollector,
                           didCollect metadataGroups: [AVDateRangeMetadataGroup],
                           indexesOfNewGroups: IndexSet,
                           indexesOfModifiedGroups: IndexSet) {
        for group in metadataGroups where TwitchAdPlaylist.isAd(className: group.classifyingLabel, id: group.uniqueID) {
            // Sans fin annoncée : attente bornée, corrigée par les mises à jour.
            let end = min(group.endDate ?? group.startDate.addingTimeInterval(Self.maxLength),
                          group.startDate.addingTimeInterval(Self.maxLength))
            guard end > group.startDate else { continue }
            let id = group.uniqueID ?? "\(group.startDate.timeIntervalSince1970)"
            let brk = AdBreak(id: id, start: group.startDate, end: end)
            if breaks[id] == nil {
                logger.info("PUB", "Pause pub annoncée par la playlist",
                            String(format: "%.0f s", end.timeIntervalSince(group.startDate)))
            }
            breaks[id] = brk
        }
        // Les plus anciennes ne servent plus (un direct peut durer des heures).
        let old = Date().addingTimeInterval(-3600)
        breaks = breaks.filter { $0.value.end > old }
    }

    /// Pause à l'écran à l'heure `date` de l'image : le bloc entier des pubs
    /// qui se suivent sans trou (plusieurs pubs d'affilée), sous l'identifiant
    /// de sa première pub — le même d'un bout à l'autre du bloc, pour que le
    /// son remis par la personne ne soit pas recoupé à la pub suivante.
    func active(at date: Date) -> AdBreak? {
        var block: AdBreak? = nil
        for next in breaks.values.sorted(by: { ($0.start, $0.id) < ($1.start, $1.id) }) {
            if let b = block, next.start <= b.end.addingTimeInterval(1) {
                if next.end > b.end { block = AdBreak(id: b.id, start: b.start, end: next.end) }
                continue
            }
            if let b = block, b.start <= date, date < b.end { return b }
            if next.start > date { return nil }
            block = next
        }
        if let b = block, b.start <= date, date < b.end { return b }
        return nil
    }
}

// MARK: – Bord d'une playlist de direct
extension AdBreakMonitor {
    /// Secondes à attendre pour que les `window` dernières secondes de la
    /// playlist de direct `url` soient sans pub cousue (balises
    /// twitch-stitched-ad passées ou annoncées) : 0 si c'est déjà le cas, nil
    /// si elle ne répond pas. Un lecteur qui l'ouvre part de quelques secondes
    /// avant le bord, où passerait encore une pub qui vient de finir. Pour les
    /// qualités supérieures sans abonnement (MainTabView) : Twitch coud ses
    /// pubs selon l'heure, pas selon ce qu'on a lu — la même adresse, relue
    /// après la pause, est revenue au direct. `timeout` : plus court au
    /// lancement, qui l'attend.
    static func adWait(at url: URL, window: TimeInterval, timeout: TimeInterval = 6) async -> TimeInterval? {
        let req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        guard text.hasPrefix("#EXTM3U") else { return nil }
        return adWait(in: text, window: window)
    }

    /// Voir adWait(at:window:), d'après le texte de la playlist : fin de la
    /// dernière pub annoncée, plus `window`, moins la fin du dernier segment.
    static func adWait(in text: String, window: TimeInterval) -> TimeInterval {
        TwitchAdPlaylist(text).adWait(window: window)
    }

}

/// Pause pub à l'écran sur un lecteur : secondes restantes (nil hors pause),
/// et le son coupé le temps qu'elle dure — seulement s'il ne l'était pas
/// déjà, rendu à la fin, au changement d'élément, au plus tard 5 s après la
/// fin prévue, et quand on détache le lecteur.
final class AdBreakWatcher: ObservableObject {
    @Published private(set) var remaining: Int? = nil

    private weak var player: AVPlayer?
    private var timer: Timer?
    /// Faux pour un lecteur dont le son est géré ailleurs.
    private let managesAudio: Bool
    /// Son coupé par nous, sur cet élément.
    private var mutedByUs = false
    private weak var mutedItem: AVPlayerItem?
    /// Pause où le son a été rendu (par quelqu'un d'autre, ou par le minuteur
    /// de secours) : on ne le recoupe pas.
    private var spared: String?
    private var currentId: String?
    private var currentEnd: Date?
    /// Minuteur de secours : fin prévue + 5 s, en temps réel.
    private var deadline: Date?

    init(managesAudio: Bool = true) {
        self.managesAudio = managesAudio
    }

    deinit {
        timer?.invalidate()
        if mutedByUs, let player, player.isMuted { player.isMuted = false }
    }

    func attach(_ player: AVPlayer) {
        if self.player !== player { detach() }
        self.player = player
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func detach() {
        timer?.invalidate(); timer = nil
        finish()
        player = nil
    }

    /// Le son du lecteur vient d'être réglé par quelqu'un d'autre (multi-live :
    /// le direct qui a le son a changé) : on oublie ce qu'on avait coupé.
    func audioTakenOver() {
        mutedByUs = false
        mutedItem = nil
        spared = nil
    }

    private func tick() {
        guard let player, let item = player.currentItem else { finish(); return }
        // Nouvel élément (qualité, source, AirPlay) : le son d'abord.
        if let mutedItem, mutedItem !== item { restore() }
        guard let current = AdBreakMonitor.monitor(of: item)?.playbackBreak(on: player) else { finish(); return }
        let now = current.clock
        let brk = current.brk
        let left = max(0, Int(brk.end.timeIntervalSince(now).rounded(.up)))
        if remaining != left { remaining = left }
        if currentId != brk.id || currentEnd != brk.end {
            if currentId != brk.id { logger.info("PUB", "Pause pub à l'écran", "\(left) s restantes") }
            currentId = brk.id
            // Bloc prolongé par une pub annoncée après coup : secours repoussé.
            currentEnd = brk.end
            deadline = Date().addingTimeInterval(brk.end.timeIntervalSince(now) + 5)
        }
        guard managesAudio else { return }
        if let deadline, Date() > deadline {
            // Plus long que prévu (lecture figée, durée fausse) : le son revient.
            if mutedByUs { restore(); spared = brk.id }
            return
        }
        if mutedByUs {
            if !player.isMuted { mutedByUs = false; mutedItem = nil; spared = brk.id }
        } else if !player.isMuted, spared != brk.id {
            player.isMuted = true
            mutedByUs = true
            mutedItem = item
        }
    }

    /// Hors pause : le son rendu, le bandeau retiré.
    private func finish() {
        restore()
        if remaining != nil {
            remaining = nil
            logger.info("PUB", "Fin de la pause pub", nil)
        }
        currentId = nil
        currentEnd = nil
        deadline = nil
        spared = nil
    }

    private func restore() {
        guard mutedByUs else { return }
        if let player, player.isMuted { player.isMuted = false }
        mutedByUs = false
        mutedItem = nil
    }
}
