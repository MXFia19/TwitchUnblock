import SwiftUI
import UIKit

// MARK: – Drops de la chaîne
/// Campagne de drops active sur la chaîne regardée, pour la carte « Drops »
/// en haut du chat (comme dans l'app Twitch). Lecture publique (GQL), sans
/// compte : nom, récompenses, temps de visionnage, échéance.
struct DropsCampaignNotice: Equatable, Identifiable {
    let id: String
    let name: String
    let game: String
    let endsAt: Date?
    let detailsURL: URL?
    /// Première récompense de la campagne et ce qu'il faut regarder pour l'avoir.
    let rewardName: String
    let rewardImage: String?
    let minutes: Int
    /// Récompenses suivantes de la même campagne.
    let more: Int
    /// Campagne de Twitch rangée dans la catégorie « Special Events »
    /// (« 1 Month of Apple TV »…, sur beaucoup de chaînes à la fois), et non
    /// drops du jeu de la chaîne : masquable à part (Réglages → Personnaliser).
    let specialEvent: Bool

    /// Catégorie « Special Events » de Twitch : son id, ou son nom (en
    /// anglais, comme Twitch le rend), au cas où l'id ne serait pas celui-là.
    static func isSpecialEvents(_ game: [String: Any]?) -> Bool {
        guard let game else { return false }
        if game["id"] as? String == "509663" { return true }
        return [game["name"], game["displayName"]].contains {
            ($0 as? String)?.trimmingCharacters(in: .whitespaces)
                .caseInsensitiveCompare("Special Events") == .orderedSame
        }
    }
}

@MainActor
final class ChannelDropsNotice: ObservableObject {
    /// Campagnes en cours sur la chaîne, dans l'ordre de Twitch, sans celles
    /// dont la carte a été fermée. Le chat montre la première que ses
    /// réglages laissent passer (drops de la chaîne, Special Events) : une
    /// campagne masquée ne cache plus celle d'après.
    @Published private(set) var campaigns: [DropsCampaignNotice] = []

    private var channelId = ""
    private var task: Task<Void, Never>?
    /// Campagnes dont on a fermé la carte : elle ne revient pas.
    private static let dismissedKey = "drops_notice_dismissed"

    /// Lue à l'arrivée, puis toutes les 10 minutes (une campagne peut
    /// commencer pendant le live).
    func start(channelId: String) {
        stop()
        guard !channelId.isEmpty else { return }
        self.channelId = channelId
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.fetch()
                try? await Task.sleep(nanoseconds: 600 * 1_000_000_000)
            }
        }
    }

    func stop() {
        task?.cancel(); task = nil
        campaigns = []
    }

    func dismiss(_ c: DropsCampaignNotice) {
        var ids = UserDefaults.standard.stringArray(forKey: Self.dismissedKey) ?? []
        if !ids.contains(c.id) { ids.append(c.id) }
        UserDefaults.standard.set(Array(ids.suffix(100)), forKey: Self.dismissedKey)
        campaigns.removeAll { $0.id == c.id }
    }

    private func fetch() async {
        let cid = channelId
        let q = """
        query { user(id: "\(gqlStr(cid))") { channel { viewerDropCampaigns {
          id name endAt detailsURL game { id name displayName }
          timeBasedDrops { name requiredMinutesWatched benefitEdges { benefit { name imageAssetURL } } }
        } } } }
        """
        guard let json = await VodChatService.rawGQL(q),
              let d = json["data"] as? [String: Any],
              let user = d["user"] as? [String: Any],
              let channel = user["channel"] as? [String: Any],
              cid == channelId else { return }
        let dismissed = Set(UserDefaults.standard.stringArray(forKey: Self.dismissedKey) ?? [])
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        let found = (channel["viewerDropCampaigns"] as? [[String: Any]] ?? []).compactMap { c -> DropsCampaignNotice? in
            guard let id = c["id"] as? String, !dismissed.contains(id) else { return nil }
            let end = (c["endAt"] as? String).flatMap { iso.date(from: $0) ?? isoPlain.date(from: $0) }
            if let end, end < Date() { return nil }
            let drops = (c["timeBasedDrops"] as? [[String: Any]] ?? [])
                .sorted { ($0["requiredMinutesWatched"] as? Int ?? 0) < ($1["requiredMinutesWatched"] as? Int ?? 0) }
            let first = drops.first
            let benefit = ((first?["benefitEdges"] as? [[String: Any]])?.first?["benefit"]) as? [String: Any]
            let game = c["game"] as? [String: Any]
            return DropsCampaignNotice(
                id: id,
                name: c["name"] as? String ?? "",
                game: game?["displayName"] as? String ?? "",
                endsAt: end,
                detailsURL: (c["detailsURL"] as? String).flatMap { $0.hasPrefix("https://") ? URL(string: $0) : nil },
                rewardName: (benefit?["name"] as? String) ?? (first?["name"] as? String) ?? "",
                rewardImage: benefit?["imageAssetURL"] as? String,
                minutes: first?["requiredMinutesWatched"] as? Int ?? 0,
                more: max(0, drops.count - 1),
                specialEvent: DropsCampaignNotice.isSpecialEvents(game))
        }
        if campaigns != found { campaigns = found }
    }
}

