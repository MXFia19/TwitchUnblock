import Foundation
import UIKit
import AVFoundation
import ObjectiveC

// ═══════════════════════════════════════════════════════════════════════════
//  Outils de debug de « TU Dev » (branche dev-17d298, jamais sur la branche de
//  test ni sur master) : une bulle flottante sur tous les écrans ouvre
//  l'inspecteur — les requêtes réseau de l'app, comme l'onglet Réseau d'un
//  navigateur, et l'état des lecteurs (statistiques d'AVPlayer).
//
//  Rien n'est détourné : les requêtes partent comme d'habitude. La reprise de
//  chaque tâche URLSession (resume) est notée, puis son état suivi jusqu'à la
//  fin (statut, en-têtes, taille, durée). Le corps des requêtes est gardé (pour
//  lire les requêtes GQL), pas celui des réponses. Les morceaux de vidéo
//  qu'AVPlayer charge lui-même ne passent pas par là : l'onglet Lecteur en
//  donne le compte.
//
//  Actif seulement quand le CI a écrit TUChannel = dev (app « TU Dev »).
// ═══════════════════════════════════════════════════════════════════════════

enum DevTools {
    static var isEnabled: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "TUChannel") as? String) == "dev"
    }

    /// Au lancement (AppDelegate) : capture réseau, suivi des lecteurs, bulle.
    static func install() {
        guard isEnabled else { return }
        NetCapture.start()
        PlayerTracker.start()
        Task { @MainActor in DevBubble.shared.attach() }
        // Scène pas encore active au lancement : la bulle s'y pose ensuite.
        _ = NotificationCenter.default.addObserver(forName: UIScene.didActivateNotification,
                                                   object: nil, queue: .main) { _ in
            Task { @MainActor in DevBubble.shared.attach() }
        }
    }

    /// Échange une méthode d'une classe avec sa remplaçante (venue d'une
    /// extension), sur cette classe seulement : ni la classe mère ni ses
    /// autres filles ne changent.
    static func swizzle(_ cls: AnyClass, _ original: Selector, _ replacement: Selector) {
        guard let o = class_getInstanceMethod(cls, original),
              let inherited = class_getInstanceMethod(cls, replacement) else { return }
        class_addMethod(cls, replacement, method_getImplementation(inherited), method_getTypeEncoding(inherited))
        guard let r = class_getInstanceMethod(cls, replacement) else { return }
        if class_addMethod(cls, original, method_getImplementation(r), method_getTypeEncoding(r)) {
            class_replaceMethod(cls, replacement, method_getImplementation(o), method_getTypeEncoding(o))
        } else {
            method_exchangeImplementations(o, r)
        }
    }
}

// MARK: – Requêtes notées

struct NetEntry: Identifiable {
    let id: Int
    let started: Date
    let method: String
    let url: URL
    let requestHeaders: [String: String]
    let requestBody: Data?
    var finalURL: URL? = nil
    var status: Int? = nil
    var responseHeaders: [String: String] = [:]
    var mime: String? = nil
    var bytes: Int64 = 0
    var duration: TimeInterval? = nil
    var error: String? = nil
    /// Corps de la réponse (texte, JSON, playlist ; 512 Ko au plus), s'il a pu
    /// être lu (voir NetCapture.startBodyCapture).
    var responseBody: Data? = nil
    var responseTruncated = false
    /// Corps oublié pour tenir le budget mémoire (48 Mo pour tous).
    var bodyDropped = false

    var finished: Bool { duration != nil }
    var cancelled: Bool { error == NetCapture.cancelledText }
    var failed: Bool { (error != nil && !cancelled) || (status ?? 0) >= 400 }

    /// Nom court, comme la colonne « Name » d'un navigateur : l'opération GQL,
    /// sinon le dernier morceau de l'adresse.
    var name: String {
        if url.host == "gql.twitch.tv", let op = gqlOperation { return op }
        let last = url.lastPathComponent
        return last.isEmpty || last == "/" ? (url.host ?? url.absoluteString) : last
    }

