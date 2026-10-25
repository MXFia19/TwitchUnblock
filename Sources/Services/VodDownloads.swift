import Foundation
import UIKit
import UserNotifications

// ═══════════════════════════════════════════════════════════════════════════
//  VODs téléchargées pour être regardées hors ligne.
//
//  On télécharge un passage (de tel instant à tel autre, ou toute la VOD)
//  dans la qualité choisie : les segments de la playlist qui couvrent ce
//  passage, posés dans un dossier avec une playlist locale, puis lus par le
//  mini-serveur de l'app (OfflineServer).
//
//  App ouverte, c'est l'app qui télécharge (VodFetcher : une session
//  ordinaire, quatre fichiers à la fois) : rapide, et toute erreur se voit.
//  Dès qu'on la quitte, ce qui manque passe à la session de téléchargement
//  d'arrière-plan d'iOS (VodDownloader), qui continue sans elle, par
//  fournées ; au retour, l'app reprend la main. Tout confier à iOS dès le
//  départ ne marchait pas : des centaines de tâches d'arrière-plan d'un
//  coup, iOS pouvait les laisser en attente — le téléchargement restait à
//  0 %. Si on ferme l'app en la balayant, iOS annule tout : ce qui manque
//  est redemandé au retour, sans retélécharger ce qui est là.
//
//  Passages coupés pour musique protégée : un jour ou deux après le live, le
//  CDN de Twitch garde encore le son d'origine (« N.ts » à la place de
//  « N-muted.ts », comme pour VodUnmuteLoader). S'il existe, c'est lui qui
//  est téléchargé ; sinon, la version muette. VODs en fMP4 : « N-unmuted.mp4 »
//  est servi AVEC le son (« N-muted.mp4 » est silencieux, « N.mp4 » refusé) :
//  il est téléchargé tel quel, comme un segment ordinaire.
//
//  Le chat du passage peut être gardé avec (VodChatArchive), pour être
//  rejoué hors ligne ; un téléchargement fini s'exporte en un seul fichier.
//
//  « Wi-Fi seulement » (Réglages, désactivé par défaut) : aucun fichier ne
//  passe par les données mobiles. App ouverte, le téléchargement attend le
//  Wi-Fi (en pause, raison « wifi ») et repart seul à son retour ; app
//  quittée, c'est iOS qui attend le Wi-Fi pour ses fichiers.
// ═══════════════════════════════════════════════════════════════════════════

struct VodDownload: Identifiable, Codable, Equatable {
    enum State: String, Codable { case downloading, paused, done, failed }

    let id: String
    let vodId: String
    let title: String
    let streamer: String
    let thumbnail: String
    let quality: String
    /// Playlist de la qualité choisie (pour reprendre un téléchargement).
    let playlist: String
    let restoreAudio: Bool
    /// Passage demandé, en secondes dans la VOD.
    let start: Double
    let end: Double
    let created: Date
    var total = 0
    var done = 0
    var bytes: Int64 = 0
    /// Secondes de son coupé rétablies, et restées muettes.
    var restored: Double = 0
    var muted: Double = 0
    var state: State = .downloading
    /// Chat gardé avec la vidéo : demandé, et messages gardés (nil tant qu'il
    /// n'est pas fini).
    var withChat: Bool? = nil
    var chatCount: Int? = nil
    /// Pourquoi il s'est arrêté (VodDownloadFailure, ou « http:403 »…).
    var reason: String? = nil
    /// Hauteur et cadence de la qualité, retenues au départ (inconnues pour
    /// un téléchargement d'avant) : « 1080p60 (Source) » dans « Mes VODs ».
    var height: Int? = nil
    var fps: Double? = nil

    var duration: Double { max(0, end - start) }
    var progress: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }
    /// Pour qualityText : la qualité téléchargée, si sa hauteur est connue.
    var variants: [String: VariantInfo] {
        guard let height, height > 0 else { return [:] }
        return [quality: VariantInfo(height: height, fps: fps ?? 0, bandwidth: 0)]
    }
}

/// Ce qu'il faut pour proposer le téléchargement de la VOD en cours.
struct VodDownloadContext {
    let vodId: String
    let title: String
    let streamer: String
    let thumbnail: String
    /// Playlists par qualité (adresses directes, pas `tuunmute://`).
    let links: QualityLinks
    /// Position de lecture actuelle, en secondes.
    let position: Double
    /// Hauteur et cadence de chaque qualité (qualité proposée d'abord).
    var variants: [String: VariantInfo] = [:]
}

// MARK: – Plan : les segments d'un passage
/// Gardé dans le dossier du téléchargement (plan.json) : de quoi reprendre,
/// et finir, même après un redémarrage de l'app par iOS.
struct VodDownloadPlan: Codable {
    struct Segment: Codable {
        let index: Int
        let url: URL
        /// Son d'origine d'un passage coupé (peut avoir disparu du CDN).
        let original: URL?
        /// Instant de la VOD où il commence.
        let start: Double
        let duration: Double
        let discontinuity: Bool

        var ext: String { url.pathExtension.isEmpty ? "ts" : url.pathExtension }
        /// Passage coupé que le CDN sert avec le son (« N-unmuted.mp4 », VODs
        /// en fMP4) : segment ordinaire, compté comme rétabli.
        var keepsSound: Bool { url.absoluteString.contains("-unmuted.mp4") }
        /// Le segment (son d'origine pour un passage coupé), et sa version muette.
        var fileName: String { "seg_\(String(format: "%05d", index)).\(ext)" }
        var mutedFileName: String { "seg_\(String(format: "%05d", index)).muted.\(ext)" }
    }
    var segments: [Segment] = []
    /// Segment d'initialisation (#EXT-X-MAP), pour les playlists en fMP4.
    var map: URL?
    /// Durée totale de la VOD (toute la playlist).
    var vodDuration: Double = 0
    /// Originaux des passages coupés encore servis (sondé au départ).
    var useOriginals = false

    var mapFileName: String? { map.map { "init." + ($0.pathExtension.isEmpty ? "mp4" : $0.pathExtension) } }
    var fileCount: Int { segments.count + (map == nil ? 0 : 1) }

