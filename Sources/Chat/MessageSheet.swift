import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════
//  Feuille ouverte en touchant un message.
//
//  Elle est centrée sur la personne, pas sur le message : seul, hors contexte,
//  un message ne dit pas grand-chose. En tête, sa fiche (badges, âge du
//  compte, suivi de la chaîne, mentionner, masquer, ouvrir sa chaîne) ; puis
//  ses derniers messages dans ce qu'on a en mémoire, et le fil de réponses
//  dessous. Répondre et copier s'appliquent au message touché.
// ═══════════════════════════════════════════════════════════════════════════

struct MessageSheet: View {
    let message: ChatMessage
    @ObservedObject var chat: ChatService
    let canSend: Bool
    /// « Mentionner » : faux quand la zone d'envoi du chat est masquée
    /// (Réglages → Chat), la mention irait dans un champ invisible. Répondre
    /// reste possible, le champ est dans cette feuille.
    var canMention = true
    var style: ChatStyle = .standard
    /// Insère « @pseudo » dans la barre d'envoi du chat et referme.
    var onMention: (String) -> Void = { _ in }
    /// Page de la chaîne de la personne (la feuille se ferme d'abord). nil :
    /// pas de page à ouvrir d'ici (multi-live, plein écran).
    var onOpenChannel: ((String) -> Void)? = nil

    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var avatar: String? = nil
    /// Fiche : création du compte, et depuis quand la personne suit la chaîne
    /// (quand Twitch le dit sans compte).
    @State private var createdAt: Date? = nil
    @State private var followedAt: Date? = nil
    @State private var replying = false
    @State private var replyText = ""
    /// Raison d'une réponse non partie (trop longue, chat pas connecté).
    @State private var replyFailed: String? = nil
    @State private var copied = false
    /// Emote ou badge touché dans le fil : sa fiche, par-dessus cette feuille.
    @State private var infoItem: ChatInfoItem? = nil
    @FocusState private var focused: Bool

