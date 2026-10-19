import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showLogs        = false
    @State private var showFeedback    = false
    /// Contexte joint au retour (ex. « traduction ru »), nil = retour libre.
    @State private var feedbackContext: String? = nil
    /// Gestion des retours, pour le compte propriétaire (vérifié par le Worker).
    @ObservedObject private var admin = AdminFeedbackService.shared
    @State private var showAdminFeedback = false
    @ObservedObject private var updater = UpdateChecker.shared
    @State private var checkingUpdate  = false
    @State private var upToDate        = false
    @State private var updateCheckFailed = false
    @State private var highlightDraft  = ""
    @State private var mutedDraft      = ""
    @State private var liveNotif       = LiveNotifier.isEnabled
    @State private var notifTestResult: String? = nil
    @State private var ntfyOn          = NtfyNotifier.isEnabled
    @State private var showNotifChannels = false
    @State private var ntfyResult: String? = nil
    @State private var ntfyCopied      = false
    @State private var ntfySynced      = !NtfyNotifier.isPending
    @State private var appIcon: AppIconChoice = .standard
    @State private var appIconError: String? = nil
    // Réglages experts : Worker personnel.
    @AppStorage(APIConfig.customKey) private var customWorker = ""
    @AppStorage(APIConfig.allKey) private var customWorkerAll = false
    @State private var workerInput = ""
    @State private var workerChecking = false
    /// Adresse (nettoyée) à laquelle se rapporte `workerResult`.
    @State private var workerResultFor: String? = nil
    /// Dernière vérification du Worker personnel (nil : rien à dire).
    @State private var workerResult: APIConfig.CheckResult? = nil
    /// « Tout par ce Worker » refusé : il n'a pas de base D1.
    @State private var workerNoDatabase = false
    @AppStorage("onboarding_done") private var onboardingDone = false
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
    @State private var showHidden      = false   // chaînes et catégories masquées
    @State private var showCustomize   = false   // onglets, accueil, lecteur, chat
    // Sauvegarde (export / import)
    @State private var exportDoc: BackupDocument? = nil
    @State private var showExporter    = false
    @State private var showImporter    = false
    @State private var backupMessage: String? = nil
    /// Page ouverte, nil = menu racine.
    @State private var page: Page? = nil

    private var vodCount:     Int { store.history.filter { $0.type == .vod }.count }
    private var channelCount: Int { store.history.filter { $0.type == .channel }.count }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader

            // Navigation maison plutôt qu'un NavigationStack : celui-ci posait
            // sa propre barre grise, avec titre et « Back » en bleu système,
            // juste sous notre en-tête. Deux barres l'une sur l'autre, dont une
            // qui ignore la charte. Ici l'en-tête se transforme : le titre
            // devient celui de la page et la croix cède la place à un chevron.
            ZStack {
                if page == nil {
                    rootMenu
                        .transition(.asymmetric(
                            insertion: .move(edge: .leading).combined(with: .opacity),
                            removal:   .move(edge: .leading).combined(with: .opacity)))
                } else if let page {
                    sectionPage(page)
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal:   .move(edge: .trailing).combined(with: .opacity)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                store.clearHistory()
            }
        } message: {
            Text(store.t("confirm"))
        }
        // ── Login web Twitch (cookie auth-token pour les points) ─────
        .sheet(isPresented: $showWebLogin) {
            TwitchWebLoginSheet(
                clearSession: webLoginClear,
                expectedLogin: store.twitchLogin,
                onComplete: { webToken, webLogin in
                    showWebLogin = false
                    Task {
                        if await store.adoptWebToken(webToken, login: webLogin) {
                            logger.success("AUTH/WEB", "Session web connectée depuis les réglages", nil)
                        }
                    }
                },
                onCancel: { showWebLogin = false }
            )
        }
        // ── Retour : bug, idée ─────────────────────────────────────────
        // Compte admin ? Demandé au Worker à l'ouverture et à chaque
        // changement de compte : l'entrée « Gérer les retours » en dépend.
        .task { await admin.refreshAdmin(token: store.twitchToken) }
        .onChange(of: store.twitchToken) { t in Task { await admin.refreshAdmin(token: t) } }
        .sheet(isPresented: $showAdminFeedback) {
            NavigationStack { AdminFeedbackList() }
                .environmentObject(store)
                .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showFeedback, onDismiss: { feedbackContext = nil }) {
            FeedbackSheet(initialKind: feedbackContext == nil ? .bug : .other,
                          context: feedbackContext)
                .environmentObject(store)
                .presentationDetents([.large])
        }
        // ── Minuteur de veille (préréglages + durée personnalisée) ───
        .sheet(isPresented: $showSleepSheet) {
            SleepTimerSheet()
                .presentationDetents([.medium, .large])
                .inAppNoticeHost()
        }
        // ── Chaînes et catégories masquées ───────────────────────────
        .sheet(isPresented: $showHidden) {
            HiddenContentSheet().environmentObject(store)
                .inAppNoticeHost()
        }
        // ── Personnaliser : onglets, accueil, lecteur, chat ──────────
        .sheet(isPresented: $showCustomize) {
            CustomizeView().environmentObject(store)
                .inAppNoticeHost()
        }
        // ── Logs sheet ───────────────────────────────────────────────
        .sheet(isPresented: $showLogs) {
            VStack(spacing: 0) {
                HStack {
                    HStack(spacing: 8) {
                        Image(systemName: "terminal.fill")
                            .foregroundColor(.tPrimary)
                        Text(store.t("logs_title"))
                            .font(.tSection).foregroundColor(.tText)
                    }
                    Spacer()
                    Button(store.t("close")) { showLogs = false }
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
    /// Les destinations du menu.
    enum Page: Hashable {
        case account, general, player, chat, drops, points, labs, other, changelog

        var titleKey: String {
            switch self {
            case .account:   return "twitch_account"
            case .general:   return "sec_general"
            case .player:    return "sec_player"
            case .chat:      return "sec_chat"
            case .drops:     return "drops"
            case .points:    return "points_tracker"
            case .labs:      return "debug_section"
            case .other:     return "sec_other"
            case .changelog: return "changelog"
            }
        }
        var subtitleKey: String {
            switch self {
            case .account:   return "sec_account_sub"
            case .general:   return "sec_general_sub"
            case .player:    return "sec_player_sub"
            case .chat:      return "sec_chat_sub"
            case .drops:     return "drops_sub"
            case .points:    return "points_tracker_sub"
            case .labs:      return "sec_labs_sub"
            case .other:     return "sec_other_sub"
            case .changelog: return "changelog_sub"
            }
        }
        var icon: String {
            switch self {
            case .account:   return "person.crop.circle.fill"
            case .general:   return "gearshape.fill"
            case .player:    return "play.rectangle.fill"
            case .chat:      return "bubble.left.and.bubble.right.fill"
            case .drops:     return "shippingbox.fill"
            case .points:    return "circle.circle.fill"
            case .labs:      return "flask.fill"
            case .other:     return "info.circle.fill"
            case .changelog: return "sparkles"
            }
        }
        /// Une teinte par domaine : on repère la ligne à la couleur avant
        /// d'avoir lu le libellé.
        var tint: Color {
            switch self {
            case .account:   return .tPurple
            case .general:   return .tPrimary
            case .player:    return .tOutplayer
            case .chat:      return .tSuccess
            case .drops:     return .tLive
            case .points:    return .tPurple
            case .labs:      return .tWarning
            case .other:     return .tMuted
            case .changelog: return .tVLC
            }
        }
    }

    /// En-tête unique, qui suit la navigation.
    @ViewBuilder private var sheetHeader: some View {
        HStack(spacing: TSpace.md) {
            if let page {
                Button {
                    withAnimation(.easeInOut(duration: 0.22)) { self.page = nil }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.tPrimary)
                        .frame(width: 34, height: 34)
                        .background(Color.tCard)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .transition(.opacity)

                Text(store.t(page.titleKey))
                    .font(.tSection)
                    .foregroundColor(.tText)
                    .lineLimit(1)
            } else {
                Text(store.t("settings"))
                    .font(.tScreenTitle)
                    .foregroundColor(.tText)
            }
            Spacer(minLength: 0)
            TIconButton(icon: "xmark") { dismiss() }
        }
        .padding(.horizontal, TSpace.lg)
        .padding(.top, TSpace.lg)
        .padding(.bottom, TSpace.md)
        .background(Color.tDark)
        .overlay(alignment: .bottom) {
            // Un filet apparaît seulement dans une page : à la racine, le grand
            // titre se suffit et un trait l'alourdirait.
            if page != nil { Divider().background(Color.tBorder) }
        }
    }

    // MARK: – Menu racine
    @ViewBuilder private var rootMenu: some View {
        ScrollView {
            VStack(spacing: TSpace.lg) {
                if let login = store.twitchLogin {
                    accountBanner(login: login)
                }

                VStack(spacing: 0) {
                    menuRow(.account)
                    rowSeparator
                    menuRow(.general)
                    rowSeparator
                    menuRow(.player)
                    rowSeparator
                    menuRow(.chat)
                    rowSeparator
                    menuRow(.drops)
                    rowSeparator
                    menuRow(.points)
                    rowSeparator
                    menuRow(.labs)
                    rowSeparator
                    menuRow(.other)
                    rowSeparator
                    menuRow(.changelog)
                }
                .tCard()

                feedbackRow

                if admin.isAdmin {
                    adminFeedbackRow
                }

                Text(versionLabel)
                    .font(.tMeta).foregroundColor(.tMuted)

                Spacer(minLength: 24)
            }
            .padding(.horizontal, 12)
            .padding(.top, TSpace.sm)
        }
    }

    /// Bandeau du compte connecté : une photo et un pseudo valent mieux qu'une
    /// ligne « Connecté » perdue au fond d'une page.
    @ViewBuilder
    private func accountBanner(login: String) -> some View {
        HStack(spacing: TSpace.md) {
            AsyncImage(url: URL(string: store.twitchAvatar ?? "")) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                ZStack {
                    Circle().fill(Color.tPrimary.opacity(0.25))
                    Image(systemName: "person.fill")
                        .font(.system(size: 20)).foregroundColor(.tPrimary)
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(Circle())

            // Session web seule (connexion depuis la page Drops) : le pseudo
            // est connu, mais pas de compte pour le chat ni les suivis.
            let full = store.twitchToken != nil
            VStack(alignment: .leading, spacing: 2) {
                Text(login).font(.tSection).foregroundColor(.tText).lineLimit(1)
                HStack(spacing: 5) {
                    Circle().fill(full ? Color.tSuccess : Color.tWarning).frame(width: 6, height: 6)
                    Text(store.t(full ? "connected" : "web_only")).font(.tMeta).foregroundColor(.tMuted)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(TSpace.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [Color.tPrimary.opacity(0.22), Color.tCard],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .cornerRadius(TRadius.card)
        .overlay(RoundedRectangle(cornerRadius: TRadius.card)
            .stroke(Color.tPrimary.opacity(0.35), lineWidth: 1))
    }

    /// Boîte de réception des retours (admin) : comme le panneau de /stats.
    private var adminFeedbackRow: some View {
        Button { showAdminFeedback = true } label: {
            HStack(spacing: TSpace.md) {
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color.tWarning.opacity(0.18))
                    .frame(width: 34, height: 34)
                    .overlay {
                        Image(systemName: "tray.full.fill")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.tWarning)
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.t("adm_feedback"))
                        .font(.tCardTitle).foregroundColor(.tText)
                    Text(store.t("adm_feedback_sub"))
                        .font(.tMeta).foregroundColor(.tMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if admin.awaitingCount > 0 {
                    Text("\(admin.awaitingCount)")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundColor(.black)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Color.tWarning)
                        .clipShape(Capsule())
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.tMuted.opacity(0.7))
            }
            .padding(.horizontal, TSpace.lg)
            .padding(.vertical, TSpace.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .tCard()
    }

    /// Signaler un bug ou proposer une idée : en vue dès l'ouverture des
    /// réglages, pas au fond de la page « Autres ».
    private var feedbackRow: some View {
        Button { showFeedback = true } label: {
            HStack(spacing: TSpace.md) {
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color.tPrimary.opacity(0.18))
                    .frame(width: 34, height: 34)
                    .overlay {
                        Image(systemName: "ladybug.fill")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.tPrimary)
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.t("feedback"))
                        .font(.tCardTitle).foregroundColor(.tText)
                    Text(store.t("feedback_sub"))
                        .font(.tMeta).foregroundColor(.tMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                FeedbackUnreadBadge()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.tMuted.opacity(0.7))
            }
            .padding(.horizontal, TSpace.lg)
            .padding(.vertical, TSpace.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .tCard()
        .overlay(RoundedRectangle(cornerRadius: TRadius.card)
            .stroke(Color.tPrimary.opacity(0.35), lineWidth: 1))
    }

    private var rowSeparator: some View {
        Divider().background(Color.tBorder).padding(.leading, 62)
    }

    @ViewBuilder
    private func menuRow(_ section: Page) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.22)) { page = section }
        } label: {
            HStack(spacing: TSpace.md) {
                // Pastille teintée : plus lisible qu'un glyphe nu sur fond noir,
                // et elle donne au menu un rythme régulier.
                RoundedRectangle(cornerRadius: 9)
                    .fill(section.tint.opacity(0.18))
                    .frame(width: 34, height: 34)
                    .overlay {
                        Image(systemName: section.icon)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(section.tint)
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(store.t(section.titleKey))
                        .font(.tCardTitle).foregroundColor(.tText)
                    Text(store.t(section.subtitleKey))
                        .font(.tMeta).foregroundColor(.tMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.tMuted.opacity(0.7))
            }
            .padding(.horizontal, TSpace.lg)
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
                    webSessionCard
                    compteCard
                    usageCard
                case .general:
                    langueCard
                    customizeCard
                    hiddenCard
                    apparenceCard
                    autoclaimCard
                    veilleCard
                    historiqueCard
                    backupCard
                    cacheCard
                case .player:
                    lecteurCard
                case .chat:
                    chatBehaviorCard
                    persoCard
                    tailleChatCard
                case .drops:
                    DropsPanel(onLogin: { startWebLogin() })
                case .points:
                    PointsTrackerPanel(onLogin: { startWebLogin() })
                case .labs:
                    debugCard
                case .other:
                    aboutCard
                    expertCard
                case .changelog:
                    ChangelogList()
                }
                Spacer(minLength: 32)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
        }
        .background(Color.tDark)
    }

    // ── Réglages experts : Worker personnel ──────────────────────────────
    @ViewBuilder private var expertCard: some View {
        settingCard {
            VStack(alignment: .leading, spacing: 12) {
                label("server.rack", store.t("expert"))
                Text(store.t("expert_worker")).font(.tCardTitle).foregroundColor(.tText)
                Text(store.t("expert_worker_sub"))
                    .font(.tMeta).foregroundColor(.tMuted)
                    .fixedSize(horizontal: false, vertical: true)
                TextField(store.t("expert_worker_ph"), text: $workerInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.done)
                    .onSubmit { checkWorker() }
                    // Résultat d'une autre adresse : effacé dès qu'on la change.
                    .onChange(of: workerInput) { v in
                        if !workerChecking, APIConfig.normalize(v) != workerResultFor { workerResult = nil }
                    }
                    .font(.tBody)
                    .foregroundColor(.tText)
                    .padding(10)
                    .background(Color.tSurface)
                    .cornerRadius(10)
                HStack(spacing: 16) {
                    Button { checkWorker() } label: {
                        HStack(spacing: 6) {
                            if workerChecking { ProgressView().scaleEffect(0.7) }
                            Text(store.t("expert_check"))
                        }
                    }
                    .disabled(workerChecking || workerInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    if !customWorker.isEmpty {
                        Button(store.t("expert_reset"), role: .destructive) { resetWorker() }
                    }
                }
                .font(.tLabel)
                .buttonStyle(.borderless)
                if let result = workerResult {
                    // Ce qui a échoué (http://, pas de réponse, quota, pas un
                    // Worker TwitchUnblock), plus un seul message pour tout.
                    Text(store.t(result.messageKey))
                        .font(.tMeta).foregroundColor(result == .ok ? .tSuccess : .tDanger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Le Worker en service reste affiché après l'échec d'une autre
                // adresse : c'est toujours lui qui sert.
                if !customWorker.isEmpty, workerResult != .ok {
                    Text(store.t("expert_using").replacingOccurrences(of: "{u}", with: customWorker))
                        .font(.tMeta).foregroundColor(.tMuted)
                }
                if !customWorker.isEmpty {
                    Toggle(isOn: $customWorkerAll) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(store.t("expert_all")).font(.tCardTitle).foregroundColor(.tText)
                            Text(store.t("expert_all_sub"))
                                .font(.tMeta).foregroundColor(.tMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .tint(.tPrimary)
                    .onChange(of: customWorkerAll) { on in
                        logger.settingChanged("Tout par le Worker personnel", value: on ? "oui" : "non")
                        guard on, let base = APIConfig.custom else { return }
                        workerNoDatabase = false
                        // Sans base D1, sauvegarde, retours et notifications y
                        // échoueraient en silence, pour toujours : l'option
                        // reste coupée. (La sauvegarde, elle, relit et fusionne
                        // avant d'écrire sur un nouveau Worker.)
                        Task {
                            guard await APIConfig.hasDatabase(base) == false,
                                  customWorkerAll, APIConfig.custom == base else { return }
                            customWorkerAll = false
                            workerNoDatabase = true
                            logger.warn("SETTINGS", "Worker personnel sans base D1", base)
                        }
                    }
                    if workerNoDatabase {
                        Text(store.t("expert_all_no_db"))
                            .font(.tMeta).foregroundColor(.tDanger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .onAppear { if workerInput.isEmpty { workerInput = customWorker } }
    }

    /// Adresse vérifiée (c'est bien un Worker TwitchUnblock) avant d'être gardée.
    private func checkWorker() {
        // Une vérification à la fois (Entrée pendant la vérification en
        // lançait une autre, et la plus lente remettait son adresse).
        guard !workerChecking else { return }
        guard let base = APIConfig.normalize(workerInput) else { workerResult = .notAWorker; return }
        workerChecking = true
        workerResult = nil
        Task {
            let result = await APIConfig.check(base)
            workerChecking = false
            // Adresse modifiée pendant la vérification : résultat périmé.
            guard APIConfig.normalize(workerInput) == base else { return }
            workerResultFor = base
            workerResult = result
            guard result == .ok else {
                logger.warn("SETTINGS", "Worker personnel refusé (\(result))", base)
                return
            }
            customWorker = base
            workerInput = base
            workerNoDatabase = false
            logger.settingChanged("Worker personnel", value: base)
            // « Tout par ce Worker » déjà actif : le nouveau doit avoir sa base D1.
            if customWorkerAll, await APIConfig.hasDatabase(base) == false, APIConfig.custom == base {
                customWorkerAll = false
                workerNoDatabase = true
            }
        }
    }

    private func resetWorker() {
        customWorker = ""
        customWorkerAll = false
        workerInput = ""
        workerResult = nil
        workerNoDatabase = false
        logger.settingChanged("Worker personnel", value: "officiels")
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
                // Langue traduite avec l'IA : on le dit, et on invite à
                // signaler ce qui sonne faux.
                if store.lang.machineTranslated {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(store.t("lang_ai_note"), systemImage: "sparkles")
                            .font(.tMeta).foregroundColor(.tMuted)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            feedbackContext = "translation \(store.lang.rawValue)"
                            showFeedback = true
                        } label: {
                            Label(store.t("lang_ai_report"), systemImage: "text.bubble")
                                .font(.tLabel).foregroundColor(.tPrimary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.tSurface)
                    .cornerRadius(10)
                }
                topLangRow
                Divider().background(Color.tBorder)
                toggleRow(store.t("home_list"), store.t("home_list_sub"),
                          $store.homeListLayout, log: "Accueil en liste")
                Divider().background(Color.tBorder)
                toggleRow(store.t("show_recent"), store.t("show_recent_sub"),
                          $store.showRecentChannels, log: "Streamers récents")
            }
        }
    }

    /// Chaînes et catégories masquées du top et des catégories : combien, et
    /// la feuille pour les réafficher.
    /// Réglages → Personnaliser : onglets, accueil, boutons du lecteur et
    /// bandeaux du chat (CustomizeView).
    @ViewBuilder private var customizeCard: some View {
        settingCard {
            VStack(alignment: .leading, spacing: 12) {
                label("square.grid.3x2.fill", store.t("cust_title"))
                Text(store.t("cust_sub"))
                    .font(.tMeta).foregroundColor(.tMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Button { showCustomize = true } label: {
                    HStack(spacing: 8) {
                        Text(store.t("cust_open"))
                            .font(.tCardTitle).foregroundColor(.tText)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.tMuted)
                    }
                    .padding(12)
                    .background(Color.tSurface)
                    .cornerRadius(10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder private var hiddenCard: some View {
        settingCard {
            VStack(alignment: .leading, spacing: 12) {
                label("eye.slash", store.t("hidden_title"))
                Text(store.t("hidden_sub"))
                    .font(.tMeta).foregroundColor(.tMuted)
                    .fixedSize(horizontal: false, vertical: true)
                if store.hidden.isEmpty {
                    Text(store.t("hidden_empty"))
                        .font(.tMeta).foregroundColor(.tMuted)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    let channels = store.t("hidden_channels_n")
                        .replacingOccurrences(of: "{n}", with: "\(store.hidden.channels.count)")
                    let categories = store.t("hidden_categories_n")
                        .replacingOccurrences(of: "{n}", with: "\(store.hidden.categories.count)")
                    Button { showHidden = true } label: {
                        HStack(spacing: 8) {
                            Text("\(channels) · \(categories)")
                                .font(.tCardTitle).foregroundColor(.tText)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.tMuted)
                        }
                        .padding(12)
                        .background(Color.tSurface)
                        .cornerRadius(10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Couleur d'accent, fond, verre liquide (iOS 26) : voir Theme.swift.
    @ViewBuilder private var apparenceCard: some View {
        settingCard {
            VStack(alignment: .leading, spacing: 14) {
                label("paintpalette.fill", store.t("appearance"))
                VStack(alignment: .leading, spacing: 8) {
                    Text(store.t("accent_color"))
                        .font(.tCardTitle).foregroundColor(.tText)
                    HStack(spacing: 8) {
                        ForEach(AccentTheme.allCases) { a in
                            let on = store.accent == a
                            Button {
                                logger.settingChanged("Couleur d'accent", value: a.rawValue)
                                store.accent = a
                            } label: {
                                Circle().fill(a.color)
                                    .frame(width: 28, height: 28)
                                    .overlay(Circle().stroke(Color.white, lineWidth: on ? 2.5 : 0))
                                    .overlay {
                                        if on {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 11, weight: .bold))
                                                .foregroundColor(.white)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(store.t(a.labelKey))
                        }
                    }
                }
                Divider().background(Color.tBorder)
                VStack(alignment: .leading, spacing: 8) {
                    Text(store.t("background_theme"))
                        .font(.tCardTitle).foregroundColor(.tText)
                    HStack(spacing: 8) {
                        ForEach(BackgroundTheme.allCases) { b in
                            TChip(title: store.t(b.labelKey), isOn: store.background == b) {
                                logger.settingChanged("Fond", value: b.rawValue)
                                store.background = b
                            }
                        }
                    }
                }
                Divider().background(Color.tBorder)
                appIconRow
                Divider().background(Color.tBorder)
                if Theme.glassSupported {
                    toggleRow(store.t("liquid_glass"), store.t("liquid_glass_sub"),
                              $store.liquidGlass, log: "Verre liquide")
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.t("liquid_glass"))
                            .font(.tCardTitle).foregroundColor(.tMuted)
                        Text(store.t("liquid_glass_unavailable"))
                            .font(.tMeta).foregroundColor(.tMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// Icône de l'app : « Contraste » reste nette en icônes transparentes ou
    /// teintées (iOS 26), toutes ont leurs versions sombre et teintée.
    @ViewBuilder private var appIconRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(store.t("app_icon"))
                .font(.tCardTitle).foregroundColor(.tText)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(AppIconChoice.allCases) { choice in
                        let on = appIcon == choice
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            appIconError = nil
                            choice.apply { error in
                                guard let error else {
                                    appIcon = choice
                                    logger.settingChanged("Icône de l'app", value: choice.rawValue)
                                    return
                                }
                                appIconError = error == AppIconChoice.unsupported
                                    ? store.t("app_icon_unsupported")
                                    : store.t("app_icon_failed").replacingOccurrences(of: "{e}", with: error)
                            }
                        } label: {
                            VStack(spacing: 6) {
                                Image(choice.previewName)
                                    .resizable()
                                    .frame(width: 58, height: 58)
                                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                                        .stroke(on ? Color.tPrimary : Color.tBorder, lineWidth: on ? 3 : 1))
                                Text(store.t(choice.labelKey))
                                    .font(.tMeta)
                                    .foregroundColor(on ? .tText : .tMuted)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(store.t(choice.labelKey))
                    }
                }
                .padding(.vertical, 3)
            }
            if let appIconError {
                Text(appIconError)
                    .font(.tMeta).foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Signée avec l'identifiant générique d'un certificat (Feather sans
            // « Merge Entitlements ») : iOS refuse le changement d'icône.
            if SigningInfo.signedForOtherIdentifier, let id = SigningInfo.applicationIdentifier {
                Text(store.t("app_icon_wildcard").replacingOccurrences(of: "{id}", with: id))
                    .font(.tMeta).foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(store.t("app_icon_sub"))
                .font(.tMeta).foregroundColor(.tMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { appIcon = AppIconChoice.current }
    }

    /// Langue des streamers dans « Top des lives » (appareil par défaut).
    @ViewBuilder private var topLangRow: some View {
        let device = TopLanguage.name(TopLanguage.device, in: store.lang)
        let options = TopLanguage.codes
            .map { ($0, TopLanguage.name($0, in: store.lang)) }
            .sorted { $0.1.localizedCompare($1.1) == .orderedAscending }
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.t("top_lang"))
                    .font(.tCardTitle)
                    .foregroundColor(.tText)
                Text(store.t("top_lang_sub").replacingOccurrences(of: "{l}", with: device))
                    .font(.tMeta)
                    .foregroundColor(.tMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Menu {
                Button { store.topLang = nil } label: {
                    if store.topLang == nil { Label("\(store.t("lang_auto")) · \(device)", systemImage: "checkmark") }
                    else { Text("\(store.t("lang_auto")) · \(device)") }
                }
                Divider()
                ForEach(options, id: \.0) { code, name in
                    Button { store.topLang = code } label: {
                        if store.topLang == code { Label(name, systemImage: "checkmark") } else { Text(name) }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(store.topLang.map { TopLanguage.name($0, in: store.lang) } ?? store.t("lang_auto"))
                        .font(.tCardTitle)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(.tPrimary)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.tPrimary.opacity(0.12))
                .cornerRadius(10)
            }
        }
        .padding(.top, 6)
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
                toggleRow(store.t("cfg_drops_notice"), store.t("cfg_drops_notice_sub"),
                          $store.showDropsNotice, log: "Carte des drops")
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
                Divider().background(Color.tBorder)
                toggleRow(store.t("cfg_land_notices"), store.t("cfg_land_notices_sub"),
                          $store.landscapeNoticesHidden, log: "Bandeaux repliés en paysage")
            }
        }
    }

    /// Test et état des notifications : savoir si iOS réveille bien l'app.
    @ViewBuilder private var liveNotifTools: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Task {
                    let ok = await LiveNotifier.sendTest(lang: store.lang)
                    await MainActor.run { notifTestResult = ok ? store.t("notif_test_sent") : store.t("notif_test_denied") }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "bell.badge.fill").font(.system(size: 13, weight: .semibold))
                    Text(store.t("notif_test")).font(.system(size: 14, weight: .semibold))
                }
                .foregroundColor(.tPrimary)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.tPrimary.opacity(0.12))
                .cornerRadius(10)
            }
            .buttonStyle(.plain)
            if let notifTestResult {
                Text(notifTestResult).font(.tMeta).foregroundColor(.tMuted)
            }
            Text(notifStatusLine).font(.tMeta).foregroundColor(.tMuted)
                .fixedSize(horizontal: false, vertical: true)
            if UIApplication.shared.backgroundRefreshStatus != .available {
                Text(store.t("notif_bg_off")).font(.tMeta).foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let err = UserDefaults.standard.string(forKey: LiveNotifier.submitErrorKey) {
                Text("\(store.t("notif_bg_refused")) (\(err))").font(.tMeta).foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, 2)
    }

    private var notifStatusLine: String {
        guard let last = LiveNotifier.lastRun else { return store.t("notif_last_never") }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: store.lang.rawValue)
        f.unitsStyle = .full
        let ok = UserDefaults.standard.bool(forKey: LiveNotifier.lastOkKey)
        return store.t("notif_last_run").replacingOccurrences(of: "{t}", with: f.localizedString(for: last, relativeTo: Date()))
            + (ok ? "" : " · " + store.t("notif_last_failed"))
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
                toggleRow(store.t("cfg_kbd_suggest"), store.t("cfg_kbd_suggest_sub"),
                          $store.chatKeyboardSuggestions, log: "Suggestions du clavier")
                Divider().background(Color.tBorder)
                toggleRow(store.t("cfg_return_sends"), store.t("cfg_return_sends_sub"),
                          $store.chatReturnSends, log: "Entrée envoie le message")
                Divider().background(Color.tBorder)
                toggleRow(store.t("cfg_deleted"), store.t("cfg_deleted_sub"),
                          $store.chatShowDeleted, log: "Messages supprimés")
                Divider().background(Color.tBorder)
                toggleRow(store.t("hide_bots"), store.t("hide_bots_sub"),
                          $store.chatHideBots, log: "Masquer les bots")
                Divider().background(Color.tBorder)
                toggleRow(store.t("hide_commands"), store.t("hide_commands_sub"),
                          $store.chatHideCommands, log: "Masquer les commandes")
                Divider().background(Color.tBorder)
                toggleRow(store.t("dbg_chat_delay"), store.t("dbg_chat_delay_sub"),
                          $store.autoChatDelay, log: "Synchro auto du chat")
                if store.autoChatDelay {
                    chatSyncNudgeRow
                }
                Divider().background(Color.tBorder)
                VStack(alignment: .leading, spacing: 6) {
                    Text(store.t("muted_words"))
                        .font(.system(size: 14, weight: .semibold)).foregroundColor(.tText)
                    Text(store.t("muted_words_sub"))
                        .font(.system(size: 12)).foregroundColor(.tMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    TextField("spoiler", text: $mutedDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(size: 14))
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(Color.tSurface).cornerRadius(8)
                        .onAppear { mutedDraft = store.chatMutedWords.joined(separator: ", ") }
                        .onChange(of: mutedDraft) { _ in
                            let w = Array(mutedDraft.split(separator: ",")
                                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                                .filter { !$0.isEmpty }.prefix(50))
                            if w != store.chatMutedWords { store.chatMutedWords = w }
                        }
                }
                if !store.chatBlockedUsers.isEmpty {
                    Divider().background(Color.tBorder)
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(store.t("hidden_users").replacingOccurrences(of: "{n}", with: "\(store.chatBlockedUsers.count)"))
                                .font(.system(size: 14, weight: .semibold)).foregroundColor(.tText)
                            Text(store.chatBlockedUsers.suffix(6).joined(separator: ", "))
                                .font(.system(size: 12)).foregroundColor(.tMuted).lineLimit(1)
                        }
                        Spacer()
                        Button(store.t("clear")) { store.chatBlockedUsers = [] }
                            .font(.system(size: 13, weight: .bold)).foregroundColor(.tPrimary)
                    }
                }
                Divider().background(Color.tBorder)
                // Mots surlignés : en plus des mentions, séparés par des virgules.
                VStack(alignment: .leading, spacing: 6) {
                    Text(store.t("highlight_words"))
                        .font(.system(size: 14, weight: .semibold)).foregroundColor(.tText)
                    Text(store.t("highlight_words_sub"))
                        .font(.system(size: 12)).foregroundColor(.tMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    TextField("giveaway, tournoi", text: $highlightDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(size: 14))
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(Color.tSurface).cornerRadius(8)
                        .onAppear { highlightDraft = store.chatHighlightWords.joined(separator: ", ") }
                        .onSubmit { saveHighlightWords() }
                        .onChange(of: highlightDraft) { _ in saveHighlightWords() }
                }
            }
        }
    }

    private func saveHighlightWords() {
        let words = highlightDraft.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        let capped = Array(words.prefix(30))
        if capped != store.chatHighlightWords { store.chatHighlightWords = capped }
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
                // 12 h ou 24 h : « Auto » suit le réglage de l'appareil.
                VStack(alignment: .leading, spacing: 6) {
                    Text(store.t("cfg_time_format")).font(.tBody).foregroundColor(.tText)
                    Text(store.t("cfg_time_format_sub"))
                        .font(.tMeta).foregroundColor(.tMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    Picker("", selection: $store.timeFormat) {
                        Text(store.t("time_auto")).tag("auto")
                        Text("12 h").tag("12")
                        Text("24 h").tag("24")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                Divider().background(Color.tBorder)

                // Mêmes bornes que l'import d'une sauvegarde (AppStore).
                sliderRow(store.t("cfg_font_size"), value: $store.chatFontSize,
                          range: AppStore.chatFontRange, step: 1) { String(format: "%.0f pt", $0) }
                sliderRow(store.t("cfg_msg_spacing"), value: $store.chatSpacing,
                          range: AppStore.chatSpacingRange, step: 1) { String(format: "%.0f px", $0) }
                sliderRow(store.t("cfg_badge_scale"), value: $store.chatBadgeScale,
                          range: AppStore.chatScaleRange, step: 0.05) { String(format: "%.2fx", $0) }
                sliderRow(store.t("cfg_emote_scale"), value: $store.chatEmoteScale,
                          range: AppStore.chatScaleRange, step: 0.05) { String(format: "%.2fx", $0) }
                sliderRow(store.t("cfg_chat_width"), value: $store.chatWidthRatio,
                          range: AppStore.chatWidthRange, step: 0.01) { String(format: "%.0f %%", $0 * 100) }

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
                Divider().background(Color.tBorder)
                liveSourceRow
                Divider().background(Color.tBorder)
                preferredQualityRow
                Divider().background(Color.tBorder)
                toggleRow(store.t("fill_screen"), store.t("fill_screen_sub"),
                          $store.fillScreen, log: "Remplir l'écran")
                Divider().background(Color.tBorder)
                toggleRow(store.t("restore_muted"), store.t("restore_muted_sub"),
                          $store.restoreMutedAudio, log: "Rétablir le son des passages coupés")
                Divider().background(Color.tBorder)
                toggleRow(store.t("multi_chat"), store.t("multi_chat_sub"),
                          $store.multiLiveChat, log: "Chat dans le multi-live")
                Divider().background(Color.tBorder)
                spatialAudioRow
                if #available(iOS 16.2, *) {
                    Divider().background(Color.tBorder)
                    toggleRow(store.t("live_activity"), store.t("live_activity_sub"),
                              $store.liveActivity, log: "Activité en direct")
                }
                Divider().background(Color.tBorder)
                toggleRow(store.t("dbg_latency"), store.t("dbg_latency_sub"),
                          $store.showLatency, log: "Afficher la latence")
            }
        }
    }

    /// Qualité préférée : celle qui démarre (ou la plus proche en dessous).
    @ViewBuilder private var preferredQualityRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.t("pref_quality"))
                    .font(.tCardTitle)
                    .foregroundColor(.tText)
                Text(store.t("pref_quality_sub"))
                    .font(.tMeta)
                    .foregroundColor(.tMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Picker("", selection: $store.preferredQuality) {
                ForEach(kQualityPrefs, id: \.self) { pref in
                    Text(pref == "source" ? store.t("q_source")
                         : pref == "audio" ? store.t("q_audio") : "\(pref)p")
                        .tag(pref)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .tint(.tPrimary)
            .onChange(of: store.preferredQuality) { value in
                logger.settingChanged("Qualité préférée", value: value)
            }
        }
        // Données mobiles : « Auto » par défaut, la qualité suit le débit (une
        // qualité fixe trop haute faisait geler l'image, le chat continuant).
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.t("cellular_quality"))
                    .font(.tCardTitle)
                    .foregroundColor(.tText)
                Text(store.t("cellular_quality_sub"))
                    .font(.tMeta)
                    .foregroundColor(.tMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Picker("", selection: $store.cellularQuality) {
                ForEach(kCellularQualityPrefs, id: \.self) { pref in
                    Text(pref == "auto" ? store.t("q_auto") : pref == "same" ? store.t("q_same_wifi")
                         : pref == "audio" ? store.t("q_audio") : "\(pref)p")
                        .tag(pref)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .tint(.tPrimary)
            .onChange(of: store.cellularQuality) { value in
                logger.settingChanged("Qualité en données mobiles", value: value)
            }
        }
        .padding(.top, 8)
    }

    /// Audio spatial (AirPods) : seul choix qu'iOS laisse aux apps (voir SpatialAudio).
    @ViewBuilder private var spatialAudioRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(store.t("spatial_audio"))
                .font(.tCardTitle)
                .foregroundColor(.tText)
            Text(store.t("spatial_audio_sub"))
                .font(.tMeta)
                .foregroundColor(.tMuted)
                .fixedSize(horizontal: false, vertical: true)
            Picker("", selection: $store.spatialAudio) {
                Text(store.t("spatial_auto")).tag("auto")
                Text(store.t("spatial_off")).tag("off")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: store.spatialAudio) { value in
                logger.settingChanged("Audio spatial", value: value)
            }
        }
    }

    /// Ordre des sources du direct : getLive les essaie l'une après l'autre.
    /// Au-dessus, le direct par le compte pour les abonnés (sans pub), qui
    /// passe avant toutes les sources.
    @ViewBuilder private var liveSourceRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            toggleRow(store.t("sub_adfree"), store.t("sub_adfree_sub"),
                      $store.subAdFree, log: "Sans pub avec mon abonnement")
            // Il faut la session web : sans elle, de quoi l'ouvrir ici.
            if store.subAdFree, (store.twitchWebToken ?? "").isEmpty {
                Button { startWebLogin() } label: {
                    Label(store.t("sub_adfree_connect"), systemImage: "person.crop.circle.badge.plus")
                        .font(.tLabel)
                        .foregroundColor(.tPrimary)
                }
                .buttonStyle(.plain)
            }
            Divider().background(Color.tBorder)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.t("live_source_order"))
                    .font(.tCardTitle)
                    .foregroundColor(.tText)
                Text(store.t("live_source_order_sub"))
                    .font(.tMeta)
                    .foregroundColor(.tMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(store.liveSourceOrder.enumerated()), id: \.element) { index, id in
                HStack(spacing: 10) {
                    Text("\(index + 1)")
                        .font(.tBadge)
                        .foregroundColor(.tPrimary)
                        .frame(width: 22, height: 22)
                        .background(Color.tPrimary.opacity(0.15))
                        .clipShape(Circle())
                    Text(store.t("src_\(id)"))
                        .font(.tCardTitle)
                        .foregroundColor(.tText)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    sourceArrow("chevron.up", label: "src_up", enabled: index > 0) {
                        store.moveLiveSource(id, by: -1)
                    }
                    sourceArrow("chevron.down", label: "src_down", enabled: index < store.liveSourceOrder.count - 1) {
                        store.moveLiveSource(id, by: 1)
                    }
                }
                .padding(.vertical, 3)
                .padding(.leading, 10)
                .padding(.trailing, 4)
                .background(Color.tSurface)
                .cornerRadius(10)
            }
            if store.liveSourceOrder != kLiveSources {
                Button(store.t("src_reset")) {
                    withAnimation { store.liveSourceOrder = kLiveSources }
                }
                .font(.tLabel)
                .foregroundColor(.tPrimary)
                .buttonStyle(.plain)
            }
        }
        .onChange(of: store.liveSourceOrder) { order in
            logger.settingChanged("Ordre des sources", value: order.joined(separator: ","))
        }
    }

    private func sourceArrow(_ icon: String, label: String, enabled: Bool,
                             action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.easeInOut(duration: 0.2)) { action() }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(enabled ? .tPrimary : .tMuted.opacity(0.4))
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(store.t(label))
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
                        Text("\(cacheSizeText) · \(cacheFiles) \(store.tn("cache_files", cacheFiles))")
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

    /// Bandeau de session web expirée. Affiché seulement après un refus franc
    /// de Twitch : une session jamais utilisée n'a rien à signaler.
    @ViewBuilder private var webSessionCard: some View {
        if let other = store.webSessionMismatch {
            settingCard {
                VStack(alignment: .leading, spacing: TSpace.md) {
                    HStack(spacing: TSpace.sm) {
                        Image(systemName: "person.crop.circle.badge.exclamationmark")
                            .foregroundColor(.tWarning)
                        Text(store.t("web_mismatch"))
                            .font(.tCardTitle).foregroundColor(.tText)
                    }
                    Text(store.t("web_mismatch_sub")
                            .replacingOccurrences(of: "{w}", with: other)
                            .replacingOccurrences(of: "{a}", with: store.twitchLogin ?? "?"))
                        .font(.tMeta).foregroundColor(.tMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    // Le bandeau reste tant que la bonne session n'est pas
                    // là (adoptWebToken l'efface) : annuler ne le perd pas.
                    TPrimaryButton(title: store.t("web_reconnect")) { startWebLogin() }
                }
            }
        }
        if store.webSessionExpired {
            settingCard {
                VStack(alignment: .leading, spacing: TSpace.md) {
                    HStack(spacing: TSpace.sm) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.tWarning)
                        Text(store.t("web_expired"))
                            .font(.tCardTitle).foregroundColor(.tText)
                    }
                    Text(store.t("web_expired_sub"))
                        .font(.tMeta).foregroundColor(.tMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    TPrimaryButton(title: store.t("web_reconnect")) { startWebLogin() }
                }
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

                // Passer sur un autre compte sans repasser par Safari, qui
                // reconnectait aussitôt le compte dont il se souvient.
                if store.twitchToken != nil {
                    Button { Task { await switchAccount() } } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.left.arrow.right.circle.fill")
                                .font(.system(size: 16))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(store.t("switch_account")).font(.tLabel)
                                Text(store.t("switch_account_sub"))
                                    .font(.tMeta).foregroundColor(.tMuted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .foregroundColor(.tPrimary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(apiLoggingIn)
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
                        Task { await TwitchWebSession.clear() }
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

    @ViewBuilder private var backupCard: some View {
        // ── Sauvegarde ──────────────────────────────────────
        settingCard {
            VStack(alignment: .leading, spacing: 12) {
                label("arrow.up.arrow.down.circle.fill", store.t("backup"))
                Text(store.t("backup_sub"))
                    .font(.tMeta).foregroundColor(.tMuted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: TSpace.sm) {
                    TSecondaryButton(title: store.t("export_data"), icon: "square.and.arrow.up",
                                     tint: .tPrimary, fullWidth: true) {
                        exportDoc = BackupDocument(data: Backup.export(store: store))
                        showExporter = true
                    }
                    TSecondaryButton(title: store.t("import_data"), icon: "square.and.arrow.down",
                                     tint: .tPrimary, fullWidth: true) {
                        showImporter = true
                    }
                }
                if let backupMessage {
                    Text(backupMessage)
                        .font(.tMeta).foregroundColor(.tMuted)
                }
            }
        }
        .fileExporter(isPresented: $showExporter, document: exportDoc,
                      contentType: .json, defaultFilename: Backup.fileName()) { result in
            if case .success = result { backupMessage = store.t("export_done") }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url),
                  let result = try? Backup.importData(data, store: store) else {
                backupMessage = store.t("import_bad"); return
            }
            var message = String(format: store.t("import_done"), result.added)
            // Au-delà de 300 suivis sur l'appareil, le reste n'est pas pris :
            // dit, plutôt que compté comme ajouté.
            if result.skipped > 0 { message += " " + String(format: store.t("import_capped"), result.skipped) }
            backupMessage = message
            logger.info("SAUVEGARDE", "Import : \(result.added) chaîne(s) ajoutée(s)",
                        result.skipped > 0 ? "\(result.skipped) ignorée(s) (limite de 300)" : nil)
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
        // ── Fonctionnalités en test ─────────────────────────
        // Ce qui marche mais demande encore des retours avant d'être rangé
        // avec le reste (aujourd'hui : les notifications de live).
        settingCard {
            VStack(alignment: .leading, spacing: 14) {
                Text(store.t("debug_note"))
                    .font(.tMeta)
                    .foregroundColor(.tMuted)
                    .fixedSize(horizontal: false, vertical: true)
                // Notifications quand une chaîne suivie passe en live.
                toggleRow(store.t("notif_live"), store.t("notif_live_sub"),
                          Binding(get: { liveNotif }, set: { on in
                              liveNotif = on
                              if on {
                                  Task {
                                      let ok = await LiveNotifier.enable()
                                      await MainActor.run { liveNotif = ok && LiveNotifier.isEnabled }
                                  }
                              } else {
                                  LiveNotifier.disable()
                              }
                          }), log: "Notifications de live")
                if liveNotif { liveNotifTools }
                Divider().background(Color.tBorder)
                // Instantanées, même app fermée : par l'app ntfy.
                toggleRow(store.t("ntfy_live"), store.t("ntfy_live_sub"),
                          Binding(get: { ntfyOn }, set: { on in
                              ntfyOn = on
                              ntfyResult = nil
                              Task {
                                  if on {
                                      // Reste activé même si le serveur ne répond pas
                                      // encore : nouvel essai à chaque retour dans l'app.
                                      let ok = await NtfyNotifier.enable(lang: store.lang)
                                      await MainActor.run {
                                          ntfySynced = ok
                                          if !ok { ntfyResult = ntfyPendingText }
                                      }
                                  } else {
                                      await NtfyNotifier.disable()
                                  }
                              }
                          }), log: "Notifications ntfy")
                if ntfyOn { ntfyTools }
                // Lesquelles des chaînes suivies préviennent (les deux modes).
                if liveNotif || ntfyOn {
                    Divider().background(Color.tBorder)
                    notifChannelsRow
                }
            }
        }
        .sheet(isPresented: $showNotifChannels) {
            NotifChannelsView().environmentObject(store)
        }
    }

    private var notifChannelsRow: some View {
        let muted = NotifChannels.muted.count
        return Button { showNotifChannels = true } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.t("notif_channels"))
                        .font(.tCardTitle)
                        .foregroundColor(.tText)
                    Text(muted == 0 ? store.t("notif_channels_all")
                         : store.t("notif_channels_muted").replacingOccurrences(of: "{n}", with: "\(muted)"))
                        .font(.tMeta)
                        .foregroundColor(.tMuted)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.tMuted)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Activé, mais pas encore accepté par le serveur : pourquoi, et la suite.
    private var ntfyPendingText: String {
        store.t(NtfyNotifier.serverNotReady ? "ntfy_not_ready" : "ntfy_pending")
    }

    /// ntfy : le sujet à ajouter dans l'app ntfy, l'installer, tester.
    @ViewBuilder private var ntfyTools: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(store.t("ntfy_steps"))
                .font(.tMeta).foregroundColor(.tMuted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text(NtfyNotifier.topic)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundColor(.tText)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .textSelection(.enabled)
                Spacer(minLength: 4)
                Button {
                    UIPasteboard.general.string = NtfyNotifier.topic
                    ntfyCopied = true
                } label: {
                    Label(store.t(ntfyCopied ? "ntfy_copied" : "ntfy_copy"),
                          systemImage: ntfyCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.tPrimary)
                }
                .buttonStyle(.plain)
            }
            .padding(10)
            .background(Color.tSurface)
            .cornerRadius(10)
            HStack(spacing: 8) {
                Link(destination: NtfyNotifier.appStoreURL) {
                    ntfyPill(store.t("ntfy_install"), icon: "arrow.down.app.fill")
                }
                Button {
                    ntfyResult = nil
                    Task {
                        let result = await NtfyNotifier.sendTest(lang: store.lang)
                        await MainActor.run { ntfyResult = store.t(result.textKey) }
                    }
                } label: {
                    ntfyPill(store.t("notif_test"), icon: "bell.badge.fill")
                }
                .buttonStyle(.plain)
            }
            if let ntfyResult {
                Text(ntfyResult).font(.tMeta).foregroundColor(.tMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if ntfySynced {
                let count = UserDefaults.standard.integer(forKey: NtfyNotifier.countKey)
                Text(store.tn("ntfy_status", count).replacingOccurrences(of: "{n}", with: "\(count)"))
                    .font(.tMeta).foregroundColor(.tMuted)
            } else if ntfyResult == nil {
                Text(ntfyPendingText).font(.tMeta).foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(store.t("ntfy_privacy"))
                .font(.tMeta).foregroundColor(.tMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 2)
    }

    private func ntfyPill(_ title: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold))
            Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
        }
        .foregroundColor(.tPrimary)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.tPrimary.opacity(0.12))
        .cornerRadius(10)
    }

    private var versionLabel: String {
        // Même numéro que la source et les versions GitHub (1.1.4…).
        "\(store.t("version_label")) \(UpdateChecker.installedVersion)"
    }

    /// Lien externe façon bouton (crédits).
    private func creditLink(icon: String, title: String, url: String) -> some View {
        Link(destination: URL(string: url)!) {
            HStack(spacing: TSpace.sm) {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                Text(title).font(.tLabel)
                Spacer()
                Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(.tText)
            .padding(.horizontal, TSpace.md)
            .frame(height: 44)
            .background(Color.tSurface)
            .cornerRadius(TRadius.control)
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
                        Text(versionLabel)
                            .font(.tMeta)
                            .foregroundColor(.tMuted)
                    }
                    Spacer()
                    Circle().fill(Color.tPrimary).frame(width: 26, height: 26)
                }

                // Mise à jour : disponible → bouton ; sinon, vérification manuelle.
                if let up = updater.available {
                    Button { UpdateChecker.openSource() } label: {
                        HStack(spacing: TSpace.sm) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 14, weight: .semibold))
                            Text(store.t("update_available").replacingOccurrences(of: "{v}", with: up.version))
                                .font(.tLabel)
                            Spacer()
                            Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, TSpace.md)
                        .frame(height: 44)
                        .background(Color.tPrimary)
                        .cornerRadius(TRadius.control)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        checkingUpdate = true
                        Task {
                            // Hors ligne (ou build local) : « vérification
                            // impossible », plus « déjà à jour ».
                            let outcome = await updater.checkIfDue(force: true)
                            checkingUpdate = false
                            upToDate = outcome == .upToDate
                            updateCheckFailed = outcome == .failed
                        }
                    } label: {
                        HStack(spacing: TSpace.sm) {
                            Image(systemName: upToDate ? "checkmark.circle.fill"
                                  : updateCheckFailed ? "exclamationmark.triangle" : "arrow.triangle.2.circlepath")
                                .font(.system(size: 13, weight: .semibold))
                            Text(store.t(upToDate ? "update_none" : updateCheckFailed ? "update_check_failed" : "update_check")).font(.tLabel)
                            Spacer()
                            if checkingUpdate { ProgressView().scaleEffect(0.8) }
                        }
                        .foregroundColor(.tText)
                        .padding(.horizontal, TSpace.md)
                        .frame(height: 44)
                        .background(Color.tSurface)
                        .cornerRadius(TRadius.control)
                    }
                    .buttonStyle(.plain)
                    .disabled(checkingUpdate)
                }
                Text(store.t("about_desc"))
                    .font(.tMeta)
                    .foregroundColor(.tMuted)
                    .fixedSize(horizontal: false, vertical: true)

                // ── Crédits ──────────────────────────────────────
                HStack(spacing: 4) {
                    Text(store.t("made_by")).foregroundColor(.tMuted)
                    Link("MXFia19", destination: URL(string: "https://github.com/MXFia19")!)
                        .foregroundColor(.tPrimary)
                }
                .font(.system(size: 14, weight: .semibold))

                // Projet vibecodé : dit franchement.
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.tPrimary)
                    Text(store.t("vibecoded"))
                        .font(.tMeta)
                        .foregroundColor(.tMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                creditLink(icon: "chevron.left.forwardslash.chevron.right",
                           title: store.t("source_ios"),
                           url: "https://github.com/MXFia19/TwitchUnblock")
                creditLink(icon: "globe",
                           title: store.t("web_version"),
                           url: "https://twitchunblock.vercel.app")
                creditLink(icon: "bubble.left.and.bubble.right.fill",
                           title: store.t("discord_join"),
                           url: kDiscordURL)

                Text(store.t("credits_thanks"))
                    .font(.tMeta)
                    .foregroundColor(.tMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Text(store.t("not_affiliated"))
                    .font(.tMeta)
                    .foregroundColor(.tMuted.opacity(0.8))

                // Signaler un bug ou proposer une idée (arrive sur Discord).
                Button { showFeedback = true } label: {
                    HStack(spacing: TSpace.sm) {
                        Image(systemName: "ladybug.fill")
                            .font(.system(size: 13, weight: .semibold))
                        Text(store.t("feedback")).font(.tLabel)
                        Spacer()
                    }
                    .foregroundColor(.tPrimary)
                    .padding(.horizontal, TSpace.md)
                    .frame(height: 44)
                    .background(Color.tPrimary.opacity(0.12))
                    .cornerRadius(12)
                }
                .buttonStyle(.plain)

                // Revoir le tutoriel du premier lancement.
                Button {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { onboardingDone = false }
                } label: {
                    HStack(spacing: TSpace.sm) {
                        Image(systemName: "graduationcap.fill")
                            .font(.system(size: 13, weight: .semibold))
                        Text(store.t("ob_replay")).font(.tLabel)
                        Spacer()
                    }
                    .foregroundColor(.tPrimary)
                    .padding(.horizontal, TSpace.md)
                    .frame(height: 44)
                    .background(Color.tPrimary.opacity(0.12))
                    .cornerRadius(12)
                }
                .buttonStyle(.plain)

                Button {
                    showLogs = true
                } label: {
                    HStack(spacing: TSpace.sm) {
                        Image(systemName: "terminal")
                            .font(.system(size: 13, weight: .semibold))
                        Text(store.t("show_logs")).font(.tLabel)
                        Spacer()
                        // Erreurs du journal : visibles avant même de l'ouvrir.
                        let errors = AppLogger.shared.count(.error)
                        if errors > 0 {
                            Label("\(errors)", systemImage: "exclamationmark.triangle.fill")
                                .font(.tBadge)
                                .foregroundColor(.white)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color.tDanger)
                                .cornerRadius(8)
                        }
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
            store.adoptToken(token)
            logger.success("AUTH", "Connexion API réussie", nil)
        }
    }

    /// Changer de compte : Twitch demande les identifiants dans une session
    /// privée. Le compte actuel reste en place tant que le nouveau n'est pas
    /// connecté — annuler ne déconnecte pas.
    private func switchAccount() async {
        apiLoggingIn = true
        defer { apiLoggingIn = false }
        logger.info("AUTH", "Changement de compte…", nil)
        let previous = store.twitchUserId
        guard let token = await TwitchAuthManager.shared.login(chooseAccount: true) else { return }
        let user = await getTwitchUser(token: token)
        // Autre compte : la session web (points de chaîne) était celle de
        // l'ancien, et ses bandeaux (expirée, autre compte) avec elle.
        if user == nil || user?.id != previous {
            if store.twitchWebToken != nil {
                store.twitchWebToken = nil
                await TwitchWebSession.clear()
            }
            store.webSessionExpired = false
            store.webSessionMismatch = nil
        }
        store.adoptToken(token)
        if let user {
            store.twitchUserId = user.id
            store.twitchLogin  = user.login
            if !user.profileImageURL.isEmpty { store.twitchAvatar = user.profileImageURL }
        }
        logger.success("AUTH", "Compte changé", user?.login)
    }

    private func startWebLogin() {
        // Session refusée par Twitch ou d'un autre compte : cookies twitch.tv
        // effacés d'abord, sinon la page reprenait aussitôt l'ancienne
        // session au lieu de demander une connexion.
        webLoginClear = store.webSessionExpired || store.webSessionMismatch != nil
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

    /// Retouche de la synchro auto du chat, à la seconde (+ = chat plus tard).
    @ViewBuilder private var chatSyncNudgeRow: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.t("chat_sync_adjust"))
                    .font(.tCardTitle)
                    .foregroundColor(.tText)
                Text(store.t("chat_sync_adjust_sub"))
                    .font(.tMeta)
                    .foregroundColor(.tMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text(store.chatSyncNudge == 0 ? "0 s" : String(format: "%+.0f s", store.chatSyncNudge))
                .font(.system(size: 14, weight: .bold).monospacedDigit())
                .foregroundColor(store.chatSyncNudge == 0 ? .tMuted : .tPrimary)
            Stepper("", value: $store.chatSyncNudge, in: -20...20, step: 1)
                .labelsHidden()
                .onChange(of: store.chatSyncNudge) { v in
                    logger.settingChanged("Retouche de la synchro du chat", value: String(format: "%+.0f s", v))
                }
        }
        .padding(.leading, 4)
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
            // Même pastille que dans le menu : les deux niveaux se répondent.
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.tPrimary.opacity(0.16))
                .frame(width: 26, height: 26)
                .overlay {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.tPrimary)
                }
            Text(text)
                .font(.tSection)
                .foregroundColor(.tText)
            Spacer(minLength: 0)
        }
        .padding(.bottom, 2)
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
                VStack(alignment: .leading, spacing: 1) {
                    Text(lang.label)
                        .font(.tCardTitle)
                        .foregroundColor(isSelected ? .tPrimary : .tText)
                    // Dans la langue elle-même : c'est à ses lecteurs qu'on parle.
                    if lang.machineTranslated {
                        Text(translate("lang_ai_badge", lang))
                            .font(.tMeta).foregroundColor(.tMuted)
                    }
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
