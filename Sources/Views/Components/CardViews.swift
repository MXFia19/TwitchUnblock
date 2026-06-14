import SwiftUI

// MARK: – StreamCardView
struct StreamCardView: View {
    let stream: TwitchStream
    let onPress: () -> Void

    private var thumbURL: String {
        stream.thumbnailURL
            .replacingOccurrences(of: "{width}", with: "320")
            .replacingOccurrences(of: "{height}", with: "180")
    }

    var body: some View {
        Button(action: onPress) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .bottomTrailing) {
                    AsyncImage(url: URL(string: thumbURL)) { img in
                        img.resizable().aspectRatio(16/9, contentMode: .fill)
                    } placeholder: {
                        Color(hex: "111111").aspectRatio(16/9, contentMode: .fill)
                    }
                    .clipped()

                    Text("🔴 \(formatViewers(stream.viewerCount))")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color(hex: "e91916").opacity(0.95))
                        .cornerRadius(4)
                        .padding(8)
                }

                // ✨ LE BLOC TEXTE AVEC HAUTEUR STRICTE
                VStack(alignment: .leading, spacing: 4) {
                    Text(stream.title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.tText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    
                    Text("\(stream.userName)\(stream.gameName.isEmpty ? "" : " • \(stream.gameName)")")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.tPrimary)
                        .lineLimit(1)
                }
                .frame(height: 55, alignment: .top) // Hauteur figée à 55 points = aucune superposition possible
                .padding(10)
            }
            .background(Color.tSurface)
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
    }
}

// MARK: – VodCardView
struct VodCardView: View {
    let vod: VodData
    let progress: Double
    let onPress: () -> Void

    private var dateString: String {
        let formatter = ISO8601DateFormatter()
        // Formatage de la date corrigé pour éviter les dates trop longues
        if let date = formatter.date(from: vod.publishedAt) {
            let df = DateFormatter()
            df.dateStyle = .short
            df.timeStyle = .none
            return df.string(from: date)
        }
        // Sécurité : si l'API renvoie un format bizarre, on ne garde que la date "YYYY-MM-DD"
        return String(vod.publishedAt.prefix(10)) 
    }

    var body: some View {
        Button(action: onPress) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .bottom) {
                    AsyncImage(url: URL(string: vod.previewThumbnailURL)) { img in
                        img.resizable().aspectRatio(16/9, contentMode: .fill)
                    } placeholder: {
                        Color(hex: "111111").aspectRatio(16/9, contentMode: .fill)
                    }
                    .clipped()

                    if progress > 0.01 {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Color.black.opacity(0.5)
                                Color.tPrimary.frame(width: geo.size.width * progress)
                            }
                        }
                        .frame(height: 3)
                    }
                }

                // ✨ LE BLOC TEXTE AVEC HAUTEUR STRICTE
                VStack(alignment: .leading, spacing: 4) {
                    Text(vod.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.tText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        
                    Text("\(dateString) • \(formatDuration(vod.lengthSeconds))")
                        .font(.system(size: 11))
                        .foregroundColor(.tMuted)
                        .lineLimit(1) // Coupe net si c'est trop long
                }
                .frame(height: 55, alignment: .top) // Hauteur figée = alignement parfait
                .padding(10)
            }
            .background(Color.tSurface)
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
    }
}

// MARK: – LiveCardView
struct LiveCardView: View {
    let isOnline: Bool
    let title: String
    let game: String
    let avatarURL: String
    let thumbnailURL: String?
    let offlineSince: String?
    let onWatchLive: (() -> Void)?

    @EnvironmentObject private var store: AppStore

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                AsyncImage(url: URL(string: avatarURL)) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Color(hex: "111111")
                }
                .frame(width: 50, height: 50)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.tPrimary, lineWidth: 2))

                VStack(alignment: .leading, spacing: 6) {
                    Text(isOnline ? store.t("live_on") : store.t("offline"))
                        .font(.system(size: 11, weight: .bold)).foregroundColor(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(isOnline ? Color.tLive : Color(hex: "555555"))
                        .cornerRadius(4)

                    Text(title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(isOnline ? .tText : .tMuted)
                        .lineLimit(2)

                    if isOnline && !game.isEmpty {
                        Text(game).font(.system(size: 13, weight: .semibold)).foregroundColor(.tPrimary)
                    }
                    if !isOnline, let since = offlineSince {
                        Text("\(store.t("offline_since"))\(since)")
                            .font(.system(size: 12, weight: .semibold)).foregroundColor(.tLive)
                    }
                    if isOnline, let action = onWatchLive {
                        Button(action: action) {
                            Text(store.t("btn_watch_live"))
                                .font(.system(size: 13, weight: .bold)).foregroundColor(.white)
                                .frame(maxWidth: .infinity).padding(.vertical, 10)
                                .background(Color.tPrimary).cornerRadius(8)
                        }
                        .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if isOnline, let thumb = thumbnailURL, !thumb.isEmpty {
                AsyncImage(url: URL(string: thumb.replacingOccurrences(of: "{width}", with: "320").replacingOccurrences(of: "{height}", with: "180"))) { img in
                    img.resizable().aspectRatio(16/9, contentMode: .fill)
                } placeholder: {
                    Color(hex: "111111").aspectRatio(16/9, contentMode: .fill)
                }
                .frame(width: 120)
                .cornerRadius(8)
            }
        }
        .padding(14)
        .background(isOnline ? Color.tLive.opacity(0.05) : Color.black.opacity(0.2))
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(isOnline ? Color.tLive : Color.tBorder, lineWidth: 1))
    }
}