    private var gqlBodies: [[String: Any]] {
        guard let body = requestBody, let json = try? JSONSerialization.jsonObject(with: body) else { return [] }
        if let list = json as? [[String: Any]] { return list }
        if let one = json as? [String: Any] { return [one] }
        return []
    }

    /// operationName, sinon le premier champ de la requête (« query {
    /// streamPlaybackAccessToken(… » → streamPlaybackAccessToken).
    var gqlOperation: String? {
        let names: [String] = gqlBodies.compactMap { d in
            if let n = d["operationName"] as? String, !n.isEmpty { return n }
            guard let q = d["query"] as? String else { return nil }
            let after = q.split(separator: "{", maxSplits: 1).dropFirst().first.map(String.init) ?? q
            let word = after.trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            return word.isEmpty ? nil : String(word)
        }
        guard !names.isEmpty else { return nil }
        return names.count > 1 ? "[\(names.count)] " + names.joined(separator: ", ") : names[0]
    }

    /// Texte des requêtes GQL, avec ses vrais retours à la ligne.
    var gqlQuery: String? {
        let queries = gqlBodies.compactMap { $0["query"] as? String }
        return queries.isEmpty ? nil : queries.joined(separator: "\n\n")
    }
}

/// Les dernières requêtes (800 au plus), lues par l'inspecteur. Verrou : les
/// tâches finissent sur n'importe quel fil.
final class NetLog: ObservableObject {
    static let shared = NetLog()
    static let maxEntries = 800

    private let lock = NSLock()
    private var items: [NetEntry] = []
    private var nextId = 1
    private var notifyPending = false
    /// Capture en pause (bouton de l'inspecteur).
    var paused = false

    var snapshot: [NetEntry] {
        lock.lock(); defer { lock.unlock() }
        return items
    }

    func begin(_ request: URLRequest) -> Int? {
        guard !paused, let url = request.url else { return nil }
        lock.lock()
        let id = nextId
        nextId += 1
        items.append(NetEntry(id: id, started: Date(), method: request.httpMethod ?? "GET", url: url,
                              requestHeaders: request.allHTTPHeaderFields ?? [:],
                              requestBody: request.httpBody.map { $0.prefix(64 * 1024) }))
        if items.count > Self.maxEntries { items.removeFirst(items.count - Self.maxEntries) }
        lock.unlock()
        notify()
        return id
    }

    func update(_ id: Int, _ change: (inout NetEntry) -> Void) {
        lock.lock()
        if let i = items.lastIndex(where: { $0.id == id }) { change(&items[i]) }
        lock.unlock()
        notify()
    }

    func clear() {
        lock.lock()
        items.removeAll()
        lock.unlock()
        notify()
    }

    func entry(_ id: Int) -> NetEntry? {
        lock.lock(); defer { lock.unlock() }
        return items.last { $0.id == id }
    }

    /// 48 Mo de corps de réponses pour toutes les requêtes gardées : au-delà,
    /// ceux des plus anciennes sont oubliés.
    static let bodyBudget = 48 * 1024 * 1024

    func trimBodies() {
        lock.lock()
        var total = items.reduce(0) { $0 + ($1.responseBody?.count ?? 0) }
        var i = 0
        while total > Self.bodyBudget, i < items.count {
            if let n = items[i].responseBody?.count {
                total -= n
                items[i].responseBody = nil
                items[i].bodyDropped = true
            }
            i += 1
        }
        lock.unlock()
    }

    /// Écran mis à jour au plus toutes les 0,3 s (une page lance des dizaines
    /// de requêtes d'un coup).
    private func notify() {
        lock.lock()
        let already = notifyPending
        notifyPending = true
        lock.unlock()
        guard !already else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.notifyPending = false
            self.lock.unlock()
            self.objectWillChange.send()
        }
    }
}

// MARK: – Capture (reprise des tâches URLSession)

