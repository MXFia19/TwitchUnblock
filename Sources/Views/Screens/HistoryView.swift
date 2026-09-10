import SwiftUI

struct HistoryView: View {
    let onPlayVod: (String, String?, String?, String?) -> Void
    @EnvironmentObject private var store: AppStore

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
                        Button {
                            onPlayVod(item.term, item.display, item.thumb, item.streamer)
                        } label: {
                            HStack {
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
                                }
                                Spacer()
                            }
                            .padding(.horizontal)
                        }
                    }
                }
            }
        }
        .background(Color.tDark)
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
