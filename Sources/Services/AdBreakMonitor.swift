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
//
//  Les autres classes sont ignorées, `twitch-maf-ad` en tête : présente dans
//  toutes les sessions quelques minutes après l'ouverture, c'est une pub que
//  dessine le lecteur de Twitch, sans rien changer à l'image d'AVPlayer.
//
//  Compilé aussi pour l'Apple TV (VodUnmute.swift y fait appel) : rien
//  d'UIKit ni d'AppStore ici.
// ═══════════════════════════════════════════════════════════════════════════

/// Une pause pub annoncée par la playlist.
struct AdBreak: Equatable {
    let id: String
    let start: Date
    let end: Date
}

final class AdBreakMonitor: NSObject, AVPlayerItemMetadataCollectorPushDelegate {
    static let adClass = "twitch-stitched-ad"
    /// Plus longue pause plausible : une durée absurde ne doit pas couper le
    /// son pour de bon (Twitch plafonne une pause à 3 min).
    private static let maxLength: TimeInterval = 200
    private static var key: UInt8 = 0

    private let collector = AVPlayerItemMetadataCollector(identifiers: nil,
                                                          classifyingLabels: [AdBreakMonitor.adClass])
    /// Pauses connues, par identifiant (file principale seulement).
    private var breaks: [String: AdBreak] = [:]

    /// Recueille les pauses pub de cet élément (une seule fois par élément).
    static func attach(to item: AVPlayerItem) {
        guard objc_getAssociatedObject(item, &key) == nil else { return }
        let monitor = AdBreakMonitor()
        monitor.collector.setDelegate(monitor, queue: .main)
        item.add(monitor.collector)
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
        for group in metadataGroups where group.classifyingLabel == Self.adClass {
            // Sans DURATION ni END-DATE (rare) : 30 s, prolongées si la
            // playlist précise ensuite la fin (groupe modifié).
            let end = min(group.endDate ?? group.startDate.addingTimeInterval(30),
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
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        func date(_ s: String) -> Date? { precise.date(from: s) ?? plain.date(from: s) }
        var adEnd: Date? = nil
        var edge: Date? = nil
        var segmentStart: Date? = nil
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-PROGRAM-DATE-TIME:") {
                segmentStart = date(String(line.dropFirst("#EXT-X-PROGRAM-DATE-TIME:".count)))
            } else if line.hasPrefix("#EXTINF:") {
                let length = Double(line.dropFirst("#EXTINF:".count).prefix { $0 != "," }) ?? 0
                // Segment sans horodatage : à la suite du précédent.
                if let start = segmentStart ?? edge { edge = start.addingTimeInterval(length) }
                segmentStart = nil
            } else if line.hasPrefix("#EXT-X-DATERANGE"), line.contains("CLASS=\"\(adClass)\""),
                      let start = attribute(line, "START-DATE").flatMap(date) {
                // Mêmes règles que le collecteur : 30 s sans durée, 200 s au plus.
                let duration: TimeInterval? = attribute(line, "DURATION").flatMap { Double($0) }
                let end: Date = attribute(line, "END-DATE").flatMap(date)
                    ?? duration.map { start.addingTimeInterval($0) }
                    ?? start.addingTimeInterval(30)
                let capped = min(end, start.addingTimeInterval(maxLength))
                adEnd = max(adEnd ?? capped, capped)
            }
        }
        guard let adEnd, let edge else { return 0 }
        return max(0, adEnd.addingTimeInterval(window).timeIntervalSince(edge))
    }

    /// Valeur d'un attribut de balise (`,NOM="valeur"` ou `,NOM=valeur`) :
    /// précédé d'une virgule ou des deux-points, « DURATION » ne prend pas
    /// « X-TV-TWITCH-AD-POD-FILLED-DURATION ».
    private static func attribute(_ line: String, _ name: String) -> String? {
        guard let r = line.range(of: #"[:,]\#(name)=("[^"]*"|[^,\s]*)"#, options: .regularExpression) else { return nil }
        var value = line[r].drop { $0 != "=" }.dropFirst()
        if value.hasPrefix("\"") { value = value.dropFirst().dropLast() }
        return String(value)
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
        guard let now = item.currentDate(),
              let brk = AdBreakMonitor.monitor(of: item)?.active(at: now) else { finish(); return }
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