/// Carte « Drops » en haut du chat : à fermer, avec un lien vers les détails.
struct DropsNoticeCard: View {
    let campaign: DropsCampaignNotice
    let onDismiss: () -> Void
    @EnvironmentObject private var store: AppStore

    private var headline: String {
        guard !campaign.rewardName.isEmpty, campaign.minutes > 0 else { return campaign.name }
        return store.t("drops_notice_title")
            .replacingOccurrences(of: "{m}", with: "\(campaign.minutes)")
            .replacingOccurrences(of: "{r}", with: campaign.rewardName)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AsyncImage(url: URL(string: campaign.rewardImage ?? "")) { img in
                img.resizable().scaledToFit()
            } placeholder: {
                Image(systemName: "gift.fill").font(.system(size: 18)).foregroundColor(.tPurple)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.system(size: 12, weight: .bold)).foregroundColor(.tText)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Text([campaign.name, campaign.game].filter { !$0.isEmpty }.joined(separator: " · ")
                     + (campaign.more > 0 ? " · " + store.tn("drops_notice_more", campaign.more).replacingOccurrences(of: "{n}", with: "\(campaign.more)") : ""))
                    .font(.system(size: 11)).foregroundColor(.tMuted).lineLimit(1)
                HStack(spacing: 10) {
                    if let end = campaign.endsAt {
                        Text(store.t("drops_notice_ends").replacingOccurrences(
                            of: "{d}", with: end.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(Locale(identifier: store.lang.rawValue)))))
                            .font(.system(size: 10)).foregroundColor(.tMuted)
                    }
                    if let url = campaign.detailsURL {
                        Button(store.t("drops_notice_details")) { UIApplication.shared.open(url) }
                            .font(.system(size: 11, weight: .bold)).foregroundColor(.tPrimary)
                            .buttonStyle(.plain)
                    }
                }
                .padding(.top, 1)
            }
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold)).foregroundColor(.tMuted)
                    .frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(store.t("close"))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.tCard)
        .overlay(Divider().background(Color.tBorder), alignment: .bottom)
    }
}

// MARK: – Bandeaux repliés (paysage)
/// Un bandeau du salon, représenté par une icône quand ils sont repliés.
enum ChatNoticeKind: Hashable {
    case pinned, drops, poll, prediction, hype, raid

    var icon: String {
        switch self {
        case .pinned:     return "pin.fill"
        case .drops:      return "gift.fill"
        case .poll:       return "chart.bar.fill"
        case .prediction: return "sparkles"
        case .hype:       return "tram.fill"
        case .raid:       return "figure.run"
        }
    }

    var tint: Color {
        switch self {
        case .pinned, .drops, .prediction: return .tPurple
        case .poll, .raid:                 return .tPrimary
        case .hype:                        return .tLive
        }
    }
}

/// Icônes des bandeaux, avec le compte à rebours d'un sondage ou d'une
/// prédiction encore ouverts, et du hype train (approche ou niveau) : ligne
/// repliée (paysage) et pastille des bandeaux fermés.
struct NoticeIconsRow: View {
    let kinds: [ChatNoticeKind]
    var pollEnds: Date? = nil
    var predictionEnds: Date? = nil
    var hypeEnds: Date? = nil
    var spacing: CGFloat = 10

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(kinds, id: \.self) { kind in
                HStack(spacing: 3) {
                    Image(systemName: kind.icon).font(.system(size: 11, weight: .semibold))
                    // Une seule lecture de l'heure : entre deux, la fin
                    // pourrait passer et l'intervalle s'inverser.
                    let now = Date()
                    if let end = ends(kind), end > now {
                        Text(timerInterval: now...end, countsDown: true)
                            .font(.system(size: 10, weight: .bold).monospacedDigit())
                    }
                }
                .foregroundColor(kind.tint)
                .fixedSize()
            }
        }
    }

    private func ends(_ kind: ChatNoticeKind) -> Date? {
        switch kind {
        case .poll:       return pollEnds
        case .prediction: return predictionEnds
        case .hype:       return hypeEnds
        default:          return nil
        }
    }
}