    static func fetch(_ playlist: URL) async -> String? {
        let req = URLRequest(url: playlist, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        return text.hasPrefix("#EXTM3U") ? text : nil
    }

    /// Segments qui recouvrent [start, end] (toute la VOD si end ≤ start).
    static func make(_ text: String, base: URL, from start: Double, to end: Double) -> VodDownloadPlan {
        var plan = VodDownloadPlan()
        var clock = 0.0, pending = 0.0, discontinuity = false
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#EXTINF:") {
                pending = Double(line.dropFirst(8).split(separator: ",").first ?? "") ?? 0
                continue
            }
            if line.hasPrefix("#EXT-X-DISCONTINUITY") { discontinuity = true; continue }
            if line.hasPrefix("#EXT-X-MAP:"),
               let r = line.range(of: #"URI="([^"]+)""#, options: .regularExpression) {
                let uri = line[r].dropFirst(5).dropLast()
                plan.map = URL(string: String(uri), relativeTo: base)?.absoluteURL
                continue
            }
            guard !line.isEmpty, !line.hasPrefix("#"),
                  let abs = URL(string: line, relativeTo: base)?.absoluteURL else { continue }
            let segStart = clock
            clock += pending
            if end <= start || (clock > start && segStart < end) {
                var url = abs
                var original: URL? = nil
                let s = abs.absoluteString
                // « N-unmuted.mp4 » (VODs en fMP4) : servi AVEC le son, comme dans
                // VodUnmuteLoader.rewrite — gardé tel quel (adresse absolue, ni
                // original ni repli muet). Sinon « N-muted.ts » / « N-unmuted.ts »,
                // ou « N-muted.mp4 » en fMP4.
                if !s.contains("-unmuted.mp4"),
                   let r = s.range(of: #"-(un)?muted\.(ts|mp4)"#, options: .regularExpression) {
                    let ext = s[r].hasSuffix(".mp4") ? "mp4" : "ts"
                    // « -unmuted.ts » est refusé par le CDN : la version muette sert de repli.
                    url = URL(string: s.replacingCharacters(in: r, with: "-muted.\(ext)")) ?? abs
                    original = URL(string: s.replacingCharacters(in: r, with: ".\(ext)"))
                }
                plan.segments.append(Segment(index: plan.segments.count, url: url, original: original,
                                             start: segStart, duration: pending,
                                             discontinuity: discontinuity && !plan.segments.isEmpty))
            }
            pending = 0
            discontinuity = false
        }
        plan.vodDuration = clock
        return plan
    }
}

/// Raisons d'arrêt montrées sous un téléchargement (avec « http:<code> »).
enum VodDownloadFailure {
    static let network = "network"
    static let space = "space"
    static let playlist = "playlist"
    /// En pause, pas en échec : « Wi-Fi seulement » en données mobiles.
    static let wifi = "wifi"
}

// MARK: – Gestionnaire
@MainActor
final class VodDownloads: ObservableObject {
    static let shared = VodDownloads()

    /// Fichiers demandés à la fois, app ouverte.
    nonisolated static var parallel: Int { 4 }
    /// Fichiers confiés à iOS d'un coup, app quittée : par milliers, iOS les
    /// traîne. La fournée suivante part quand celle-ci est finie (iOS réveille
    /// l'app pour ça).
    nonisolated static var batchSize: Int { 300 }

    @Published private(set) var items: [VodDownload] = []
    /// Préparations en cours (playlist, sondage des originaux).
    private var preparing: [String: Task<Void, Never>] = [:]
    /// Téléchargements faits par l'app (app ouverte).
    private var runners: [String: Task<Void, Never>] = [:]
    /// Chats en cours de téléchargement.
    private var chats: [String: Task<Void, Never>] = [:]
    /// Cases remplies (un segment, ou sa version muette) par téléchargement
    /// en cours : un fichier reçu deux fois ne compte qu'une fois.
    private var present: [String: Set<String>] = [:]
    /// Côté iOS : fichiers abandonnés (refusés, après les nouveaux essais),
    /// pas redemandés avant le retour dans l'app.
    private var lost: [String: Set<String>] = [:]
    /// Côté iOS : vérifications de fin de fournée prévues.
    private var batchChecks: [String: Task<Void, Never>] = [:]
    /// App à l'écran : c'est elle qui télécharge.
    private var foreground = false
    private var unsaved = 0

