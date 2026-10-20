import SwiftUI

struct EmotePickerView: View {
    let channelId: String?
    let onSelect: (TwitchEmote) -> Void
    /// Appui long → « Voir la fiche » (nil : entrée absente du menu).
    var onInfo: ((TwitchEmote) -> Void)? = nil

    @EnvironmentObject private var store: AppStore
    @State private var groups:      [(label: String, emotes: [TwitchEmote])] = []
    @State private var selectedTab  = 0
    @State private var searchText   = ""
    /// Recherche rognée : une recherche faite d'espaces masquait les onglets.
    private var query: String { searchText.trimmingCharacters(in: .whitespaces) }
    @State private var isLoading    = true

    /// Index de recherche : toutes les emotes dédupliquées, nom déjà en
    /// minuscules. Sans lui, chaque frappe relançait un
    /// `localizedCaseInsensitiveContains` (comparaison sensible à la locale, donc
    /// coûteuse) sur plusieurs milliers d'emotes — d'où les à-coups.
    @State private var searchIndex: [(emote: TwitchEmote, lower: String)] = []

    // 6 colonnes fixes — bon équilibre taille / densité
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 6)

    // Emotes à afficher : recherche globale OU onglet courant
    private var displayed: [TwitchEmote] {
        guard !groups.isEmpty else { return [] }
        let kw = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !kw.isEmpty {
            // 200 résultats suffisent largement à la saisie ; au-delà on ne fait
            // que construire des cellules que personne ne fera défiler.
            var out: [TwitchEmote] = []
            out.reserveCapacity(200)
            for entry in searchIndex where entry.lower.contains(kw) {
                out.append(entry.emote)
                if out.count == 200 { break }
            }
            return out
        }
        return groups.indices.contains(selectedTab) ? groups[selectedTab].emotes : []
    }

    var body: some View {
        VStack(spacing: 0) {

            // ── Barre de recherche ──────────────────────────────────
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.tMuted)
                    .font(.system(size: 13))
                TextField(store.t("emote_search_ph"), text: $searchText)
                    .foregroundColor(.tText)
                    .font(.system(size: 13))
                    .autocorrectionDisabled()
                    .autocapitalization(.none)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.tMuted)
                            .font(.system(size: 13))
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.tSurface)
            .cornerRadius(8)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            // ── Onglets sources (cachés pendant la recherche) ───────
            if query.isEmpty && !groups.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(groups.indices, id: \.self) { i in
                            Button { withAnimation(.easeInOut(duration: 0.15)) { selectedTab = i } } label: {
                                Text(tabLabel(groups[i].label))
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(selectedTab == i ? .white : .tMuted)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 5)
                                    .background(selectedTab == i ? Color.tPrimary : Color.tSurface)
                                    .cornerRadius(8)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(selectedTab == i ? Color.tPrimary : Color.tBorder, lineWidth: 1)
                                    )
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .padding(.bottom, 6)
            } else if !query.isEmpty && !isLoading {
                // Compteur résultats
                HStack {
                    Text(store.t("emote_results")
                            .replacingOccurrences(of: "{q}", with: searchText)
                            .replacingOccurrences(of: "{n}", with: "\(displayed.count)"))
                        .font(.system(size: 11))
                        .foregroundColor(.tMuted)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 4)
            }

            Divider().background(Color.tBorder)

            // ── Contenu ─────────────────────────────────────────────
            if isLoading {
                Spacer()
                VStack(spacing: 10) {
                    ProgressView().tint(.tPrimary)
                    Text(store.t("emotes_loading"))
                        .font(.system(size: 12))
                        .foregroundColor(.tMuted)
                }
                Spacer()

            } else if displayed.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Text(store.t(query.isEmpty ? "emotes_none" : "emotes_no_result"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.tMuted)
                    if query.isEmpty {
                        Text(store.t("emotes_open_live"))
                            .font(.system(size: 11))
                            .foregroundColor(.tMuted)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding()
                Spacer()

            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(displayed) { emote in
                            // Toucher : insère ; appui long : fiche ou copie du nom.
                            EmoteCell(emote: emote, onTap: { onSelect(emote) },
                                      onInfo: onInfo.map { open in { open(emote) } })
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
            }
        }
        .background(Color.tCard)
        .task {
            // Emotes Twitch de la chaîne : chargées avec le chat, sinon (échec,
            // « Recharger ») demandées ici, sans retenir l'affichage.
            if let channelId { Task { await EmoteService.shared.loadTwitchChannel(channelId: channelId) } }
            // Le compte : ses jeux d'emotes grisent les emotes d'abonné qu'il n'a pas.
            let login = store.twitchLogin
            // Chargements encore en cours à l'ouverture (direct tout juste
            // ouvert, « Recharger ») : relu à 2, 5 et 10 s tant que la liste
            // grandit — elle restait vide, ou sans l'onglet de la chaîne.
            var lastCount = -1
            for delay in [0, 2, 5, 10] as [UInt64] {
                if delay > 0 { try? await Task.sleep(nanoseconds: delay * 1_000_000_000) }
                if Task.isCancelled { return }
                let loaded = await EmoteService.shared.groupedEmotes(channelId: channelId, login: login)
                let count = loaded.reduce(0) { $0 + $1.emotes.count }
                if count == lastCount { continue }
                lastCount = count
                // Index trié ici plutôt qu'à chaque frappe.
                var seen = Set<String>()
                let index = loaded.flatMap { $0.emotes }
                    .filter { seen.insert($0.id).inserted }
                    .map { (emote: $0, lower: $0.name.lowercased()) }
                    .sorted { $0.lower < $1.lower }
                groups      = loaded
                searchIndex = index
                isLoading   = false
            }
        }
    }

    /// Onglets : noms de marque (7TV, BTTV, FFZ), sauf celui de la chaîne.
    private func tabLabel(_ label: String) -> String {
        label == "emotes_channel" ? "⭐ " + store.t("emotes_channel") : label
    }
}

