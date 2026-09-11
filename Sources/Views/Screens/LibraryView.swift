import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════
//  Mes VODs : ce qu'on a regardé, avec la reprise de lecture.
//  Chaque ligne se lance au toucher ; la corbeille la retire de l'historique.
// ═══════════════════════════════════════════════════════════════════════════

struct LibraryView: View {
    let onPlayVod: (String, String?, String?, String?) -> Void

    @EnvironmentObject private var store: AppStore
    @ObservedObject private var metaStore = VodMetaStore.shared

    @State private var confirmClear = false

    private var vods: [HistoryItem] { store.history.filter { $0.type == .vod } }

    var body: some View {
        Group {
            if vods.isEmpty {
                VStack {
                    Spacer()
                    TEmptyState(icon: "film.stack",
                                title: store.t("history_vods_empty"),
                                message: store.t("history_vods_empty_msg"))
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: TSpace.md) {
                        TSectionHeader("\(vods.count) \(store.t("vods"))", icon: "clock.arrow.circlepath") {
                            Button { confirmClear = true } label: {
                                Text(store.t("btn_clear"))
                                    .font(.tMeta).foregroundColor(.tDanger)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.top, TSpace.md)

                        ForEach(vods) { item in
                            row(item)
                                .task { await metaStore.load(item.term) }
                        }

                        Spacer(minLength: 40)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.tDark)
        .alert(store.t("btn_clear"), isPresented: $confirmClear) {
            Button(store.t("cancel"), role: .cancel) {}
            Button(store.t("erase"), role: .destructive) {
                store.history = store.history.filter { $0.type != .vod }
            }
        } message: {
            Text(store.t("confirm"))
        }
    }

    // MARK: – Ligne
    @ViewBuilder private func row(_ item: HistoryItem) -> some View {
        // Pas de Button englobant : un Button dans un Button déclenche les deux.
        // La ligne réagit au toucher, seule la corbeille est un vrai bouton.
        HStack(spacing: TSpace.md) {
            HStack(spacing: TSpace.md) {
                ZStack(alignment: .bottom) {
                    AsyncImage(url: URL(string: item.thumb ?? "")) { img in
                        img.resizable().aspectRatio(16/9, contentMode: .fill)
                    } placeholder: {
                        Rectangle().fill(Color.tSurface)
                            .overlay(Image(systemName: "film")
                                .font(.system(size: 16)).foregroundColor(.tMuted))
                    }
                    .frame(width: 116, height: 65)
                    .clipped()

                    if let ratio = progressRatio(item.term) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Color.black.opacity(0.5)
                                Color.tPrimary.frame(width: geo.size.width * ratio)
                            }
                        }
                        .frame(height: 3)
                    }
                }
                .cornerRadius(TRadius.chip)

                VStack(alignment: .leading, spacing: TSpace.xs) {
                    Text(item.display)
                        .font(.tCardTitle)
                        .foregroundColor(.tText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    if let streamer = item.streamer {
                        Text(streamer)
                            .font(.tMeta).foregroundColor(.tPurple).lineLimit(1)
                    }

                    metaLine(item.term)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onPlayVod(item.term, item.display, item.thumb, item.streamer)
            }

            TIconButton(icon: "trash", tint: .tDanger) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    store.removeFromHistory(term: item.term)
                }
            }
            .accessibilityLabel(store.t("delete_vod"))
        }
        .padding(.horizontal, TSpace.lg)
    }

    /// Part de la VOD déjà vue, nil si on n'en sait pas assez pour l'afficher.
    private func progressRatio(_ vodId: String) -> Double? {
        let watched = store.getVodProgress(vodId)
        guard watched > 1, let total = metaStore.meta(vodId)?.lengthSeconds, total > 0
        else { return nil }
        return min(1, watched / Double(total))
    }

    @ViewBuilder private func metaLine(_ vodId: String) -> some View {
        let watched = store.getVodProgress(vodId)
        let total   = metaStore.meta(vodId)?.lengthSeconds ?? 0
        let views   = metaStore.meta(vodId)?.viewCount ?? 0

        HStack(spacing: TSpace.md) {
            if total > 0 {
                TMeta(icon: "clock.fill",
                      text: "\(formatDuration(Int(watched))) / \(formatDuration(total))")
            }
            if views > 0 {
                TMeta(icon: "eye.fill", text: formatViewers(views))
            }
        }
        .lineLimit(1)
    }
}
