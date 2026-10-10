import Foundation
import UIKit

// ═══════════════════════════════════════════════════════════════════════════
//  Gestion des retours depuis l'app, pour le propriétaire seulement : les
//  mêmes routes que le panneau de /stats (/api/admin/feedback). Le Worker
//  vérifie à chaque requête que le jeton Twitch est celui d'un compte admin
//  (ADMIN_IDS) — l'app ne fait qu'afficher l'entrée quand il le confirme.
// ═══════════════════════════════════════════════════════════════════════════

/// Un retour, vu par l'admin.
struct AdminFeedbackItem: Decodable, Identifiable, Hashable {
    let key: String
    let kind: String
    let message: String
    let contact: String?
    let platform: String
    let version: String
    let info: String?
    let at: Double
    let status: String
    let updatedAt: Double
    let lastFrom: String
    let count: Int
    let photos: Int

    var id: String { key }
    /// La personne a répondu en dernier : à toi de jouer.
    var awaiting: Bool { lastFrom == "u" && count > 1 }
    var date: Date { Date(timeIntervalSince1970: at / 1000) }
    var updatedDate: Date { Date(timeIntervalSince1970: updatedAt / 1000) }

    /// Infos techniques (JSON envoyé par l'appareil) en lignes « clé : valeur ».
    var readableInfo: String? {
        guard let info, !info.isEmpty else { return nil }
        guard let data = info.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return info }
        let lines = dict.keys.sorted().compactMap { k -> String? in
            let v = dict[k]
            if v is NSNull { return nil }
            if let b = v as? Bool { return b ? "\(k) : oui" : nil }
            let s = "\(v ?? "")"
            return s.isEmpty ? nil : "\(k) : \(s)"
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

/// État du webhook Discord (dernier envoi), sans jamais son adresse.
struct WebhookState: Decodable {
    let configured: Bool
    let last: Last?

    struct Last: Decodable {
        let ok: Bool?
        let status: Int?
        let detail: String?
        let at: Double?
    }
}

@MainActor
final class AdminFeedbackService: ObservableObject {
    static let shared = AdminFeedbackService()

    @Published private(set) var isAdmin = false
    @Published private(set) var items: [AdminFeedbackItem] = []
    @Published private(set) var webhook: WebhookState? = nil
    @Published private(set) var threads: [String: [FeedbackMessage]] = [:]

    /// Retours où la personne attend une réponse.
    var awaitingCount: Int { items.filter(\.awaiting).count }

    private var token: String?
    private var photoCache: [String: UIImage] = [:]

    private struct Me: Decodable { let admin: Bool }
    private struct ListResponse: Decodable { let items: [AdminFeedbackItem]; let webhook: WebhookState? }
    private struct ThreadResponse: Decodable { let item: AdminFeedbackItem; let thread: [FeedbackMessage] }
    private struct TestResponse: Decodable { let ok: Bool; let webhook: WebhookState? }

    /// Le compte connecté est-il admin ? Demandé au Worker, avec son jeton.
    func refreshAdmin(token: String?) async {
        self.token = token
        guard let token, !token.isEmpty else {
            isAdmin = false
            items = []
            threads = [:]
            return
        }
        guard let data = await request("GET", "/api/admin/me"),
              let me = try? JSONDecoder().decode(Me.self, from: data) else { return }
        isAdmin = me.admin
        if me.admin { await load() }
    }

    func load() async {
        guard isAdmin, let data = await request("GET", "/api/admin/feedback"),
              let r = try? JSONDecoder().decode(ListResponse.self, from: data) else { return }
        items = r.items
        webhook = r.webhook
    }

    func loadThread(_ key: String) async {
        let q = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key
        guard let data = await request("GET", "/api/admin/feedback?key=\(q)"),
              let r = try? JSONDecoder().decode(ThreadResponse.self, from: data) else { return }
        apply(r.item, thread: r.thread)
    }

    func reply(_ key: String, message: String, photos: [Data]) async -> Bool {
        await post(["reply": ["key": key, "message": message,
                              "photos": photos.map { $0.base64EncodedString() }]])
    }

    func setStatus(_ key: String, _ status: String) async -> Bool {
        await post(["status": ["key": key, "status": status]])
    }

    /// Supprime le retour et ses photos.
    func delete(_ key: String) async -> Bool {
        guard await request("POST", "/api/admin/feedback", body: ["delete": key]) != nil else { return false }
        items.removeAll { $0.key == key }
        threads[key] = nil
        return true
    }

    /// Envoie un message de test au salon Discord ; rend vrai s'il est arrivé.
    func testWebhook() async -> Bool {
        guard let data = await request("POST", "/api/admin/feedback", body: ["testWebhook": true]),
              let r = try? JSONDecoder().decode(TestResponse.self, from: data) else { return false }
        webhook = r.webhook
        return r.ok
    }

    /// Photo d'une discussion, demandée avec le jeton admin (gardée en mémoire).
    func photo(_ key: String, _ n: Int) async -> UIImage? {
        let id = "\(key)/\(n)"
        if let hit = photoCache[id] { return hit }
        let q = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key
        guard let data = await request("GET", "/api/feedback/photo?id=\(q)&n=\(n)"),
              let img = UIImage(data: data) else { return nil }
        if photoCache.count > 60 { photoCache.removeAll() }
        photoCache[id] = img
        return img
    }

    private func post(_ body: [String: Any]) async -> Bool {
        guard let data = await request("POST", "/api/admin/feedback", body: body),
              let r = try? JSONDecoder().decode(ThreadResponse.self, from: data) else { return false }
        apply(r.item, thread: r.thread)
        return true
    }

    private func apply(_ item: AdminFeedbackItem, thread: [FeedbackMessage]) {
        threads[item.key] = thread
        if let i = items.firstIndex(where: { $0.key == item.key }) { items[i] = item }
        else { items.insert(item, at: 0) }
    }

    private func request(_ method: String, _ path: String, body: [String: Any]? = nil) async -> Data? {
        guard let token, let url = URL(string: kAPIURL + path) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return nil }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { isAdmin = false }
        guard code == 200 else {
            logger.warn("ADMIN", "Requête refusée", "\(method) \(path.split(separator: "?").first ?? "") — HTTP \(code)")
            return nil
        }
        return data
    }
}