/// Bandeaux repliés : une ligne d'icônes, avec le compte à rebours d'un
/// sondage, d'une prédiction ou d'un hype train. La toucher les déplie.
struct CollapsedNoticesBar: View {
    let kinds: [ChatNoticeKind]
    var pollEnds: Date? = nil
    var predictionEnds: Date? = nil
    var hypeEnds: Date? = nil
    let onExpand: () -> Void
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Button(action: onExpand) {
            HStack(spacing: 10) {
                NoticeIconsRow(kinds: kinds, pollEnds: pollEnds, predictionEnds: predictionEnds,
                               hypeEnds: hypeEnds)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold)).foregroundColor(.tMuted)
            }
            .padding(.horizontal, 12)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.tCard)
        .overlay(Divider().background(Color.tBorder), alignment: .bottom)
        .accessibilityLabel(store.t("notices_show"))
    }
}

/// Sondage, prédiction ou hype train fermés (×) : une seule pastille, quel
/// que soit leur nombre (la barre de statut est étroite), qui les rouvre.
struct ClosedNoticesChip: View {
    let kinds: [ChatNoticeKind]
    var pollEnds: Date? = nil
    var predictionEnds: Date? = nil
    var hypeEnds: Date? = nil
    let onReopen: () -> Void
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Button(action: onReopen) {
            NoticeIconsRow(kinds: kinds, pollEnds: pollEnds, predictionEnds: predictionEnds,
                           hypeEnds: hypeEnds, spacing: 6)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Color.tSurface).clipShape(Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel(store.t("notices_show"))
    }
}

/// Sous les bandeaux dépliés, en paysage : « Masquer » les replie en une
/// ligne. Une épingle réduite et les bandeaux fermés (×) se rouvrent ici, la
/// barre de statut qui porte leurs pastilles n'étant pas affichée.
struct NoticesHideStrip: View {
    var showPinChip = false
    let onReopenPin: () -> Void
    /// Bandeaux fermés : leur pastille groupée (vide = pas de pastille).
    var closedKinds: [ChatNoticeKind] = []
    var pollEnds: Date? = nil
    var predictionEnds: Date? = nil
    var hypeEnds: Date? = nil
    var onReopenClosed: () -> Void = {}
    let onHide: () -> Void
    @EnvironmentObject private var store: AppStore

    var body: some View {
        HStack(spacing: 6) {
            if showPinChip {
                Button(action: onReopenPin) {
                    HStack(spacing: 3) {
                        Image(systemName: "pin.fill").font(.system(size: 9))
                        Text(store.t("pinned_short")).font(.system(size: 10, weight: .bold))
                    }
                    .foregroundColor(.tPurple)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color.tPurple.opacity(0.15)).cornerRadius(6)
                }
                .buttonStyle(.plain)
                .fixedSize()
            }
            if !closedKinds.isEmpty {
                ClosedNoticesChip(kinds: closedKinds, pollEnds: pollEnds,
                                  predictionEnds: predictionEnds, hypeEnds: hypeEnds,
                                  onReopen: onReopenClosed)
            }
            Spacer(minLength: 4)
            Button(action: onHide) {
                HStack(spacing: 3) {
                    Text(store.t("notices_hide")).font(.system(size: 10, weight: .semibold))
                    Image(systemName: "chevron.up").font(.system(size: 9, weight: .bold))
                }
                .foregroundColor(.tMuted)
                .padding(.horizontal, 6)
                .frame(height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()
        }
        .padding(.leading, 12).padding(.trailing, 6)
        .background(Color.tCard)
        .overlay(Divider().background(Color.tBorder), alignment: .bottom)
    }
}

// MARK: – Fiche d'une emote ou d'un badge
/// Ce qu'on touche dans un message : une emote ou un badge.
enum ChatInfoItem: Identifiable {
    case emote(TwitchEmote)
    case badge(TwitchBadge)

    var id: String {
        switch self {
        case .emote(let e): return "emote:\(e.source.rawValue):\(e.id)"
        case .badge(let b): return "badge:\(b.id)"
        }
    }

