import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════
//  Cartes de contenu. Toutes bâties sur le même gabarit : vignette 16/9,
//  badge en surimpression, puis deux lignes de texte de hauteur fixe pour que
//  les grilles restent alignées quelle que soit la longueur des titres.
// ═══════════════════════════════════════════════════════════════════════════

/// Hauteur du bloc texte des cartes en grille : deux lignes de titre + une
/// ligne de méta. Figée pour garantir l'alignement des colonnes.
private let cardTextHeight: CGFloat = 56

// MARK: – Vignette 16/9
private struct Thumbnail: View {
    let url: String
    var body: some View {
        AsyncImage(url: URL(string: url)) { img in
            img.resizable().aspectRatio(16/9, contentMode: .fill)
        } placeholder: {
            Rectangle().fill(Color.tSurface).aspectRatio(16/9, contentMode: .fill)
                .overlay(Image(systemName: "photo")
                    .font(.system(size: 18)).foregroundColor(.tMuted.opacity(0.5)))
        }
        .clipped()
    }
}

// MARK: – Tags d'un live
/// Tags de la chaîne (langue comprise), comme sous les cartes de Twitch : une
/// seule ligne ; ceux qui ne tiennent pas sont omis, pas tronqués.
struct TagChips: View {
    let tags: [String]

    var body: some View {
        OneLineLayout(spacing: 4) {
            ForEach(Array(tags.prefix(8).enumerated()), id: \.offset) { _, tag in
                Text(tag)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.tMuted)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .frame(height: 18)
                    .background(Color.tSurface)
                    .clipShape(Capsule())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 18)
        .clipped()
    }
}

/// Vues côte à côte sur une seule ligne. À partir de la première qui déborde,
/// les suivantes sont posées hors du cadre (masquées par `.clipped()`), comme
/// des tags passés à la ligne sur le site. La première, si elle est trop
/// longue à elle seule, est tronquée plutôt que masquée.
struct OneLineLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        let ideal = subviews.map { $0.sizeThatFits(.unspecified).width }.reduce(0, +)
            + spacing * CGFloat(max(0, subviews.count - 1))
        return CGSize(width: proposal.width ?? ideal, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var overflow = false
        for (i, v) in subviews.enumerated() {
            var size = v.sizeThatFits(.unspecified)
            if i == 0 { size.width = min(size.width, bounds.width) }
            if overflow || x + size.width > bounds.maxX + 0.5 {
                overflow = true
                v.place(at: CGPoint(x: bounds.maxX + 1000, y: bounds.minY), proposal: ProposedViewSize(size))
                continue
            }
            v.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(size))
            x += size.width + spacing
        }
    }
}

// MARK: – Carte de direct
struct StreamCardView: View {
    let stream: TwitchStream
    /// Chaîne suivie : l'appui long propose de l'épingler en tête.
    var pinnable = false
    /// Liste de découverte : l'appui long propose de masquer la chaîne et,
    /// si `hideCategory`, sa catégorie.
    var hideable = false
    var hideCategory = true
    let onPress: () -> Void
    @EnvironmentObject private var store: AppStore

    private var thumbURL: String {
        stream.thumbnailURL
            .replacingOccurrences(of: "{width}", with: "440")
            .replacingOccurrences(of: "{height}", with: "248")
    }

    var body: some View {
        Button(action: onPress) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    Thumbnail(url: thumbURL)

                    TLiveBadge(compact: true)
                        .padding(TSpace.sm)

                    // Multi-live : « + » en haut à droite, une fois un direct choisi.
                    HStack {
                        Spacer()
                        MultiLiveCardToggle(login: stream.userLogin, name: stream.userName)
                    }
                    .padding(TSpace.sm)

                    // Spectateurs : en bas à droite, là où l'œil les cherche.
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            TMeta(icon: "eye.fill", text: formatViewers(stream.viewerCount),
                                  tint: .white)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(Color.black.opacity(0.65))
                                .cornerRadius(4)
                        }
                    }
                    .padding(TSpace.sm)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(stream.title)
                        .font(.tCardTitle)
                        .foregroundColor(.tText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    // Le pseudo ouvre la chaîne (comme sur Twitch), la carte le direct.
                    Button { store.openChannelPage(stream.userLogin) } label: {
                        HStack(spacing: 4) {
                            if pinnable && store.isPinned(stream.userLogin) { PinnedMark() }
                            Text(stream.userName)
                                .font(.tMeta)
                                .foregroundColor(.tPurple)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)

                    if !stream.gameName.isEmpty {
                        Text(stream.gameName)
                            .font(.tMeta)
                            .foregroundColor(.tMuted)
                            .lineLimit(1)
                    }

                    if !stream.tags.isEmpty {
                        TagChips(tags: stream.tags).padding(.top, 2)
                    }
                }
                // Place des tags réservée sur toutes les cartes : la grille
                // reste alignée, qu'un live en ait ou non.
                .frame(height: cardTextHeight + 14 + 22, alignment: .top)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(TSpace.md)
            }
            .background(Color.tCard)
            .cornerRadius(TRadius.card)
        }
        .buttonStyle(.plain)
        .contextMenu {
            MultiLiveMenuButton(login: stream.userLogin, name: stream.userName)
            if pinnable { PinStreamerMenuButton(login: stream.userLogin) }
            if hideable { HideMenuButtons(stream: stream, allowCategory: hideCategory) }
        }
    }
}