    private var rootId: String { message.threadRootId ?? message.id }
    private var canReply: Bool { !replyText.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Fil de réponses du message touché (vide s'il n'y en a pas).
    private var thread: [ChatMessage] {
        let thread = chat.threadMessages(rootId: rootId)
        return thread.count > 1 ? thread : []
    }

    /// Derniers messages de la personne dans ce chat (en mémoire). Avec un
    /// fil, les cinq derniers seulement : le fil reste dessous.
    private func recentMessages(withThread: Bool) -> [ChatMessage] {
        let mine = chat.messagesFrom(userName: message.userName)
        let list = mine.isEmpty ? [message] : mine
        return withThread ? Array(list.suffix(5)) : list
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color.tBorder)
            messageList
            if replying, canSend { replyBar }
        }
        .background(Color.tDark)
        .overlay(alignment: .top) {
            if copied {
                Text(store.t("msg_copied"))
                    .font(.tLabel).foregroundColor(.white)
                    .padding(.horizontal, TSpace.lg).padding(.vertical, TSpace.sm)
                    .background(Color.tPrimary).clipShape(Capsule())
                    .padding(.top, TSpace.md)
                    .transition(.opacity)
            }
        }
        // Fiche présentée depuis cette feuille : celle du chat, en dessous, ne
        // peut pas s'afficher tant que le fil est ouvert (elle surgissait à sa
        // fermeture). Ni « Ajouter au message » ni « Voir la chaîne » ici :
        // il faudrait fermer deux feuilles l'une après l'autre.
        .sheet(item: $infoItem) { item in
            ChatInfoSheet(item: item, channelId: chat.channelId, onInsert: nil)
                .environmentObject(store)
        }
        .task {
            // Le chat IRC ne transporte pas les photos de profil : une requête
            // Helix, mise en cache pour la session (voir AvatarCache).
            avatar = await AvatarCache.shared.avatar(login: message.userName,
                                                     token: store.twitchToken)
        }
        .task {
            // Fiche : âge du compte et suivi de la chaîne (API publique), en
            // parallèle — l'un peut manquer sans l'autre.
            let user = message.userName, channel = chat.channelName
            guard !user.isEmpty else { return }
            async let created = getUserCreatedAt(login: user)
            async let followed = getFollowedAt(login: user, channel: channel)
            createdAt = await created
            followedAt = await followed
        }
    }

    // MARK: – Fiche : qui parle, et que faire
    @ViewBuilder private var header: some View {
        VStack(alignment: .leading, spacing: TSpace.md) {
            HStack(alignment: .top, spacing: TSpace.md) {
                AsyncImage(url: URL(string: avatar ?? "")) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    // Repli sur l'initiale : la photo peut manquer (compte supprimé,
                    // pas de jeton), et un rond vide n'aide personne.
                    ZStack {
                        Circle().fill(message.color.opacity(0.25))
                        Text(String(message.displayName.prefix(1)).uppercased())
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(message.color)
                    }
                }
                .frame(width: 46, height: 46)
                .clipShape(Circle())

                VStack(alignment: .leading, spacing: 3) {
                    // Badges portés dans ce chat (touchés : leur fiche), puis le nom.
                    HStack(spacing: 4) {
                        ForEach(message.badges) { badge in
                            CachedEmoteImage(url: badge.url, name: "", height: 18,
                                             showsNameFallback: false)
                                .chatInfoTap({ infoItem = $0 }, .badge(badge))
                        }
                        Text(message.displayName)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(message.color)
                            .lineLimit(1)
                    }
                    // Pseudo différent du nom affiché (caractères non latins).
                    if !message.userName.isEmpty,
                       message.displayName.lowercased() != message.userName.lowercased() {
                        Text("@" + message.userName)
                            .font(.tMeta).foregroundColor(.tMuted).lineLimit(1)
                    }
                    if let createdAt {
                        infoLine(icon: "calendar",
                                 text: store.t("user_created").replacingOccurrences(of: "{d}", with: day(createdAt)))
                    }
                    if let followedAt {
                        infoLine(icon: "heart.fill",
                                 text: store.t("user_followed").replacingOccurrences(of: "{d}", with: day(followedAt)))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if canSend, !message.id.hasPrefix("local-") {
                    actionButton(icon: "arrowshape.turn.up.left.fill") {
                        replying = true
                        focused  = true
                    }
                }
                actionButton(icon: "doc.on.doc") {
                    UIPasteboard.general.string = plainText
                    withAnimation { copied = true }
                    Task {
                        try? await Task.sleep(nanoseconds: 900_000_000)
                        withAnimation { copied = false }
                    }
                }
                .accessibilityLabel(store.t("copy_message"))
            }

            // Mentionner, masquer (dans ce chat, sur cet appareil), sa chaîne.
            if !message.userName.isEmpty {
                HStack(spacing: TSpace.sm) {
                    if canSend, canMention {
                        cardButton(icon: "at", title: store.t("mention_user")) {
                            onMention(message.displayName.lowercased() == message.userName.lowercased()
                                      ? message.displayName : message.userName)
                            dismiss()
                        }
                    }
                    let hidden = store.chatBlockedUsers.contains(message.userName.lowercased())
                    cardButton(icon: hidden ? "eye" : "eye.slash",
                               title: store.t(hidden ? "unhide_user" : "hide_user"),
                               tint: hidden ? .tText : .tDanger) {
                        store.toggleBlocked(message.userName)
                        dismiss()
                    }
                    if let onOpenChannel {
                        cardButton(icon: "person.crop.square", title: store.t("user_channel")) {
                            onOpenChannel(message.userName.lowercased())
                        }
                    }
                }
                // Même hauteur pour tous, libellé sur deux lignes compris.
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, TSpace.lg)
        .padding(.vertical, TSpace.md)
    }

    /// Ligne de la fiche (création du compte, suivi de la chaîne).
    private func infoLine(icon: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            Text(text).font(.tMeta).lineLimit(1).minimumScaleFactor(0.85)
        }
        .foregroundColor(.tMuted)
    }

    /// « 12 mars 2016 », dans la langue de l'app.
    private func day(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.wide).year().locale(Locale(identifier: store.lang.rawValue)))
    }

    /// Bouton de la fiche : icône au-dessus du libellé, en colonnes égales.
    private func cardButton(icon: String, title: String, tint: Color = .tText,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 15, weight: .semibold))
                Text(title).font(.tMeta)
                    .multilineTextAlignment(.center)
                    .lineLimit(2).minimumScaleFactor(0.85)
            }
            .foregroundColor(tint)
            .padding(.horizontal, TSpace.xs)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, TSpace.sm)
            .background(Color.tSurface)
            .cornerRadius(TRadius.control)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func actionButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(.tText)
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: – Messages : les siens, puis le fil
    @ViewBuilder private var messageList: some View {
        let thread = self.thread
        let recent = recentMessages(withThread: !thread.isEmpty)
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        sectionTitle(store.t("user_recent"))
                        ForEach(recent) { m in
                            messageRow(m, width: geo.size.width)
                                // Avec un fil, le message touché est repéré dans
                                // le fil : son id va là-bas.
                                .id(thread.isEmpty ? m.id : "recent-" + m.id)
                        }
                        if !thread.isEmpty {
                            sectionTitle(store.t("thread_title"))
                            ForEach(thread) { m in
                                messageRow(m, width: geo.size.width)
                                    .id(m.id)
                            }
                        }
                    }
                    .frame(width: geo.size.width, alignment: .leading)
                    .padding(.vertical, TSpace.xs)
                }
                .onAppear { proxy.scrollTo(message.id, anchor: .center) }
            }
        }
        // Remplace l'action héritée du chat, qui ouvrait la fiche sous le fil.
        .environment(\.chatInfoAction, { infoItem = $0 })
    }

    private func messageRow(_ m: ChatMessage, width: CGFloat) -> some View {
        ChatMessageRow(message: m, availableWidth: width, style: style)
            // Le message d'où l'on vient reste repérable au milieu des autres.
            .background(m.id == message.id ? Color.tPrimary.opacity(0.12) : Color.clear)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.tBadge).foregroundColor(.tMuted)
            .padding(.horizontal, TSpace.lg)
            .padding(.top, TSpace.sm).padding(.bottom, TSpace.xs)
    }

    // MARK: – Réponse
    @ViewBuilder private var replyBar: some View {
        Divider().background(Color.tBorder)
        HStack(spacing: TSpace.sm) {
            TextField("\(store.t("thread_reply_to")) @\(message.displayName)",
                      text: $replyText)
                .focused($focused)
                .foregroundColor(.tText)
                .autocorrectionDisabled(!store.chatKeyboardSuggestions)
                .padding(.horizontal, TSpace.md).padding(.vertical, 10)
                .background(Color.tSurface).cornerRadius(TRadius.control)
                .overlay(RoundedRectangle(cornerRadius: TRadius.control)
                    .stroke(focused ? Color.tPrimary : Color.tBorder, lineWidth: 1))
                // Comme le chat : Entrée ferme le clavier, sauf réglage contraire.
                .submitLabel(store.chatReturnSends ? .send : .done)
                .onSubmit { if store.chatReturnSends { sendReply() } else { focused = false } }

            Button(action: sendReply) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 15, weight: .bold)).foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(canReply ? Color.tPrimary : Color.tMuted.opacity(0.35))
                    .cornerRadius(TRadius.control)
            }
            .disabled(!canReply)
        }
        .padding(.horizontal, TSpace.md).padding(.vertical, TSpace.sm)
        .background(Color.tCard)
        if let replyFailed {
            Text(replyFailed)
                .font(.tMeta).foregroundColor(.tDanger)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, TSpace.md).padding(.bottom, TSpace.sm)
                .background(Color.tCard)
        }
    }

    /// Texte brut du message, emotes remplacées par leur nom (c'est ce qu'on
    /// colle ailleurs de toute façon).
    private var plainText: String {
        message.tokens.map { token in
            switch token {
            case .text(let t):    return t
            case .emote(let e):   return e.name
            case .mention(let m): return "@\(m)"
            case .link(let l):    return l
            case .gif(let u, _):  return u
            }
        }.joined(separator: " ")
    }

    /// La feuille ne se ferme que si la réponse est partie : trop longue
    /// (500 caractères) ou chat pas connecté, elle était perdue sans un mot.
    private func sendReply() {
        let t = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        replyFailed = nil
        Task {
            let sent = await chat.sendMessage(t, replyParentId: message.id,
                                              replyRootId: rootId,
                                              replyToName: message.displayName)
            if sent {
                replyText = ""
                dismiss()
            } else {
                replyFailed = store.t(t.count > 500 ? "reply_too_long" : "reply_not_connected")
            }
        }
    }
}
