import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════
//  Onglet « À propos » d'une chaîne : ce qu'on trouve sous le lecteur sur
//  Twitch — description, followers, réseaux, et les panneaux du streamer
//  (image, lien, texte).
// ═══════════════════════════════════════════════════════════════════════════

struct ChannelAboutView: View {
    let about: ChannelAbout
    let name: String
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: TSpace.md) {
            card
            ForEach(about.panels) { p in panel(p) }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: TSpace.sm) {
            Text(store.t("about_channel").replacingOccurrences(of: "{u}", with: name))
                .font(.tSection).foregroundColor(.tText)
            if let f = about.followers {
                (Text(formatViewers(f)).bold().foregroundColor(.tText)
                 + Text(" \(store.t("followers"))").foregroundColor(.tMuted))
                    .font(.tMeta)
            }
            if about.description.isEmpty {
                Text(store.t("about_empty")).font(.tMeta).foregroundColor(.tMuted)
            } else {
                Text(richText(about.description))
                    .font(.tBody).foregroundColor(.tText)
                    .tint(.tPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !about.socials.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: TSpace.sm) {
                        ForEach(about.socials) { s in
                            Link(destination: s.url) {
                                Label(s.title, systemImage: "link")
                                    .font(.tLabel).foregroundColor(.tText)
                                    .padding(.horizontal, 12).frame(height: 32)
                                    .background(Color.tSurface)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }
            }
        }
        .padding(TSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.tCard)
        .cornerRadius(TRadius.card)
    }

    private func panel(_ p: ChannelAbout.Panel) -> some View {
        VStack(alignment: .leading, spacing: TSpace.sm) {
            if let img = p.imageURL {
                // Image du panneau : elle mène à son lien, comme sur Twitch.
                if let link = p.linkURL {
                    Link(destination: link) { panelImage(img) }
                } else {
                    panelImage(img)
                }
            }
            if !p.title.isEmpty {
                Text(p.title).font(.tCardTitle).foregroundColor(.tText)
            }
            if !p.text.isEmpty {
                Text(panelText(p.text))
                    .font(.tMeta).foregroundColor(.tMuted)
                    .tint(.tPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(TSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.tCard)
        .cornerRadius(TRadius.card)
    }

    private func panelImage(_ url: URL) -> some View {
        AsyncImage(url: url) { img in
            img.resizable().scaledToFit()
        } placeholder: {
            Color.tSurface.frame(height: 100)
        }
        .frame(maxWidth: .infinity)
        .cornerRadius(8)
    }
}