    /// Ce que VoiceOver annonce : nom de l'emote, ou nom du jeu de badges.
    var accessibilityName: String {
        switch self {
        case .emote(let e): return e.name
        case .badge(let b): return ChatInfoSheet.fallbackTitle(b)
        }
    }
}

private struct ChatInfoActionKey: EnvironmentKey {
    static let defaultValue: ((ChatInfoItem) -> Void)? = nil
}

extension EnvironmentValues {
    /// Fourni par le chat qui affiche les messages : un toucher sur une emote
    /// ou un badge ouvre sa fiche. Absent ailleurs (rien ne se passe).
    var chatInfoAction: ((ChatInfoItem) -> Void)? {
        get { self[ChatInfoActionKey.self] }
        set { self[ChatInfoActionKey.self] = newValue }
    }
}

extension View {
    /// Toucher → fiche, seulement si un chat la propose : sinon le geste
    /// prendrait le toucher destiné au message. Annoncé comme un bouton à
    /// VoiceOver, qui peut alors l'ouvrir aussi.
    ///
    /// Le toucher est pris par une couche SwiftUI transparente posée dessus :
    /// une emote ou un badge animé est une vue UIKit (AnimatedImageView) qui
    /// ne prend aucun toucher, et un geste posé sur elle ne recevait rien —
    /// le toucher allait au message, qui ouvrait son fil.
    @ViewBuilder
    func chatInfoTap(_ action: ((ChatInfoItem) -> Void)?, _ item: @escaping @autoclosure () -> ChatInfoItem) -> some View {
        if let action {
            accessibilityAddTraits(.isButton)
                .accessibilityLabel(Text(item().accessibilityName))
                .accessibilityAction { action(item()) }
                .overlay {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { action(item()) }
                        // VoiceOver garde l'image, déjà annoncée comme un bouton.
                        .accessibilityHidden(true)
                }
        } else {
            self
        }
    }
}

/// Hauteur du contenu de la fiche : la feuille prend juste ce qu'il faut.
private struct ChatInfoHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Nom exact (à copier), source et portée, auteur, image en grand ; pour une
/// emote Twitch, son type et sa chaîne (lus à part, comme sur twitch.tv) ;
/// pour un badge, son titre.
struct ChatInfoSheet: View {
    let item: ChatInfoItem
    let channelId: String?
    /// Ajouter l'emote au message en cours (nil si on ne peut pas écrire).
    var onInsert: ((TwitchEmote) -> Void)? = nil
    /// « Voir la chaîne » d'une emote Twitch : ferme la fiche et ouvre la page
    /// de la chaîne. nil : bouton masqué (multi-live, fil d'un message).
    var onOpenChannel: ((String) -> Void)? = nil

    @EnvironmentObject private var store: AppStore
    @State private var badge: (title: String, description: String)? = nil
    @State private var twitchInfo: TwitchEmoteInfo? = nil
    @State private var copied = false
    @State private var contentHeight: CGFloat = 260

    var body: some View {
        // Défile si le contenu dépasse l'écran (paysage, grand texte).
        ScrollView {
            VStack(spacing: 12) {
                switch item {
                case .emote(let e): emoteContent(e)
                case .badge(let b): badgeContent(b)
                }
            }
            .padding(20)
            .padding(.top, 6)
            .frame(maxWidth: .infinity)
            .background(GeometryReader { g in
                Color.clear.preference(key: ChatInfoHeightKey.self, value: g.size.height)
            })
        }
        .onPreferenceChange(ChatInfoHeightKey.self) { h in
            if h > 0 { contentHeight = ceil(h) }
        }
        // Nouvelle fiche dans la même feuille : l'ancienne réponse n'est
        // jamais posée sur la nouvelle.
        .task(id: item.id) {
            switch item {
            case .badge(let b):
                let info = await BadgeService.shared.info(badgeId: b.id, channelId: channelId)
                if !Task.isCancelled { badge = info }
            case .emote(let e):
                twitchInfo = nil
                guard e.source == .twitch else { return }
                // Sans réponse (Twitch bloqué, schéma changé) : la fiche reste
                // celle d'avant, sans message d'erreur.
                let info = await EmoteInfoService.shared.twitch(id: e.id)
                if !Task.isCancelled { twitchInfo = info }
            }
        }
        // Un peu de marge : selon le système, la barre d'accueil est comptée
        // dans la hauteur demandée.
        .presentationDetents([.height(max(200, contentHeight + 16))])
        .presentationDragIndicator(.visible)
    }