enum NetCapture {
    static let cancelledText = "annulée"
    private static let lock = NSLock()
    private static var watched: [ObjectIdentifier: NSKeyValueObservation] = [:]
    private static var started = false
    /// Tâche suivie → sa requête notée, et le corps de sa réponse en cours.
    private static var ids: [ObjectIdentifier: Int] = [:]
    private static var bodies: [ObjectIdentifier: (data: Data, truncated: Bool)] = [:]
    /// Corps gardé par réponse.
    static let bodyCap = 512 * 1024
    /// Lecture des corps branchée (la classe privée existe sur cet iOS).
    private(set) static var bodyCaptureActive = false

    static func start() {
        guard !started else { return }
        started = true
        // La classe privée qui définit resume (grappe de NSURLSessionTask),
        // trouvée sur une tâche jamais lancée.
        let session = URLSession(configuration: .ephemeral)
        let probe = session.dataTask(with: URL(string: "https://127.0.0.1/")!)
        let sel = #selector(URLSessionTask.resume)
        var cls: AnyClass = type(of: probe)
        while let parent = class_getSuperclass(cls),
              let mine = class_getInstanceMethod(cls, sel),
              let theirs = class_getInstanceMethod(parent, sel),
              method_getImplementation(mine) == method_getImplementation(theirs) {
            cls = parent
        }
        probe.cancel()
        session.invalidateAndCancel()
        DevTools.swizzle(cls, sel, #selector(URLSessionTask.tuDev_resume))
        startBodyCapture()
    }

    /// Corps des réponses, lus là où la connexion de chaque tâche les reçoit
    /// (classe privée de CFNetwork, comme Atlantis de Proxyman) : quel que
    /// soit l'appel (async, bloc, délégué), sans rien détourner. Absente sur
    /// une autre version d'iOS : pas de corps, le reste marche.
    private static func startBodyCapture() {
        let sel = NSSelectorFromString("_didReceiveData:")
        let names = ["__NSCFURLLocalSessionConnection", "__NSCFURLSessionConnection"]
        guard let cls = names.compactMap({ NSClassFromString($0) }).first(where: { class_getInstanceMethod($0, sel) != nil }),
              let method = class_getInstanceMethod(cls, sel) else { return }
        typealias Original = @convention(c) (AnyObject, Selector, AnyObject) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
        let taskSel = NSSelectorFromString("task")
        let block: @convention(block) (NSObject, AnyObject) -> Void = { connection, data in
            if connection.responds(to: taskSel),
               let task = connection.value(forKey: "task") as? URLSessionTask,
               let bytes = data as? Data {
                received(bytes, for: task)
            }
            original(connection, sel, data)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
        bodyCaptureActive = true
    }

    /// Un morceau de réponse : ajouté au corps de sa tâche, 512 Ko au plus.
    /// Images, vidéo et son : pas gardés (lourds, illisibles ici) ; les
    /// playlists (…mpegurl) le sont.
    static func received(_ data: Data, for task: URLSessionTask) {
        if let mime = task.response?.mimeType?.lowercased(),
           mime.hasPrefix("image/") || mime.hasPrefix("video/") || mime == "application/octet-stream"
            || (mime.hasPrefix("audio/") && !mime.contains("mpegurl")) {
            return
        }
        let key = ObjectIdentifier(task)
        lock.lock()
        defer { lock.unlock() }
        guard ids[key] != nil else { return }
        var body = bodies[key] ?? (data: Data(), truncated: false)
        guard !body.truncated else { return }
        let room = bodyCap - body.data.count
        if data.count > room {
            body.data.append(data.prefix(room))
            body.truncated = true
        } else {
            body.data.append(data)
        }
        bodies[key] = body
    }

    /// Juste avant le vrai resume : la requête notée, son état suivi.
    static func willResume(_ task: URLSessionTask) {
        guard let request = task.originalRequest ?? task.currentRequest,
              let scheme = request.url?.scheme?.lowercased(), scheme == "http" || scheme == "https",
              // Envois vers le PC (DevPCStream) : pas notés, sinon ils se renverraient.
              request.value(forHTTPHeaderField: DevPCStream.marker) == nil else { return }
        let key = ObjectIdentifier(task)
        lock.lock()
        let known = watched[key] != nil
        lock.unlock()
        // Reprise après une suspension : déjà suivie.
        guard !known, let id = NetLog.shared.begin(request) else { return }
        let observation = task.observe(\.state, options: [.new]) { task, _ in
            let state = task.state
            guard state == .completed || state == .canceling else { return }
            finish(task, id: id)
        }
        lock.lock()
        watched[key] = observation
        ids[key] = id
        lock.unlock()
    }

    private static func finish(_ task: URLSessionTask, id: Int) {
        let http = task.response as? HTTPURLResponse
        var headers: [String: String] = [:]
        for (k, v) in http?.allHeaderFields ?? [:] {
            if let k = k as? String { headers[k] = "\(v)" }
        }
        let bytes = task.countOfBytesReceived
        let mime = task.response?.mimeType
        let final = task.currentRequest?.url
        let error: String? = task.error.map { err in
            (err as NSError).code == NSURLErrorCancelled ? cancelledText : err.localizedDescription
        } ?? (task.state == .canceling ? cancelledText : nil)
        let key = ObjectIdentifier(task)
        lock.lock()
        let observation = watched.removeValue(forKey: key)
        let body = bodies.removeValue(forKey: key)
        ids.removeValue(forKey: key)
        lock.unlock()
        NetLog.shared.update(id) { e in
            guard !e.finished else { return }
            e.status = http?.statusCode
            e.responseHeaders = headers
            e.mime = mime
            e.bytes = bytes
            e.duration = Date().timeIntervalSince(e.started)
            e.error = error
            if let final, final != e.url { e.finalURL = final }
            if let body, !body.data.isEmpty {
                e.responseBody = body.data
                e.responseTruncated = body.truncated
            }
        }
        if body != nil { NetLog.shared.trimBodies() }
        if let entry = NetLog.shared.entry(id) { DevPCStream.shared.enqueue(entry) }
        // Arrêtée hors de son propre rappel.
        DispatchQueue.main.async { observation?.invalidate() }
    }
}

extension URLSessionTask {
    /// Remplace resume (voir NetCapture.start) : note la requête, puis la lance.
    @objc dynamic func tuDev_resume() {
        NetCapture.willResume(self)
        tuDev_resume()
    }
}

// MARK: – Lecteurs suivis

/// Tous les AVPlayer de l'app (lecteur, multi-live, aperçus), notés à leur
/// lecture ou à leur changement d'élément, gardés en lien faible.
enum PlayerTracker {
    private static let players = NSHashTable<AVPlayer>.weakObjects()
    private static var started = false

    static func start() {
        guard !started else { return }
        started = true
        DevTools.swizzle(AVPlayer.self, #selector(AVPlayer.play), #selector(AVPlayer.tuDev_play))
        DevTools.swizzle(AVPlayer.self, #selector(AVPlayer.replaceCurrentItem(with:)),
                         #selector(AVPlayer.tuDev_replaceCurrentItem(with:)))
    }

    static func track(_ player: AVPlayer) {
        if Thread.isMainThread {
            players.add(player)
        } else {
            DispatchQueue.main.async { players.add(player) }
        }
    }

    /// Lecteurs encore en vie, ceux qui jouent d'abord (fil principal).
    static var all: [AVPlayer] {
        players.allObjects.sorted { ($0.rate > 0 ? 0 : 1) < ($1.rate > 0 ? 0 : 1) }
    }
}

extension AVPlayer {
    @objc dynamic func tuDev_play() {
        PlayerTracker.track(self)
        tuDev_play()
    }

    @objc dynamic func tuDev_replaceCurrentItem(with item: AVPlayerItem?) {
        PlayerTracker.track(self)
        tuDev_replaceCurrentItem(with: item)
    }
}
