import Foundation
import SwiftUI

// MARK: – Annonces du développeur
//
// Un message publié depuis /stats (outils développeur) et gardé par le Worker
// jusqu'à expiration. L'app le relit à l'ouverture et au retour au premier
// plan (au plus toutes les 5 min) et l'affiche en haut de l'accueil, jusqu'à
// ce qu'on le ferme ou qu'il expire.
@MainActor
final class AnnouncementService: ObservableObject {
    static let shared = AnnouncementService()

    struct Announcement: Equatable, Identifiable {
        let id: String
        let title: String
        let message: String
        let link: URL?
        let until: Date
    }

    @Published private(set) var current: Announcement? = nil

    private let dismissedKey = "announcement_dismissed"
    private let reactedKey = "announcement_reacted"

    /// Réactions proposées (mêmes que sur le site et côté Worker).
    static let reactions = ["👍", "❤️", "🔥", "😂", "👎"]
    /// Réaction de cet appareil, par annonce.
    @Published private(set) var reacted: [String: String] =
        UserDefaults.standard.dictionary(forKey: "announcement_reacted") as? [String: String] ?? [:]
    private var lastFetch: Date? = nil

    func refresh(force: Bool = false) async {
        if !force, let lastFetch, Date().timeIntervalSince(lastFetch) < 5 * 60 { pruneExpired(); return }
        guard let url = URL(string: "\(kAPIURL)/api/announcement") else { return }
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        lastFetch = Date()
        guard let a = json["announcement"] as? [String: Any],
              let id = a["id"] as? String,
              let untilMs = a["until"] as? Double else { current = nil; return }
        let item = Announcement(
            id: id,
            title: a["title"] as? String ?? "",
            message: a["message"] as? String ?? "",
            link: (a["link"] as? String).flatMap(URL.init(string:)),
            until: Date(timeIntervalSince1970: untilMs / 1000))
        let dismissed = UserDefaults.standard.stringArray(forKey: dismissedKey) ?? []
        current = (item.until > Date() && !dismissed.contains(item.id)) ? item : nil
    }

    /// ✕ : cette annonce ne revient plus (une nouvelle, si).
    func dismiss(_ a: Announcement) {
        var ids = UserDefaults.standard.stringArray(forKey: dismissedKey) ?? []
        ids.append(a.id)
        UserDefaults.standard.set(Array(ids.suffix(20)), forKey: dismissedKey)
        withAnimation { current = nil }
    }

    /// Toucher une réaction : la choisit, ou la retire si c'était déjà elle.
    /// Affichée tout de suite ; annulée si le serveur refuse.
    func react(_ a: Announcement, _ emoji: String) async {
        let prev = reacted[a.id]
        let next: String? = prev == emoji ? nil : emoji
        setReaction(next, for: a.id)
        guard let url = URL(string: "\(kAPIURL)/api/announcement/react") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "announcementId": a.id,
            "id": UsageService.shared.installId,
            "emoji": next.map { $0 as Any } ?? NSNull(),
        ])
        let ok = ((try? await URLSession.shared.data(for: req))?.1 as? HTTPURLResponse)?.statusCode == 200
        if !ok { setReaction(prev, for: a.id) }
    }

    private func setReaction(_ emoji: String?, for id: String) {
        var m = reacted
        m[id] = emoji
        // Les 10 dernières annonces suffisent.
        if m.count > 10 { m = Dictionary(uniqueKeysWithValues: m.sorted { $0.key > $1.key }.prefix(10).map { ($0.key, $0.value) }) }
        reacted = m
        UserDefaults.standard.set(m, forKey: reactedKey)
    }

    private func pruneExpired() {
        if let c = current, c.until <= Date() { current = nil }
    }
}

/// Bandeau d'annonce, dans le style des autres cartes de l'accueil.
struct AnnouncementBanner: View {
    let announcement: AnnouncementService.Announcement
    let onDismiss: () -> Void
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var service = AnnouncementService.shared

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [Color.tPrimary, Color.tPurple],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 38, height: 38)
                Image(systemName: "megaphone.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
            }
            VStack(alignment: .leading, spacing: 6) {
                if !announcement.title.isEmpty {
                    Text(announcement.title)
                        .font(.tCardTitle).foregroundColor(.tText)
                }
                if !announcement.message.isEmpty {
                    Text(announcement.message)
                        .font(.system(size: 13)).foregroundColor(.tMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let link = announcement.link {
                    Button { UIApplication.shared.open(link) } label: {
                        HStack(spacing: 4) {
                            Text(store.t("announcement_open"))
                            Image(systemName: "arrow.up.right")
                        }
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Color.tPrimary)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
                // Réactions : une par appareil, re-toucher la retire.
                HStack(spacing: 6) {
                    ForEach(AnnouncementService.reactions, id: \.self) { emoji in
                        let on = service.reacted[announcement.id] == emoji
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            Task { await service.react(announcement, emoji) }
                        } label: {
                            Text(emoji)
                                .font(.system(size: 16))
                                .frame(minWidth: 40, minHeight: 32)
                                .background(on ? Color.tPrimary.opacity(0.25) : Color.tSurface)
                                .clipShape(Capsule())
                                .overlay(Capsule().stroke(on ? Color.tPrimary : Color.tBorder, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.tMuted)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(Color.tPrimary.opacity(0.10))
        .background(Color.tCard)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(Color.tPrimary.opacity(0.45), lineWidth: 1))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}
