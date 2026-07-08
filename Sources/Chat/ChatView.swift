import SwiftUI

// MARK: – Main Chat View
struct ChatView: View {
    let channelName: String
    let channelId: String?
    let token: String?
    let login: String?

    @EnvironmentObject private var store: AppStore
    @StateObject private var chat          = ChatService()
    @StateObject private var pointsService = ChannelPointsService()
    @StateObject private var pubsub        = ChatPubSub()
    @StateObject private var follow        = FollowService()

    @State private var autoScroll       = true
    @State private var messageText      = ""
    @State private var showEmotePicker  = false
    @State private var showPointsSheet  = false
    @State private var showWebLogin     = false
    @State private var webLoginClear    = false   // true = re-login forcé (token web expiré)
    @State private var threadRoot: ChatMessage? = nil   // fil de discussion ouvert
    @State private var pinnedCollapsed  = false   // bandeau épinglé masqué/affiché
    @State private var isSetup          = false   // chat/points déjà initialisés
    @State private var teardownWork: DispatchWorkItem? = nil   // anti-rebond plein écran
    @FocusState private var isInputFocused: Bool

    private var canSendMessages: Bool { token != nil && login != nil }
    private var canSend: Bool {
        chat.isConnected && chat.isAuthenticated &&
        !messageText.trimmingCharacters(in: .whitespaces).isEmpty &&
        messageText.count <= 500
    }