    // MARK: Emote
    @ViewBuilder
    private func emoteContent(_ e: TwitchEmote) -> some View {
        // 72 pt suffisent : les plus grandes images servies font 84 à 128 px.
        // Largeur bornée : une emote très large ne déborde pas.
        CachedEmoteImage(url: Self.largeURL(e), name: e.name, height: 72,
                         maxWidth: 280, fallbackURL: e.url)
        Text(e.name)
            .font(.system(size: 22, weight: .bold, design: .monospaced))
            .foregroundColor(.tText)
            .textSelection(.enabled)
            .multilineTextAlignment(.center)
        VStack(spacing: 4) {
            Text(sourceLabel(e)).font(.system(size: 13)).foregroundColor(.tMuted)
            ForEach(detailLines(e), id: \.self) { line in
                Text(line).font(.system(size: 12)).foregroundColor(.tMuted)
                    .multilineTextAlignment(.center)
            }
        }
        if let info = twitchInfo, let owner = info.owner {
            ownerRow(owner)
            subEmotes(info, ownerName: owner.displayName)
        }
        if let page = Self.pageURL(e) {
            Button { UIApplication.shared.open(page.url) } label: {
                Label(store.t("emote_view_on").replacingOccurrences(of: "{p}", with: page.name),
                      systemImage: "arrow.up.right.square")
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.tPrimary)
            .buttonStyle(.plain)
        }
        HStack(spacing: 10) {
            Button {
                UIPasteboard.general.string = e.name
                copied = true
            } label: {
                Label(store.t(copied ? "chat_info_copied" : "chat_info_copy"),
                      systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderedProminent).tint(.tPrimary)
            // Emote d'abonné verrouillée (sélecteur) : la fiche ne l'insère
            // pas plus que la grille.
            if let onInsert, !e.locked {
                Button { onInsert(e) } label: {
                    Label(store.t("chat_info_insert"), systemImage: "text.cursor")
                }
                .buttonStyle(.bordered).tint(.tPrimary)
            }
        }
        .font(.system(size: 14, weight: .semibold))
        // Masquée : affichée dans le chat comme le mot tapé (Réglages → Chat).
        // Le sélecteur d'emotes la garde : on peut toujours l'envoyer.
        EmoteHideButton(code: e.name)
    }

    /// Chaîne propriétaire d'une emote Twitch : avatar, nom, en direct ou non.
    @ViewBuilder
    private func ownerRow(_ o: TwitchEmoteInfo.Owner) -> some View {
        HStack(spacing: 10) {
            AsyncImage(url: URL(string: o.avatar ?? "")) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                Circle().fill(Color.tSurface)
            }
            .frame(width: 28, height: 28)
            .clipShape(Circle())
            Text(o.displayName)
                .font(.system(size: 14, weight: .bold)).foregroundColor(.tText)
                .lineLimit(1)
            if o.isLive { TLiveBadge(compact: true) }
            Spacer(minLength: 4)
            if let onOpenChannel {
                Button { onOpenChannel(o.login) } label: {
                    HStack(spacing: 2) {
                        Text(store.t("see_channel"))
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                    }
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.tPrimary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fixedSize()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.tSurface.opacity(0.6))
        .cornerRadius(10)
    }

    /// Emotes d'abonné du même niveau, comme Twitch (« 63 autres » pour 64 au
    /// niveau 1) : leur nombre et quelques aperçus.
    @ViewBuilder
    private func subEmotes(_ info: TwitchEmoteInfo, ownerName: String) -> some View {
        if info.type == "SUBSCRIPTIONS", info.tier != nil, !info.sameTier.isEmpty {
            let others = Array(info.sameTier.filter { $0.id != info.id }.prefix(8))
            Text(store.t("emote_sub_count")
                    .replacingOccurrences(of: "{c}", with: ownerName)
                    .replacingOccurrences(of: "{n}", with: "\(info.sameTier.count)"))
                .font(.system(size: 12)).foregroundColor(.tMuted)
                .multilineTextAlignment(.center)
            if !others.isEmpty {
                HStack(spacing: 6) {
                    ForEach(others) { x in
                        CachedEmoteImage(url: x.url, name: x.token, height: 28,
                                         showsNameFallback: false, maxWidth: 34)
                    }
                }
            }
        }
    }

    /// Source et portée : « 7TV · Emote de la chaîne » ; pour une emote
    /// Twitch, son type dès qu'il est connu.
    private func sourceLabel(_ e: TwitchEmote) -> String {
        switch e.source {
        case .twitch:
            return twitchTypeLabel ?? store.t("emote_src_twitch")
        case .bttv where e.personal:
            return store.t("emote_src_bttv_personal")
        default:
            let scope: String?
            switch e.scope {
            case .global:  scope = store.t("emote_scope_global")
            case .channel: scope = store.t("emote_scope_channel")
            case .personal, .unknown: scope = nil
            }
            return [Self.brand(e.source), scope].compactMap { $0 }.joined(separator: " · ")
        }
    }

    /// Seuls ces types sont vérifiés : pour un autre, la ligne générique
    /// plutôt qu'une valeur brute.
    private var twitchTypeLabel: String? {
        guard let info = twitchInfo else { return nil }
        switch info.type {
        case "GLOBALS", "SMILIES":
            return store.t("emote_type_global")
        case "SUBSCRIPTIONS":
            guard let n = info.tier else { return nil }
            return "Twitch · " + store.t("emote_type_sub").replacingOccurrences(of: "{n}", with: "\(n)")
        case "CHANNEL_POINTS":
            return "Twitch · " + store.t("emote_type_points")
        default:
            return nil
        }
    }

    /// Auteur, nom d'origine, zero-width (7TV), modificateur (BTTV, FFZ).
    private func detailLines(_ e: TwitchEmote) -> [String] {
        var lines: [String] = []
        if let a = e.author, !a.isEmpty {
            lines.append(store.t("emote_by").replacingOccurrences(of: "{u}", with: a))
        }
        if let o = e.originalName {
            lines.append(store.t("emote_original").replacingOccurrences(of: "{n}", with: o))
        }
        if e.zeroWidth { lines.append(store.t("emote_zero_width")) }
        if e.isModifier { lines.append(store.t("emote_modifier")) }
        return lines
    }

    private static func brand(_ s: EmoteSource) -> String {
        switch s {
        case .twitch:  return "Twitch"
        case .bttv:    return "BetterTTV"
        case .ffz:     return "FrankerFaceZ"
        case .seventv: return "7TV"
        }
    }

    /// Page de l'emote chez BTTV, FFZ ou 7TV (« Voir sur … »).
    static func pageURL(_ e: TwitchEmote) -> (name: String, url: URL)? {
        guard !e.id.isEmpty,
              let id = e.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        let link: String
        switch e.source {
        case .twitch:  return nil
        case .bttv:    link = "https://betterttv.com/emotes/\(id)"
        case .ffz:     link = "https://www.frankerfacez.com/emoticon/\(id)"
        case .seventv: link = "https://7tv.app/emotes/\(id)"
        }
        guard let url = URL(string: link) else { return nil }
        return (name: brand(e.source), url: url)
    }

    /// Image plus grande que celle du chat, quand la source la propose.
    static func largeURL(_ e: TwitchEmote) -> String {
        // VOD téléchargée : image gardée dans le dossier, une seule taille.
        guard e.url.hasPrefix("https://") else { return e.url }
        if let large = e.largeURL, !large.isEmpty { return large }
        switch e.source {
        case .twitch: return e.url.replacingOccurrences(of: "/2.0", with: "/3.0")
        case .bttv: return e.url.replacingOccurrences(of: "/2x", with: "/3x")
        case .seventv: return e.url.replacingOccurrences(of: "/2x.", with: "/4x.")
        case .ffz: return e.url
        }
    }

    // MARK: Badge
    @ViewBuilder
    private func badgeContent(_ b: TwitchBadge) -> some View {
        CachedEmoteImage(url: Self.largeBadgeURL(b.url), name: "", height: 54,
                         showsNameFallback: false, fallbackURL: b.url)
        Text(badge?.title ?? Self.fallbackTitle(b))
            .font(.system(size: 20, weight: .bold)).foregroundColor(.tText)
            .multilineTextAlignment(.center)
        if let d = badge?.description, !d.isEmpty, d != badge?.title {
            Text(d).font(.system(size: 13)).foregroundColor(.tMuted)
                .multilineTextAlignment(.center)
        }
        Text(store.t("chat_info_badge")).font(.system(size: 12)).foregroundColor(.tMuted)
    }

    /// Taille /3 (72 px) : la /2 du chat (36 px) est floue en grand.
    static func largeBadgeURL(_ url: String) -> String {
        guard url.hasPrefix("https://"), url.hasSuffix("/2") else { return url }
        return String(url.dropLast()) + "3"
    }

    /// Sans titre connu : le nom du jeu de badges (« subscriber »…).
    static func fallbackTitle(_ b: TwitchBadge) -> String {
        let set = b.id.components(separatedBy: "/").first ?? b.id
        return set.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