    /// Application Support/Downloads, exclu des sauvegardes iCloud.
    nonisolated static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Downloads", isDirectory: true)
    }
    nonisolated static func folder(_ id: String) -> URL {
        directory.appendingPathComponent(id, isDirectory: true)
    }
    /// Fichiers exportés pour le partage : temporaires, vidés au lancement.
    nonisolated static var exportsDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Exports", isDirectory: true)
    }

    /// Réglage « Wi-Fi seulement » (AppStore.downloadWifiOnly).
    nonisolated static var wifiOnly: Bool { UserDefaults.standard.bool(forKey: "cfg_dl_wifi_only") }
    /// « Wi-Fi seulement » et en données mobiles : rien ne se télécharge.
    nonisolated static var cellularBlocked: Bool { wifiOnly && NetworkStatus.shared.isCellular }

    /// Espace libre pour l'app, en octets (ce qu'iOS libérerait au besoin
    /// compris) ; nil si iOS ne le dit pas.
    nonisolated static func freeSpace() -> Int64? {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
    private var indexURL: URL { Self.directory.appendingPathComponent("index.json") }

    private init() {
        var dir = Self.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        if let data = try? Data(contentsOf: indexURL),
           let list = try? JSONDecoder().decode([VodDownload].self, from: data) {
            items = list
        }
        try? FileManager.default.removeItem(at: Self.exportsDirectory)
        // Pas seulement d'après les changements d'état de la scène : créé
        // app déjà à l'écran, le premier peut lui avoir échappé.
        foreground = UIApplication.shared.applicationState == .active
        VodDownloader.shared.activate()
        // Et la reprise des téléchargements en cours avec lui.
        if foreground { Task { self.sceneActive() } }
        // Wi-Fi ↔ données mobiles : « Wi-Fi seulement ».
        _ = NotificationCenter.default.addObserver(forName: .tuNetworkChanged, object: nil, queue: .main) { _ in
            Task { @MainActor in VodDownloads.shared.networkChanged() }
        }
    }

    private func save() {
        unsaved = 0
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: indexURL, options: .atomic) }
    }

    private func update(_ id: String, _ change: (inout VodDownload) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[i])
    }

    private func item(_ id: String) -> VodDownload? { items.first { $0.id == id } }

    var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }

    // MARK: Actions
    func start(_ ctx: VodDownloadContext, quality: String, start: Double, end: Double,
               restoreAudio: Bool, withChat: Bool) {
        guard let playlist = ctx.links[quality] else { return }
        let safeQuality = quality.filter { $0.isLetter || $0.isNumber }
        let id = "\(ctx.vodId)_\(Int(start))_\(Int(end))_\(safeQuality)"
        if item(id) == nil {
            var new = VodDownload(id: id, vodId: ctx.vodId, title: ctx.title, streamer: ctx.streamer,
                                  thumbnail: ctx.thumbnail, quality: quality, playlist: playlist,
                                  restoreAudio: restoreAudio, start: start, end: end, created: Date())
            // Une VOD supprimée retrouvée n'a plus de chat.
            new.withChat = withChat && Self.hasChat(ctx.vodId)
            new.height = ctx.variants[quality]?.height
            new.fps = ctx.variants[quality]?.fps
            items.insert(new, at: 0)
        }
        resume(id)
    }

    func resume(_ id: String) {
        guard let current = item(id), current.state != .done else { return }
        // Demandé depuis l'app (bouton) : elle est à l'écran, c'est elle qui télécharge.
        if UIApplication.shared.applicationState == .active { foreground = true }
        // « Wi-Fi seulement » en données mobiles : il attend le Wi-Fi. App
        // quittée, iOS l'attend de lui-même (VodDownloader).
        if foreground, Self.cellularBlocked {
            waitForWifi(id)
            return
        }
        update(id) {
            $0.state = .downloading
            $0.reason = nil
        }
        // On réessaie aussi ce qu'iOS avait abandonné.
        lost[id] = nil
        save()
        prepare(id)
    }

    func pause(_ id: String) {
        stopWork(id)
        update(id) {
            $0.state = .paused
            // Pause voulue : ne repart pas seule au retour du Wi-Fi.
            $0.reason = nil
        }
        save()
    }

    /// « Wi-Fi seulement » en données mobiles : arrêté, en pause jusqu'au
    /// retour du Wi-Fi (networkChanged) ou jusqu'à « Reprendre ».
    private func waitForWifi(_ id: String) {
        stopWork(id)
        update(id) {
            $0.state = .paused
            $0.reason = VodDownloadFailure.wifi
        }
        save()
        logger.info("DOWNLOAD", "En attente du Wi-Fi (Wi-Fi seulement)", id)
    }

    /// Connexion changée, ou réglage « Wi-Fi seulement » : en données
    /// mobiles, ce que l'app télécharge s'arrête et attend le Wi-Fi ; en
    /// Wi-Fi (ou réglage coupé), ce qui l'attendait repart. Hors ligne, rien
    /// ne bouge : il échouerait aussitôt.
    func networkChanged() {
        if Self.cellularBlocked {
            // App quittée : iOS attend le Wi-Fi pour ses fichiers.
            guard foreground else { return }
            for d in items where d.state == .downloading { waitForWifi(d.id) }
        } else if NetworkStatus.shared.isOnline {
            resumeWaitingForWifi()
        }
    }

    /// Ceux qui attendaient le Wi-Fi repartent.
    private func resumeWaitingForWifi() {
        for d in items where d.state == .paused && d.reason == VodDownloadFailure.wifi {
            logger.info("DOWNLOAD", "Reprise du téléchargement qui attendait le Wi-Fi", d.id)
            resume(d.id)
        }
    }

    func delete(_ id: String) {
        stopWork(id)
        present[id] = nil
        lost[id] = nil
        try? FileManager.default.removeItem(at: Self.folder(id))
        items.removeAll { $0.id == id }
        save()
        NotificationCenter.default.post(name: .vodDownloadDeleted, object: id)
    }

    private func stopWork(_ id: String) {
        preparing[id]?.cancel()
        preparing[id] = nil
        runners[id]?.cancel()
        runners[id] = nil
        chats[id]?.cancel()
        chats[id] = nil
        batchChecks[id]?.cancel()
        batchChecks[id] = nil
        VodDownloader.shared.cancel(item: id)
    }

    // MARK: App à l'écran, ou quittée
    /// Au lancement et au retour dans l'app : elle reprend la main sur ce
    /// qu'iOS téléchargeait (ses tâches annulées, les fichiers reçus restent),
    /// redemande ce qui manque (app fermée en la balayant, réseau perdu…) et
    /// reprend les chats inachevés.
    func sceneActive() {
        foreground = true
        let generation = VodDownloader.shared.generation
        for d in items where d.state == .downloading {
            batchChecks[d.id]?.cancel()
            batchChecks[d.id] = nil
            // Seulement les fournées déjà parties : pas une qui partirait
            // juste après (app aussitôt quittée). Redit un peu plus tard :
            // une fournée encore en création au retour y échappait.
            VodDownloader.shared.cancel(item: d.id, upTo: generation)
            prepare(d.id)
        }
        let ids = items.filter { $0.state == .downloading }.map(\.id)
        if !ids.isEmpty {
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                for id in ids { VodDownloader.shared.cancel(item: id, upTo: generation) }
            }
        }
        for d in items where d.state != .paused && d.withChat == true && d.chatCount == nil {
            startChat(d.id)
        }
        // Ceux qui attendaient le Wi-Fi, s'il est là (ou le réglage coupé).
        if !Self.cellularBlocked, NetworkStatus.shared.isOnline { resumeWaitingForWifi() }
    }

    /// L'app quitte l'écran : ce qui manque passe à iOS, qui continue sans
    /// elle. Dès qu'elle n'est plus active, avant d'être en arrière-plan : une
    /// tâche créée app en arrière-plan, iOS la garde pour quand ça l'arrange
    /// (Wi-Fi, en charge).
    func sceneInactive() {
        guard foreground else { return }
        foreground = false
        for d in items where d.state == .downloading && runners[d.id] != nil {
            runners[d.id]?.cancel()
            runners[d.id] = nil
            if let plan = Self.loadPlan(d.id) { handOff(d.id, plan) }
        }
        // Préparation en cours : elle passera la main elle-même.
        // « Wi-Fi seulement » : ce qui attendait le Wi-Fi passe aussi à iOS,
        // qui l'attend de lui-même (rien par les données mobiles). Resté en
        // pause, il ne repartait qu'au retour dans l'app. Revenue sans Wi-Fi,
        // l'app le remet en attente (proceed).
        var handed = false
        for d in items where d.state == .paused && d.reason == VodDownloadFailure.wifi {
            guard let plan = Self.loadPlan(d.id) else { continue }
            update(d.id) {
                $0.state = .downloading
                $0.reason = nil
            }
            handOff(d.id, plan)
            handed = true
        }
        if handed { save() }
    }

    /// Lecture hors ligne : la playlist locale, servie par OfflineServer.
    func playback(_ item: VodDownload) async -> RecoveredVod? {
        guard item.state == .done, let base = await OfflineServer.shared.baseURL() else { return nil }
        let url = base.appendingPathComponent(item.id).appendingPathComponent("index.m3u8")
        return RecoveredVod(streamID: "offline-\(item.id)", title: item.title,
                            streamer: item.streamer, links: [item.quality: url.absoluteString])
    }

    // MARK: Préparation
    private func prepare(_ id: String) {
        guard preparing[id] == nil, runners[id] == nil else { return }
        // Un peu de temps demandé à iOS pour la préparation (playlist,
        // sondage) : l'app quittée juste après « Télécharger » la coupait.
        let time = BackgroundTaskBox()
        time.id = UIApplication.shared.beginBackgroundTask(withName: "download-prepare") { time.end() }
        preparing[id] = Task {
            defer { time.end() }
            let plan = await self.makePlan(id)
            // Arrêtée (pause, suppression) : une autre a peut-être pris sa place.
            guard !Task.isCancelled else { return }
            self.preparing[id] = nil
            guard let plan, self.item(id)?.state == .downloading else { return }
            self.proceed(id, plan)
        }
    }

    /// Plan gardé sur le disque, ou fait d'après la playlist (et le sondage
    /// des originaux).
    private func makePlan(_ id: String) async -> VodDownloadPlan? {
        guard let current = item(id) else { return nil }
        try? FileManager.default.createDirectory(at: Self.folder(id), withIntermediateDirectories: true)
        if let saved = Self.loadPlan(id) { return saved }
        logger.info("DOWNLOAD", "Téléchargement…", "\(current.title) · \(current.quality)")
        guard let url = URL(string: current.playlist), let text = await VodDownloadPlan.fetch(url) else {
            // Hors premier plan : l'élément reste « en cours » et repart au
            // retour (sceneActive) — l'échec était définitif (« playlist
            // introuvable ») pour une simple mise en arrière-plan.
            if !Task.isCancelled, foreground { fail(id, VodDownloadFailure.playlist) }
            return nil
        }
        var made = VodDownloadPlan.make(text, base: url, from: current.start, to: current.end)
        guard !made.segments.isEmpty else { fail(id, VodDownloadFailure.playlist); return nil }
        if current.restoreAudio { made.useOriginals = await Self.originalsAvailable(made) }
        guard !Task.isCancelled else { return nil }
        Self.savePlan(made, id)
        return made
    }

    /// Plan prêt : ce qui est déjà là est compté, le reste téléchargé — par
    /// l'app si elle est à l'écran, par iOS sinon.
    private func proceed(_ id: String, _ plan: VodDownloadPlan) {
        let (names, bytes) = Self.scan(plan, folder: Self.folder(id))
        present[id] = names
        update(id) {
            $0.total = plan.fileCount
            $0.done = names.count
            $0.bytes = bytes
        }
        if let d = item(id), d.withChat == true, d.chatCount == nil { startChat(id) }
        if names.count >= plan.fileCount { finalize(id, plan); return }
        // Passé en données mobiles pendant la préparation (« Wi-Fi seulement »).
        if foreground, Self.cellularBlocked { waitForWifi(id); return }
        if foreground { runInApp(id, plan) } else { handOff(id, plan) }
    }

    /// Ce qui manque sur le disque, sauf ce qui est à laisser de côté.
    nonisolated private static func missingJobs(_ plan: VodDownloadPlan, item: String, folder: URL,
                                                skipping skipped: Set<String>) -> [VodDownloader.Job] {
        let fm = FileManager.default
        let has = { (name: String) in fm.fileExists(atPath: folder.appendingPathComponent(name).path) }
        var jobs: [VodDownloader.Job] = []
        if let map = plan.map, let name = plan.mapFileName, !has(name), !skipped.contains(name) {
            jobs.append(.init(item: item, kind: .initSegment, url: map, fallback: nil, fileName: name))
        }
        for s in plan.segments where !has(s.fileName) && !has(s.mutedFileName)
            && !skipped.contains(s.fileName) && !skipped.contains(s.mutedFileName) {
            if s.original == nil {
                jobs.append(.init(item: item, kind: .normal, url: s.url, fallback: nil, fileName: s.fileName))
            } else if plan.useOriginals, let original = s.original {
                jobs.append(.init(item: item, kind: .original, url: original, fallback: s.url, fileName: s.fileName))
            } else {
                jobs.append(.init(item: item, kind: .muted, url: s.url, fallback: nil, fileName: s.mutedFileName))
            }
        }
        return jobs
    }

    // MARK: Téléchargement par l'app
    private func runInApp(_ id: String, _ plan: VodDownloadPlan) {
        guard runners[id] == nil else { return }
        let folder = Self.folder(id)
        let jobs = Self.missingJobs(plan, item: id, folder: folder, skipping: [])
        logger.info("DOWNLOAD", "Téléchargement par l'app", "\(jobs.count) fichiers · \(id)")
        runners[id] = Task {
            // Premier problème rencontré : la raison montrée si des fichiers manquent.
            var problem: String? = nil
            await withTaskGroup(of: VodFetcher.Outcome.self) { group in
                var queue = jobs[...]
                for _ in 0 ..< Self.parallel {
                    guard let job = queue.popFirst() else { break }
                    group.addTask { await VodFetcher.fetch(job, into: folder) }
                }
                while let result = await group.next() {
                    switch result {
                    case .saved(let name, let size):
                        self.fileArrived(item: id, name: name, size: size)
                    case .refused(let reason):
                        // Les autres fichiers continuent.
                        if problem == nil {
                            problem = reason
                            logger.warn("DOWNLOAD", "Fichier refusé", "\(reason) · \(id)")
                        }
                    case .fatal(let reason):
                        // Réseau perdu, plus de place : inutile d'insister.
                        problem = reason
                        queue.removeAll()
                        group.cancelAll()
                    case .cancelled:
                        break
                    }
                    if Task.isCancelled {
                        queue.removeAll()
                        group.cancelAll()
                    }
                    if let job = queue.popFirst() {
                        group.addTask { await VodFetcher.fetch(job, into: folder) }
                    }
                }
            }
            // Arrêté (pause, app quittée) : rien à conclure.
            guard !Task.isCancelled else { return }
            self.runners[id] = nil
            self.settle(id, plan, problem: problem)
        }
    }

    /// Fin du téléchargement par l'app : tout est là, ou on dit pourquoi.
    private func settle(_ id: String, _ plan: VodDownloadPlan, problem: String?) {
        guard item(id)?.state == .downloading else { return }
        let (names, bytes) = Self.scan(plan, folder: Self.folder(id))
        present[id] = names
        update(id) {
            $0.done = names.count
            $0.bytes = bytes
        }
        if names.count >= plan.fileCount { finalize(id, plan); return }
        // Réseau « perdu » faute de Wi-Fi (données mobiles refusées) : il
        // attend le Wi-Fi au lieu d'échouer.
        if problem == VodDownloadFailure.network, Self.cellularBlocked { waitForWifi(id); return }
        fail(id, problem)
    }

    // MARK: Fichiers reçus (app ou iOS)
    /// « seg_00012.muted.ts » occupe la case de « seg_00012.ts ».
    nonisolated private static func slot(_ name: String) -> String {
        name.replacingOccurrences(of: ".muted.", with: ".")
    }

    func fileArrived(item id: String, name: String, size: Int64) {
        guard item(id)?.state == .downloading else { return }
        if present[id] == nil {
            // App relancée par iOS pour lui livrer ses fichiers : le disque fait foi.
            guard let plan = Self.loadPlan(id) else { return }
            let (names, bytes) = Self.scan(plan, folder: Self.folder(id))
            present[id] = names
            update(id) {
                $0.total = plan.fileCount
                $0.done = names.count
                $0.bytes = bytes
            }
        } else if present[id]?.insert(Self.slot(name)).inserted == true {
            let count = present[id]?.count ?? 0
            update(id) {
                $0.done = count
                $0.bytes += size
            }
        } else {
            return
        }
        unsaved += 1
        if unsaved >= 25 { save() }
        // Par l'app, la fin se décide quand tout a été demandé (settle).
        if runners[id] == nil, let now = item(id), now.total > 0, now.done >= now.total,
           let plan = Self.loadPlan(id) {
            finalize(id, plan)
        }
    }

    /// Fichier abandonné par iOS (refusé, après le repli muet et les nouveaux
    /// essais) : pas redemandé avant le retour dans l'app, qui dira pourquoi.
    func fileLost(item id: String, name: String) {
        lost[id, default: []].insert(name)
    }

    // MARK: Côté iOS (app quittée)
    /// Fournée suivante confiée à iOS : au plus `batchSize` fichiers.
    private func handOff(_ id: String, _ plan: VodDownloadPlan) {
        let jobs = Self.missingJobs(plan, item: id, folder: Self.folder(id), skipping: lost[id] ?? [])
        guard !jobs.isEmpty else { return }
        let batch = Array(jobs.prefix(Self.batchSize))
        VodDownloader.shared.enqueue(batch)
        logger.info("DOWNLOAD", "Suite confiée à iOS", "\(batch.count)/\(jobs.count) fichiers · \(id)")
    }

    /// Nouvelles d'iOS : quelques secondes après le dernier fichier arrivé,
    /// on regarde si la fournée est finie, pour lancer la suivante.
    func backgroundProgress(item id: String) {
        guard !foreground else { return }
        batchChecks[id]?.cancel()
        batchChecks[id] = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            await self.checkBatch(id)
        }
    }

    /// iOS a livré tout ce qu'il avait (app réveillée pour ça) : fournées
    /// suivantes, avant de lui rendre la main.
    func backgroundEventsDelivered() async {
        for d in items where d.state == .downloading {
            batchChecks[d.id]?.cancel()
            batchChecks[d.id] = nil
            await checkBatch(d.id)
        }
    }

    private func checkBatch(_ id: String) async {
        guard !foreground, item(id)?.state == .downloading, runners[id] == nil,
              let pending = await VodDownloader.shared.pendingFiles(item: id), pending.isEmpty,
              !foreground, item(id)?.state == .downloading, let plan = Self.loadPlan(id) else { return }
        let (names, _) = Self.scan(plan, folder: Self.folder(id))
        if names.count >= plan.fileCount { finalize(id, plan); return }
        handOff(id, plan)
    }

    // MARK: Fin
    private func fail(_ id: String, _ reason: String?) {
        guard item(id)?.state == .downloading else { return }
        update(id) {
            $0.state = .failed
            $0.reason = reason
        }
        save()
        logger.warn("DOWNLOAD", "Téléchargement interrompu", "\(reason ?? "?") · \(id)")
    }

    private func finalize(_ id: String, _ plan: VodDownloadPlan) {
        guard let d = item(id), d.state != .done else { return }
        let folder = Self.folder(id)
        let fm = FileManager.default
        var names: [Int: String] = [:]
        var restored = 0.0, muted = 0.0
        for s in plan.segments {
            if fm.fileExists(atPath: folder.appendingPathComponent(s.fileName).path) {
                names[s.index] = s.fileName
                // Original remis, ou « -unmuted.mp4 » (le son y est).
                if s.original != nil || s.keepsSound { restored += s.duration }
            } else if fm.fileExists(atPath: folder.appendingPathComponent(s.mutedFileName).path) {
                names[s.index] = s.mutedFileName
                muted += s.duration
            }
        }
        do {
            try Self.writePlaylist(plan, folder: folder, names: names)
        } catch {
            fail(id, VodDownloadFailure.space)
            return
        }
        runners[id]?.cancel()
        runners[id] = nil
        present[id] = nil
        lost[id] = nil
        // Doublons encore attendus d'iOS : plus utiles.
        VodDownloader.shared.cancel(item: id)
        update(id) {
            $0.state = .done
            $0.done = $0.total
            $0.reason = nil
            $0.restored = restored
            $0.muted = muted
        }
        save()
        logger.success("DOWNLOAD", "Téléchargement terminé", d.title)
        let lang = Lang(rawValue: UserDefaults.standard.string(forKey: "lang") ?? "en") ?? .en
        InAppNotices.shared.deliver(
            InAppNotice(kind: .download, title: translate("dl_done_notif", lang), body: d.title),
            id: "download-\(id)")
    }

    // MARK: Chat
    nonisolated static func hasChat(_ vodId: String) -> Bool { !vodId.isEmpty && vodId.allSatisfy(\.isNumber) }

    private func startChat(_ id: String) {
        guard chats[id] == nil, let d = item(id), d.withChat == true, d.chatCount == nil,
              let plan = Self.loadPlan(id), let first = plan.segments.first, let last = plan.segments.last else { return }
        let from = first.start, to = last.start + last.duration
        chats[id] = Task { [weak self] in
            let count = await VodChatArchive.download(vodId: d.vodId, from: from, to: to, into: VodDownloads.folder(id))
            guard let self, !Task.isCancelled else { return }
            self.chats[id] = nil
            guard let count else {
                // Chat introuvable (VOD supprimée par la chaîne…) : trois essais
                // espacés, puis le téléchargement s'en passe — il restait « chat
                // en cours » à vie, et repartait du début à chaque retour.
                let tries = (self.chatAttempts[id] ?? 0) + 1
                self.chatAttempts[id] = tries
                guard tries < 3 else {
                    logger.warn("DOWNLOAD", "Chat du téléchargement indisponible", d.title)
                    self.update(id) { $0.withChat = false }
                    self.save()
                    return
                }
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if !Task.isCancelled { self.startChat(id) }
                return
            }
            self.chatAttempts[id] = nil
            self.update(id) { $0.chatCount = count }
            self.save()
        }
    }

    /// Essais du chat de chaque téléchargement (session en cours).
    private var chatAttempts: [String: Int] = [:]

    // MARK: Export
    /// Un seul fichier (.ts, ou .mp4 pour les VODs en fMP4), pour Fichiers,
    /// AirDrop ou VLC. Temporaire : effacé après le partage, ou au lancement.
    func export(_ d: VodDownload) async -> URL? {
        guard d.state == .done, let plan = Self.loadPlan(d.id) else { return nil }
        let name = Self.exportName(d, ext: plan.map == nil ? "ts" : "mp4")
        let folder = Self.folder(d.id)
        return await Task.detached(priority: .userInitiated) {
            VodDownloads.concatenate(plan, folder: folder, name: name)
        }.value
    }

    nonisolated private static func concatenate(_ plan: VodDownloadPlan, folder: URL, name: String) -> URL? {
        let fm = FileManager.default
        try? fm.createDirectory(at: exportsDirectory, withIntermediateDirectories: true)
        let out = exportsDirectory.appendingPathComponent(name)
        try? fm.removeItem(at: out)
        guard fm.createFile(atPath: out.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: out) else { return nil }
        defer { try? handle.close() }
        var files: [String] = []
        if let mapName = plan.mapFileName { files.append(mapName) }
        for s in plan.segments {
            files.append(fm.fileExists(atPath: folder.appendingPathComponent(s.fileName).path) ? s.fileName : s.mutedFileName)
        }
        for file in files {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(file), options: .mappedIfSafe) else { continue }
            do { try handle.write(contentsOf: data) } catch { return nil }
        }
        return out
    }

    nonisolated private static func exportName(_ d: VodDownload, ext: String) -> String {
        let clean = { (s: String) in
            String(s.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || " -_".unicodeScalars.contains($0) })
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: " ", with: "_")
                .prefix(60)
        }
        let clock = { (t: Double) in dlClock(t).replacingOccurrences(of: ":", with: "-") }
        let parts = [String(clean(d.streamer)), String(clean(d.title)), "\(clock(d.start))_\(clock(d.end))",
                     String(clean(d.quality))].filter { !$0.isEmpty }
        return parts.joined(separator: "_") + ".\(ext)"
    }

    // MARK: Fichiers
    nonisolated private static func planURL(_ id: String) -> URL { folder(id).appendingPathComponent("plan.json") }

    nonisolated private static func loadPlan(_ id: String) -> VodDownloadPlan? {
        guard let data = try? Data(contentsOf: planURL(id)) else { return nil }
        return try? JSONDecoder().decode(VodDownloadPlan.self, from: data)
    }

    nonisolated private static func savePlan(_ plan: VodDownloadPlan, _ id: String) {
        if let data = try? JSONEncoder().encode(plan) { try? data.write(to: planURL(id), options: .atomic) }
    }

    /// Cases déjà remplies (segment, ou sa version muette) et leur taille.
    nonisolated private static func scan(_ plan: VodDownloadPlan, folder: URL) -> (Set<String>, Int64) {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        var sizes: [String: Int64] = [:]
        for u in urls { sizes[u.lastPathComponent] = Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        var names: Set<String> = []
        var bytes: Int64 = 0
        if let name = plan.mapFileName, let size = sizes[name] { names.insert(name); bytes += size }
        for s in plan.segments {
            if let size = sizes[s.fileName] ?? sizes[s.mutedFileName] { names.insert(s.fileName); bytes += size }
        }
        return (names, bytes)
    }

    /// Son d'origine encore là ? Quatre premiers passages coupés : tous
    /// refusés (403/404), la VOD est trop ancienne — inutile d'essayer les
    /// autres. Sans réponse (réseau lent, app quittée), on essaie quand même,
    /// segment par segment (repli muet sur refus) : « non » restait figé dans
    /// le plan, « Réessayer » et la reprise compris.
    nonisolated private static func originalsAvailable(_ plan: VodDownloadPlan) async -> Bool {
        var probed = 0, refused = 0
        for s in plan.segments.lazy.filter({ $0.original != nil }).prefix(4) {
            guard let original = s.original else { continue }
            probed += 1
            var req = URLRequest(url: original, timeoutInterval: 6)
            req.httpMethod = "HEAD"
            let code = (try? await URLSession.shared.data(for: req).1 as? HTTPURLResponse)?.statusCode
            if code == 200 { return true }
            if code == 403 || code == 404 { refused += 1 }
        }
        return probed > 0 && refused < probed
    }

    nonisolated private static func writePlaylist(_ plan: VodDownloadPlan, folder: URL, names: [Int: String]) throws {
        let target = Int((plan.segments.map(\.duration).max() ?? 10).rounded(.up))
        let mapName = plan.mapFileName
        var out = "#EXTM3U\n#EXT-X-VERSION:\(mapName != nil ? 7 : 3)\n#EXT-X-TARGETDURATION:\(max(1, target))\n"
        out += "#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n"
        if let mapName { out += "#EXT-X-MAP:URI=\"\(mapName)\"\n" }
        for s in plan.segments {
            guard let name = names[s.index] else { continue }
            if s.discontinuity { out += "#EXT-X-DISCONTINUITY\n" }
            out += String(format: "#EXTINF:%.3f,\n", s.duration) + name + "\n"
        }
        out += "#EXT-X-ENDLIST\n"
        try out.write(to: folder.appendingPathComponent("index.m3u8"), atomically: true, encoding: .utf8)
    }
}

