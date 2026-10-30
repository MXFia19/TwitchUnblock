import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════
//  Mes VODs : ce qu'on a regardé, avec la reprise de lecture.
//  Chaque ligne se lance au toucher ; la corbeille la retire de l'historique.
// ═══════════════════════════════════════════════════════════════════════════

struct LibraryView: View {
    let onPlayVod: (String, String?, String?, String?) -> Void
    /// VOD téléchargée : lue hors ligne, par le serveur local.
    var onPlayOffline: (RecoveredVod) -> Void = { _ in }

    @EnvironmentObject private var store: AppStore
    @ObservedObject private var metaStore = VodMetaStore.shared
    @ObservedObject private var downloads = VodDownloads.shared

    @State private var confirmClear = false
    /// Téléchargement touché, mais le serveur local de lecture n'a pas démarré.
    @State private var offlineFailed = false

    private var vods: [HistoryItem] { store.history.filter { $0.type == .vod } }

    var body: some View {
        Group {
            if vods.isEmpty && downloads.items.isEmpty {
                VStack {
                    Spacer()
                    TEmptyState(icon: "film.stack",
                                title: store.t("history_vods_empty"),
                                message: store.t("history_vods_empty_msg"))
                    Spacer()
                }
            } else {
                // Onglet touché à nouveau : retour en haut de la liste.
                TabScrollView(tab: .library) {
                    LazyVStack(spacing: TSpace.md) {
                        if !downloads.items.isEmpty {
                            TSectionHeader("\(store.t("dl_section")) · \(ByteCountFormatter.string(fromByteCount: downloads.totalBytes, countStyle: .file))",
                                           icon: "arrow.down.circle") { EmptyView() }
                                .padding(.top, TSpace.md)
                            ForEach(downloads.items) { item in
                                DownloadRow(item: item) { playOffline($0) }
                            }
                        }

                        if !vods.isEmpty {
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
                        }

                        Spacer(minLength: 40)
                    }
                }
                // Sur la liste, pas sur le Group : une seule alerte par vue.
                .alert(store.t("offline_play_failed"), isPresented: $offlineFailed) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(store.t("offline_play_failed_msg"))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.tDark)
        .alert(store.t("btn_clear"), isPresented: $confirmClear) {
            Button(store.t("cancel"), role: .cancel) {}
            Button(store.t("erase"), role: .destructive) {
                // Positions de reprise comprises, et envoyé tout de suite.
                store.clearVodHistory()
            }
        } message: {
            Text(store.t("confirm"))
        }
    }

    private func playOffline(_ item: VodDownload) {
        Task { @MainActor in
            // Serveur local pas prêt (port pris, app relancée en arrière-plan) :
            // une seconde demande le relance, sur un autre port au besoin ;
            // sinon un message, au lieu d'un toucher sans effet.
            var rec = await downloads.playback(item)
            if rec == nil { rec = await downloads.playback(item) }
            if let rec { onPlayOffline(rec) } else { offlineFailed = true }
        }
    }

    // MARK: – Ligne
    @ViewBuilder private func row(_ item: HistoryItem) -> some View {
        // Pas de Button englobant : un Button dans un Button déclenche les deux.
        // La ligne réagit au toucher, seule la corbeille est un vrai bouton.
        HStack(spacing: TSpace.md) {
            HStack(spacing: TSpace.md) {
                // La taille est portée par le ZStack, pas par l'image : un
                // GeometryReader prend toute la largeur qu'on lui propose, donc
                // l'apparition de la barre de progression (après le chargement
                // des métadonnées) élargissait le ZStack et décalait la ligne.
                ZStack(alignment: .bottom) {
                    AsyncImage(url: URL(string: item.thumb ?? "")) { img in
                        img.resizable().aspectRatio(16/9, contentMode: .fill)
                    } placeholder: {
                        Rectangle().fill(Color.tSurface)
                            .overlay(Image(systemName: "film")
                                .font(.system(size: 16)).foregroundColor(.tMuted))
                    }

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
                .frame(width: 116, height: 65)
                .clipped()
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
            // Appui long : le multi-live. `streamer` peut être un nom affiché :
            // la chaîne est complétée au démarrage de la tuile.
            .contextMenu {
                MultiVodMenuButton(vodId: item.term, title: item.display, thumb: item.thumb,
                                   name: item.streamer ?? "", login: "")
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

    /// Durée vue / totale et nombre de vues. Les métadonnées arrivent du réseau :
    /// la hauteur est réservée d'avance pour que la liste ne saute pas à l'arrivée.
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
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        // Hauteur réservée, à la taille du texte d'iOS.
        .frame(height: 16 * TType.ratio(12))
    }
}
