import SwiftUI

struct EmotePickerView: View {
    let channelId: String?
    let onSelect: (TwitchEmote) -> Void

    @State private var groups:      [(label: String, emotes: [TwitchEmote])] = []
    @State private var selectedTab  = 0
    @State private var searchText   = ""
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
                TextField("Chercher une emote…", text: $searchText)
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
            if searchText.isEmpty && !groups.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(groups.indices, id: \.self) { i in
                            Button { withAnimation(.easeInOut(duration: 0.15)) { selectedTab = i } } label: {
                                Text(groups[i].label)
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
            } else if !searchText.isEmpty && !isLoading {
                // Compteur résultats
                HStack {
                    Text("\(displayed.count) résultat(s) pour « \(searchText) »")
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
                    Text("Chargement des emotes…")
                        .font(.system(size: 12))
                        .foregroundColor(.tMuted)
                }
                Spacer()

            } else if displayed.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Text(searchText.isEmpty ? "Aucune emote disponible" : "Aucun résultat")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.tMuted)
                    if searchText.isEmpty {
                        Text("Ouvre un live pour charger les emotes du canal")
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
                            EmoteCell(emote: emote) { onSelect(emote) }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
            }
        }
        .background(Color.tCard)
        .task {
            let loaded = await EmoteService.shared.groupedEmotes(channelId: channelId)
            // Index bâti une seule fois, trié ici plutôt qu'à chaque frappe.
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

// MARK: – Cellule emote
private struct EmoteCell: View {
    let emote: TwitchEmote
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 3) {
                // animated: false — des centaines d'emotes animées en même temps
                // saturent le processeur et rendent la grille inutilisable.
                CachedEmoteImage(url: emote.url, name: String(emote.name.prefix(3)),
                                 height: 34, animated: false)
                    .frame(width: 34, height: 34)

                Text(emote.name)
                    .font(.system(size: 8))
                    .foregroundColor(.tMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 52)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
