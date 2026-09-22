import SwiftUI

// MARK: – Main Chat View
struct ChatView: View {
    let channelName: String
    let channelId: String?
    let token: String?
    let login: String?
    /// Décalage (s) appliqué aux messages reçus pour les recaler sur l'image.
    var chatDelay: Double = 0
    /// Mode « chat seul » : la vidéo est masquée, le parent en a besoin.
    @Binding var chatOnly: Bool
    /// Présentation : plein cadre, colonne étroite, ou calque sur l'image.
    var style: ChatStyle = .standard
    var onJoinChannel: (String) -> Void = { _ in }   // raid → bascule vers une autre chaîne

    @EnvironmentObject private var store: AppStore
    @StateObject private var chat          = ChatService()
    @StateObject private var pointsService = ChannelPointsService()
    @StateObject private var pubsub        = ChatPubSub()
    @StateObject private var follow        = FollowService()
    @StateObject private var events        = LiveEventsService()
    @StateObject private var raidService   = RaidService()

    @State private var autoScroll       = true
    @State private var messageText      = ""
    @State private var showEmotePicker  = false
    @State private var showChatMenu     = false
    @State private var showPointsSheet  = false
    @State private var showWebLogin     = false
    @State private var webLoginClear    = false   // true = re-login forcé (token web expiré)
    @State private var threadRoot: ChatMessage? = nil   // fil de discussion ouvert
    @State private var pinnedCollapsed  = false   // bandeau épinglé masqué/affiché
    @State private var isSetup          = false   // chat/points déjà initialisés
    @State private var teardownWork: DispatchWorkItem? = nil   // anti-rebond plein écran
    @FocusState private var isInputFocused: Bool

    @State private var emoteMatches: [TwitchEmote] = []   // autocomplétion en cours
    @State private var sentinelVisible = true   // le bas de la liste est-il visible ?
    @State private var isDragging      = false  // l'utilisateur fait-il défiler à la main ?

    private let bottomAnchor = "chat_bottom_anchor"   // sentinelle de bas de liste

    private var canSendMessages: Bool { token != nil && login != nil }
    private var canSend: Bool {
        chat.isConnected && chat.isAuthenticated &&
        !messageText.trimmingCharacters(in: .whitespaces).isEmpty &&
        messageText.count <= 500
    }