    var body: some View {
        VStack(spacing: 0) {

            // ── Barre de statut ─────────────────────────────────────
            HStack(spacing: 6) {
                Circle()
                    .fill(chat.isConnected ? Color.tSuccess : Color.tDanger)
                    .frame(width: 6, height: 6)
                Text(chat.isConnected ? store.t("chat_connected") : store.t("chat_connecting"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.tMuted)
                Spacer()
                // Bouton Suivre / Ne plus suivre
                if let following = follow.isFollowing {
                    Button {
                        Task { await follow.toggle(token: store.twitchWebToken) }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: following ? "heart.fill" : "heart")
                            Text(following ? store.t("following") : store.t("follow"))
                                .font(.system(size: 10, weight: .bold))
                        }
                        .foregroundColor(following ? .tDanger : .tPrimary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background((following ? Color.tDanger : Color.tPrimary).opacity(0.15))
                        .cornerRadius(6)
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .stroke(following ? Color.tDanger : Color.tPrimary, lineWidth: 1))
                    }
                    .disabled(follow.busy)
                    .opacity(follow.busy ? 0.5 : 1)
                }
                if chat.isAuthenticated, let l = login {
                    Text("✏️ @\(l)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.tPrimary)
                }
                Text("#\(channelName)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.tPrimary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.tCard)
            .overlay(Divider().background(Color.tBorder), alignment: .bottom)

            // ── Message épinglé ─────────────────────────────────────
            if let pin = pubsub.pinnedText {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 12)).foregroundColor(.tWarning)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 2) {
                        if let author = pubsub.pinnedAuthor {
                            Text(author)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.tWarning)
                        }
                        if !pinnedCollapsed {
                            // Liens cliquables (détection auto d'URL) + retour à la ligne
                            Text(linkified(pin))
                                .font(.system(size: 12))
                                .tint(.tOutplayer)
                                .foregroundColor(.tText)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text(pin)
                                .font(.system(size: 12)).foregroundColor(.tMuted)
                                .lineLimit(1).truncationMode(.tail)
                        }
                    }
                    Spacer(minLength: 0)
                    // Bouton masquer / afficher
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { pinnedCollapsed.toggle() }
                    } label: {
                        Image(systemName: pinnedCollapsed ? "chevron.down" : "chevron.up")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.tMuted)
                            .frame(width: 26, height: 26)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.tWarning.opacity(0.12))
                .overlay(Divider().background(Color.tBorder), alignment: .bottom)
            }

            // ── Zone principale ─────────────────────────────────────
            if showEmotePicker && canSendMessages {
                EmotePickerView(channelId: channelId) { emote in
                    insertEmote(emote)
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal:   .move(edge: .bottom).combined(with: .opacity)
                ))
            } else {
                GeometryReader { geo in
                    ZStack(alignment: .bottomTrailing) {
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 0) {
                                    ForEach(chat.messages.reversed()) { msg in
                                        ChatMessageRow(
                                            message: msg,
                                            availableWidth: geo.size.width
                                        )
                                        .id(msg.id)
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            guard msg.userId != "system" else { return }
                                            threadRoot = msg
                                        }
                                    }
                                }
                                .frame(width: geo.size.width, alignment: .leading)
                                .padding(.vertical, 4)
                            }
                            .onChange(of: chat.messages.first?.id) { newId in
                                guard autoScroll, let id = newId else { return }
                                withAnimation(.linear(duration: 0.1)) {
                                    proxy.scrollTo(id, anchor: .bottom)
                                }
                            }
                        }

                        if !autoScroll {
                            Button { autoScroll = true } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.down")
                                    Text(store.t("chat_follow")).font(.system(size: 11, weight: .bold))
                                }
                                .foregroundColor(.white)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Color.tPrimary)
                                .cornerRadius(20)
                            }
                            .padding(10)
                        }
                    }
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .top).combined(with: .opacity),
                    removal:   .move(edge: .top).combined(with: .opacity)
                ))
            }

            // ── Barre d'envoi ───────────────────────────────────────
            if canSendMessages { inputBar }
        }
        .background(Color.tDark)
        // ── Fil de discussion (répondre) ─────────────────────────────
        .sheet(item: $threadRoot) { root in
            ThreadSheet(root: root, chat: chat,
                        canSend: canSendMessages,
                        rootDisplayName: root.displayName)
                .presentationDetents([.medium, .large])
        }
        // ── Sheet points ─────────────────────────────────────────────
        .sheet(isPresented: $showPointsSheet) {
            ChannelPointsSheet(service: pointsService) {
                // L'utilisateur demande à connecter son compte pour les points.
                webLoginClear   = pointsService.needsWebLogin && store.twitchWebToken != nil
                showPointsSheet = false
                // Délai : éviter le conflit « fermeture + ouverture » de sheets simultanées.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    showWebLogin = true
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.hidden)
        }
        // ── Login web Twitch (capture du cookie auth-token) ──────────
        .sheet(isPresented: $showWebLogin) {
            TwitchWebLoginSheet(
                clearSession: webLoginClear,
                onComplete: { webToken, webLogin in
                    showWebLogin = false
                    if store.twitchLogin == nil, let l = webLogin { store.twitchLogin = l }
                    store.twitchWebToken = webToken   // → déclenche onChange ci-dessous
                },
                onCancel: { showWebLogin = false }
            )
        }
        // ── Token web mis à jour → recharge les points ───────────────
        .onChange(of: store.twitchWebToken) { newWebToken in
            guard let cid = channelId else { return }
            logger.info("POINTS", "Token web mis à jour → rechargement points",
                        String((newWebToken ?? "").prefix(8)) + "…")
            Task {
                await pointsService.load(
                    channelLogin: channelName,
                    channelId:   cid,
                    token:       newWebToken ?? "",
                    userLogin:   store.twitchLogin,
                    viewerId:    store.twitchUserId
                )
            }
        }
        // ── Token OAuth mis à jour → reconnecte uniquement l'IRC ──────
        .onChange(of: store.twitchToken) { newToken in
            guard let tok = newToken else { return }
            logger.info("CHAT", "Token OAuth mis à jour → reconnexion IRC",
                        String(tok.prefix(8)) + "…")
            chat.connect(channel: channelName, token: tok, login: store.twitchLogin)
        }
        .onChange(of: store.autoClaimChest) { pointsService.autoClaim = $0 }
        .onAppear {
            // Annule un éventuel teardown différé (retour de plein écran).
            teardownWork?.cancel(); teardownWork = nil
            guard !isSetup else { return }   // déjà initialisé → pas de double connexion
            isSetup = true
            Task { await setupChat() }
        }
        .onDisappear {
            // Le passage en plein écran (AVPlayerViewController) déclenche un onDisappear
            // transitoire. On NE coupe PAS l'IRC/les points tant qu'on est en plein écran ;
            // le délai + le flag couvrent aussi le PiP / transitions rapides.
            let work = DispatchWorkItem {
                guard !PlayerFullscreen.isActive else { return }   // plein écran → on garde tout actif
                chat.disconnect()
                pubsub.disconnect()
                pointsService.stopPolling()
                isSetup = false
            }
            teardownWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
        }
    }

    // MARK: – Setup initial
    private func setupChat() async {
        await EmoteService.shared.loadGlobals()
        if let cid = channelId {
            await EmoteService.shared.loadChannel(channelId: cid, channelName: channelName)
        }
        if let tok = token {
            await BadgeService.shared.loadGlobal(token: tok)
            if let cid = channelId {
                await BadgeService.shared.loadChannel(channelId: cid, token: tok)
            }
        }
        pointsService.autoClaim = store.autoClaimChest
        // Points : on utilise le token de session web (cookie auth-token), pas l'OAuth.
        // Si absent, load() affiche quand même les récompenses et signale needsWebLogin.
        if let cid = channelId {
            await pointsService.load(
                channelLogin: channelName,
                channelId:   cid,
                token:       store.twitchWebToken ?? "",
                userLogin:   login,
                viewerId:    store.twitchUserId
            )
        }
        chat.channelId = channelId
        chat.connect(channel: channelName, token: token, login: login)

        // Messages épinglés (PubSub) — nécessite un token + l'ID du canal.
        if let cid = channelId, let tok = store.twitchWebToken ?? store.twitchToken {
            pubsub.connect(channelId: cid, token: tok)
        }
        // Statut de suivi (nécessite le token web pour le champ self.follower)
        if let cid = channelId {
            await follow.load(login: channelName, channelId: cid, token: store.twitchWebToken)
        }
    }

    // MARK: – Input bar
    @ViewBuilder
    private var inputBar: some View {
        VStack(spacing: 0) {
            Divider().background(Color.tBorder)
            VStack(spacing: 4) {
                HStack(spacing: 6) {

                    // 🎁 Points de chaîne
                    ChannelPointsButton(service: pointsService) {
                        showEmotePicker = false
                        showPointsSheet = true
                    }

                    // 😊 Emote picker
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            if showEmotePicker {
                                showEmotePicker = false
                            } else {
                                isInputFocused  = false
                                showEmotePicker = true
                            }
                        }
                    } label: {
                        Image(systemName: showEmotePicker ? "keyboard" : "face.smiling")
                            .font(.system(size: 20))
                            .foregroundColor(showEmotePicker ? .tPrimary : .tMuted)
                            .frame(width: 32, height: 44)
                    }

                    // Champ texte
                    TextField(
                        chat.isConnected ? store.t("chat_send_ph") : store.t("chat_connecting_ph"),
                        text: $messageText
                    )
                    .focused($isInputFocused)
                    .autocorrectionDisabled()
                    .autocapitalization(.sentences)
                    .foregroundColor(.tText)
                    .submitLabel(.send)
                    .onSubmit { sendMessage() }
                    .disabled(!chat.isConnected || !chat.isAuthenticated)
                    .onChange(of: isInputFocused) { focused in
                        if focused && showEmotePicker {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                showEmotePicker = false
                            }
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(Color.tSurface)
                    .cornerRadius(10)
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .stroke(isInputFocused ? Color.tPrimary : Color.tBorder, lineWidth: 1))

                    // Bouton envoyer
                    Button(action: sendMessage) {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(canSend ? Color.tPrimary : Color.tMuted.opacity(0.35))
                            .cornerRadius(10)
                    }
                    .disabled(!canSend)
                }

                if messageText.count > 400 {
                    HStack {
                        Spacer()
                        Text("\(messageText.count)/500")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(messageText.count > 480 ? .tDanger : .tWarning)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 10)
            .background(Color.tCard)
        }
    }

    // MARK: – Actions
    private func sendMessage() {
        let trimmed = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 500 else { return }
        messageText = ""; autoScroll = true
        Task { await chat.sendMessage(trimmed) }
    }

    private func insertEmote(_ emote: TwitchEmote) {
        messageText += (messageText.isEmpty || messageText.hasSuffix(" ") ? "" : " ")
            + emote.name + " "
    }

    /// Transforme les URLs d'un texte en liens tappables (message épinglé).
    private func linkified(_ s: String) -> AttributedString {
        var att = AttributedString(s)
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let ns = s as NSString
            for m in detector.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                guard let url = m.url,
                      let r = Range(m.range, in: s),
                      let attRange = att.range(of: String(s[r])) else { continue }
                att[attRange].link = url
                att[attRange].underlineStyle = .single
                att[attRange].foregroundColor = .tOutplayer
            }
        }
        return att
    }
}

