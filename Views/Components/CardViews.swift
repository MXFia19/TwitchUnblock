import SwiftUI

// MARK: – StreamCardView (replaces StreamCard.tsx)
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

                VStack(alignment: .leading, spacing: 4) {
                    Text(stream.title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.tText)
                        .lineLimit(2)
                    Text("\(stream.userName)\(stream.gameName.isEmpty ? "" : " • \(stream.gameName)")")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.tPrimary)
                        .lineLimit(1)
                }
                .padding(10)
            }
            .background(Color.tSurface)
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
    }
}

// MARK: – VodCardView (replaces VodCard.tsx)
struct VodCardView: View {
    let vod: VodData
    let progress: Double   // 0–1
    let onPress: () -> Void

    private var dateString: String {
        let df = ISO8601DateFormatter()
        df.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = df.date(from: vod.publishedAt) else { return vod.publishedAt }
        return DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .none)
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

                VStack(alignment: .leading, spacing: 4) {
                    Text(vod.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.tText).lineLimit(2)
                    Text("\(dateString) • \(formatDuration(vod.lengthSeconds))")
                        .font(.system(size: 11)).foregroundColor(.tMuted)
                }
                .padding(10)
            }
            .background(Color.tSurface)
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
    }
}

// MARK: – LiveCardView (replaces LiveCard.tsx)
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
            // Left column
            HStack(alignment: .top, spacing: 12) {
                // Avatar
                AsyncImage(url: URL(string: avatarURL)) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Color(hex: "111111")
                }
                .frame(width: 50, height: 50)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.tPrimary, lineWidth: 2))

                VStack(alignment: .leading, spacing: 6) {
                    // Badge
                    Text(isOnline ? store.t("live_on") : store.t("offline"))
                        .font(.system(size: 11, weight: .bold)).foregroundColor(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(isOnline ? Color.tLive : Color(hex: "555555"))
                        .cornerRadius(4)

                    // Title
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

            // Thumbnail (online only)
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