    /// Décor autour des messages : statut de connexion, épinglés, sondages,
    /// raids. En paysage la colonne est étroite et ce bandeau lui mangeait la
    /// moitié de la hauteur utile — d'où `ChatStyle.showsChrome`.
    @ViewBuilder private var chrome: some View {
        VStack(spacing: 0) {

            // ── Barre de statut ─────────────────────────────────────
            HStack(spacing: 6) {
                Circle()
                    .fill(chat.isConnected ? Color.tSuccess : Color.tDanger)
                    .frame(width: 6, height: 6)
                Text(chat.isConnected ? store.t("chat_connected") : store.t("chat_connecting"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.tMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                // Synchro auto : décalage appliqué au chat
                if chatDelay >= 0.5 {
                    HStack(spacing: 2) {
                        Image(systemName: "clock.arrow.2.circlepath").font(.system(size: 9))
                        Text(String(format: "%.0fs", chatDelay))
                            .font(.system(size: 10, weight: .bold).monospacedDigit())
                    }
                    .foregroundColor(.tOutplayer)
                    .fixedSize()
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Color.tOutplayer.opacity(0.15)).cornerRadius(6)
                }
                // Série de visionnage
                if store.showWatchStreak, events.watchStreak > 0 {
                    HStack(spacing: 2) {
                        Text("🔥").font(.system(size: 10))
                        Text("\(events.watchStreak)").font(.system(size: 10, weight: .bold))
                    }
                    .foregroundColor(.tWarning)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Color.tWarning.opacity(0.15)).cornerRadius(6)
                }
                // Bouton Suivre / Ne plus suivre
                if store.showFollowButton, let following = follow.isFollowing {
                    Button {
                        Task { await follow.toggle(token: store.twitchWebToken) }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: following ? "heart.fill" : "heart")
                            Text(following ? store.t("following") : store.t("follow"))
                                .font(.system(size: 10, weight: .bold))
                                .lineLimit(1)
                        }
                        .fixedSize()
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
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Text("#\(channelName)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.tPrimary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.tCard)
            .overlay(Divider().background(Color.tBorder), alignment: .bottom)

            // ── Message épinglé ─────────────────────────────────────
            if store.showPinnedMessages, let pin = pubsub.pinnedText {
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

            // ── Événements live (sondage / prédiction / hype train) ─
            if store.showLiveEvents {
                LiveEventsBanner(events: events)
            }

            // ── Raid sortant ────────────────────────────────────────
            if store.enableRaids, let r = raidService.raid {
                Button {
                    onJoinChannel(r.targetLogin)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "figure.run").font(.system(size: 13, weight: .bold))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("🚀 \(store.t("raid_to")) \(r.targetName)")
                                .font(.system(size: 12, weight: .bold)).foregroundColor(.tText)
                            if r.viewers > 0 {
                                Text("\(r.viewers) \(store.t("viewers"))")
                                    .font(.system(size: 10)).foregroundColor(.tMuted)
                            }
                        }
                        Spacer(minLength: 0)
                        Text(store.t("join")).font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Color.tPrimary).clipShape(Capsule())
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.tPrimary.opacity(0.12))
                    .overlay(Divider().background(Color.tBorder), alignment: .bottom)
                }
                .buttonStyle(.plain)
            }

        }
    }

    var body: some View {
        VStack(spacing: 0) {

            if style.showsChrome { chrome }

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
                    ScrollViewReader { proxy in
                        ZStack(alignment: .bottomTrailing) {
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 0) {
                                    ForEach(chat.messages.reversed()) { msg in
                                        ChatMessageRow(
                                            message: msg,
                                            availableWidth: geo.size.width,
                                            style: style
                                        )
                                        .id(msg.id)
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            guard msg.userId != "system" else { return }
                                            threadRoot = msg
                                        }
                                    }
                                    // Sentinelle de bas de liste : visible ⇒ on est en bas.
                                    Color.clear
                                        .frame(height: 1)
                                        .id(bottomAnchor)
                                        .onAppear {
                                            sentinelVisible = true
                                            autoScroll = true    // revenu en bas → on suit
                                        }
                                        .onDisappear {
                                            sentinelVisible = false
                                            // On NE coupe PAS le suivi ici : sinon une rafale
                                            // de messages (qui pousse brièvement la sentinelle
                                            // hors champ) l'activerait à tort. C'est le geste
                                            // de défilement manuel qui coupe le suivi.
                                        }
                                }
                                .frame(width: geo.size.width, alignment: .leading)
                                .padding(.vertical, 4)
                                // Peu de messages : ils se collent en bas comme
                                // sur Twitch, au lieu de flotter en haut d'un
                                // grand vide — criant posé sur l'image.
                                .frame(minHeight: geo.size.height, alignment: .bottom)
                            }
                            // Défilement manuel de l'utilisateur → on arrête de le ramener en bas.
                            .simultaneousGesture(
                                DragGesture(minimumDistance: 10)
                                    .onChanged { _ in
                                        isDragging = true
                                        if !sentinelVisible { autoScroll = false }
                                    }
                                    .onEnded { _ in isDragging = false }
                            )
                            .onChange(of: chat.messages.first?.id) { _ in
                                // Suit les nouveaux messages seulement si en bas et hors défilement
                                // manuel. Sans animation → re-cale instantané, la sentinelle reste
                                // visible même en rafale (n'active plus le mode lecture par erreur).
                                guard autoScroll, !isDragging else { return }
                                proxy.scrollTo(bottomAnchor, anchor: .bottom)
                            }
                            // En mode lecture (remonté), on met en pause la purge des vieux
                            // messages : sinon retirer les plus anciens (en haut) fait « descendre »
                            // la vue pendant qu'on lit l'historique.
                            .onChange(of: autoScroll) { chat.pauseTrim = !$0 }

                            if !autoScroll {
                                Button {
                                    autoScroll = true
                                    proxy.scrollTo(bottomAnchor, anchor: .bottom)
                                } label: {
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
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .top).combined(with: .opacity),
                    removal:   .move(edge: .top).combined(with: .opacity)
                ))
            }

            // ── Barre d'envoi ───────────────────────────────────────
            if canSendMessages { inputBar }
        }
        .task(id: messageText) { await refreshEmoteSuggestions() }
        // Superposé à l'image : pas de fond opaque, mais un dégradé qui assombrit
        // le bas de l'image, là où les messages s'accumulent. Sans lui, du texte
        // blanc sur une scène claire devient illisible.
        .background {
            if style.translucent {
                LinearGradient(colors: [.black.opacity(0.0), .black.opacity(0.55)],
                               startPoint: .top, endPoint: .bottom)
                    .allowsHitTesting(false)
            } else {
                Color.tDark
            }
        }
        // ── Fil de discussion (répondre) ─────────────────────────────
        .sheet(item: $threadRoot) { root in
            MessageSheet(message: root, chat: chat,
                         canSend: canSendMessages,
                         style: store.chatStyle(chrome: false, translucent: false),
                         onMention: { name in
                             messageText += (messageText.isEmpty || messageText.hasSuffix(" ")
                                             ? "" : " ") + "@\(name) "
                             isInputFocused = true
                         })
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        // ── Menu « … » du chat ───────────────────────────────────────
        .sheet(isPresented: $showChatMenu) {
            ChatMenuSheet(
                channelName: channelName,
                isAuthenticated: chat.isAuthenticated,
                chatOnly: $chatOnly,
                chat: chat,
                onReloadEmotes: { Task { await reloadEmotesAndBadges() } },
                onReconnect: {
                    chat.reconnect(token: token, login: login)
                }
            )
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
        .onChange(of: chatDelay) { chat.displayDelay = $0 }
        .onChange(of: raidService.joinTarget) { target in
            // Raid parti → on suit automatiquement vers la chaîne raidée.
            guard let target = target else { return }
            raidService.disconnect()
            onJoinChannel(target)
        }
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
                events.stop()
                raidService.disconnect()
                pointsService.stopPolling()
                // Cache emotes/badges : purge en quittant le live (si l'option est active).
                ImageCache.shared.purgeIfNeeded()
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
        chat.displayDelay = chatDelay
        // Réglés AVANT la connexion : c'est elle qui déclenche le rejeu de
        // l'historique, et la modération peut frapper dès les premières secondes.
        chat.loadRecent  = store.chatLoadRecent
        chat.keepDeleted = store.chatShowDeleted
        chat.connect(channel: channelName, token: token, login: login)

        // Les services ci-dessous sont conditionnés par les réglages de personnalisation :
        // on n'ouvre pas de sondage/websocket inutile si l'option est désactivée.
        // Messages épinglés (PubSub) — nécessite un token + l'ID du canal.
        if store.showPinnedMessages, let cid = channelId,
           let tok = store.twitchWebToken ?? store.twitchToken {
            pubsub.connect(channelId: cid, token: tok)
        }
        if let cid = channelId {
            // Statut de suivi (nécessite le token web pour le champ self.follower)
            if store.showFollowButton {
                await follow.load(login: channelName, channelId: cid, token: store.twitchWebToken)
            }
            // Événements live (série de visionnage, sondage, prédiction, hype train)
            if store.showWatchStreak || store.showLiveEvents {
                events.start(login: channelName, channelId: cid,
                             token: store.twitchWebToken,
                             viewerId: store.twitchUserId ?? "")
            }
            // Raid sortant (auto-bascule vers la chaîne raidée)
            if store.enableRaids {
                raidService.connect(channelId: cid, token: store.twitchWebToken ?? "")
            }
        }
    }

    /// Vide puis recharge emotes et badges du canal (menu du chat).
    private func reloadEmotesAndBadges() async {
        await EmoteService.shared.reset()
        await BadgeService.shared.reset()
        ImageCache.shared.purge()
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
        logger.success("CHAT", "Emotes et badges rechargés", "#\(channelName)")
    }

    // MARK: – Autocomplétion
    /// Dernier mot en cours de frappe. `@pseudo` cherche parmi les gens du chat,
    /// tout le reste parmi les emotes.
    private var currentWord: String {
        messageText.components(separatedBy: " ").last ?? ""
    }

    private var mentionSuggestions: [String] {
        let word = currentWord
        guard word.hasPrefix("@"), word.count > 1 else { return [] }
        let kw = String(word.dropFirst()).lowercased()
        // Les gens qui viennent d'écrire d'abord : c'est à eux qu'on répond.
        var seen = Set<String>()
        var out: [String] = []
        for m in chat.messages where !m.userName.isEmpty {
            if m.userName.lowercased().hasPrefix(kw), seen.insert(m.userName).inserted {
                out.append(m.displayName.isEmpty ? m.userName : m.displayName)
            }
            if out.count == 12 { break }
        }
        for login in chat.presentUsers.sorted() where out.count < 12 {
            if login.hasPrefix(kw), seen.insert(login).inserted { out.append(login) }
        }
        return out
    }

    /// EmoteService est un acteur : la recherche ne peut pas se faire dans le
    /// corps de la vue. On la relance à chaque frappe et on garde le résultat.
    private func refreshEmoteSuggestions() async {
        let word = currentWord
        guard store.chatAutocomplete, !word.hasPrefix("@"), word.count >= 2 else {
            emoteMatches = []
            return
        }
        emoteMatches = await EmoteService.shared.suggest(prefix: word, channelId: channelId)
    }

    @ViewBuilder
    private var autocompleteBar: some View {
        if store.chatAutocomplete, isInputFocused, !showEmotePicker {
            let emotes   = emoteMatches
            let mentions = mentionSuggestions
            if !emotes.isEmpty || !mentions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(mentions, id: \.self) { name in
                            suggestionChip { complete(with: "@" + name) } content: {
                                Text("@\(name)")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.tPrimary)
                            }
                        }
                        ForEach(emotes) { emote in
                            suggestionChip { complete(with: emote.name) } content: {
                                HStack(spacing: 5) {
                                    // animated: false — une rangée qui s'anime
                                    // pendant la frappe distrait plus qu'elle n'aide.
                                    CachedEmoteImage(url: emote.url, name: "", height: 20,
                                                     showsNameFallback: false, animated: false)
                                    Text(emote.name)
                                        .font(.system(size: 12)).foregroundColor(.tText)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                }
                .background(style.translucent ? Color.black.opacity(0.55) : Color.tSurface)
            }
        }
    }

    @ViewBuilder
    private func suggestionChip<C: View>(action: @escaping () -> Void,
                                         @ViewBuilder content: () -> C) -> some View {
        Button(action: action) {
            content()
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(height: 30)
                .background(Color.tCard)
                .cornerRadius(TRadius.chip)
        }
        .buttonStyle(.plain)
    }

    /// Remplace le mot en cours par la proposition retenue.
    private func complete(with replacement: String) {
        var words = messageText.components(separatedBy: " ")
        guard !words.isEmpty else { return }
        words[words.count - 1] = replacement
        messageText = words.joined(separator: " ") + " "
    }

    // MARK: – Input bar
    @ViewBuilder
    private var inputBar: some View {
        VStack(spacing: 0) {
            autocompleteBar
            if !style.translucent { Divider().background(Color.tBorder) }
            VStack(spacing: 4) {
                HStack(spacing: 6) {

                    // 🎁 Points de chaîne — le jeton prend de la place et n'a rien
                    // d'urgent : en colonne étroite il cède le pas au champ texte.
                    if style.showsChrome {
                        ChannelPointsButton(service: pointsService) {
                            showEmotePicker = false
                            showPointsSheet = true
                        }
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

                    // Menu « … » : actions du chat
                    Button {
                        isInputFocused = false
                        showChatMenu = true
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.tMuted)
                            // 44 pt : la cible tactile minimale d'Apple. À 32
                            // de large, coincé dans le coin, on le rate une fois sur deux.
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
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
            .padding(.horizontal, style.showsChrome ? 12 : 8)
            .padding(.top, style.showsChrome ? 8 : 4)
            .padding(.bottom, style.showsChrome ? 10 : 6)
            .background(style.translucent ? Color.black.opacity(0.45) : Color.tCard)
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
    var style: ChatStyle = .standard
    @EnvironmentObject private var store: AppStore

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
    private var timeString: String {
        message.vodOffsetLabel ?? Self.timeFormatter.string(from: message.timestamp)
    }

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
                                   availableWidth: availableWidth - 24,
                                   style: style)
                        .padding(.horizontal, 12)
                        .padding(.vertical, style.rowPadding)
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
        // Supprimé mais conservé : barré et estompé. Le texte reste lisible —
        // c'est tout l'intérêt du réglage — mais on voit qu'il a été retiré.
        .strikethrough(message.isDeleted, color: .tDanger.opacity(0.8))
        .opacity(message.isDeleted ? 0.55 : 1)
        // Sur l'image, une ombre portée fait tenir le texte clair au-dessus
        // d'une scène claire sans avoir à assombrir toute la vidéo.
        .shadow(color: .black.opacity(style.translucent ? 0.95 : 0), radius: 2, x: 0, y: 1)
    }
}

// MARK: – Wrapping HStack
struct WrappingHStack: View {
    let message: ChatMessage
    let timeString: String
    let availableWidth: CGFloat
    var style: ChatStyle = .standard

    var body: some View {
        let blocks = message.tokens.enumerated().map { i, t in TokenBlock(id: i, content: t) }
        let size = style.fontSize
        // Badges et emotes suivent le texte : à 11 pt ils ne doivent pas rester
        // à leur hauteur d'origine, sinon la ligne reste aussi haute qu'avant.
        let emoteHeight = style.emoteHeight
        MessageFlowLayout(spacing: 4, lineSpacing: 4, width: availableWidth) {
            if style.showsTimestamp {
                Text(timeString).font(.system(size: size - 2)).foregroundColor(.tMuted)
            }
            // Repêché dans l'historique : sans ce repère on croit avoir vu la
            // conversation se dérouler alors qu'elle a eu lieu avant l'arrivée.
            if message.isHistorical {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: size - 3)).foregroundColor(.tMuted)
            }
            ForEach(message.badges) { badge in
                CachedEmoteImage(url: badge.url, name: "", height: style.badgeHeight,
                                 showsNameFallback: false)
            }
            Text(message.displayName + ":")
                .font(.system(size: size, weight: .bold)).foregroundColor(message.color)
            ForEach(blocks) { block in
                switch block.content {
                case .text(let t):
                    Text(t).font(.system(size: size))
                        .foregroundColor(message.isAction ? message.color : .tText)
                case .emote(let e):
                    CachedEmoteImage(url: e.url, name: e.name, height: emoteHeight)
                case .mention(let m):
                    Text("@\(m)").font(.system(size: size, weight: .semibold)).foregroundColor(.tPrimary)
                case .link(let l):
                    Text(l).font(.system(size: size))
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
