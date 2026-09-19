import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showLogs        = false
    @State private var showLogoutAlert = false
    @State private var showClearAlert  = false
    @State private var showWebLogin    = false   // login web (points de chaîne)
    @State private var webLoginClear   = false
    @State private var apiLoggingIn    = false
    @State private var cacheBytes: Int64 = 0
    @State private var cacheFiles      = 0
    @ObservedObject private var sleepTimer = SleepTimerService.shared
    @ObservedObject private var usage      = UsageService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showSleepSheet  = false

    private var vodCount:     Int { store.history.filter { $0.type == .vod }.count }
    private var channelCount: Int { store.history.filter { $0.type == .channel }.count }

    var body: some View {
        VStack(spacing: 0) {

            // ── En-tête de la feuille ───────────────────────────────
            HStack(spacing: TSpace.md) {
                Text(store.t("settings"))
                    .font(.tScreenTitle)
                    .foregroundColor(.tText)
                Spacer()
                TIconButton(icon: "xmark") { dismiss() }
            }
            .padding(.horizontal, TSpace.lg)
            .padding(.top, TSpace.lg)
            .padding(.bottom, TSpace.md)
            .background(Color.tDark)

            // Une page par domaine, plutôt qu'un rouleau unique : la liste
            // avait atteint douze cartes, et on ne retrouvait plus rien.
            NavigationStack {
                ScrollView {
                    VStack(spacing: 12) {
                        settingCard {
                            VStack(spacing: 0) {
                                menuRow("person.crop.circle", store.t("twitch_account"),
                                        .account)
                            }
                        }
                        settingCard {
                            VStack(spacing: 0) {
                                menuRow("gearshape.fill", store.t("sec_general"), .general)
                                Divider().background(Color.tBorder)
                                menuRow("play.tv.fill", store.t("sec_player"), .player)
                                Divider().background(Color.tBorder)
                                menuRow("bubble.left.fill", store.t("sec_chat"), .chat)
                            }
                        }
                        settingCard {
                            VStack(spacing: 0) {
                                menuRow("info.circle.fill", store.t("sec_other"), .other)
                            }
                        }
                        Spacer(minLength: 32)
                    }
                    .padding(.horizontal, 12)
                }
                .background(Color.tDark)
                .navigationDestination(for: Page.self) { section in
                    sectionPage(section)
                }
            }
        }
        .background(Color.tDark)
        .onAppear {
            refreshCacheInfo()
            Task { await usage.loadStats() }
        }
        // Retrait du comptage → on efface aussi l'identifiant côté serveur.
        .onChange(of: store.shareUsage) { on in
            Task {
                if on { await usage.ping(enabled: true, force: true) }
                else  { await usage.forget() }
                await usage.loadStats()
            }
        }
        // ── Alerts ──────────────────────────────────────────────────
        .alert(store.t("btn_logout"), isPresented: $showLogoutAlert) {
            Button(store.t("cancel"), role: .cancel) {}
            Button(store.t("btn_logout"), role: .destructive) {
                logger.authLogout()
                store.logout()
            }
        } message: {
            Text(store.t("confirm_logout"))
        }
        .alert(store.t("btn_clear"), isPresented: $showClearAlert) {
            Button(store.t("cancel"), role: .cancel) {}
            Button(store.t("erase"), role: .destructive) {
                logger.historyCleared()
                store.history = []
            }
        } message: {
            Text(store.t("confirm"))
        }
        // ── Login web Twitch (cookie auth-token pour les points) ─────
        .sheet(isPresented: $showWebLogin) {
            TwitchWebLoginSheet(
                clearSession: webLoginClear,
                onComplete: { webToken, webLogin in
                    showWebLogin = false
                    if store.twitchLogin == nil, let l = webLogin { store.twitchLogin = l }
                    store.twitchWebToken = webToken
                    logger.success("AUTH/WEB", "Session web connectée depuis les réglages", nil)
                },
                onCancel: { showWebLogin = false }
            )
        }
        // ── Minuteur de veille (préréglages + durée personnalisée) ───
        .sheet(isPresented: $showSleepSheet) {
            SleepTimerSheet()
                .presentationDetents([.medium, .large])
        }
        // ── Logs sheet ───────────────────────────────────────────────
        .sheet(isPresented: $showLogs) {
            VStack(spacing: 0) {
                HStack {
                    HStack(spacing: 8) {
                        Image(systemName: "terminal.fill")
                            .foregroundColor(.tPrimary)
                        Text("Logs")
                            .font(.tSection).foregroundColor(.tText)
                    }
                    Spacer()
                    Button("Fermer") { showLogs = false }
                        .foregroundColor(.tPrimary).fontWeight(.semibold)
                }
                .padding(16)
                .background(Color.tCard)
                .overlay(Divider().background(Color.tBorder), alignment: .bottom)
                LogsView()
            }
            .background(Color.tDark)
        }
    }


    // MARK: – Pages de réglages
    /// Les cinq destinations du menu.
    enum Page: Hashable { case account, general, player, chat, other

        var titleKey: String {
            switch self {
            case .account: return "twitch_account"
            case .general: return "sec_general"
            case .player:  return "sec_player"
            case .chat:    return "sec_chat"
            case .other:   return "sec_other"
            }
        }
    }

    @ViewBuilder
    private func menuRow(_ icon: String, _ title: String, _ section: Page) -> some View {
        NavigationLink(value: section) {
            HStack(spacing: TSpace.md) {
                Image(systemName: icon)
                    .font(.system(size: 15)).foregroundColor(.tPrimary)
                    .frame(width: 26)
                Text(title).font(.tCardTitle).foregroundColor(.tText)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(.tMuted)
            }
            .padding(.vertical, TSpace.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func sectionPage(_ section: Page) -> some View {
        ScrollView {
            VStack(spacing: 12) {
                // Une vue par ligne : dans un ViewBuilder, deux vues séparées
                // par un point-virgule sur la même ligne ne se composent pas.
                switch section {
                case .account:
                    compteCard
                    usageCard
                case .general:
                    langueCard
                    autoclaimCard
                    veilleCard
                    historiqueCard
                    cacheCard
                case .player:
                    lecteurCard
                    debugCard
                case .chat:
                    chatBehaviorCard
                    persoCard
                    tailleChatCard
                case .other:
                    aboutCard
                }
                Spacer(minLength: 32)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
        }
        .background(Color.tDark)
        .navigationTitle(store.t(section.titleKey))
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private var langueCard: some View {
        // ── Langue ──────────────────────────────────────────
        settingCard {
            VStack(alignment: .leading, spacing: 12) {
                label("globe", store.t("language"))
                VStack(spacing: 8) {
                    ForEach(Lang.allCases) { lang in
                        langButton(lang)
                    }
                }
            }
        }
    }

    @ViewBuilder private var autoclaimCard: some View {
        // ── Auto-claim coffres ──────────────────────────────
        settingCard {
            VStack(alignment: .leading, spacing: 8) {
                label("gift.fill", store.t("auto_claim"))
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.t("auto_claim"))
                            .font(.tCardTitle)
                            .foregroundColor(.tText)
                        Text(store.t("auto_claim_sub"))
                            .font(.tMeta)
                            .foregroundColor(.tMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("", isOn: $store.autoClaimChest)
                        .labelsHidden()
                        .tint(.tPrimary)
                        .onChange(of: store.autoClaimChest) { val in
                            logger.settingChanged("Auto-claim coffres", value: val ? "activé" : "désactivé")
                        }
                }
            }
        }
    }

    @ViewBuilder private var persoCard: some View {
        // ── Personnalisation chat & lecteur ─────────────────
        settingCard {
            VStack(alignment: .leading, spacing: 14) {
                label("paintbrush.fill", store.t("customize"))
                toggleRow(store.t("cfg_pinned"), store.t("cfg_pinned_sub"),
                          $store.showPinnedMessages, log: "Messages épinglés")
                Divider().background(Color.tBorder)
                toggleRow(store.t("cfg_follow"), store.t("cfg_follow_sub"),
                          $store.showFollowButton,   log: "Bouton suivre")
                Divider().background(Color.tBorder)
                toggleRow(store.t("cfg_streak"), store.t("cfg_streak_sub"),
                          $store.showWatchStreak,    log: "Série de visionnage")
                Divider().background(Color.tBorder)
                toggleRow(store.t("cfg_events"), store.t("cfg_events_sub"),
                          $store.showLiveEvents,     log: "Événements live")
                Divider().background(Color.tBorder)
                toggleRow(store.t("cfg_raids"),  store.t("cfg_raids_sub"),
                          $store.enableRaids,        log: "Système de raid")
            }
        }
    }

    @ViewBuilder private var chatBehaviorCard: some View {
        // ── Comportement du chat ────────────────────────────
        settingCard {
            VStack(alignment: .leading, spacing: 14) {
                label("bubble.left.and.bubble.right.fill", store.t("chat_behavior"))
                toggleRow(store.t("cfg_recent"), store.t("cfg_recent_sub"),
                          $store.chatLoadRecent, log: "Messages récents")
                Divider().background(Color.tBorder)
                toggleRow(store.t("cfg_autocomplete"), store.t("cfg_autocomplete_sub"),
                          $store.chatAutocomplete, log: "Autocomplétion")
                Divider().background(Color.tBorder)
                toggleRow(store.t("cfg_deleted"), store.t("cfg_deleted_sub"),
                          $store.chatShowDeleted, log: "Messages supprimés")
            }
        }
    }

    @ViewBuilder private var tailleChatCard: some View {
        // ── Taille du chat ──────────────────────────────────
        // La bonne taille dépend de l'écran, de la distance de lecture et
        // de la vue de chacun : un aperçu en direct évite l'aller-retour
        // « je règle, je ferme, je regarde, je reviens ».
        settingCard {
            VStack(alignment: .leading, spacing: 14) {
                label("textformat.size", store.t("chat_sizing"))

                chatPreview

                Divider().background(Color.tBorder)
                toggleRow(store.t("cfg_timestamps"), store.t("cfg_timestamps_sub"),
                          $store.chatTimestamps, log: "Horodatage du chat")
                Divider().background(Color.tBorder)

                sliderRow(store.t("cfg_font_size"), value: $store.chatFontSize,
                          range: 10...20, step: 1) { String(format: "%.0f pt", $0) }
                sliderRow(store.t("cfg_msg_spacing"), value: $store.chatSpacing,
                          range: 0...16, step: 1) { String(format: "%.0f px", $0) }
                sliderRow(store.t("cfg_badge_scale"), value: $store.chatBadgeScale,
                          range: 0.5...2, step: 0.05) { String(format: "%.2fx", $0) }
                sliderRow(store.t("cfg_emote_scale"), value: $store.chatEmoteScale,
                          range: 0.5...2, step: 0.05) { String(format: "%.2fx", $0) }
                sliderRow(store.t("cfg_chat_width"), value: $store.chatWidthRatio,
                          range: 0.20...0.60, step: 0.01) { String(format: "%.0f %%", $0 * 100) }

                Text(store.t("cfg_chat_width_sub"))
                    .font(.tMeta).foregroundColor(.tMuted)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    store.chatFontSize   = 13
                    store.chatSpacing    = 8
                    store.chatBadgeScale = 1
                    store.chatEmoteScale = 1
                    store.chatWidthRatio = 0.32
                    store.chatTimestamps = true
                } label: {
                    Text(store.t("reset_defaults"))
                        .font(.tLabel).foregroundColor(.tPrimary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder private var lecteurCard: some View {
        // ── Lecteur vidéo ───────────────────────────────────
        settingCard {
            VStack(alignment: .leading, spacing: 14) {
                label("play.tv.fill", store.t("player_section"))
                toggleRow(store.t("immersive_player"), store.t("immersive_player_sub"),
                          $store.immersivePlayer, log: "Lecteur immersif")
                Divider().background(Color.tBorder)
                toggleRow(store.t("low_latency"), store.t("low_latency_sub"),
                          $store.lowLatency, log: "Mode faible latence")
            }
        }
    }

    @ViewBuilder private var veilleCard: some View {
        // ── Minuteur de veille ──────────────────────────────
        // Les durées (préréglages + durée personnalisée) sont réglées dans
        // la même feuille que depuis le lecteur : une seule UI à maintenir.
        settingCard {
            VStack(alignment: .leading, spacing: 12) {
                label("moon.zzz.fill", store.t("sleep_timer"))
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        if sleepTimer.isActive {
                            Text(store.t("sleep_remaining"))
                                .font(.tMeta).foregroundColor(.tMuted)
                            Text(sleepTimer.label)
                                .font(.system(size: 26, weight: .bold).monospacedDigit())
                                .foregroundColor(.tPurple)
                        } else {
                            Text(store.t("sleep_timer_sub"))
                                .font(.tMeta).foregroundColor(.tMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 8)
                    Button { showSleepSheet = true } label: {
                        Text(sleepTimer.isActive ? store.t("sleep_edit")
                                                 : store.t("sleep_set"))
                            .font(.tLabel)
                            .foregroundColor(.tPrimary)
                            .fixedSize()
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Color.tPrimary.opacity(0.15))
                            .cornerRadius(8)
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.tPrimary, lineWidth: 1))
                    }
                }
            }
        }
    }

    @ViewBuilder private var cacheCard: some View {
        // ── Cache emotes & badges ───────────────────────────
        settingCard {
            VStack(alignment: .leading, spacing: 14) {
                label("externaldrive.fill", store.t("cache_section"))
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.t("cache_size"))
                            .font(.tCardTitle)
                            .foregroundColor(.tText)
                        Text("\(cacheSizeText) · \(cacheFiles) \(store.t("cache_files"))")
                            .font(.tMeta)
                            .foregroundColor(.tMuted)
                    }
                    Spacer(minLength: 8)
                    Button {
                        ImageCache.shared.purge()
                        refreshCacheInfo()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "trash")
                            Text(store.t("cache_clear"))
                                .font(.tLabel)
                        }
                        .foregroundColor(.tDanger)
                        .fixedSize()
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Color.tDanger.opacity(0.15))
                        .cornerRadius(8)
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.tDanger, lineWidth: 1))
                    }
                    .disabled(cacheBytes == 0)
                    .opacity(cacheBytes == 0 ? 0.4 : 1)
                }
                Divider().background(Color.tBorder)
                toggleRow(store.t("cache_auto"), store.t("cache_auto_sub"),
                          $store.autoPurgeImageCache, log: "Purge auto du cache")
            }
        }
    }

    @ViewBuilder private var compteCard: some View {
        // ── Compte Twitch ───────────────────────────────────
        settingCard {
            VStack(alignment: .leading, spacing: 14) {
                label("person.crop.circle.fill", store.t("twitch_account"))

                // Connexion API (OAuth) — chat + chaînes suivies
                accountRow(
                    title: store.t("account_api"),
                    sub: store.t("account_api_sub"),
                    connected: store.twitchToken != nil,
                    busy: apiLoggingIn,
                    actionLabel: store.twitchToken != nil ? store.t("btn_logout")
                                                          : store.t("btn_login_twitch")
                ) {
                    if store.twitchToken != nil { showLogoutAlert = true }
                    else { Task { await handleApiLogin() } }
                }

                Divider().background(Color.tBorder)

                // Session web — points de chaîne (cookie auth-token)
                accountRow(
                    title: store.t("account_web"),
                    sub: store.t("account_web_sub"),
                    connected: store.twitchWebToken != nil,
                    busy: false,
                    actionLabel: store.twitchWebToken != nil ? store.t("btn_logout")
                                                             : store.t("points_connect_btn")
                ) {
                    if store.twitchWebToken != nil {
                        logger.info("AUTH/WEB", "Déconnexion session web", nil)
                        store.twitchWebToken = nil
                    } else {
                        startWebLogin()
                    }
                }
            }
        }
    }

    @ViewBuilder private var historiqueCard: some View {
        // ── Historique ──────────────────────────────────────
        settingCard {
            VStack(alignment: .leading, spacing: 12) {
                label("chart.bar.fill", store.t("history"))
                HStack(spacing: TSpace.sm) {
                    statBox(value: vodCount, label: store.t("vods"), icon: "film")
                    statBox(value: channelCount, label: store.t("channels"), icon: "person.fill")
                }
                if vodCount > 0 || channelCount > 0 {
                    TSecondaryButton(title: store.t("btn_clear"), icon: "trash",
                                     tint: .tDanger, fullWidth: true) {
                        showClearAlert = true
                    }
                }
            }
        }
    }

    @ViewBuilder private var usageCard: some View {
        // ── Utilisation de l'app ────────────────────────────
        settingCard {
            VStack(alignment: .leading, spacing: 14) {
                label("chart.line.uptrend.xyaxis", store.t("usage_section"))

                if usage.loading {
                    TLoader()
                } else if let s = usage.stats {
                    HStack(spacing: TSpace.sm) {
                        statBox(value: s.today, label: store.t("usage_today"),
                                icon: "sun.max.fill")
                        statBox(value: s.week,  label: store.t("usage_week"),
                                icon: "calendar")
                        statBox(value: s.month, label: store.t("usage_month"),
                                icon: "calendar.badge.clock")
                    }

                    // Fidélité : la question n'est pas « combien ont
                    // installé » mais « combien reviennent ».
                    if s.loyalty.total > 0 {
                        Divider().background(Color.tBorder)
                        loyaltyBlock(s)
                    }

                    if !s.versions.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(store.t("usage_versions"))
                                .font(.tMeta).foregroundColor(.tMuted)
                            ForEach(Array(s.versions.prefix(4))) { v in
                                HStack {
                                    Text(v.version)
                                        .font(.tLabel).foregroundColor(.tText)
                                    Spacer()
                                    Text("\(v.count)")
                                        .font(.tLabel).foregroundColor(.tPrimary)
                                }
                            }
                        }
                    }
                } else if usage.lastError == "worker_missing" {
                    Text(store.t("usage_worker_missing"))
                        .font(.tMeta).foregroundColor(.tWarning)
                        .fixedSize(horizontal: false, vertical: true)
                } else if usage.lastError != nil {
                    Text(store.t("usage_error"))
                        .font(.tMeta).foregroundColor(.tMuted)
                } else {
                    Text(store.t("usage_tap_refresh"))
                        .font(.tMeta).foregroundColor(.tMuted)
                }

                TSecondaryButton(title: store.t("usage_refresh"),
                                 icon: "arrow.clockwise", fullWidth: true) {
                    Task { await usage.loadStats() }
                }

                Divider().background(Color.tBorder)

                toggleRow(store.t("usage_share"), store.t("usage_share_sub"),
                          $store.shareUsage, log: "Partage d'utilisation")
            }
        }
    }

    @ViewBuilder private var debugCard: some View {
        // ── Débogage (temporaire) ───────────────────────────
        settingCard {
            VStack(alignment: .leading, spacing: 14) {
                label("wrench.and.screwdriver.fill", store.t("debug_section"))
                Text(store.t("debug_note"))
                    .font(.tMeta)
                    .foregroundColor(.tMuted)
                    .fixedSize(horizontal: false, vertical: true)
                toggleRow(store.t("dbg_latency"), store.t("dbg_latency_sub"),
                          $store.showLatency,   log: "Afficher la latence")
                Divider().background(Color.tBorder)
                toggleRow(store.t("dbg_chat_delay"), store.t("dbg_chat_delay_sub"),
                          $store.autoChatDelay, log: "Synchro auto du chat")
            }
        }
    }

    @ViewBuilder private var aboutCard: some View {
        // ── À propos / Logs ─────────────────────────────────
        settingCard {
            VStack(alignment: .leading, spacing: 12) {
                label("info.circle.fill", store.t("about"))
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("TwitchUnblock")
                            .font(.tSection)
                            .foregroundColor(.tText)
                        Text(store.t("version"))
                            .font(.tMeta)
                            .foregroundColor(.tMuted)
                    }
                    Spacer()
                    Circle().fill(Color.tPrimary).frame(width: 26, height: 26)
                }
                Text(store.t("about_desc"))
                    .font(.tMeta)
                    .foregroundColor(.tMuted)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    showLogs = true
                } label: {
                    HStack(spacing: TSpace.sm) {
                        Image(systemName: "terminal")
                            .font(.system(size: 13, weight: .semibold))
                        Text(store.t("show_logs")).font(.tLabel)
                        Spacer()
                        Text("\(AppLogger.shared.logs.count)")
                            .font(.tBadge)
                            .foregroundColor(.white)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.tPrimary)
                            .cornerRadius(8)
                    }
                    .foregroundColor(.tPrimary)
                    .padding(.horizontal, TSpace.md)
                    .frame(height: 44)
                    .background(Color.tPrimary.opacity(0.12))
                    .cornerRadius(TRadius.control)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: – Fidélité des installations
    @ViewBuilder
    private func loyaltyBlock(_ s: UsageStats) -> some View {
        VStack(alignment: .leading, spacing: TSpace.sm) {
            HStack {
                Text(store.t("usage_returning"))
                    .font(.tCardTitle).foregroundColor(.tText)
                Spacer()
                Text("\(s.returning) / \(s.known)  ·  \(s.returnRate) %")
                    .font(.tLabel).foregroundColor(.tPrimary)
            }

            // Une ligne par tranche, avec la barre ET le chiffre : la longueur
            // seule se compare mal quand les effectifs sont petits.
            loyaltyRow(store.t("usage_loyalty_once"),    s.loyalty.once,    s.loyalty.total, .tMuted)
            loyaltyRow(store.t("usage_loyalty_few"),     s.loyalty.few,     s.loyalty.total, .tOutplayer)
            loyaltyRow(store.t("usage_loyalty_regular"), s.loyalty.regular, s.loyalty.total, .tPurple)
            loyaltyRow(store.t("usage_loyalty_daily"),   s.loyalty.daily,   s.loyalty.total, .tSuccess)

            HStack(spacing: TSpace.md) {
                TMeta(icon: "calendar",
                      text: "\(store.t("usage_avg_days")) \(String(format: "%.1f", s.avgDays))")
                if let first = s.oldestFirst {
                    TMeta(icon: "clock.arrow.circlepath",
                          text: "\(store.t("usage_since")) \(first)")
                }
            }
            .padding(.top, 2)
        }
    }

    @ViewBuilder
    private func loyaltyRow(_ title: String, _ value: Int,
                            _ total: Int, _ tint: Color) -> some View {
        let ratio = total > 0 ? Double(value) / Double(total) : 0
        HStack(spacing: TSpace.sm) {
            Text(title)
                .font(.tMeta).foregroundColor(.tMuted)
                .frame(width: 92, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.tSurface)
                    Capsule().fill(tint)
                        .frame(width: max(value > 0 ? 4 : 0, geo.size.width * ratio))
                }
            }
            .frame(height: 8)

            Text("\(value)")
                .font(.tLabel).foregroundColor(value > 0 ? .tText : .tMuted)
                .frame(width: 28, alignment: .trailing)
        }
    }

    // MARK: – Cache
    private var cacheSizeText: String {
        ByteCountFormatter.string(fromByteCount: cacheBytes, countStyle: .file)
    }

    /// Lit la taille du cache hors du thread principal (parcours de dossier).
    private func refreshCacheInfo() {
        Task.detached(priority: .utility) {
            let bytes = ImageCache.shared.diskSize()
            let files = ImageCache.shared.fileCount()
            await MainActor.run { cacheBytes = bytes; cacheFiles = files }
        }
    }

    // MARK: – Actions login
    private func handleApiLogin() async {
        apiLoggingIn = true
        defer { apiLoggingIn = false }
        if let token = await TwitchAuthManager.shared.login() {
            store.twitchToken = token
            logger.success("AUTH", "Connexion API réussie", nil)
        }
    }

    private func startWebLogin() {
        // Re-login forcé seulement si un token existe déjà mais est invalide.
        webLoginClear = false
        showWebLogin = true
    }

    // MARK: – Aperçu du chat
    /// Deux lignes factices rendues par le vrai `ChatMessageRow` : ce qu'on voit
    /// ici est exactement ce que donnera le chat.
    private static let previewMessages: [ChatMessage] = [
        ChatMessage(id: "p1", userId: "0", userName: "lewdolas", displayName: "Lewdolas",
                    color: .tWarning, badges: [],
                    tokens: [.text("ça"), .text("va"), .text("y'a"), .text("des"),
                             .text("sourires")],
                    timestamp: Date()),
        ChatMessage(id: "p2", userId: "0", userName: "damonarix", displayName: "Damonarix",
                    color: .tOutplayer, badges: [],
                    tokens: [.text("L'honnêteté"), .text("d'un"), .text("Skaven"),
                             .mention("toi")],
                    timestamp: Date()),
    ]

    @ViewBuilder
    private var chatPreview: some View {
        let style = store.chatStyle(chrome: false, translucent: false)
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Self.previewMessages) { msg in
                    ChatMessageRow(message: msg, availableWidth: geo.size.width,
                                   style: style)
                }
            }
            .frame(width: geo.size.width, alignment: .leading)
        }
        // Hauteur tenue à la main : un GeometryReader n'en propose aucune. Large
        // de quatre lignes, pour le cas où les deux messages passent à la ligne
        // aux plus grosses tailles ; `clipped` évite tout débordement.
        .frame(height: store.chatFontSize * 4 + store.chatSpacing * 2 + 20)
        .clipped()
        .padding(TSpace.sm)
        .background(Color.tDark)
        .cornerRadius(TRadius.chip)
    }

    @ViewBuilder
    private func sliderRow(_ title: String, value: Binding<Double>,
                           range: ClosedRange<Double>, step: Double,
                           format: @escaping (Double) -> String) -> some View {
        VStack(spacing: 2) {
            HStack {
                Text(title).font(.tCardTitle).foregroundColor(.tText)
                Spacer()
                Text(format(value.wrappedValue))
                    .font(.tMeta.monospacedDigit()).foregroundColor(.tMuted)
            }
            Slider(value: value, in: range, step: step).tint(.tPrimary)
        }
    }

    // MARK: – Subviews
    @ViewBuilder
    private func settingCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .tCard()
    }

    @ViewBuilder
    private func toggleRow(_ title: String, _ sub: String,
                           _ isOn: Binding<Bool>, log: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.tCardTitle)
                    .foregroundColor(.tText)
                Text(sub)
                    .font(.tMeta)
                    .foregroundColor(.tMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(.tPrimary)
                .onChange(of: isOn.wrappedValue) { v in
                    logger.settingChanged(log, value: v ? "activé" : "désactivé")
                }
        }
    }

    @ViewBuilder
    private func accountRow(title: String, sub: String, connected: Bool, busy: Bool,
                           actionLabel: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: connected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 17))
                .foregroundColor(connected ? .tSuccess : .tMuted)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.tCardTitle)
                    .foregroundColor(.tText)
                Text(connected ? store.t("connected") : sub)
                    .font(.tMeta)
                    .foregroundColor(connected ? .tSuccess : .tMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(action: action) {
                Group {
                    if busy {
                        ProgressView().tint(.tPrimary)
                    } else {
                        Text(actionLabel).font(.tLabel)
                    }
                }
                .foregroundColor(connected ? .tDanger : .tPrimary)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background((connected ? Color.tDanger : Color.tPrimary).opacity(0.15))
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(connected ? Color.tDanger : Color.tPrimary, lineWidth: 1))
            }
            .disabled(busy)
        }
    }

    /// Titre d'une carte de réglages.
    @ViewBuilder
    private func label(_ icon: String, _ text: String) -> some View {
        HStack(spacing: TSpace.sm) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.tPrimary)
            Text(text)
                .font(.tSection)
                .foregroundColor(.tText)
        }
    }

    @ViewBuilder
    private func langButton(_ lang: Lang) -> some View {
        let isSelected = store.lang == lang
        Button {
            logger.settingChanged("Langue", value: lang.rawValue)
            store.lang = lang
        } label: {
            HStack(spacing: 12) {
                Text(lang.flag).font(.system(size: 22))
                Text(lang.label)
                    .font(.tCardTitle)
                    .foregroundColor(isSelected ? .tPrimary : .tText)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.tPrimary)
                        .font(.system(size: 18))
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(isSelected ? Color.tPrimary.opacity(0.12) : Color.tSurface)
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(isSelected ? Color.tPrimary : Color.tBorder, lineWidth: isSelected ? 1.5 : 1))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func statBox(value: Int, label: String, icon: String) -> some View {
        VStack(spacing: TSpace.xs) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(.tMuted)
            Text("\(value)")
                .font(.system(size: 26, weight: .bold))
                .foregroundColor(.tPrimary)
            Text(label)
                .font(.tMeta)
                .foregroundColor(.tMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, TSpace.lg)
        .background(Color.tSurface)
        .cornerRadius(TRadius.control)
    }
}
