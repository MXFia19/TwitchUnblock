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

            ScrollView {
            VStack(spacing: 12) {

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

                // ── Lecteur vidéo ───────────────────────────────────
                settingCard {
                    VStack(alignment: .leading, spacing: 14) {
                        label("play.tv.fill", store.t("player_section"))
                        toggleRow(store.t("low_latency"), store.t("low_latency_sub"),
                                  $store.lowLatency, log: "Mode faible latence")
                    }
                }

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

                Spacer(minLength: 32)
            }
            .padding(.horizontal, 12)
            }
        }
        .background(Color.tDark)
        .onAppear { refreshCacheInfo() }
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