// MARK: – Épingler un streamer
/// Appui long sur une chaîne suivie : l'épingler en tête des suivis, ou l'en retirer.
struct PinStreamerMenuButton: View {
    let login: String
    @EnvironmentObject private var store: AppStore

    var body: some View {
        let pinned = store.isPinned(login)
        Button { withAnimation { store.togglePin(login) } } label: {
            Label(store.t(pinned ? "unpin_streamer" : "pin_streamer"),
                  systemImage: pinned ? "pin.slash" : "pin")
        }
    }
}

// MARK: – Masquer (listes de découverte)
/// Appui long sur un live du top ou d'une catégorie : masquer la chaîne, ou
/// toute sa catégorie. Rien pour une chaîne suivie ou épinglée, ni pour une
/// catégorie suivie : elles ne sont jamais masquées.
struct HideMenuButtons: View {
    let stream: TwitchStream
    var allowCategory = true
    @EnvironmentObject private var store: AppStore

    var body: some View {
        if !store.isFollowedOrPinned(stream.userLogin) {
            Button(role: .destructive) {
                withAnimation { store.hideChannel(login: stream.userLogin, name: stream.userName) }
            } label: {
                Label(store.t("hide_channel"), systemImage: "eye.slash")
            }
        }
        if allowCategory, !stream.gameId.isEmpty, !stream.gameName.isEmpty,
           !store.followsCategory(stream.gameId) {
            Button(role: .destructive) {
                withAnimation { store.hideCategory(id: stream.gameId, name: stream.gameName, box: "") }
            } label: {
                Label(store.t("hide_category").replacingOccurrences(of: "{c}", with: stream.gameName),
                      systemImage: "eye.slash")
            }
        }
    }
}

/// Pastille « Masquée » : élément masqué montré quand même (recherche,
/// page ouverte directement).
struct HiddenBadge: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "eye.slash").font(.system(size: 10, weight: .bold))
            Text(store.t("hidden_badge")).font(.system(size: 11, weight: .bold)).lineLimit(1)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Color.black.opacity(0.7))
        .clipShape(Capsule())
    }
}

/// Petite punaise devant le nom d'une chaîne épinglée.
struct PinnedMark: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Image(systemName: "pin.fill")
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(.tPrimary)
            .accessibilityLabel(store.t("pinned_short"))
    }
}

// MARK: – Carte de VOD
struct VodCardView: View {
    let vod: VodData
    let progress: Double
    /// Nom de la chaîne, devant la date (résultats de la recherche, où les
    /// VODs viennent de chaînes différentes).
    var channel: String? = nil
    let onPress: () -> Void

    private var dateString: String {
        let formatter = ISO8601DateFormatter()
        var date = String(vod.publishedAt.prefix(10))
        if let d = formatter.date(from: vod.publishedAt) {
            let df = DateFormatter()
            df.dateStyle = .short
            df.timeStyle = .none
            date = df.string(from: d)
        }
        guard let channel, !channel.isEmpty else { return date }
        return date.isEmpty ? channel : "\(channel) · \(date)"
    }

