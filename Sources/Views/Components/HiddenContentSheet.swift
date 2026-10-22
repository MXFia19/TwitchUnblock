import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════
//  Chaînes et catégories masquées : la liste, pour les réafficher sans
//  retrouver leur carte. S'ouvre depuis les Réglages (Général) et depuis la
//  ligne « N masqués ici · Gérer » du top et des catégories.
// ═══════════════════════════════════════════════════════════════════════════

/// Ligne « N masqués ici · Gérer » sous une liste de découverte. Elle reste
/// là même si tout est masqué : une liste vide ressemblerait à une panne.
struct HiddenFooter: View {
    let count: Int
    let action: () -> Void
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "eye.slash").font(.tSystem(size: 11, weight: .semibold))
                Text(store.t("hidden_footer").replacingOccurrences(of: "{n}", with: "\(count)"))
                    .font(.tMeta)
                    .lineLimit(1)
            }
            .foregroundColor(.tMuted)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, TSpace.lg)
            .padding(.vertical, TSpace.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct HiddenContentSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmAll = false

    var body: some View {
        let hidden = store.hidden
        NavigationStack {
            List {
                Section {
                    Text(store.t(hidden.isEmpty ? "hidden_empty" : "hidden_sub"))
                        .font(.tMeta).foregroundColor(.tMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .listRowBackground(Color.tCard)
                }

                if !hidden.channels.isEmpty {
                    Section {
                        ForEach(hidden.channels) { c in
                            row(title: c.name, subtitle: c.name.lowercased() == c.login ? nil : c.login,
                                image: nil) { store.unhideChannel(c.login) }
                        }
                    } header: {
                        Text(store.t("hidden_channels_n").replacingOccurrences(of: "{n}", with: "\(hidden.channels.count)"))
                    }
                }

                if !hidden.categories.isEmpty {
                    Section {
                        ForEach(hidden.categories) { c in
                            row(title: c.name.isEmpty ? c.id : c.name, subtitle: nil,
                                image: c.box.isEmpty ? nil : sharpBoxArt(c.box)) { store.unhideCategory(c.id) }
                        }
                    } header: {
                        Text(store.t("hidden_categories_n").replacingOccurrences(of: "{n}", with: "\(hidden.categories.count)"))
                    }
                }

                if !hidden.isEmpty {
                    Section {
                        Button(role: .destructive) { confirmAll = true } label: {
                            Label(store.t("unhide_all"), systemImage: "eye")
                        }
                        .listRowBackground(Color.tCard)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.tDark)
            .navigationTitle(store.t("hidden_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(store.t("close")) { dismiss() }
                }
            }
            .alert(store.t("unhide_all"), isPresented: $confirmAll) {
                Button(store.t("cancel"), role: .cancel) {}
                Button(store.t("unhide_all")) { withAnimation { store.unhideAll() } }
            } message: {
                Text(store.t("confirm"))
            }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }

    /// Nom, et « Réafficher » en bouton et en balayage (pas `.onDelete`,
    /// dont le libellé système est « Supprimer »).
    @ViewBuilder
    private func row(title: String, subtitle: String?, image: String?,
                     unhide: @escaping () -> Void) -> some View {
        HStack(spacing: TSpace.md) {
            if let image {
                AsyncImage(url: URL(string: image)) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Color.tSurface
                }
                .frame(width: 27, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.tSystem(size: 15, weight: .semibold))
                    .foregroundColor(.tText)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.tMeta).foregroundColor(.tMuted).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Button { withAnimation { unhide() } } label: {
                Text(store.t("unhide"))
                    .font(.tSystem(size: 13, weight: .bold))
                    .foregroundColor(.tPrimary)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.tPrimary.opacity(0.14))
                    .clipShape(Capsule())
            }
            .buttonStyle(.borderless)
        }
        .listRowBackground(Color.tCard)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button { withAnimation { unhide() } } label: {
                Label(store.t("unhide"), systemImage: "eye")
            }
            .tint(.tPrimary)
        }
    }
}