// MARK: – Téléchargement par l'app (app ouverte)
/// Une session ordinaire : pour des centaines de petits fichiers, bien plus
/// rapide que celle d'arrière-plan, et chaque erreur se voit.
enum VodFetcher {
    enum Outcome: Sendable {
        case saved(String, Int64)
        /// Refusé par le serveur (« http:403 »…) : les autres continuent.
        case refused(String)
        /// Réseau perdu, plus de place : inutile de continuer.
        case fatal(String)
        case cancelled
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.httpMaximumConnectionsPerHost = VodDownloads.parallel
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    /// Un fichier, rangé dans le dossier du téléchargement. Original refusé :
    /// la version muette ; serveur débordé ou réseau instable : trois
    /// nouveaux essais, de plus en plus espacés.
    static func fetch(_ job: VodDownloader.Job, into folder: URL) async -> Outcome {
        let fm = FileManager.default
        var url = job.url, name = job.fileName, kind = job.kind
        var attempt = 0
        while true {
            if Task.isCancelled { return .cancelled }
            // Déjà là (livré par iOS entre-temps) : rien à refaire.
            for existing in [name, VodDownloader.counterpart(name)] {
                if let size = fileSize(folder.appendingPathComponent(existing)) { return .saved(existing, size) }
            }
            do {
                var request = URLRequest(url: url)
                // « Wi-Fi seulement » : jamais par les données mobiles.
                request.allowsCellularAccess = !VodDownloads.wifiOnly
                let (tmp, response) = try await session.download(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if code == 200 {
                    let dest = folder.appendingPathComponent(name)
                    try? fm.removeItem(at: dest)
                    do {
                        try fm.moveItem(at: tmp, to: dest)
                    } catch {
                        try? fm.removeItem(at: tmp)
                        // Dossier effacé entre-temps (téléchargement supprimé).
                        guard fm.fileExists(atPath: folder.path) else { return .cancelled }
                        return isOutOfSpace(error) ? .fatal(VodDownloadFailure.space) : .refused("storage")
                    }
                    return .saved(name, fileSize(dest) ?? 0)
                }
                try? fm.removeItem(at: tmp)
                // Erreur passagère (429, 5xx) : nouvel essai d'abord, original
                // compris — il passait aussitôt à la version muette, pour de bon.
                if code == 429 || code >= 500, attempt < 3 {
                    attempt += 1
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)
                    continue
                }
                // Son d'origine effacé du CDN (ou toujours refusé) : la version muette.
                if kind == .original, let fallback = job.fallback {
                    url = fallback
                    name = VodDownloader.mutedName(job.fileName)
                    kind = .muted
                    attempt = 0
                    continue
                }
                return .refused("http:\(code)")
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled { return .cancelled }
                if isOutOfSpace(error) { return .fatal(VodDownloadFailure.space) }
                if attempt < 3 {
                    attempt += 1
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)
                    continue
                }
                return .fatal(VodDownloadFailure.network)
            }
        }
    }

