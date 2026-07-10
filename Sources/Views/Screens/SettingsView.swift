import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @AppStorage("liveSource") private var liveSource: LiveSource = .auto
    @State private var showLogs        = false
    @State private var showLogoutAlert = false
    @State private var showClearAlert  = false
    @State private var showWebLogin    = false   // login web (points de chaîne)
    @State private var webLoginClear   = false
    @State private var apiLoggingIn    = false

    private var vodCount:     Int { store.history.filter { $0.type == .vod }.count }
    private var channelCount: Int { store.history.filter { $0.type == .channel }.count }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {

                // ── Header ──────────────────────────────────────────
                HStack(spacing: 10) {
                    Text("⚙️")
                        .font(.system(size: 28))
                    Text(store.t("settings"))
                        .font(.system(size: 26, weight: .heavy))
                        .foregroundColor(.tPurple)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                // ── Source vidéo ─────────────────────────────────────
                settingCard {
                    VStack(alignment: .leading, spacing: 12) {
                        label("🎬", store.t("proxy"))
                        VStack(spacing: 8) {
                            ForEach(LiveSource.allCases, id: \.self) { src in
                                sourceButton(src)
                            }
                        }
                    }
                }

                // ── Langue ──────────────────────────────────────────
                settingCard {
                    VStack(alignment: .leading, spacing: 12) {
                        label("🌐", store.t("language"))
                        VStack(spacing: 8) {
                            ForEach(Lang.allCases) { lang in
                                langButton(lang)
                            }
                        }
                    }
                }

                // ── Proxy toggle ────────────────────────────────────
                settingCard {
                    VStack(alignment: .leading, spacing: 8) {
                        label("🔒", store.t("proxy_enable"))
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(store.t("proxy_enable"))
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.tText)
                                Text(store.t("proxy_sub"))
                                    .font(.system(size: 12))
                                    .foregroundColor(.tMuted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Toggle("", isOn: $store.useProxy)
                                .labelsHidden()
                                .tint(.tPrimary)
                                .onChange(of: store.useProxy) { val in
                                    logger.settingChanged("Proxy", value: val ? "activé" : "désactivé")
                                }
                        }
                    }
                }

                // ── Auto-claim coffres ──────────────────────────────
                settingCard {
                    VStack(alignment: .leading, spacing: 8) {
                        label("🎁", store.t("auto_claim"))
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(store.t("auto_claim"))
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.tText)
                                Text(store.t("auto_claim_sub"))
                                    .font(.system(size: 12))
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
                        label("🎨", store.t("customize"))
                        toggleRow(store.t("cfg_title"),  store.t("cfg_title_sub"),
                                  $store.showStreamTitle,    log: "Titre du live")
                        Divider().background(Color.tBorder)
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

                // ── Compte Twitch ───────────────────────────────────
                settingCard {
                    VStack(alignment: .leading, spacing: 14) {
                        label("💜", store.t("twitch_account"))

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
                        label("📋", store.t("history"))
                        HStack(spacing: 10) {
                            statBox(value: vodCount, label: "VODs", icon: "🎬")
                            statBox(value: channelCount, label: store.t("channels"), icon: "👤")
                        }
                        if vodCount > 0 || channelCount > 0 {
                            Button {
                                showClearAlert = true
                            } label: {
                                HStack {
                                    Image(systemName: "trash")
                                    Text(store.t("btn_clear"))
                                }
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.tDanger)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(Color.tDanger.opacity(0.1))
                                .cornerRadius(10)
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.tDanger.opacity(0.4), lineWidth: 1))
                            }
                        }
                    }
                }

                // ── À propos / Logs ─────────────────────────────────
                settingCard {
                    VStack(alignment: .leading, spacing: 12) {
                        label("ℹ️", store.t("about"))
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("TwitchUnblock")
                                    .font(.system(size: 16, weight: .heavy))
                                    .foregroundColor(.white)
                                Text(store.t("version"))
                                    .font(.system(size: 12))
                                    .foregroundColor(.tMuted)
                            }
                            Spacer()
                            Text("🟣")
                                .font(.system(size: 28))
                        }
                        Text(store.t("about_desc"))
                            .font(.system(size: 13))
                            .foregroundColor(.tMuted)
                            .fixedSize(horizontal: false, vertical: true)

                        Button {
                            showLogs = true
                        } label: {
                            HStack {
                                Image(systemName: "terminal")
                                Text(store.t("show_logs"))
                                Spacer()
                                Text("\(AppLogger.shared.logs.count)")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Color.tPrimary)
                                    .cornerRadius(8)
                            }
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.tPrimary)
                            .padding(.vertical, 12).padding(.horizontal, 14)
                            .background(Color.tPrimary.opacity(0.1))
                            .cornerRadius(10)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.tPrimary.opacity(0.3), lineWidth: 1))
                        }
                    }
                }

                Spacer(minLength: 32)
            }
            .padding(.horizontal, 12)
        }
        .background(Color.tDark)
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
        // ── Logs sheet ───────────────────────────────────────────────
        .sheet(isPresented: $showLogs) {
            VStack(spacing: 0) {
                HStack {
                    HStack(spacing: 8) {
                        Image(systemName: "terminal.fill")
                            .foregroundColor(.tPrimary)
                        Text("Logs Système")
                            .font(.system(size: 16, weight: .bold)).foregroundColor(.white)
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
        .padding(16)
        .background(Color.tCard)
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.tBorder, lineWidth: 1))
    }

    @ViewBuilder
    private func toggleRow(_ title: String, _ sub: String,
                           _ isOn: Binding<Bool>, log: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.tText)
                Text(sub)
                    .font(.system(size: 12))
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
            Text(connected ? "✅" : "⚪").font(.system(size: 16))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.tText)
                Text(connected ? store.t("connected") : sub)
                    .font(.system(size: 11))
                    .foregroundColor(connected ? .tSuccess : .tMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(action: action) {
                Group {
                    if busy {
                        ProgressView().tint(.tPrimary)
                    } else {
                        Text(actionLabel).font(.system(size: 13, weight: .bold))
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

    @ViewBuilder
    private func label(_ emoji: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            Text(emoji).font(.system(size: 14))
            Text(text.uppercased())
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.tPurple)
                .tracking(0.8)
        }
    }

    @ViewBuilder
    private func sourceButton(_ src: LiveSource) -> some View {
        let isSelected = liveSource == src
        Button {
            logger.settingChanged("Source vidéo", value: src.rawValue)
            liveSource = src
        } label: {
            HStack(spacing: 12) {
                Text(src.emoji)
                    .font(.system(size: 18))
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(src.displayName)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(isSelected ? .tPrimary : .tText)
                    Text(src.subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.tMuted)
                }
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
    private func langButton(_ lang: Lang) -> some View {
        let isSelected = store.lang == lang
        Button {
            logger.settingChanged("Langue", value: lang.rawValue)
            store.lang = lang
        } label: {
            HStack(spacing: 12) {
                Text(lang.flag).font(.system(size: 22))
                Text(lang.label)
                    .font(.system(size: 14, weight: .semibold))
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
        VStack(spacing: 6) {
            Text(icon).font(.system(size: 22))
            Text("\(value)")
                .font(.system(size: 26, weight: .heavy))
                .foregroundColor(.tPrimary)
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.tMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Color.tSurface)
        .cornerRadius(12)
    }
}