// MARK: – Single Message Row
struct ChatMessageRow: View {
    let message: ChatMessage
    let availableWidth: CGFloat
    @EnvironmentObject private var store: AppStore

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
    private var timeString: String { Self.timeFormatter.string(from: message.timestamp) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            if message.isFirstMessage {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles").font(.system(size: 10, weight: .bold))
                    Text(store.t("chat_first_message")).font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(.tPurple)
                .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 4)
                .frame(width: availableWidth, alignment: .leading)
            }

            // Bannière USERNOTICE (abonnement, série de visionnage…)
            if let sys = message.systemMsg {
                HStack(spacing: 6) {
                    Image(systemName: "star.fill").font(.system(size: 10, weight: .bold))
                    Text(sys).font(.system(size: 11, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundColor(.tWarning)
                .padding(.horizontal, 12).padding(.top, 6)
                .padding(.bottom, message.tokens.isEmpty ? 6 : 2)
                .frame(width: availableWidth, alignment: .leading)
            }

            if let replyUser = message.replyTo {
                HStack(spacing: 0) {
                    Color.tPrimary.opacity(0.5).frame(width: 2).padding(.leading, 12)
                    HStack(spacing: 5) {
                        Image(systemName: "arrowshape.turn.up.left.fill")
                            .font(.system(size: 9)).foregroundColor(.tMuted)
                        (
                            Text("@\(replyUser)").fontWeight(.bold).foregroundColor(.tMuted)
                            + Text(message.replyBody.map { ": \($0)" } ?? "")
                                .foregroundColor(.tMuted.opacity(0.75))
                        )
                        .font(.system(size: 11)).lineLimit(1)
                    }
                    .padding(.leading, 8)
                    Spacer()
                }
                .padding(.top, 5).padding(.bottom, 3)
                .frame(width: availableWidth, alignment: .leading)
            }

            // Ligne du message (masquée si USERNOTICE sans texte écrit)
            if message.systemMsg == nil || !message.tokens.isEmpty {
                HStack(alignment: .top, spacing: 0) {
                    if message.isHighlight { Rectangle().fill(Color.tWarning).frame(width: 3) }
                    WrappingHStack(message: message, timeString: timeString,
                                   availableWidth: availableWidth - 24)
                        .padding(.horizontal, 12).padding(.vertical, 4)
                }
                .frame(width: availableWidth, alignment: .leading)
            }
        }
        .frame(width: availableWidth, alignment: .leading)
        .background(
            message.isHighlight    ? Color.tWarning.opacity(0.08) :
            message.isFirstMessage ? Color.tPrimary.opacity(0.05) :
                                     Color.clear
        )
    }
}

// MARK: – Wrapping HStack
struct WrappingHStack: View {
    let message: ChatMessage
    let timeString: String
    let availableWidth: CGFloat

