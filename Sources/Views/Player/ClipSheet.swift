import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════
//  « Créer un clip » (menu ⋯ du lecteur, pendant un direct) : la création en
//  cours, puis le lien du clip (copier, partager) ou ce qui l'a empêchée.
//  Sans session web : de quoi la connecter, et le clip part ensuite au même
//  instant.
// ═══════════════════════════════════════════════════════════════════════════

struct ClipSheet: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var clips = ClipCreator.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showWebLogin = false
    /// Lien copié : le bouton le dit, jusqu'au clip suivant.
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(store.t("clip_create")).font(.tSection).foregroundColor(.tText)
                Spacer()
                TIconButton(icon: "xmark") { dismiss() }
            }
            .padding(TSpace.lg)

            Divider().background(Color.tBorder)

            ScrollView {
                content
                    .frame(maxWidth: .infinity)
                    .padding(TSpace.lg)
            }
        }
        .background(Color.tDark)
        .onChange(of: clips.state) { _ in copied = false }
        // Connexion de la session web : le clip part dès qu'elle est acceptée.
        .sheet(isPresented: $showWebLogin) {
            TwitchWebLoginSheet(
                clearSession: store.webSessionExpired || store.webSessionMismatch != nil,
                expectedLogin: store.twitchLogin,
                onComplete: { webToken, webLogin in
                    showWebLogin = false
                    Task { @MainActor in
                        if await store.adoptWebToken(webToken, login: webLogin) {
                            clips.retry(store: store)
                        }
                    }
                },
                onCancel: { showWebLogin = false }
            )
        }
    }

    @ViewBuilder private var content: some View {
        switch clips.state {
        case .idle, .working:
            VStack(spacing: TSpace.md) {
                ProgressView().tint(.tPrimary).scaleEffect(1.2)
                Text(store.t("clip_working")).font(.tCardTitle).foregroundColor(.tText)
            }
            .padding(.vertical, TSpace.xl)
        case .finished(.created(let url)):
            created(url)
        case .finished(.needsSession):
            TEmptyState(icon: "person.badge.key", title: store.t("clip_create"),
                        message: store.t("clip_needs_web"),
                        actionTitle: store.t("clip_connect"),
                        action: { showWebLogin = true })
        case .finished(let outcome):
            TEmptyState(icon: "exclamationmark.triangle", title: store.t("clip_create"),
                        message: failure(outcome),
                        actionTitle: store.t("retry"),
                        action: { clips.retry(store: store) })
        }
    }

    /// Clip créé : son lien, à copier ou partager.
    private func created(_ url: String) -> some View {
        VStack(spacing: TSpace.md) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 34)).foregroundColor(.tSuccess)
            Text(store.t("clip_done")).font(.tSection).foregroundColor(.tText)
            Text(url)
                .font(.tBody).foregroundColor(.tPrimary)
                .lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
            Text(store.t("clip_done_sub"))
                .font(.tMeta).foregroundColor(.tMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: TSpace.sm) {
                TSecondaryButton(title: store.t(copied ? "copied" : "copy_link"),
                                 icon: copied ? "checkmark" : "doc.on.doc", fullWidth: true) {
                    UIPasteboard.general.string = url
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    withAnimation { copied = true }
                }
                if let link = URL(string: url) {
                    ShareLink(item: link) {
                        HStack(spacing: TSpace.sm) {
                            Image(systemName: "square.and.arrow.up").font(.system(size: 13, weight: .bold))
                            Text(store.t("share")).font(.tLabel)
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)
                        .tGlass(in: RoundedRectangle(cornerRadius: TRadius.control, style: .continuous),
                                fallback: .tPrimary, tint: .tPrimary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, TSpace.xs)
        }
    }

    /// Ce qui a empêché le clip, en clair (le détail est au journal).
    private func failure(_ outcome: ClipOutcome) -> String {
        switch outcome {
        case .offline:     return store.t("clip_err_offline")
        case .disabled:    return store.t("clip_err_disabled")
        case .rateLimited: return store.t("clip_err_rate")
        case .refused(let code):
            return store.t("clip_err_refused").replacingOccurrences(of: "{c}", with: String(code.prefix(80)))
        case .network, .created, .needsSession:
            return store.t("clip_err_network")
        }
    }
}
