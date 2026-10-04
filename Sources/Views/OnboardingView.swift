import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════
//  Tutoriel du tout premier lancement : ce que fait l'app, en quelques pages.
//  Revu depuis Réglages → À propos (« Revoir le tutoriel »).
// ═══════════════════════════════════════════════════════════════════════════

struct OnboardingView: View {
    let onFinish: () -> Void
    @EnvironmentObject private var store: AppStore
    @State private var page = 0

    private struct Page: Identifiable {
        let id: Int
        let icon: String
        let titleKey: String
        let textKey: String
    }

    private let pages: [Page] = [
        Page(id: 0, icon: "play.tv.fill",                     titleKey: "ob_welcome_title", textKey: "ob_welcome_text"),
        Page(id: 1, icon: "magnifyingglass",                  titleKey: "ob_watch_title",   textKey: "ob_watch_text"),
        Page(id: 2, icon: "heart.fill",                       titleKey: "ob_follow_title",  textKey: "ob_follow_text"),
        Page(id: 3, icon: "bubble.left.and.bubble.right.fill", titleKey: "ob_chat_title",   textKey: "ob_chat_text"),
        Page(id: 4, icon: "sparkles",                         titleKey: "ob_more_title",    textKey: "ob_more_text"),
    ]

    private var isLast: Bool { page == pages.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                if !isLast {
                    Button(store.t("ob_skip")) { onFinish() }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.tMuted)
                        .padding(.horizontal, 20).padding(.top, 12)
                }
            }
            .frame(height: 44)

            TabView(selection: $page) {
                ForEach(pages) { p in
                    VStack(spacing: 22) {
                        Spacer()
                        ZStack {
                            Circle()
                                .fill(LinearGradient(colors: [Color.tPrimary, Color.tPurple],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 110, height: 110)
                                .shadow(color: Color.tPrimary.opacity(0.45), radius: 24, y: 8)
                            Image(systemName: p.icon)
                                .font(.system(size: 46, weight: .bold))
                                .foregroundColor(.white)
                        }
                        Text(store.t(p.titleKey))
                            .font(.system(size: 26, weight: .heavy))
                            .foregroundColor(.tText)
                            .multilineTextAlignment(.center)
                        Text(store.t(p.textKey))
                            .font(.system(size: 16))
                            .foregroundColor(.tMuted)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 32)
                        Spacer()
                        Spacer()
                    }
                    .tag(p.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            // Points de progression
            HStack(spacing: 8) {
                ForEach(pages) { p in
                    Capsule()
                        .fill(p.id == page ? Color.tPrimary : Color.tBorder)
                        .frame(width: p.id == page ? 22 : 8, height: 8)
                }
            }
            .animation(.spring(response: 0.3), value: page)
            .padding(.bottom, 20)

            Button {
                if isLast { onFinish() } else { withAnimation { page += 1 } }
            } label: {
                Text(store.t(isLast ? "ob_start" : "ob_next"))
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(Color.tPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .background(Color.tDark.ignoresSafeArea())
    }
}