    var body: some View {
        let blocks = message.tokens.enumerated().map { i, t in TokenBlock(id: i, content: t) }
        MessageFlowLayout(spacing: 4, lineSpacing: 4, width: availableWidth) {
            Text(timeString).font(.system(size: 11)).foregroundColor(.tMuted)
            ForEach(message.badges) { badge in
                AsyncImage(url: URL(string: badge.url)) { phase in
                    if let img = phase.image { img.resizable().interpolation(.medium).scaledToFit() }
                    else { Color.clear.frame(width: 16) }
                }
                .frame(width: 16, height: 16)
            }
            Text(message.displayName + ":")
                .font(.system(size: 13, weight: .bold)).foregroundColor(message.color)
            ForEach(blocks) { block in
                switch block.content {
                case .text(let t):
                    Text(t).font(.system(size: 13))
                        .foregroundColor(message.isAction ? message.color : .tText)
                case .emote(let e): CachedEmoteImage(url: e.url, name: e.name)
                case .mention(let m):
                    Text("@\(m)").font(.system(size: 13, weight: .semibold)).foregroundColor(.tPrimary)
                case .link(let l):
                    Text(l).font(.system(size: 13))
                        .foregroundColor(.tOutplayer).underline()
                        .lineLimit(1).truncationMode(.middle)
                        .onTapGesture { openLink(l) }
                }
            }
        }
        .frame(width: availableWidth, alignment: .leading)
    }

