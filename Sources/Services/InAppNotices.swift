import SwiftUI
import UIKit
import UserNotifications

// MARK: – Avis internes
/// Avis de l'app : réponse à un signalement, drop prêt ou réclamé,
/// téléchargement terminé. App ouverte, ils s'affichent dans un bandeau en
/// haut de l'écran, notifications d'iOS permises ou non : sans permission,
/// iOS n'affichait rien du tout, même app ouverte. App en arrière-plan :
/// notification d'iOS si elle est permise, sinon l'avis attend le prochain
/// retour dans l'app.
struct InAppNotice: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case feedback, dropReady, dropClaimed, download, info

        var icon: String {
            switch self {
            case .feedback:    return "bubble.left.and.bubble.right.fill"
            case .dropReady:   return "gift.fill"
            case .dropClaimed: return "checkmark.seal.fill"
            case .download:    return "arrow.down.circle.fill"
            case .info:        return "info.circle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .feedback, .info:         return .tPrimary
            case .dropReady, .dropClaimed: return .tPurple
            case .download:                return .tSuccess
            }
        }
    }

    var id = UUID()
    var kind: Kind
    var title: String
    var body: String
    var at = Date()
}

@MainActor
final class InAppNotices: ObservableObject {
    static let shared = InAppNotices()

    /// Bandeau affiché, s'il y en a un.
    @Published private(set) var current: InAppNotice?
    /// Écrans capables de l'afficher (racine, feuilles ouvertes par-dessus) :
    /// seul le dernier apparu le montre, les autres sont dessous.
    @Published private(set) var hosts: [UUID] = []

    private var queue: [InAppNotice] = []
    private var timer: Task<Void, Never>?
    private static let pendingKey = "inapp_pending"

    /// Bandeau si l'app est au premier plan ; sinon notification d'iOS si
    /// elles sont permises, et sinon gardé pour le prochain retour.
    func deliver(_ notice: InAppNotice, id: String, userInfo: [String: String] = [:]) {
        if UIApplication.shared.applicationState == .active { show(notice); return }
        // Un peu de temps demandé à iOS : en arrière-plan, l'app pouvait être
        // suspendue avant que la notification soit posée (réponse vue pendant
        // un réveil, fin de téléchargement : annoncées des heures après, ou
        // jamais).
        let time = BackgroundTaskBox()
        time.id = UIApplication.shared.beginBackgroundTask(withName: "notice") { time.end() }
        Task {
            await deliverNow(notice, id: id, userInfo: userInfo)
            time.end()
        }
    }

    /// Comme `deliver`, mais attendu : un réveil en arrière-plan ne se termine
    /// qu'une fois la notification posée.
    func deliverNow(_ notice: InAppNotice, id: String, userInfo: [String: String] = [:]) async {
        if UIApplication.shared.applicationState == .active { show(notice); return }
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        switch status {
        case .authorized, .provisional, .ephemeral:
            let content = UNMutableNotificationContent()
            content.title = notice.title
            content.body = notice.body
            content.sound = .default
            content.userInfo = userInfo
            try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        default:
            keepForLater(notice)
        }
    }

    /// Un bandeau à la fois, 5 s chacun ; le même avis n'est pas répété.
    func show(_ notice: InAppNotice) {
        let same = { (n: InAppNotice) in n.kind == notice.kind && n.title == notice.title && n.body == notice.body }
        guard !queue.contains(where: same), !(current.map(same) ?? false) else { return }
        queue.append(notice)
        if queue.count > 5 { queue.removeFirst(queue.count - 5) }
        if current == nil { next() }
    }

    func dismiss() {
        timer?.cancel()
        current = nil
        guard !queue.isEmpty else { return }
        // Le temps que le bandeau parte avant le suivant.
        timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.next()
        }
    }

    /// Bandeau touché : ce qu'il annonce (« Mes signalements »).
    func open(_ notice: InAppNotice) {
        dismiss()
        if notice.kind == .feedback {
            NotificationCenter.default.post(name: .openMyFeedback, object: nil)
        }
    }

    /// Retour dans l'app : les avis arrivés en arrière-plan sans permission
    /// de notifier (trois jours au plus).
    func showPending() {
        let ud = UserDefaults.standard
        guard let data = ud.data(forKey: Self.pendingKey) else { return }
        ud.removeObject(forKey: Self.pendingKey)
        let list = (try? JSONDecoder().decode([InAppNotice].self, from: data)) ?? []
        for n in list where Date().timeIntervalSince(n.at) < 3 * 86_400 { show(n) }
    }

    func pushHost(_ id: UUID) {
        hosts.removeAll { $0 == id }
        hosts.append(id)
    }

    func popHost(_ id: UUID) {
        hosts.removeAll { $0 == id }
    }

    private func next() {
        guard !queue.isEmpty else { return }
        current = queue.removeFirst()
        timer?.cancel()
        timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    private func keepForLater(_ notice: InAppNotice) {
        let ud = UserDefaults.standard
        var list = ud.data(forKey: Self.pendingKey)
            .flatMap { try? JSONDecoder().decode([InAppNotice].self, from: $0) } ?? []
        list.append(notice)
        if let data = try? JSONEncoder().encode(Array(list.suffix(5))) {
            ud.set(data, forKey: Self.pendingKey)
        }
    }
}

extension View {
    /// Montre ici les avis internes quand cet écran est le plus haut : la
    /// racine de l'app, et chaque feuille ouverte par-dessus (Réglages…),
    /// sous laquelle un bandeau de la racine resterait caché.
    func inAppNoticeHost() -> some View { modifier(InAppNoticeHost()) }
}

private struct InAppNoticeHost: ViewModifier {
    @ObservedObject private var notices = InAppNotices.shared
    @State private var hostId = UUID()

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if notices.hosts.last == hostId, let notice = notices.current {
                    InAppNoticeBanner(notice: notice)
                        .id(notice.id)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: notices.current?.id)
            .onAppear { notices.pushHost(hostId) }
            .onDisappear { notices.popHost(hostId) }
    }
}

/// Bandeau d'un avis : touché, il ouvre ce qu'il annonce ; glissé vers le
/// haut, il part.
private struct InAppNoticeBanner: View {
    let notice: InAppNotice

    var body: some View {
        Button { InAppNotices.shared.open(notice) } label: {
            HStack(spacing: 10) {
                Image(systemName: notice.kind.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(notice.kind.tint)
                    .frame(width: 32, height: 32)
                    .background(notice.kind.tint.opacity(0.15))
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(notice.title)
                        .font(.system(size: 13, weight: .bold)).foregroundColor(.tText)
                        .lineLimit(1)
                    if !notice.body.isEmpty {
                        Text(notice.body)
                            .font(.system(size: 12)).foregroundColor(.tMuted)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: 440)
            .background(Color.tCard)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.tBorder, lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(DragGesture(minimumDistance: 10).onEnded { v in
            if v.translation.height < -12 { InAppNotices.shared.dismiss() }
        })
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }
}
