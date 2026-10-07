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

// MARK: – Carte de direct
struct StreamCardView: View {
    let stream: TwitchStream
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
                        Text(stream.userName)
                            .font(.tMeta)
                            .foregroundColor(.tPurple)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)

                    if !stream.gameName.isEmpty {
                        Text(stream.gameName)
                            .font(.tMeta)
                            .foregroundColor(.tMuted)
                            .lineLimit(1)
                    }
                }
                .frame(height: cardTextHeight + 14, alignment: .top)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(TSpace.md)
            }
            .background(Color.tCard)
            .cornerRadius(TRadius.card)
        }
        .buttonStyle(.plain)
    }
}

// MARK: – Carte de VOD
struct VodCardView: View {
    let vod: VodData
    let progress: Double
    let onPress: () -> Void

    private var dateString: String {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: vod.publishedAt) {
            let df = DateFormatter()
            df.dateStyle = .short
            df.timeStyle = .none
            return df.string(from: date)
        }
        return String(vod.publishedAt.prefix(10))
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
                            Text(formatDuration(clip.durationSeconds))
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
    let onPress: () -> Void

    var body: some View {
        Button(action: onPress) {
            VStack(alignment: .leading, spacing: 0) {
                AsyncImage(url: URL(string: category.boxArtURL)) { img in
                    img.resizable().aspectRatio(3/4, contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(Color.tSurface).aspectRatio(3/4, contentMode: .fill)
                        .overlay(Image(systemName: "gamecontroller")
                            .font(.system(size: 20)).foregroundColor(.tMuted.opacity(0.5)))
                }
                .clipped()

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
        }
        .buttonStyle(.plain)
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
                        Text(stream.userName)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.tText)
                            .lineLimit(1)
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
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