    private func openLink(_ raw: String) {
        var s = raw
        if s.lowercased().hasPrefix("www.") { s = "https://" + s }
        if let url = URL(string: s) { UIApplication.shared.open(url) }
    }
}

struct TokenBlock: Identifiable { let id: Int; let content: MessageToken }

// MARK: – Flow Layout
struct MessageFlowLayout: Layout {
    var spacing, lineSpacing, width: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize { computeLayout(subviews).size }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let l = computeLayout(subviews)
        for (i, sub) in subviews.enumerated() {
            let p = l.positions[i]; let sz = l.sizes[i]
            sub.place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y + max(0,(l.lineHeights[i]-sz.height)/2)),
                      anchor: .topLeading,
                      proposal: ProposedViewSize(width: sz.width, height: sz.height))
        }
    }
    private func computeLayout(_ subviews: Subviews) -> (size: CGSize, positions: [CGPoint], lineHeights: [CGFloat], sizes: [CGSize]) {
        let W = max(width,1); var cx: CGFloat=0, cy: CGFloat=0, mh: CGFloat=0
        var pos=[CGPoint](); var sizes=[CGSize](); var lh=[CGFloat](repeating:0,count:subviews.count); var ls=0
        for (i,s) in subviews.enumerated() {
            var sz = s.sizeThatFits(.unspecified)
            // Capé à la largeur dispo : un token trop large (URL, mot long) est
            // re-mesuré borné pour ne jamais déborder du chat.
            if sz.width > W { sz = s.sizeThatFits(ProposedViewSize(width: W, height: nil)) }
            sizes.append(sz)
            if cx>0 && cx+sz.width>W { for j in ls..<i {lh[j]=mh}; cx=0; cy+=mh+lineSpacing; mh=0; ls=i }
            pos.append(CGPoint(x:cx,y:cy)); mh=max(mh,sz.height); cx+=sz.width+spacing
        }
        for j in ls..<subviews.count {lh[j]=mh}
        return (CGSize(width:W,height:cy+mh),pos,lh,sizes)
    }
}

// MARK: – Cached Emote Image
struct CachedEmoteImage: View {
    let url: String; let name: String
    var body: some View {
        AsyncImage(url: URL(string: url)) { phase in
            if let img = phase.image { img.resizable().interpolation(.medium).scaledToFit() }
            else if phase.error != nil { Text(name).font(.system(size:11)).foregroundColor(.tMuted) }
            else { Color.clear.frame(width:24,height:24) }
        }
        .frame(height: 24)
    }
}

// MARK: – Fil de discussion (thread + réponse)
struct ThreadSheet: View {
    let root: ChatMessage
    @ObservedObject var chat: ChatService
    let canSend: Bool
    let rootDisplayName: String

    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var replyText = ""
    @FocusState private var focused: Bool

    private var rootId: String { root.threadRootId ?? root.id }
    private var displayed: [ChatMessage] {
        let t = chat.threadMessages(rootId: rootId)
        return t.isEmpty ? [root] : t
    }
    private var canReply: Bool { !replyText.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            // ── En-tête ──────────────────────────────────────────────
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 15)).foregroundColor(.tPrimary)
                Text(store.t("thread_title"))
                    .font(.system(size: 16, weight: .bold)).foregroundColor(.tText)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .bold))
                        .foregroundColor(.tMuted).frame(width: 30, height: 30)
                        .background(Color.tSurface).clipShape(Circle())
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color.tCard)
            Divider().background(Color.tBorder)

            // ── Messages du fil ──────────────────────────────────────
            GeometryReader { geo in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(displayed) { m in
                            ChatMessageRow(message: m, availableWidth: geo.size.width)
                                .id(m.id)
                        }
                    }
                    .frame(width: geo.size.width, alignment: .leading)
                    .padding(.vertical, 4)
                }
            }

            // ── Réponse ──────────────────────────────────────────────
            if canSend {
                Divider().background(Color.tBorder)
                HStack(spacing: 8) {
                    TextField("\(store.t("thread_reply_to")) @\(rootDisplayName)", text: $replyText)
                        .focused($focused)
                        .foregroundColor(.tText)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(Color.tSurface).cornerRadius(10)
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .stroke(focused ? Color.tPrimary : Color.tBorder, lineWidth: 1))
                        .submitLabel(.send).onSubmit(sendReply)
                    Button(action: sendReply) {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 15, weight: .bold)).foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(canReply ? Color.tPrimary : Color.tMuted.opacity(0.35))
                            .cornerRadius(10)
                    }
                    .disabled(!canReply)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Color.tCard)
            }
        }
        .background(Color.tDark)
    }

    private func sendReply() {
        let t = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        replyText = ""
        Task {
            await chat.sendMessage(t, replyParentId: root.id,
                                   replyRootId: rootId, replyToName: rootDisplayName)
        }
    }
}