// MARK: – Cellule emote
private struct EmoteCell: View {
    let emote: TwitchEmote
    let onTap: () -> Void
    var onInfo: (() -> Void)? = nil
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Button {
            // Emote d'abonné que le compte n'a pas : jamais insérée ; sa fiche
            // (si on peut l'ouvrir) dit à quel niveau elle se débloque.
            if emote.locked { onInfo?() } else { onTap() }
        } label: {
            VStack(spacing: 3) {
                // animated: false — des centaines d'emotes animées en même temps
                // saturent le processeur et rendent la grille inutilisable.
                // Largeur bornée : les emotes larges (7TV surtout) sont réduites
                // au lieu de déborder sur les cases voisines.
                CachedEmoteImage(url: emote.url, name: String(emote.name.prefix(3)),
                                 height: 34, animated: false, maxWidth: 46)
                    .frame(width: 46, height: 34)
                    .clipped()
                    // Verrouillée : grisée, cadenas dans le coin.
                    .saturation(emote.locked ? 0 : 1)
                    .opacity(emote.locked ? 0.35 : 1)
                    .overlay(alignment: .bottomTrailing) {
                        if emote.locked {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.tText)
                        }
                    }

                Text(emote.name)
                    .font(.system(size: 8))
                    .foregroundColor(.tMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 52)
                    .opacity(emote.locked ? 0.6 : 1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(emote.locked ? "\(emote.name), \(store.t("emote_locked"))" : emote.name))
        .contextMenu {
            if let onInfo {
                Button(action: onInfo) {
                    Label(store.t("chat_info_open"), systemImage: "info.circle")
                }
            }
            Button {
                UIPasteboard.general.string = emote.name
            } label: {
                Label(store.t("chat_info_copy"), systemImage: "doc.on.doc")
            }
        }
    }
}
