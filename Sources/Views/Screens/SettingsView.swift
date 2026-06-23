import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @AppStorage("liveSource") private var liveSource: LiveSource = .auto
    @State private var showLogs        = false
    @State private var showLogoutAlert = false
    @State private var showClearAlert  = false
    
    // Ajout d'une variable d'état pour l'édition manuelle du token
    @State private var manualToken: String = ""

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

                // ── Compte Twitch ───────────────────────────────────
                settingCard {
                    VStack(alignment: .leading, spacing: 12) {
                        label("💜", store.t("twitch_account"))
                        if store.twitchToken != nil {
                            HStack(spacing: 12) {
                                Text("✅")
                                Text(store.t("connected"))
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundColor(.tSuccess)
                                Spacer()
                                Button {
                                    showLogoutAlert = true
                                } label: {
                                    Text(store.t("btn_logout"))
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundColor(.tDanger)
                                        .padding(.horizontal, 14).padding(.vertical, 8)
                                        .background(Color.tDanger.opacity(0.15))
                                        .cornerRadius(8)
                                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.tDanger, lineWidth: 1))
                                }
                            }
                        } else {
                            HStack(spacing: 10) {
                                Text("⚪")
                                Text(store.t("not_connected"))
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.tMuted)
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

                // ── DEBUG Points (temporaire) ─────────────────────────
                settingCard {
                    VStack(alignment: .leading, spacing: 12) {
                        label("🔬", "DEBUG — Points de chaîne")

                        Text("Saisis un nouveau token OAuth ou utilise celui existant pour tester le GQL manuellement.")
                            .font(.system(size: 12))
                            .foregroundColor(.tMuted)
                            .fixedSize(horizontal: false, vertical: true)
                        
                        // Éditeur de Token
                        HStack(spacing: 8) {
                            SecureField("OAuth Token (ex: a1b2c3...)", text: $manualToken)
                                .font(.system(size: 12, design: .monospaced))
                                .padding(10)
                                .background(Color.tSurface)
                                .cornerRadius(8)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled(true)
                            
                            Button {
                                store.twitchToken = manualToken.isEmpty ? nil : manualToken
                                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                            } label: {
                                Text("Sauver")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 12).padding(.vertical, 10)
                                    .background(Color.tPrimary)
                                    .cornerRadius(8)
                            }
                        }

                        if let token = store.twitchToken, !token.isEmpty {
                            // Bouton pour copier le token actuel si besoin
                            Button {
                                UIPasteboard.general.string = token
                            } label: {
                                HStack {
                                    Text("Copier le token actuel")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(.tPrimary)
                                    Spacer()
                                    Image(systemName: "doc.on.doc")
                                        .foregroundColor(.tPrimary)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 8)
                                .background(Color.tPrimary.opacity(0.15))
                                .cornerRadius(8)
                            }

                            // Bouton test direct depuis l'app
                            Button {
                                Task {
                                    logger.info("DEBUG/GQL", "Test communityPoints…", "OAuth + kGQLClientID · canal: samueletienne")
                                    guard let url = URL(string: "https://gql.twitch.tv/gql") else { return }
                                    var req = URLRequest(url: url)
                                    req.httpMethod = "POST"
                                    req.setValue("kimne78kx3ncx6brgo4mv6wki5h1ko", forHTTPHeaderField: "Client-ID")
                                    req.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
                                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                                    req.httpBody = try? JSONSerialization.data(withJSONObject: [
                                        "query": "{ channel(name: \"samueletienne\") { self { communityPoints { balance availableClaim { id } } } } }"
                                    ])
                                    if let (data, resp) = try? await URLSession.shared.data(for: req),
                                       let status = (resp as? HTTPURLResponse)?.statusCode,
                                       let raw = String(data: data, encoding: .utf8) {
                                        if status == 200 {
                                            logger.success("DEBUG/GQL", "HTTP \(status)", String(raw.prefix(500)))
                                        } else {
                                            logger.error("DEBUG/GQL", "HTTP \(status)", String(raw.prefix(200)))
                                        }
                                    }
                                }
                            } label: {
                                Label("Tester GQL depuis l'app (voir Logs)", systemImage: "play.fill")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(Color.tSuccess)
                                    .cornerRadius(10)
                            }

                            // Commande curl pour test Mac
                            Button {
                                let curlStr = "curl -s -X POST https://gql.twitch.tv/gql -H \"Client-ID: kimne78kx3ncx6brgo4mv6wki5h1ko\" -H \"Authorization: OAuth \(token)\" -H \"Content-Type: application/json\" -d '{\"query\":\"{ channel(name: \\\"samueletienne\\\") { self { communityPoints { balance } } } }\"}'"
                                UIPasteboard.general.string = curlStr
                            } label: {
                                Label("Copier commande curl (Mac Terminal)", systemImage: "terminal")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.tText)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .background(Color.tSurface)
                                    .cornerRadius(8)
                            }
                        }
                    }
                }

                Spacer(minLength: 32)
            }
            .padding(.horizontal, 12)
        }
        .background(Color.tDark)
        .onAppear {
            // Initialiser le champ texte avec le token actuel au chargement
            manualToken = store.twitchToken ?? ""
        }
        // ── Alerts ──────────────────────────────────────────────────
        .alert(store.t("btn_logout"), isPresented: $showLogoutAlert) {
            Button(store.t("cancel"), role: .cancel) {}
            Button(store.t("btn_logout"), role: .destructive) {
                logger.authLogout()
                store.logout()
                manualToken = "" // Vider le champ lors de la déconnexion
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
