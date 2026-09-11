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

    @EnvironmentObject private var store: AppStore

    private var safeTop: CGFloat {
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

            Button(action: onOpenSettings) {
                avatar
            }
            .buttonStyle(.plain)
            .accessibilityLabel(store.t("settings"))
        }
        .padding(.horizontal, TSpace.lg)
        .padding(.top, safeTop + 4)
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
