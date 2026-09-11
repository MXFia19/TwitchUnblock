import SwiftUI

struct HistoryView: View {
    let onPlayVod: (String, String?, String?, String?) -> Void
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var metaStore = VodMetaStore.shared

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                Text(store.t("history_vods_title"))
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal)
                    .padding(.top, 16)

                let vods = store.history.filter { $0.type == .vod }
                
                if vods.isEmpty {
                    Text(store.t("history_vods_empty"))
                        .foregroundColor(.tMuted)
                        .padding()
                } else {
                    ForEach(vods, id: \.term) { item in
                        // Pas de Button englobant : un Button dans un Button déclenche
                        // les deux. La ligne se lance au toucher, la corbeille reste
                        // le seul vrai bouton.
                        HStack(spacing: 10) {
                            HStack(spacing: 10) {
                                // ✨ Chargement de l'image de la VOD
                                if let thumbURL = item.thumb, let url = URL(string: thumbURL) {
                                    AsyncImage(url: url) { phase in
                                        switch phase {
                                        case .empty:
                                            ProgressView().frame(width: 120, height: 68)
                                        case .success(let image):
                                            image
                                                .resizable()
                                                .aspectRatio(contentMode: .fill)
                                                .frame(width: 120, height: 68)
                                                .clipped()
                                        case .failure:
                                            fallbackRectangle
                                        @unknown default:
                                            fallbackRectangle
                                        }
                                    }
                                    .cornerRadius(8)
                                } else {
                                    fallbackRectangle
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.display)
                                        .font(.subheadline)
                                        .fontWeight(.bold)
                                        .foregroundColor(.white)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)

                                    if let streamer = item.streamer {
                                        Text(streamer)
                                            .font(.caption)
                                            .foregroundColor(.tPrimary)
                                    }

                                    progressLine(for: item.term)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                onPlayVod(item.term, item.display, item.thumb, item.streamer)
                            }

                            // Retirer cette VOD de l'historique
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    store.removeFromHistory(term: item.term)
                                }
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(.tDanger)
                                    .frame(width: 34, height: 34)
                                    .background(Color.tDanger.opacity(0.15))
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(store.t("delete_vod"))
                        }
                        .padding(.horizontal)
                        // Lignes visibles uniquement (LazyVStack) → une requête par VOD.
                        .task { await metaStore.load(item.term) }
                    }
                }
            }
        }
        .background(Color.tDark)
    }
    
    /// « position atteinte / durée totale » + nombre de vues, avec une fine
    /// barre de progression. Les métadonnées arrivent de façon asynchrone.
    @ViewBuilder
    private func progressLine(for vodId: String) -> some View {
        let watched = store.getVodProgress(vodId)
        let total   = metaStore.meta(vodId)?.lengthSeconds ?? 0
        let views   = metaStore.meta(vodId)?.viewCount ?? 0

        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                if total > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "clock.fill").font(.system(size: 9))
                        Text("\(formatDuration(Int(watched))) / \(formatDuration(total))")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(.tMuted)
                }
                if views > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "eye.fill").font(.system(size: 9))
                        Text(formatViewers(views))
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(.tMuted)
                }
            }
            .lineLimit(1)

            if total > 0, watched > 1 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.tSurface).frame(height: 3)
                        Capsule().fill(Color.tPrimary)
                            .frame(width: max(2, geo.size.width *
                                   min(1, watched / Double(total))), height: 3)
                    }
                }
                .frame(height: 3)
            }
        }
    }

    // Le rectangle gris de secours si l'image ne charge pas
    private var fallbackRectangle: some View {
        Rectangle()
            .fill(Color.tSurface)
            .frame(width: 120, height: 68)
            .cornerRadius(8)
            .overlay(Text("VOD").foregroundColor(.tMuted).font(.caption))
    }
}