    private static func fileSize(_ url: URL) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let n = attrs[.size] as? NSNumber else { return nil }
        return n.int64Value
    }

    private static func isOutOfSpace(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteOutOfSpaceError { return true }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOSPC) { return true }
        if let url = error as? URLError, url.code == .cannotWriteToFile || url.code == .cannotCreateFile { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return isOutOfSpace(underlying) }
        return false
    }
}

// MARK: – Téléchargements en arrière-plan (app quittée)
/// Session de téléchargement d'arrière-plan d'iOS : un fichier par tâche,
/// rangé dans le dossier du téléchargement dès qu'il arrive, puis
/// VodDownloads prévenu. iOS relance l'app en arrière-plan pour livrer les
/// fichiers arrivés pendant qu'elle était fermée (AppDelegate).
final class VodDownloader: NSObject, URLSessionDownloadDelegate {
    static let shared = VodDownloader()
    static let identifier = "com.mxfia19.TwitchUnblock.downloads"

    enum Kind: String { case initSegment = "i", normal = "n", original = "o", muted = "m" }

    struct Job {
        let item: String
        let kind: Kind
        let url: URL
        /// Original refusé : la version muette à demander à la place.
        let fallback: URL?
        let fileName: String
    }

    /// Rendu à iOS une fois les événements d'arrière-plan traités.
    var backgroundCompletion: (() -> Void)?

    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.name = "tu.downloads"
        return q
    }()
    private var session: URLSession!
    // Tenus sur `queue` seulement.
    private var finished: [Int: Int64] = [:]
    private var refused: [Int: Int] = [:]
    private var retries: [String: Int] = [:]

    private override init() {
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.httpMaximumConnectionsPerHost = 4
        session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }

    /// Recréer la session au lancement : iOS lui rend les tâches en cours.
    func activate() {}

    // MARK: Fournées
    private static let generationKey = "dl_generation"
    /// Numéro de la dernière fournée confiée à iOS (gardé d'un lancement à
    /// l'autre) : au retour dans l'app, seules les fournées déjà parties
    /// sont annulées.
    var generation: Int { UserDefaults.standard.integer(forKey: Self.generationKey) }

    /// Fichiers confiés à iOS, avec un peu de temps demandé pour finir de
    /// tout créer même si l'app passe en arrière-plan entre-temps.
    @MainActor
    func enqueue(_ jobs: [Job]) {
        guard !jobs.isEmpty else { return }
        let next = generation + 1
        UserDefaults.standard.set(next, forKey: Self.generationKey)
        let time = BackgroundTaskBox()
        time.id = UIApplication.shared.beginBackgroundTask(withName: "downloads") { time.end() }
        queue.addOperation { [self] in
            for job in jobs { start(job, generation: next) }
            Task { @MainActor in time.end() }
        }
    }

    private func start(_ job: Job, generation: Int) {
        var request = URLRequest(url: job.url)
        // « Wi-Fi seulement » : iOS attend le Wi-Fi pour ce fichier.
        request.allowsCellularAccess = !VodDownloads.wifiOnly
        let task = session.downloadTask(with: request)
        task.taskDescription = Self.describe(job, generation: generation)
        task.resume()
    }

    /// Tâches de ce téléchargement, des fournées jusqu'à `upTo` comprise.
    func cancel(item: String, upTo generation: Int = .max) {
        session.getAllTasks { tasks in
            for t in tasks {
                guard let parsed = Self.parse(t.taskDescription), parsed.job.item == item,
                      parsed.generation <= generation else { continue }
                t.cancel()
            }
        }
    }

    /// Fichiers encore attendus d'iOS pour ce téléchargement ; nil si la
    /// session ne répond pas.
    func pendingFiles(item: String) async -> Set<String>? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Set<String>?, Never>) in
            let once = Once()
            session.getAllTasks { tasks in
                let names = Set(tasks.compactMap { t -> String? in
                    guard t.state == .running || t.state == .suspended,
                          let parsed = Self.parse(t.taskDescription), parsed.job.item == item else { return nil }
                    return parsed.job.fileName
                })
                if once.claim() { continuation.resume(returning: names) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                if once.claim() { continuation.resume(returning: nil) }
            }
        }
    }

    // MARK: Description d'une tâche : « téléchargement|type|fichier|repli|fournée »
    private static func describe(_ job: Job, generation: Int) -> String {
        [job.item, job.kind.rawValue, job.fileName, job.fallback?.absoluteString ?? "", String(generation)]
            .joined(separator: "|")
    }

    /// Les tâches d'avant les fournées n'ont pas de numéro : 0.
    private static func parse(_ text: String?) -> (job: Job, generation: Int)? {
        guard var parts = text?.components(separatedBy: "|"), parts.count >= 4,
              let kind = Kind(rawValue: parts[1]) else { return nil }
        var generation = 0
        if parts.count >= 5, let g = Int(parts[parts.count - 1]) {
            generation = g
            parts.removeLast()
        }
        let job = Job(item: parts[0], kind: kind, url: URL(fileURLWithPath: "/"),
                      fallback: URL(string: parts[3...].joined(separator: "|")), fileName: parts[2])
        return (job, generation)
    }

    /// « seg_00012.ts » → « seg_00012.muted.ts ».
    static func mutedName(_ name: String) -> String {
        let ns = name as NSString
        return ns.deletingPathExtension + ".muted." + ns.pathExtension
    }

    /// « seg_00012.ts » ⇄ « seg_00012.muted.ts ».
    static func counterpart(_ name: String) -> String {
        name.contains(".muted.") ? name.replacingOccurrences(of: ".muted.", with: ".") : mutedName(name)
    }

    // MARK: URLSessionDownloadDelegate
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let job = Self.parse(downloadTask.taskDescription)?.job else { return }
        let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { refused[downloadTask.taskIdentifier] = code; return }
        // À ranger avant de rendre la main : iOS efface le fichier ensuite.
        let dest = VodDownloads.folder(job.item).appendingPathComponent(job.fileName)
        let fm = FileManager.default
        try? fm.removeItem(at: dest)
        do {
            try fm.moveItem(at: location, to: dest)
            let size = (try? fm.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.int64Value ?? 0
            finished[downloadTask.taskIdentifier] = size
        } catch {
            refused[downloadTask.taskIdentifier] = -1   // dossier supprimé entre-temps
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let (job, generation) = Self.parse(task.taskDescription) else { return }
        let key = task.taskDescription ?? ""
        if let size = finished.removeValue(forKey: task.taskIdentifier) {
            retries[key] = nil
            Task { @MainActor in
                VodDownloads.shared.fileArrived(item: job.item, name: job.fileName, size: size)
                VodDownloads.shared.backgroundProgress(item: job.item)
            }
            return
        }
        if let code = refused.removeValue(forKey: task.taskIdentifier) {
            if code == -1 { return }
            // Erreur passagère (429, 5xx) : trois nouveaux essais avant de
            // conclure (un original passait sinon aussitôt en version muette).
            if code == 429 || code >= 500, (retries[key] ?? 0) < 3, let url = task.originalRequest?.url {
                retries[key] = (retries[key] ?? 0) + 1
                start(Job(item: job.item, kind: job.kind, url: url, fallback: job.fallback, fileName: job.fileName),
                      generation: generation)
                return
            }
            retries[key] = nil
            // Son d'origine refusé (effacé du CDN) : la version muette.
            if job.kind == .original, let fallback = job.fallback {
                start(Job(item: job.item, kind: .muted, url: fallback, fallback: nil,
                          fileName: Self.mutedName(job.fileName)), generation: generation)
                return
            }
            lose(job)
            return
        }
        if (error as? URLError)?.code == .cancelled { return }
        // Erreur réseau : trois nouveaux essais.
        let count = (retries[key] ?? 0) + 1
        retries[key] = count
        if count <= 3, let url = task.originalRequest?.url {
            start(Job(item: job.item, kind: job.kind, url: url, fallback: job.fallback, fileName: job.fileName),
                  generation: generation)
        } else {
            retries[key] = nil
            lose(job)
        }
    }

    private func lose(_ job: Job) {
        Task { @MainActor in
            VodDownloads.shared.fileLost(item: job.item, name: job.fileName)
            VodDownloads.shared.backgroundProgress(item: job.item)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            await VodDownloads.shared.backgroundEventsDelivered()
            self.backgroundCompletion?()
            self.backgroundCompletion = nil
        }
    }
}

/// Vrai la première fois seulement : la réponse ou le délai, le premier gagne.
private final class Once {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

extension Notification.Name {
    /// Téléchargement supprimé (objet : son identifiant) : le lecteur qui le
    /// lisait se ferme.
    static let vodDownloadDeleted = Notification.Name("VodDownloadDeleted")
}
