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
    /// Raid → bascule vers une autre chaîne. nil (multi-live) : pas de bascule,
    /// et la détection des raids continue (elle se coupait avant un no-op).
    var onJoinChannel: ((String) -> Void)? = nil
    /// « Voir la chaîne » dans la fiche d'une emote. Faux en multi-live : la
    /// mosaïque est plein écran, la page s'ouvrirait dessous.
    var opensChannelPages = true
    /// « Chat seul » dans le menu du chat. Faux en multi-live : il n'y a pas
    /// de lecteur à couper, l'interrupteur ne faisait rien.
    var allowsChatOnly = true

    @EnvironmentObject private var store: AppStore
    @StateObject private var chat          = ChatService()
    @StateObject private var pointsService = ChannelPointsService()
    @StateObject private var pubsub        = ChatPubSub()
    @StateObject private var dropsNotice   = ChannelDropsNotice()
    @StateObject private var follow        = FollowService()
    @StateObject private var events        = LiveEventsService()
    @StateObject private var raidService   = RaidService()

    @State private var autoScroll       = true
    @State private var messageText      = ""
    @State private var showEmotePicker  = false
    @State private var showChatMenu     = false
    /// Règles du chat à accepter avant le premier message, et ce message en attente.
    @State private var showRules        = false
    @State private var pendingMessage: String? = nil
    @State private var showPointsSheet  = false
    @State private var showWebLogin     = false
    @State private var webLoginClear    = false   // true = re-login forcé (token web expiré)
    @State private var threadRoot: ChatMessage? = nil   // fil de discussion ouvert
    @State private var pinnedExpanded   = false   // bandeau épinglé déplié
    @State private var dismissedPinId: String? = nil   // épingle réduite en pastille
    /// Sondages, prédictions et hype trains fermés (×), par `noticeKey` :
    /// gardés tant que ce chat vit (mini-lecteur, rotation compris).
    @State private var closedNotices: Set<String> = []
    /// « Ne plus suivre » touché : on demande d'abord confirmation.
    @State private var confirmUnfollow = false
    /// Emote ou badge touché : sa fiche (nom exact, source, copier).
    @State private var infoItem: ChatInfoItem? = nil
    @State private var chromeWidth: CGFloat = 320
    @State private var isSetup          = false   // chat/points déjà initialisés
    @State private var teardownWork: DispatchWorkItem? = nil   // anti-rebond plein écran
    /// Mise en place en cours : annulée au démontage, sans quoi les services
    /// lancés après ses attentes (PubSub, drops, événements, raid) restaient
    /// actifs pour une vue déjà fermée.
    @State private var setupTask: Task<Void, Never>? = nil
    @FocusState private var isInputFocused: Bool
    /// Clavier fermé par un toucher du chat : le même toucher n'ouvre ni le
    /// fil d'un message ni la fiche d'une emote ou d'un badge (les gestes
    /// arrivent dans un ordre variable, d'où ce délai).
    @State private var keyboardClosedAt = Date.distantPast

    @State private var emoteMatches: [TwitchEmote] = []   // autocomplétion en cours
    @State private var sentinelVisible = true   // le bas de la liste est-il visible ?
    @State private var isDragging      = false  // l'utilisateur fait-il défiler à la main ?

    private let bottomAnchor = "chat_bottom_anchor"   // sentinelle de bas de liste

    /// Faux aussi en lecture seule (compte banni de ce chat) : plus de champ,
    /// de sélecteur d'emotes, de réponse ni de commandes.
    private var canSendMessages: Bool { token != nil && login != nil && !chat.readOnly }
    private var canSend: Bool {
        chat.isConnected && chat.isAuthenticated &&
        !messageText.trimmingCharacters(in: .whitespaces).isEmpty &&
        messageText.count <= 500
    }

    /// Barre de statut au-dessus des messages : connexion, synchro, suivre,
    /// épingle réduite. En paysage la colonne est étroite et elle lui
    /// mangeait la hauteur utile — d'où `ChatStyle.showsChrome`. Les bandeaux
    /// (épinglé, drops, sondages, raid) sont à part : voir `notices`.
    @ViewBuilder private var chrome: some View {
        VStack(spacing: 0) {

            // ── Barre de statut ─────────────────────────────────────
            HStack(spacing: 6) {
                // Seul le point dit l'état de la connexion : la place va aux
                // pastilles utiles (synchro, série, suivre, épinglé).
                Circle()
                    .fill(chat.readOnly ? Color.tWarning : (chat.isConnected ? Color.tSuccess : Color.tDanger))
                    .frame(width: 7, height: 7)
                    .accessibilityLabel(chat.readOnly ? store.t("chat_ban_banner")
                                        : chat.isConnected ? store.t("chat_connected") : store.t("chat_connecting"))
                Spacer(minLength: 4)
                // Synchro auto : décalage appliqué au chat. Un appui le retouche
                // d'une seconde : le bon réglage dépend aussi du retard des
                // autres spectateurs, qu'on ne peut qu'estimer.
                if store.autoChatDelay, chatDelay >= 0.5 || store.chatSyncNudge != 0 {
                    Menu {
                        Section(store.t("chat_sync_hint")) {
                            Button { nudgeChatSync(1) } label: {
                                Label(store.t("chat_sync_later"), systemImage: "plus.circle")
                            }
                            Button { nudgeChatSync(-1) } label: {
                                Label(store.t("chat_sync_earlier"), systemImage: "minus.circle")
                            }
                            if store.chatSyncNudge != 0 {
                                Button { nudgeChatSync(0) } label: {
                                    Label(store.t("chat_sync_reset"), systemImage: "arrow.counterclockwise")
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: "clock.arrow.2.circlepath").font(.system(size: 9))
                            Text(String(format: "%.0fs", chatDelay))
                                .font(.system(size: 10, weight: .bold).monospacedDigit())
                            if store.chatSyncNudge != 0 {
                                Text(String(format: "(%+.0f)", store.chatSyncNudge))
                                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                                    .opacity(0.75)
                            }
                        }
                        .foregroundColor(.tOutplayer)
                        .fixedSize()
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Color.tOutplayer.opacity(0.15)).cornerRadius(6)
                    }
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
                // Bouton Suivre / Ne plus suivre. Juste sous la vidéo en
                // portrait, à portée de pouce : ne plus suivre se confirme
                // (sur Twitch avec la session web, et les notifications avec).
                if store.showFollowButton, let following = follow.isFollowing {
                    Button {
                        if follow.isFollowing == true {
                            confirmUnfollow = true
                            return
                        }
                        Task { @MainActor in
                            await follow.toggle(token: store.twitchWebToken)
                            // Suivie (aussi sur Twitch) : plus masquée des listes.
                            if follow.isFollowing == true { store.unhideChannel(channelName) }
                        }
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
                    .confirmationDialog(
                        store.t("unfollow_confirm").replacingOccurrences(of: "{c}", with: channelName),
                        isPresented: $confirmUnfollow, titleVisibility: .visible
                    ) {
                        // Action explicite, jamais une bascule : un statut relu
                        // entre-temps ne peut pas la changer en abonnement.
                        Button(store.t("unfollow"), role: .destructive) {
                            Task { @MainActor in await follow.unfollow(token: store.twitchWebToken) }
                        }
                        Button(store.t("follow_hide_button")) {
                            store.showFollowButton = false
                            logger.settingChanged("Bouton suivre", value: "désactivé")
                        }
                        Button(store.t("cancel"), role: .cancel) {}
                    } message: {
                        Text(store.t("follow_hide_hint"))
                    }
                }
                // Épingle réduite : une pastille la rouvre.
                if store.showPinnedMessages, let pin = pubsub.pinned, pin.id == dismissedPinId {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { dismissedPinId = nil }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "pin.fill").font(.system(size: 9))
                            Text(store.t("pinned_short")).font(.system(size: 10, weight: .bold))
                        }
                        .foregroundColor(.tPurple)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color.tPurple.opacity(0.15)).cornerRadius(6)
                    }
                    .fixedSize()
                }
                // Bandeaux fermés (×) : une seule pastille les rouvre tous.
                if !closedKinds.isEmpty {
                    ClosedNoticesChip(kinds: closedKinds, pollEnds: pollEnds,
                                      predictionEnds: predictionEnds,
                                      hypeEnds: hypeEnds) { reopenClosedNotices() }
                }
            }
            // Hauteur stable même quand seul le point est affiché.
            .frame(minHeight: 22)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { chromeWidth = g.size.width }
                    .onChange(of: g.size.width) { chromeWidth = $0 }
            })
            .background(Color.tCard)
            .overlay(Divider().background(Color.tBorder), alignment: .bottom)
        }
    }

    /// Bandeaux du salon : message épinglé, drops de la chaîne, sondages,
    /// prédictions, raid. Affichés aussi sans la barre de statut (chat en
    /// paysage, posé sur l'image) : avant, ils disparaissaient avec elle.
    @ViewBuilder private var notices: some View {
        VStack(spacing: 0) {
            // ── Message épinglé ─────────────────────────────────────
            // Replié, il garde sa place ; déplié, il s'affiche par-dessus le chat
            // au lieu de le pousser : le chat ne bouge pas et continue de défiler.
            if store.showPinnedMessages, let pin = pubsub.pinned, pin.id != dismissedPinId {
                PinnedBanner(pin: pin, width: chromeWidth, expanded: $pinnedExpanded, layoutOnly: true) {
                    withAnimation(.easeInOut(duration: 0.18)) { dismissedPinId = pin.id }
                }
                // La version dépliée est dessinée à la racine du chat (voir
                // `body`), calée sur cette ancre : un simple overlay restait
                // sous la liste du chat (vue UIKit).
                .anchorPreference(key: PinnedSlotKey.self, value: .bounds) { $0 }
                .transition(.opacity)
            }

            // ── Drops de la chaîne (carte à fermer) ─────────────────
            if store.showDropsNotice, let campaign = dropsNotice.campaign {
                DropsNoticeCard(campaign: campaign) {
                    withAnimation(.easeInOut(duration: 0.18)) { dropsNotice.dismiss(campaign) }
                }
                .transition(.opacity)
            }

            // ── Événements live (sondage / prédiction / hype train) ─
            if store.showLiveEvents {
                LiveEventsBanner(events: events, points: pointsService, closed: closedNotices) { key in
                    withAnimation(.easeInOut(duration: 0.18)) { _ = closedNotices.insert(key) }
                }
            }

            // ── Raid sortant ────────────────────────────────────────
            if store.enableRaids, let r = raidService.raid {
                Button {
                    onJoinChannel?(r.targetLogin)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "figure.run").font(.system(size: 13, weight: .bold))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("🚀 \(store.t("raid_to")) \(r.targetName)")
                                .font(.system(size: 12, weight: .bold)).foregroundColor(.tText)
                            if r.viewers > 0 {
                                Text("\(r.viewers) \(store.tn("viewers", r.viewers))")
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

    /// Bandeaux présents, dans l'ordre d'affichage (épingle réduite comprise).
    private var activeNotices: [ChatNoticeKind] {
        var kinds: [ChatNoticeKind] = []
        if store.showPinnedMessages, pubsub.pinned != nil { kinds.append(.pinned) }
        if store.showDropsNotice, dropsNotice.campaign != nil { kinds.append(.drops) }
        if store.showLiveEvents {
            if events.poll != nil { kinds.append(.poll) }
            if events.prediction != nil { kinds.append(.prediction) }
            if events.hype != nil { kinds.append(.hype) }
        }
        if store.enableRaids, raidService.raid != nil { kinds.append(.raid) }
        return kinds
    }

    /// Événements présents dont le bandeau a été fermé (×) : leur pastille.
    private var closedKinds: [ChatNoticeKind] {
        guard store.showLiveEvents, !closedNotices.isEmpty else { return [] }
        var kinds: [ChatNoticeKind] = []
        if let p = events.poll, closedNotices.contains(p.noticeKey) { kinds.append(.poll) }
        if let p = events.prediction, closedNotices.contains(p.noticeKey) { kinds.append(.prediction) }
        if let h = events.hype, closedNotices.contains(h.noticeKey) { kinds.append(.hype) }
        return kinds
    }

    /// Fin d'un sondage ou d'une prédiction encore ouverts (comptes à rebours
    /// des icônes).
    private var pollEnds: Date? { events.poll.flatMap { $0.isActive ? $0.endsAt : nil } }
    private var predictionEnds: Date? {
        events.prediction.flatMap { $0.locked || $0.winnerId != nil ? nil : $0.closesAt }
    }
    /// Fin de l'approche ou du niveau en cours (nil sur l'écran de fin).
    private var hypeEnds: Date? { events.hype?.endsAt }

    /// Clés des événements présents (sondage, prédiction, hype train).
    private var liveNoticeKeys: Set<String> {
        var keys: Set<String> = []
        if let p = events.poll { keys.insert(p.noticeKey) }
        if let p = events.prediction { keys.insert(p.noticeKey) }
        if let h = events.hype { keys.insert(h.noticeKey) }
        return keys
    }

    private func reopenClosedNotices() {
        withAnimation(.easeInOut(duration: 0.18)) { closedNotices = [] }
    }

    /// Les bandeaux, et en paysage (sans barre de statut) de quoi les replier :
    /// la colonne est étroite, un sondage et une prédiction la remplissaient.
    /// Repliés, ils tiennent sur une ligne d'icônes qui les rouvre ; le choix
    /// est retenu (Réglages → Personnaliser).
    @ViewBuilder private var noticesArea: some View {
        if style.showsChrome {
            notices
        } else if !activeNotices.isEmpty {
            if store.landscapeNoticesHidden {
                CollapsedNoticesBar(
                    kinds: activeNotices,
                    pollEnds: pollEnds,
                    predictionEnds: predictionEnds,
                    hypeEnds: hypeEnds
                ) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        dismissedPinId = nil
                        closedNotices = []
                        store.landscapeNoticesHidden = false
                    }
                }
                .transition(.opacity)
            } else {
                notices
                NoticesHideStrip(
                    // Sa pastille vit dans la barre de statut, absente ici.
                    showPinChip: pubsub.pinned.map { $0.id == dismissedPinId } ?? false,
                    onReopenPin: { withAnimation(.easeInOut(duration: 0.18)) { dismissedPinId = nil } },
                    closedKinds: closedKinds,
                    pollEnds: pollEnds,
                    predictionEnds: predictionEnds,
                    hypeEnds: hypeEnds,
                    onReopenClosed: { reopenClosedNotices() },
                    onHide: {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            pinnedExpanded = false
                            store.landscapeNoticesHidden = true
                        }
                    })
            }
        }
    }

    var body: some View {
        content
            // Message épinglé déplié : par-dessus tout le chat, à la place exacte
            // du bandeau replié, sans rien pousser.
            .overlayPreferenceValue(PinnedSlotKey.self) { anchor in
                GeometryReader { geo in
                    if pinnedExpanded, let anchor, store.showPinnedMessages,
                       let pin = pubsub.pinned, pin.id != dismissedPinId {
                        let r = geo[anchor]
                        PinnedBanner(pin: pin, width: r.width, expanded: $pinnedExpanded) {
                            withAnimation(.easeInOut(duration: 0.18)) { dismissedPinId = pin.id }
                        }
                        .frame(width: r.width)
                        .fixedSize(horizontal: false, vertical: true)
                        .shadow(color: .black.opacity(0.45), radius: 10, y: 6)
                        .offset(x: r.minX, y: r.minY)
                        .transition(.opacity)
                    }
                }
            }
            .sheet(item: $infoItem) { item in
                ChatInfoSheet(item: item, channelId: channelId,
                              onInsert: canSendMessages ? { (e: TwitchEmote) in insertEmote(e); infoItem = nil } : nil,
                              onOpenChannel: opensChannelPages ? { (login: String) in
                                  // Une seule feuille à la fois : la fiche se ferme
                                  // avant que la page s'ouvre (le lecteur se réduit).
                                  infoItem = nil
                                  DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                      store.openChannelPage(login)
                                  }
                              } : nil)
                    .environmentObject(store)
                    .inAppNoticeHost()
            }
            // Toucher une emote ou un badge (messages, épinglé) : sa fiche.
            .environment(\.chatInfoAction, { item in
                if closesKeyboard() { return }
                infoItem = item
            })
    }

    private var content: some View {
        VStack(spacing: 0) {

            if style.showsChrome { chrome }
            noticesArea

            // ── Zone principale ─────────────────────────────────────
            if showEmotePicker && canSendMessages {
                // Appui long sur une emote : sa fiche (le sélecteur est dans la
                // vue, pas dans une feuille : aucun conflit).
                EmotePickerView(channelId: channelId,
                                onSelect: { emote in insertEmote(emote) },
                                onInfo: { emote in infoItem = .emote(emote) })
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
                                    ForEach(chat.messages.reversed().filter { !store.isChatFiltered($0) }) { msg in
                                        ChatMessageRow(
                                            message: msg,
                                            availableWidth: geo.size.width,
                                            style: style,
                                            onOpenChannel: onJoinChannel ?? { _ in }
                                        )
                                        .id(msg.id)
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            // Clavier ouvert : ce toucher le ferme, sans plus.
                                            if closesKeyboard() { return }
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
                            // Clavier ouvert : faire glisser le chat vers le bas ou
                            // le toucher le referme, sans envoyer (Entrée était le
                            // seul moyen, au risque d'envoyer un brouillon).
                            .scrollDismissesKeyboard(.interactively)
                            .simultaneousGesture(TapGesture().onEnded {
                                _ = closesKeyboard()
                            })
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
                            // La zone du chat change de hauteur (clavier, rotation…) : on
                            // reste calé en bas si on suivait, sinon
                            // le bas sort de l'écran et le suivi semble s'arrêter.
                            .onChange(of: geo.size.height) { _ in
                                guard autoScroll else { return }
                                DispatchQueue.main.async { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
                            }
                            // Recréée à la fermeture du sélecteur d'emotes : elle
                            // repartait du haut (les plus vieux messages).
                            .onAppear {
                                guard autoScroll else { return }
                                DispatchQueue.main.async { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
                            }

                            if !autoScroll {
                                Button {
                                    autoScroll = true
                                    isDragging = false
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
            // Compte banni de ce chat : un bandeau à la place du champ.
            if chat.readOnly { readOnlyBar } else if canSendMessages { inputBar } else { anonymousBar }
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
                .inAppNoticeHost()
        }
        // ── Menu « … » du chat ───────────────────────────────────────
        .sheet(isPresented: $showRules) {
            ChatRulesSheet(channel: chat.channelName, rules: chat.rules) { closeRules(accepted: $0) }
                .environmentObject(store)
                .inAppNoticeHost()
        }
        .sheet(isPresented: $showChatMenu) {
            ChatMenuSheet(
                channelName: channelName,
                isAuthenticated: chat.isAuthenticated,
                chatOnly: $chatOnly,
                allowsChatOnly: allowsChatOnly,
                chat: chat,
                onReloadEmotes: { Task { await reloadEmotesAndBadges() } },
                onReconnect: {
                    chat.reconnect(token: token, login: login)
                },
                onUseCommand: canSendMessages ? { cmd in
                    messageText = cmd + " "
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { isInputFocused = true }
                } : nil
            )
            .presentationDetents([.medium, .large])
            .inAppNoticeHost()
        }
        // ── Sheet points ─────────────────────────────────────────────
        .sheet(isPresented: $showPointsSheet) {
            ChannelPointsSheet(service: pointsService) {
                // L'utilisateur demande à connecter son compte pour les points.
                // Session refusée (expirée, autre compte) : cookies effacés,
                // sinon la page reprenait aussitôt l'ancienne session.
                webLoginClear   = (pointsService.needsWebLogin && store.twitchWebToken != nil)
                    || store.webSessionExpired || store.webSessionMismatch != nil
                showPointsSheet = false
                // Délai : éviter le conflit « fermeture + ouverture » de sheets simultanées.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    showWebLogin = true
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.hidden)
            .inAppNoticeHost()
        }
        // ── Login web Twitch (capture du cookie auth-token) ──────────
        .sheet(isPresented: $showWebLogin) {
            TwitchWebLoginSheet(
                clearSession: webLoginClear,
                expectedLogin: store.twitchLogin,
                onComplete: { webToken, webLogin in
                    showWebLogin = false
                    // → déclenche onChange ci-dessous (refusée si autre compte)
                    Task { await store.adoptWebToken(webToken, login: webLogin) }
                },
                onCancel: { showWebLogin = false }
            )
            .inAppNoticeHost()
        }
        // ── Token web mis à jour → recharge les points et le suivi ───
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
            // Sans ça, le bouton gardait le mode d'avant (appareil ou compte)
            // et ne faisait plus rien, en silence.
            // Bouton masqué : statut oublié, relu quand on le réactive.
            if store.showFollowButton { Task { await loadFollow() } } else { follow.reset() }
            // Pronostics, sondages, série et raid gardaient le jeton du
            // démarrage : parier répondait « connecte ta session ».
            if store.showWatchStreak || store.showLiveEvents {
                events.start(login: channelName, channelId: cid, token: newWebToken,
                             viewerId: store.twitchUserId ?? "", hype: store.showLiveEvents)
            }
            if store.enableRaids { raidService.connect(channelId: cid, token: newWebToken ?? "") }
        }
        // Bouton Suivre réactivé pendant le live : il revient tout de suite.
        .onChange(of: store.showFollowButton) { show in
            guard show, follow.isFollowing == nil else { return }
            Task { await loadFollow() }
        }
        // Événement terminé : sa fermeture (×) est oubliée, le suivant
        // s'affiche même s'il reprend la même clé (id absent).
        .onChange(of: liveNoticeKeys) { keys in
            closedNotices.formIntersection(keys)
        }
        // Événements masqués ou réaffichés pendant le live : le relevé du
        // hype train (toutes les 5 s pendant une approche) suit.
        .onChange(of: store.showLiveEvents) { events.setHypeEnabled($0) }
        // ── Compte changé → reconnecte uniquement l'IRC ───────────────
        // Jeton et login arrivent l'un après l'autre : on attend les deux
        // (la reconnexion partait sans login, en anonyme, champ grisé). À la
        // déconnexion, retour en anonyme (il restait sous l'ancien pseudo).
        .onChange(of: "\(store.twitchToken ?? "")|\(store.twitchLogin ?? "")") { _ in
            guard let tok = store.twitchToken else {
                logger.info("CHAT", "Compte déconnecté → chat en anonyme", nil)
                chat.connect(channel: channelName, token: nil, login: nil)
                return
            }
            guard let login = store.twitchLogin, !login.isEmpty else { return }
            logger.info("CHAT", "Token OAuth mis à jour → reconnexion IRC",
                        String(tok.prefix(8)) + "…")
            chat.connect(channel: channelName, token: tok, login: login)
        }
        .onChange(of: store.autoClaimChest) { pointsService.autoClaim = $0 }
        .onChange(of: chatDelay) { chat.displayDelay = $0 }
        .onChange(of: raidService.joinTarget) { target in
            // Raid parti → on suit automatiquement vers la chaîne raidée.
            guard let target = target, store.enableRaids, let join = onJoinChannel else { return }
            raidService.disconnect()
            join(target)
        }
        .onAppear {
            // Annule un éventuel teardown différé (retour de plein écran).
            teardownWork?.cancel(); teardownWork = nil
            guard !isSetup else { return }   // déjà initialisé → pas de double connexion
            isSetup = true
            setupTask = Task { await setupChat() }
        }
        .onDisappear { scheduleTeardown(after: 0.6) }
    }

    /// Le passage en plein écran (AVPlayerViewController) ou en PiP déclenche
    /// un onDisappear transitoire : on ne coupe rien tant qu'il dure (le retour
    /// annule ce démontage, voir onAppear). Mais on attend sa fin au lieu
    /// d'abandonner — une vue vraiment détruite pendant le PiP (raid suivi)
    /// gardait IRC, points et minuteries jusqu'à la fermeture de l'app.
    private func scheduleTeardown(after delay: Double, fullscreenSeen: Bool = false) {
        let work = DispatchWorkItem {
            if PlayerFullscreen.isActive { scheduleTeardown(after: 1, fullscreenSeen: true); return }
            // Plein écran fini : une vue qui revient réapparaît d'abord
            // (onAppear annule ce démontage) — on lui en laisse le temps.
            if fullscreenSeen { scheduleTeardown(after: 0.8); return }
            setupTask?.cancel(); setupTask = nil
            chat.disconnect()
            pubsub.disconnect()
            dropsNotice.stop()
            if let cid = channelId { Task { await BTTVLive.shared.leave(channelId: cid) } }
            events.stop()
            raidService.disconnect()
            pointsService.stopPolling()
            // Cache emotes/badges : purge en quittant le live (si l'option est active).
            ImageCache.shared.purgeIfNeeded()
            isSetup = false
        }
        teardownWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Mise en place toujours voulue : pas démontée entre-temps (tâche annulée).
    private var setupWanted: Bool { isSetup && !Task.isCancelled }

    // MARK: – Setup initial
    private func setupChat() async {
        // Emotes (globales, de la chaîne) et badges en parallèle avant la
        // connexion : les messages sont découpés en emotes à la réception, le
        // premier et l'historique doivent les trouver. Mais 3,5 s au plus :
        // l'un après l'autre et sans délai propre, un service lent ou bloqué
        // laissait le champ sur « Connecting… ». Le reste arrive derrière.
        let cid = channelId, name = channelName, tok = token
        // Salon déjà refusé à ce compte pendant la séance : bandeau d'emblée.
        chat.prepare(channel: channelName, login: login)
        let assets = Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await EmoteService.shared.loadGlobals() }
                // Sans compte : BadgeService passe par la requête GQL publique.
                group.addTask { await BadgeService.shared.loadGlobal(token: tok) }
                if let cid {
                    group.addTask { await EmoteService.shared.loadChannel(channelId: cid, channelName: name) }
                    group.addTask { await BadgeService.shared.loadChannel(channelId: cid, token: tok) }
                }
            }
        }
        let ready = await finishes(assets, within: 3.5)
        if !ready { logger.warn("CHAT", "Emotes et badges encore en chargement après 3,5 s", "connexion sans les attendre") }
        // Chat refermé pendant l'attente : pas de connexion orpheline (de même
        // après chaque attente ci-dessous).
        guard setupWanted else { return }
        pointsService.autoClaim = store.autoClaimChest
        chat.channelId = channelId
        chat.displayDelay = chatDelay
        // Réglés AVANT la connexion : c'est elle qui déclenche le rejeu de
        // l'historique, et la modération peut frapper dès les premières secondes.
        chat.loadRecent  = store.chatLoadRecent
        chat.keepDeleted = store.chatShowDeleted
        chat.connect(channel: channelName, token: token, login: login)

        if let cid = channelId {
            // BTTV en direct : emotes personnelles (Pro), emotes ajoutées en live.
            await BTTVLive.shared.join(channelId: cid)
            // Démonté pendant l'attente : son départ (leave) est passé avant
            // l'arrivée — la chaîne n'était jamais quittée.
            guard setupWanted else { await BTTVLive.shared.leave(channelId: cid); return }
            // Points : on utilise le token de session web (cookie auth-token), pas l'OAuth.
            // Si absent, load() affiche quand même les récompenses et signale needsWebLogin.
            await pointsService.load(
                channelLogin: channelName,
                channelId:   cid,
                token:       store.twitchWebToken ?? "",
                userLogin:   login,
                viewerId:    store.twitchUserId
            )
            guard setupWanted else { pointsService.stopPolling(); return }
        }

        // Les services ci-dessous sont conditionnés par les réglages de personnalisation :
        // on n'ouvre pas de sondage/websocket inutile si l'option est désactivée.
        // Messages épinglés (PubSub) — nécessite un token + l'ID du canal.
        // Lecture publique : plus besoin d'être connecté pour les voir.
        if store.showPinnedMessages, let cid = channelId {
            pubsub.connect(channelId: cid)
        }
        // Drops de la chaîne : lecture publique, une carte à fermer.
        if store.showDropsNotice, let cid = channelId {
            dropsNotice.start(channelId: cid)
        }
        if let cid = channelId {
            // Statut de suivi (nécessite le token web pour le champ self.follower)
            if store.showFollowButton { await loadFollow() }
            guard setupWanted else { pubsub.disconnect(); dropsNotice.stop(); return }
            // Événements live (série de visionnage, sondage, prédiction, hype train)
            if store.showWatchStreak || store.showLiveEvents {
                events.start(login: channelName, channelId: cid,
                             token: store.twitchWebToken,
                             viewerId: store.twitchUserId ?? "",
                             hype: store.showLiveEvents)
            }
            // Raid sortant (auto-bascule vers la chaîne raidée)
            if store.enableRaids {
                raidService.connect(channelId: cid, token: store.twitchWebToken ?? "")
            }
        }
    }

    /// Statut de suivi : celui du compte avec la session web (champ
    /// self.follower), sinon le suivi gardé sur cet appareil.
    private func loadFollow() async {
        guard let cid = channelId else { return }
        if store.twitchWebToken == nil {
            follow.loadLocal(login: channelName, store: store)
        } else {
            await follow.load(login: channelName, channelId: cid, token: store.twitchWebToken)
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
        // Sans compte : BadgeService passe par la requête GQL publique.
        await BadgeService.shared.loadGlobal(token: token)
        if let cid = channelId {
            await BadgeService.shared.loadChannel(channelId: cid, token: token)
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
                out.append(m.displayName.lowercased() == m.userName.lowercased() ? m.displayName : m.userName)
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
    /// Sans compte : une fine barre avec le menu ⋯ (chat seul, recharger les
    /// emotes, reconnecter, commandes) — il n'existait qu'avec un compte.
    private var anonymousBar: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            Button {
                showChatMenu = true
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.tMuted)
                    .frame(width: 44, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 6)
        .background(style.translucent ? Color.black.opacity(0.45) : Color.tCard)
    }

    private var inputBar: some View {
        VStack(spacing: 0) {
            autocompleteBar
            if !style.translucent { Divider().background(Color.tBorder) }
            VStack(spacing: 4) {
                roomModesLine
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
                                // Retour au clavier, comme l'icône le promet.
                                isInputFocused = true
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
                    // Suggestions et correction d'iOS : la barre de mots
                    // proposés n'apparaît qu'avec elles (réglage du chat).
                    .autocorrectionDisabled(!store.chatKeyboardSuggestions)
                    .autocapitalization(.sentences)
                    .foregroundColor(.tText)
                    // Entrée ferme le clavier, le bouton ➤ envoie (réglage
                    // « Entrée envoie le message » pour l'inverse).
                    .submitLabel(store.chatReturnSends ? .send : .done)
                    .onSubmit {
                        if store.chatReturnSends { sendMessage() } else { isInputFocused = false }
                    }
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

    /// Lecture seule : Twitch refuse le compte dans ce chat (banni), le chat
    /// continue sans lui. Twitch ne prévient pas d'un déban sur l'IRC, d'où
    /// le bouton qui retente avec le compte. Le menu « … » reste à portée.
    private var readOnlyBar: some View {
        VStack(spacing: 0) {
            if !style.translucent { Divider().background(Color.tBorder) }
            HStack(spacing: 8) {
                Image(systemName: "nosign").font(.system(size: 12, weight: .bold))
                Text(store.t("chat_ban_banner"))
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    chat.reconnect(token: token, login: login)
                } label: {
                    Text(store.t("chat_ban_retry"))
                        .font(.system(size: 12, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.tWarning.opacity(0.18))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                Button {
                    showChatMenu = true
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.tMuted)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .foregroundColor(.tWarning)
            .padding(.leading, style.showsChrome ? 12 : 8)
            .padding(.trailing, style.showsChrome ? 4 : 2)
            .padding(.vertical, 2)
            .background(Color.tWarning.opacity(0.14))
            .accessibilityElement(children: .contain)
            .background(style.translucent ? Color.black.opacity(0.45) : Color.tCard)
        }
    }

    /// Modes du salon qui limitent qui peut écrire, au-dessus du champ : on le
    /// sait avant d'écrire, plutôt qu'en voyant son message refusé.
    @ViewBuilder private var roomModesLine: some View {
        let m = chat.roomModes
        if !m.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if let minutes = m.followersMinutes {
                        modeChip("person.2.fill", minutes > 0
                                 ? store.t("chat_mode_followers_min")
                                     .replacingOccurrences(of: "{d}", with: ChatRoomModes.duration(minutes, lang: store.lang))
                                 : store.t("chat_mode_followers"))
                    }
                    if m.subsOnly { modeChip("star.fill", store.t("chat_mode_subs")) }
                    if m.emoteOnly { modeChip("face.smiling", store.t("chat_mode_emotes")) }
                    if m.slowSeconds > 0 {
                        modeChip("tortoise.fill", store.t("chat_mode_slow").replacingOccurrences(of: "{s}", with: "\(m.slowSeconds)"))
                    }
                    if m.uniqueChat { modeChip("square.on.square", store.t("chat_mode_unique")) }
                    if m.verifiedOnly { modeChip("checkmark.seal.fill", store.t("chat_mode_verified")) }
                }
            }
        }
    }

    private func modeChip(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10, weight: .bold))
            Text(text).font(.system(size: 11, weight: .semibold)).lineLimit(1)
        }
        .foregroundColor(.tWarning)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color.tWarning.opacity(0.14))
        .clipShape(Capsule())
    }

    // MARK: – Actions
    /// Ferme le clavier s'il était ouvert, ou s'il vient de l'être par ce
    /// même toucher. Vrai : le toucher n'a rien d'autre à faire.
    private func closesKeyboard() -> Bool {
        if isInputFocused {
            isInputFocused = false
            keyboardClosedAt = Date()
            return true
        }
        return Date().timeIntervalSince(keyboardClosedAt) < 0.35
    }

    private func sendMessage() {
        let trimmed = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 500 else { return }
        // Règles du chat pas encore acceptées (comme sur Twitch) : elles
        // d'abord, le message part une fois acceptées.
        if !chat.rules.isEmpty, !ChatRules.accepted(chat.channelName, rules: chat.rules) {
            pendingMessage = trimmed
            isInputFocused = false
            showRules = true
            return
        }
        messageText = ""; autoScroll = true
        Task { await chat.sendMessage(trimmed) }
    }

    private func closeRules(accepted: Bool) {
        showRules = false
        defer { pendingMessage = nil }
        guard accepted, let text = pendingMessage else { return }
        ChatRules.accept(chat.channelName, rules: chat.rules)
        messageText = ""; autoScroll = true
        Task { await chat.sendMessage(text) }
    }

    private func insertEmote(_ emote: TwitchEmote) {
        messageText += (messageText.isEmpty || messageText.hasSuffix(" ") ? "" : " ")
            + emote.name + " "
    }

    /// Retouche de la synchro auto (pastille de la barre de statut) : ±1 s,
    /// ou 0 pour revenir à l'estimation seule.
    private func nudgeChatSync(_ step: Double) {
        let v = step == 0 ? 0 : min(20, max(-20, store.chatSyncNudge + step))
        store.chatSyncNudge = v
        logger.settingChanged("Retouche de la synchro du chat", value: String(format: "%+.0f s", v))
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
    /// Raid entrant : ouvrir la chaîne d'où vient le raid.
    var onOpenChannel: (String) -> Void = { _ in }
    @EnvironmentObject private var store: AppStore

    /// Mentionné (avec ou sans @) ou mot surveillé (réglages) : surligné.
    private var isMention: Bool {
        guard message.systemMsg == nil, message.userId != "system" else { return false }
        let me = store.twitchLogin?.lowercased() ?? ""
        guard message.userName.lowercased() != me || me.isEmpty else { return false }
        let words = store.chatHighlightWords
        guard !me.isEmpty || !words.isEmpty else { return false }
        if !me.isEmpty {
            for token in message.tokens {
                switch token {
                case .mention(let m):
                    // « @pseudo, » : la ponctuation collée restait dans le nom.
                    let w = m.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "@.,!?:;"))
                    if w == me { return true }
                case .text(let t):
                    let w = t.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "@.,!?:;"))
                    if w == me { return true }
                default: break
                }
            }
        }
        guard !words.isEmpty else { return false }
        // Mots surveillés : cherchés dans tout le message, noms d'emotes
        // compris, entre frontières de mots — un mot de plusieurs mots
        // (« giveaway gratuit ») ou une emote (« KEKW ») ne déclenchait jamais.
        let flat = Self.normalized(message.tokens.map { token -> String in
            switch token {
            case .text(let t):    return t
            case .emote(let e):   return e.name
            case .mention(let m): return m
            case .link(let l):    return l
            case .gif:            return ""
            }
        }.joined(separator: " "))
        return words.contains { w in
            let n = Self.normalized(w)
            return !n.isEmpty && " \(flat) ".contains(" \(n) ")
        }
    }

    /// Minuscules, ponctuation changée en espaces, espaces simples :
    /// « Giveaway, GRATUIT ! » → « giveaway gratuit ».
    private static func normalized(_ s: String) -> String {
        let mapped = String(s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " })
        return mapped.split(separator: " ").joined(separator: " ")
    }

    /// Heure du message, 12 h ou 24 h (Réglages → Chat, « auto » : l'appareil).
    private static let time24: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = ClockFormat.pattern(twelve: false); return f
    }()
    private static let time12: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = ClockFormat.pattern(twelve: true); return f
    }()
    private var timeString: String {
        message.vodOffsetLabel ?? (store.clock12h ? Self.time12 : Self.time24).string(from: message.timestamp)
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

            // Raid entrant : carte avec un lien vers la chaîne qui arrive.
            if message.noticeKind == "raid", let sys = message.systemMsg {
                HStack(spacing: 8) {
                    Image(systemName: "person.3.fill").font(.system(size: 11)).foregroundColor(.tPurple)
                    Text(sys).font(.system(size: 12, weight: .semibold)).foregroundColor(.tText)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if let raider = message.raider {
                        Button { onOpenChannel(raider) } label: {
                            Text(store.t("see_channel")).font(.system(size: 11, weight: .bold))
                                .foregroundColor(.tPurple)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Color.tPurple.opacity(0.18)).cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Color.tPurple.opacity(0.14))
                .cornerRadius(8)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .frame(width: availableWidth, alignment: .leading)
            }
            // Bannière USERNOTICE (abonnement, série de visionnage…)
            else if let sys = message.systemMsg {
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
                    if let accent = message.accent { Rectangle().fill(accent).frame(width: 3) }
                    else if isMention { Rectangle().fill(Color.tPrimary).frame(width: 3) }
                    else if message.isHighlight { Rectangle().fill(Color.tWarning).frame(width: 3) }
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
            message.accent != nil  ? (message.accent ?? .clear).opacity(0.16) :
            isMention              ? Color.tPrimary.opacity(0.14) :
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
    /// Fiche d'une emote ou d'un badge touché (fournie par le chat).
    @Environment(\.chatInfoAction) private var infoAction

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
                    .chatInfoTap(infoAction, .badge(badge))
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
                        .chatInfoTap(infoAction, .emote(e))
                case .mention(let m):
                    Text("@\(m)").font(.system(size: size, weight: .semibold)).foregroundColor(.tPrimary)
                case .link(let l):
                    Text(l).font(.system(size: size))
                        .foregroundColor(.tOutplayer).underline()
                        .lineLimit(1).truncationMode(.middle)
                        .onTapGesture { openLink(l) }
                case .gif(let url, let alt):
                    // GIF du clavier GIF de Twitch : sur sa propre ligne,
                    // comme dans l'app Twitch (son texte, s'il ne charge pas).
                    CachedEmoteImage(url: url, name: alt, height: min(140, availableWidth * 0.45),
                                     maxWidth: availableWidth)
                        .frame(width: availableWidth, alignment: .leading)
                }
            }
        }
        .frame(width: availableWidth, alignment: .leading)
    }

    private func openLink(_ raw: String) {
        var s = raw
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") { s = "https://" + s }
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

/// Position du bandeau épinglé replié, pour y caler la version dépliée.
private struct PinnedSlotKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

// MARK: – Règles du chat
/// Règles de la chaîne, à accepter avant d'écrire (comme sur Twitch).
struct ChatRulesSheet: View {
    let channel: String
    let rules: [String]
    let done: (Bool) -> Void
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(store.t("chat_rules_title").replacingOccurrences(of: "{c}", with: channel),
                  systemImage: "list.bullet.rectangle")
                .font(.tSection).foregroundColor(.tText)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(rules.enumerated()), id: \.offset) { _, rule in
                        Text(rule)
                            .font(.tBody).foregroundColor(.tText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack(spacing: 12) {
                Button(store.t("cancel")) { done(false) }
                    .foregroundColor(.tMuted)
                Spacer()
                Button {
                    done(true)
                } label: {
                    Text(store.t("chat_rules_accept"))
                        .font(.tLabel).foregroundColor(.white)
                        .padding(.horizontal, 18).frame(height: 40)
                        .background(Color.tPrimary)
                        .cornerRadius(10)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.tDark.ignoresSafeArea())
        .presentationDetents([.medium, .large])
    }
}

/// Attend `work` au plus `seconds` secondes ; au-delà, il continue sans nous.
/// true s'il a fini à temps.
private func finishes(_ work: Task<Void, Never>, within seconds: Double) async -> Bool {
    await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
        let gate = FirstResume(cont)
        Task { await work.value; gate.resume(true) }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            gate.resume(false)
        }
    }
}

/// Reprend une attente une seule fois : le premier arrivé l'emporte.
private final class FirstResume {
    private let lock = NSLock()
    private var cont: CheckedContinuation<Bool, Never>?
    init(_ cont: CheckedContinuation<Bool, Never>) { self.cont = cont }
    func resume(_ value: Bool) {
        lock.lock()
        let c = cont
        cont = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}
