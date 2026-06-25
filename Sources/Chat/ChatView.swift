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

    @State private var autoScroll       = true
    @State private var messageText      = ""
    @State private var showEmotePicker  = false
    @State private var showPointsSheet  = false
    @State private var isReauthing      = false
    @State private var reauthAttempts   = 0   // évite les boucles infinies
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
                Text(chat.isConnected ? "Chat connecté" : "Connexion...")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.tMuted)
                Spacer()
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
                                    Text("Suivre").font(.system(size: 11, weight: .bold))
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
        // ── Sheet points ─────────────────────────────────────────────
        .sheet(isPresented: $showPointsSheet) {
            ChannelPointsSheet(service: pointsService)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.hidden)
        }
        // ── Re-auth quand le service détecte un 401 ──────────────────
        .onChange(of: pointsService.needsReauth) { needsReauth in
            guard needsReauth, !isReauthing, reauthAttempts < 2 else {
                if reauthAttempts >= 2 {
                    logger.error("AUTH", "Impossible de rafraîchir le token après 2 tentatives",
                                 "Reconnecte-toi manuellement via Paramètres")
                }
                return
            }
            Task { await handleTokenRefresh() }
        }
        // ── Quand le token change dans le store (après re-auth) ───────
        // Un seul endroit qui recharge les points — pas d'appel double
        .onChange(of: store.twitchToken) { newToken in
            guard let tok = newToken, let cid = channelId else { return }
            logger.info("POINTS", "Token mis à jour → rechargement",
                        String(tok.prefix(8)) + "…")
            Task {
                await pointsService.load(
                    channelLogin: channelName,
                    channelId:   cid,
                    token:       tok,
                    userLogin:   store.twitchLogin   // login déjà mis à jour avant le token
                )
                // Re-connecter IRC avec le nouveau token
                chat.connect(channel: channelName, token: tok, login: store.twitchLogin)
            }
        }
        .onAppear { Task { await setupChat() } }
        .onDisappear {
            chat.disconnect()
            pointsService.stopPolling()
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
        if let tok = token, let cid = channelId {
            await pointsService.load(
                channelLogin: channelName,
                channelId:   cid,
                token:       tok,
                userLogin:   login
            )
        }
        chat.channelId = channelId
        chat.connect(channel: channelName, token: token, login: login)
    }

    // MARK: – Re-auth automatique
    // Stratégie :
    //   Tentative 1 (reauthAttempts=0) → force_verify: false (silencieux)
    //   Tentative 2 (reauthAttempts=1) → force_verify: true  (re-login visible)
    // Après 2 échecs → message d'erreur, l'utilisateur doit se reconnecter manuellement
    private func handleTokenRefresh() async {
        guard !isReauthing else { return }
        isReauthing = true
        reauthAttempts += 1

        let forceVerify = reauthAttempts > 1
        logger.info("AUTH",
                    "Re-auth automatique (tentative \(reauthAttempts)/2)",
                    forceVerify ? "force_verify: true (re-login visible)" : "force_verify: false (silencieux)")

        guard let newToken = await TwitchAuthManager.shared.login(forceVerify: forceVerify) else {
            logger.warn("AUTH", "Re-auth annulée ou échouée",
                        "tentative \(reauthAttempts)")
            isReauthing = false
            return
        }

        // ── 1. Récupérer le login AVANT de mettre à jour le token ────
        //    (évite l'état partiel où twitchToken est mis à jour mais twitchLogin est encore nil)
        var userLogin = store.twitchLogin
        if userLogin == nil {
            if let user = await getTwitchUser(token: newToken) {
                userLogin = user.login
                store.twitchUserId = user.id
                // Définit le login d'abord (pas de onChange dessus dans ChatView)
                store.twitchLogin = userLogin
            }
        }

        logger.success("AUTH", "Nouveau token obtenu (tentative \(reauthAttempts))",
                       String(newToken.prefix(8)) + "… · @\(userLogin ?? "?")")

        // ── 2. Mettre à jour le token → déclenche onChange(store.twitchToken) ──
        //    onChange est le seul endroit qui recharge les points (pas d'appel double)
        store.twitchToken = newToken

        // ── 3. Réinitialiser le flag pour permettre de futurs re-auths ──
        isReauthing = false
        // NOTE : reauthAttempts n'est pas réinitialisé ici pour éviter les boucles
        // Il se réinitialise à la prochaine session (nouvelle instance de ChatView)
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
                        chat.isConnected ? "Envoyer un message…" : "Connexion en cours…",
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
}

// MARK: – Single Message Row
struct ChatMessageRow: View {
    let message: ChatMessage
    let availableWidth: CGFloat

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
    private var timeString: String { Self.timeFormatter.string(from: message.timestamp) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            if message.isFirstMessage {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles").font(.system(size: 10, weight: .bold))
                    Text("Premier message").font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(.tPurple)
                .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 4)
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

            HStack(alignment: .top, spacing: 0) {
                if message.isHighlight { Rectangle().fill(Color.tWarning).frame(width: 3) }
                WrappingHStack(message: message, timeString: timeString,
                               availableWidth: availableWidth - 24)
                    .padding(.horizontal, 12).padding(.vertical, 4)
            }
            .frame(width: availableWidth, alignment: .leading)
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
                }
            }
        }
        .frame(width: availableWidth, alignment: .leading)
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
            let p = l.positions[i]; let sz = sub.sizeThatFits(.unspecified)
            sub.place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y + max(0,(l.lineHeights[i]-sz.height)/2)),
                      anchor: .topLeading, proposal: .unspecified)
        }
    }
    private func computeLayout(_ subviews: Subviews) -> (size: CGSize, positions: [CGPoint], lineHeights: [CGFloat]) {
        let W = max(width,1); var cx: CGFloat=0, cy: CGFloat=0, mh: CGFloat=0
        var pos=[CGPoint](); var lh=[CGFloat](repeating:0,count:subviews.count); var ls=0
        for (i,s) in subviews.enumerated() {
            let sz=s.sizeThatFits(.unspecified)
            if cx>0 && cx+sz.width>W { for j in ls..<i {lh[j]=mh}; cx=0; cy+=mh+lineSpacing; mh=0; ls=i }
            pos.append(CGPoint(x:cx,y:cy)); mh=max(mh,sz.height); cx+=sz.width+spacing
        }
        for j in ls..<subviews.count {lh[j]=mh}
        return (CGSize(width:W,height:cy+mh),pos,lh)
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
