import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════
//  En-tête : le titre de l'écran courant, et l'avatar qui ouvre les réglages.
//
//  L'ancien bandeau affichait le nom de l'app et un drapeau de langue sur
//  toute la largeur — beaucoup de place pour rien. On y met maintenant le
//  repère utile (où suis-je) et l'accès au compte, comme sur Twitch.
// ═══════════════════════════════════════════════════════════════════════════

struct HeaderView: View {
    let title: String
    let onOpenSettings: () -> Void
    /// Signaler un bug ou proposer une idée : en vue sur tous les onglets.
    var onFeedback: (() -> Void)? = nil
    /// Marge de l'encoche ou de la Dynamic Island, suivie par MainTabView
    /// (lue ici une fois, elle restait celle d'avant une rotation).
    var safeTop: CGFloat = HeaderView.windowSafeTop

    @EnvironmentObject private var store: AppStore

    /// Marge haute de la fenêtre, lue dans UIKit (repli : 47).
    static var windowSafeTop: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first(where: { $0.isKeyWindow })?.safeAreaInsets.top ?? 47
    }

    var body: some View {
        HStack(spacing: TSpace.md) {
            Text(title)
                .font(.tScreenTitle)
                .foregroundColor(.tText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Spacer(minLength: TSpace.sm)

            if let onFeedback {
                Button(action: onFeedback) {
                    Image(systemName: "ladybug.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.tPrimary)
                        .frame(width: 34, height: 34)
                        .tGlass(in: Circle(), fallback: Color.tPrimary.opacity(0.15))
                        // Réponse du développeur à un retour : on le voit d'ici.
                        .overlay(alignment: .topTrailing) {
                            FeedbackUnreadBadge().offset(x: 5, y: -5)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(store.t("feedback"))
            }

            Button(action: onOpenSettings) {
                avatar
            }
            .buttonStyle(.plain)
            .accessibilityLabel(store.t("settings"))
            .tourAnchor(.settings)
        }
        .padding(.horizontal, TSpace.lg)
        // Pas de marge haute (iPhone Duo, barre d'état en colonne sur le
        // côté) : le titre collait au bord de l'écran (fb_mvwsyucv).
        .padding(.top, max(safeTop, 20) + 4)
        .padding(.bottom, TSpace.md)
        .background(Color.tDark)
    }

    /// Photo de profil Twitch si on est connecté, silhouette sinon.
    /// Un liseré violet signale que la session est active.
    @ViewBuilder private var avatar: some View {
        Group {
            if let url = store.twitchAvatar, let parsed = URL(string: url) {
                AsyncImage(url: parsed) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Circle().fill(Color.tSurface)
                }
            } else {
                Circle().fill(Color.tSurface)
                    .overlay(Image(systemName: "person.fill")
                        .font(.system(size: 15))
                        .foregroundColor(.tMuted))
            }
        }
        .frame(width: 34, height: 34)
        .clipShape(Circle())
        .overlay(Circle().stroke(store.twitchToken != nil ? Color.tPrimary : Color.tBorder,
                                 lineWidth: 2))
    }
}

/// Pastille « nouvelle réponse » d'un retour (FeedbackStore).
struct FeedbackUnreadBadge: View {
    @ObservedObject private var inbox = FeedbackStore.shared
    var body: some View {
        if inbox.unreadCount > 0 {
            Text(inbox.unreadCount > 9 ? "9+" : String(inbox.unreadCount))
                .font(.system(size: 10, weight: .heavy))
                .foregroundColor(.white)
                .padding(.horizontal, 5)
                .frame(minWidth: 17, minHeight: 17)
                .background(Color.tLive)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color.tDark, lineWidth: 1.5))
                .accessibilityHidden(true)
        }
    }
}