    var body: some View {
        Button(action: onPress) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .bottom) {
                    Thumbnail(url: vod.previewThumbnailURL)

                    // Durée en surimpression, et barre de progression collée au bas.
                    VStack(spacing: 0) {
                        HStack {
                            Spacer()
                            Text(formatDuration(vod.lengthSeconds))
                                .font(.tBadge)
                                .foregroundColor(.white)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(Color.black.opacity(0.65))
                                .cornerRadius(4)
                        }
                        .padding(TSpace.sm)

                        Spacer(minLength: 0)

                        if progress > 0.01 {
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Color.black.opacity(0.5)
                                    Color.tPrimary.frame(width: geo.size.width * min(1, progress))
                                }
                            }
                            .frame(height: 3)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(vod.title)
                        .font(.tCardTitle)
                        .foregroundColor(.tText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    Text(dateString)
                        .font(.tMeta)
                        .foregroundColor(.tMuted)
                        .lineLimit(1)
                }
                .frame(height: cardTextHeight, alignment: .top)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(TSpace.md)
            }
            .background(Color.tCard)
            .cornerRadius(TRadius.card)
        }
        .buttonStyle(.plain)
    }
}

// MARK: – Carte de VOD non listée
/// Diffusion sans VOD dans la liste de Twitch (supprimée ou masquée), que
/// l'app sait reconstruire : rangée à sa date parmi les VODs, même gabarit,
/// mais sans vignette — Twitch n'en sert plus.
struct UnlistedVodCardView: View {
    let stream: RecoverableStream
    var resolving = false
    /// La reconstruction a échoué : le CDN ne sert plus ses segments.
    var gone = false
    let onPress: () -> Void

    @EnvironmentObject private var store: AppStore

    private var meta: String {
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .none
        return [df.string(from: stream.startedAt), stream.game]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    var body: some View {
        Button(action: onPress) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    LinearGradient(colors: [Color.tSurface, Color.tCard],
                                   startPoint: .top, endPoint: .bottom)
                        .aspectRatio(16/9, contentMode: .fit)
                    if resolving {
                        ProgressView().tint(.tPrimary)
                    } else {
                        Image(systemName: gone ? "xmark.octagon" : "eye.slash")
                            .font(.system(size: 22))
                            .foregroundColor(.tMuted)
                    }
                    VStack(spacing: 0) {
                        HStack(spacing: TSpace.xs) {
                            Text(store.t(gone ? "unlisted_gone" : "unlisted_vod"))
                                .font(.tBadge)
                                .foregroundColor(.white)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(gone ? Color.tDanger.opacity(0.85) : Color.tPrimary.opacity(0.9))
                                .cornerRadius(4)
                            Spacer(minLength: 0)
                            if stream.duration > 0 {
                                Text(formatDuration(stream.duration))
                                    .font(.tBadge)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                    .background(Color.black.opacity(0.65))
                                    .cornerRadius(4)
                            }
                        }
                        .padding(TSpace.sm)
                        Spacer(minLength: 0)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(stream.title.isEmpty ? stream.login : stream.title)
                        .font(.tCardTitle)
                        .foregroundColor(.tText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    Text(meta)
                        .font(.tMeta)
                        .foregroundColor(.tMuted)
                        .lineLimit(1)
                }
                .frame(height: cardTextHeight, alignment: .top)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(TSpace.md)
            }
            .background(Color.tCard)
            .cornerRadius(TRadius.card)
            .opacity(gone ? 0.6 : 1)
        }
        .buttonStyle(.plain)
        .disabled(resolving)
    }
}

// MARK: – Carte de clip
struct ClipCardView: View {
    let clip: ClipData
    let onPress: () -> Void

    private var meta: String {
        var parts: [String] = []
        if let date = ISO8601DateFormatter().date(from: clip.createdAt) {
            let df = DateFormatter(); df.dateStyle = .short; df.timeStyle = .none
            parts.append(df.string(from: date))
        }
        if let c = clip.curator, !c.isEmpty { parts.append(c) }
        return parts.joined(separator: " · ")
    }

    /// « 0:28 » : un clip dure une minute au plus, formatDuration (heures et
    /// minutes) affichait « 0min » sur presque toutes les cartes.
    private var durationText: String {
        let s = max(0, clip.durationSeconds)
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }

    var body: some View {
        Button(action: onPress) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    Thumbnail(url: clip.thumbnailURL)
                    VStack {
                        HStack {
                            HStack(spacing: 3) {
                                Image(systemName: "eye.fill").font(.system(size: 8))
                                Text(formatViewers(clip.viewCount))
                            }
                            .font(.tBadge).foregroundColor(.white)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.black.opacity(0.65)).cornerRadius(4)
                            Spacer()
                        }
                        Spacer()
                        HStack {
                            Spacer()
                            Text(durationText)
                                .font(.tBadge).foregroundColor(.white)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(Color.black.opacity(0.65)).cornerRadius(4)
                        }
                    }
                    .padding(TSpace.sm)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(clip.title)
                        .font(.tCardTitle).foregroundColor(.tText)
                        .lineLimit(2).multilineTextAlignment(.leading)
                    Text(meta).font(.tMeta).foregroundColor(.tMuted).lineLimit(1)
                }
                .frame(height: cardTextHeight, alignment: .top)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(TSpace.md)
            }
            .background(Color.tCard)
            .cornerRadius(TRadius.card)
        }
        .buttonStyle(.plain)
    }
}

// MARK: – Carte de catégorie
struct CategoryCardView: View {
    let category: TwitchCategory
    /// Grille « Toutes » : l'appui long propose de masquer la catégorie (ou
    /// de la réafficher), et une catégorie masquée montrée par la recherche
    /// est atténuée.
    var hideable = false
    let onPress: () -> Void
    @EnvironmentObject private var store: AppStore

    private var isHidden: Bool {
        hideable && store.hidden.hides(category: category.id) && !store.followsCategory(category.id)
    }

