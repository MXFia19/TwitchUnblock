import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════
//  Journal des modifications (Réglages) : chaque version publiée, avec ses
//  nouveautés. Lu dans la source de l'app — apps.json, ou apps-test.json
//  pour « TU Test » —, comme la fenêtre de mise à jour, qui n'en montre que
//  les versions manquantes.
// ═══════════════════════════════════════════════════════════════════════════

struct ChangelogList: View {
    @EnvironmentObject private var store: AppStore
    @State private var versions: [UpdateChecker.Changes] = []
    @State private var loading = true
    @State private var failed = false

    var body: some View {
        VStack(spacing: 12) {
            if loading {
                TLoader()
            } else if failed {
                TEmptyState(icon: "wifi.exclamationmark",
                            title: store.t("changelog_failed"),
                            actionTitle: store.t("changelog_retry")) {
                    Task { await load() }
                }
            } else {
                ForEach(versions) { versionCard($0) }
            }
        }
        .task { await load() }
    }

    @MainActor private func load() async {
        loading = true
        failed = false
        if let list = await UpdateChecker.history(), !list.isEmpty {
            versions = list
        } else {
            failed = true
        }
        loading = false
    }

    @ViewBuilder private func versionCard(_ v: UpdateChecker.Changes) -> some View {
        let installed = UpdateChecker.installedBuild
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(v.version)
                    .font(.system(size: 15, weight: .bold).monospacedDigit())
                    .foregroundColor(.tText)
                // Build local (Xcode) : pas de numéro fiable, donc pas de repère.
                if installed > 1 && v.build == installed {
                    badge(store.t("changelog_installed"), tint: .tSuccess)
                } else if installed > 1 && v.build > installed {
                    badge(store.t("changelog_available"), tint: .tPrimary)
                }
                Spacer(minLength: 0)
                Text(dateText(v.date))
                    .font(.tMeta)
                    .foregroundColor(.tMuted)
            }
            ForEach(Array(v.items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("•").foregroundColor(.tPrimary)
                    Text(item)
                        .foregroundColor(.tText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 13))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tCard(padding: TSpace.md)
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.tBadge)
            .foregroundColor(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.15))
            .clipShape(Capsule())
    }

    /// « 2026-10-06 » → « 6 oct. 2026 », dans la langue de l'app.
    private func dateText(_ raw: String) -> String {
        let parse = DateFormatter()
        parse.locale = Locale(identifier: "en_US_POSIX")
        parse.dateFormat = "yyyy-MM-dd"
        guard let d = parse.date(from: raw) else { return raw }
        let f = DateFormatter()
        f.locale = Locale(identifier: store.lang.rawValue)
        f.dateStyle = .medium
        return f.string(from: d)
    }
}
