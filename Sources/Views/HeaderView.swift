import SwiftUI

struct HeaderView: View {
    @EnvironmentObject private var store: AppStore

    private var langCycle: [Lang] { Lang.allCases }

    private var safeTop: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first(where: { $0.isKeyWindow })?.safeAreaInsets.top ?? 47
    }

    private func cycleLang() {
        let idx = langCycle.firstIndex(of: store.lang) ?? 0
        store.lang = langCycle[(idx + 1) % langCycle.count]
    }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Text("🟣").font(.system(size: 20))
                Text(store.t("title"))
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundColor(.tText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5) // Sécurité si le texte est long
            }
            Spacer()

            Button(action: { store.useProxy.toggle() }) {
                Text(store.useProxy ? "🔒 Proxy" : "🔓 Direct")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.tMuted)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.tSurface)
                    .cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.tBorder, lineWidth: 1))
            }

            Button(action: cycleLang) {
                Text(store.lang.flag)
                    .font(.system(size: 16))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.tSurface)
                    .cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.tBorder, lineWidth: 1))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, safeTop + 6)   // ✅ Safe area dynamique (MainTabView ignore la safe area)
        .padding(.bottom, 12)
        .background(Color.tCard)
        .overlay(Divider().background(Color.tBorder), alignment: .bottom)
    }
}