    var body: some View {
        Button(action: onPress) {
            VStack(alignment: .leading, spacing: 0) {
                AsyncImage(url: URL(string: sharpBoxArt(category.boxArtURL))) { img in
                    img.resizable().aspectRatio(3/4, contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(Color.tSurface).aspectRatio(3/4, contentMode: .fill)
                        .overlay(Image(systemName: "gamecontroller")
                            .font(.system(size: 20)).foregroundColor(.tMuted.opacity(0.5)))
                }
                .clipped()
                .overlay(alignment: .topLeading) {
                    if isHidden { HiddenBadge().padding(TSpace.sm) }
                }

                // Nom puis audience, sous la jaquette : l'affiche reste lisible.
                // L'audience arrive après la grille (requête séparée) : sa
                // ligne garde sa place pour que les cartes ne sautent pas.
                VStack(alignment: .leading, spacing: 4) {
                    Text(category.name)
                        .font(.tCardTitle)
                        .foregroundColor(.tText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(height: 36, alignment: .top)
                    HStack(spacing: 4) {
                        Circle().fill(Color.tLive).frame(width: 6, height: 6)
                        Text(category.viewers.map { formatViewers($0) } ?? " ")
                            .font(.tMeta).foregroundColor(.tMuted)
                    }
                    .opacity(category.viewers == nil ? 0 : 1)
                    .animation(.easeOut(duration: 0.2), value: category.viewers)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(TSpace.md)
            }
            .background(Color.tCard)
            .cornerRadius(TRadius.card)
            .opacity(isHidden ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if hideable && !store.followsCategory(category.id) {
                if store.hidden.hides(category: category.id) {
                    Button {
                        withAnimation { store.unhideCategory(category.id) }
                    } label: {
                        Label(store.t("unhide"), systemImage: "eye")
                    }
                } else {
                    Button(role: .destructive) {
                        withAnimation {
                            store.hideCategory(id: category.id, name: category.name, box: category.boxArtURL)
                        }
                    } label: {
                        Label(store.t("hide_this_category"), systemImage: "eye.slash")
                    }
                }
            }
        }
    }
}

// MARK: – Bandeau d'une chaîne (résultat de recherche)
/// Grande carte affichée en tête des résultats : état du direct + accès à la lecture.
struct ChannelHeroView: View {
    let login: String
    let isOnline: Bool
    let title: String
    let game: String
    let avatarURL: String
    let thumbnailURL: String?
    let viewerCount: Int
    let offlineSince: String?
    let onWatchLive: (() -> Void)?
    /// Chaîne hors ligne : son prochain live prévu (« Prochain live : mardi
    /// · 20:00 ») ou ses vacances, d'après son planning ; le toucher ouvre
    /// l'onglet Planning.
    var nextLive: String? = nil
    var nextLiveIcon = "calendar"
    var onNextLive: (() -> Void)? = nil

    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: TSpace.md) {

            // Aperçu du direct
            if isOnline, let thumb = thumbnailURL, !thumb.isEmpty {
                ZStack(alignment: .topLeading) {
                    Thumbnail(url: thumb
                        .replacingOccurrences(of: "{width}", with: "440")
                        .replacingOccurrences(of: "{height}", with: "248"))
                    TLiveBadge().padding(TSpace.sm)
                }
                .cornerRadius(TRadius.control)
            }

            HStack(alignment: .top, spacing: TSpace.md) {
                AsyncImage(url: URL(string: avatarURL)) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Circle().fill(Color.tSurface)
                }
                .frame(width: 46, height: 46)
                .clipShape(Circle())
                .overlay(Circle().stroke(isOnline ? Color.tLive : Color.tBorder, lineWidth: 2))

                VStack(alignment: .leading, spacing: TSpace.xs) {
                    Text(login)
                        .font(.tSection)
                        .foregroundColor(.tText)
                        .lineLimit(1)

                    Text(title)
                        .font(.tBody)
                        .foregroundColor(isOnline ? .tText : .tMuted)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: TSpace.md) {
                        if isOnline {
                            if !game.isEmpty {
                                TMeta(icon: "gamecontroller.fill", text: game, tint: .tPurple)
                            }
                            if viewerCount > 0 {
                                TMeta(icon: "eye.fill", text: formatViewers(viewerCount))
                            }
                        } else if let since = offlineSince, !since.isEmpty {
                            TMeta(icon: "moon.zzz.fill",
                                  text: "\(store.t("offline_since"))\(since)")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !isOnline, let next = nextLive {
                Button { onNextLive?() } label: {
                    HStack(spacing: TSpace.sm) {
                        Image(systemName: nextLiveIcon)
                            .font(.system(size: 13, weight: .bold))
                        Text(next)
                            .font(.tLabel)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        if onNextLive != nil {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .bold))
                        }
                    }
                    .foregroundColor(.tPrimary)
                    .padding(.horizontal, TSpace.md)
                    .padding(.vertical, TSpace.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.tPrimary.opacity(0.12))
                    .cornerRadius(TRadius.control)
                }
                .buttonStyle(.plain)
                .disabled(onNextLive == nil)
            }

            if isOnline, let action = onWatchLive {
                TPrimaryButton(title: store.t("btn_watch_live"), icon: "play.fill",
                               fullWidth: true, action: action)
            }
        }
        .tCard()
    }
}

// MARK: – Direct en liste (façon Twitch)
/// Miniature à gauche, infos à droite : plus de chaînes visibles d'un coup.
struct StreamRowView: View {
    let stream: TwitchStream
    /// Chaîne suivie : l'appui long propose de l'épingler en tête.
    var pinnable = false
    /// Liste de découverte : l'appui long propose de masquer (voir StreamCardView).
    var hideable = false
    var hideCategory = true
    let onPress: () -> Void
    @EnvironmentObject private var store: AppStore

    private var thumbURL: String {
        stream.thumbnailURL
            .replacingOccurrences(of: "{width}", with: "320")
            .replacingOccurrences(of: "{height}", with: "180")
    }

    var body: some View {
        Button(action: onPress) {
            HStack(alignment: .top, spacing: TSpace.md) {
                ZStack(alignment: .bottomLeading) {
                    Thumbnail(url: thumbURL)
                        .frame(width: 136, height: 76.5)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    HStack(spacing: 3) {
                        Circle().fill(Color.tLive).frame(width: 6, height: 6)
                        Text(formatViewers(stream.viewerCount))
                            .font(.system(size: 11, weight: .bold).monospacedDigit())
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(4)
                    .padding(5)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Button { store.openChannelPage(stream.userLogin) } label: {
                        HStack(spacing: 4) {
                            if pinnable && store.isPinned(stream.userLogin) { PinnedMark() }
                            Text(stream.userName)
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(.tText)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    Text(stream.title)
                        .font(.system(size: 13))
                        .foregroundColor(.tMuted)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if !stream.gameName.isEmpty {
                        Text(stream.gameName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.tPurple)
                            .lineLimit(1)
                    }
                    if !stream.tags.isEmpty {
                        TagChips(tags: stream.tags).padding(.top, 2)
                    }
                }
                Spacer(minLength: 0)
                MultiLiveCardToggle(login: stream.userLogin, name: stream.userName)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            MultiLiveMenuButton(login: stream.userLogin, name: stream.userName)
            if pinnable { PinStreamerMenuButton(login: stream.userLogin) }
            if hideable { HideMenuButtons(stream: stream, allowCategory: hideCategory) }
        }
    }
}
