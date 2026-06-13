import SwiftUI

// MARK: – LiveSource
enum LiveSource: String, CaseIterable {
    case auto, luminous, twitch, cloudflare
}

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @AppStorage("liveSource") private var liveSource: LiveSource = .auto
    @State private var showLogs        = false
    @State private var showLogoutAlert = false

    private var vodCount:     Int { store.history.filter { $0.type == .vod }.count }
    private var channelCount: Int { store.history.filter { $0.type == .channel }.count }

    var body: some View {
        NavigationView {
            Form {
                // ── Source ──────────────────────────────────────────
                Section {
                    Picker(store.t("settings_source"), selection: $liveSource) {
                        Text("Auto").tag(LiveSource.auto)
                        Text("Luminous").tag(LiveSource.luminous)
                        Text("Twitch").tag(LiveSource.twitch)
                        Text("Cloudflare").tag(LiveSource.cloudflare)
                    }
                    .tint(.tPrimary)
                } header: {
                    Text(store.t("proxy"))
                }

                // ── Langue ──────────────────────────────────────────
                Section {
                    Picker(store.t("language"), selection: $store.lang) {
                        ForEach(Lang.allCases) { lang in
                            Text("\(lang.flag) \(lang.label)").tag(lang)
                        }
                    }
                    .tint(.tPrimary)
                } header: {
                    Text(store.t("language"))
                }

                // ── Proxy toggle ────────────────────────────────────
                Section {
                    Toggle(store.t("proxy_enable"), isOn: $store.useProxy)
                        .tint(.tPrimary)
                    Text(store.t("proxy_sub"))
                        .font(.system(size: 12))
                        .foregroundColor(.tMuted)
                } header: {
                    Text(store.t("proxy"))
                }

                // ── Compte Twitch ───────────────────────────────────
                Section {
                    if store.twitchToken != nil {
                        HStack {
                            Text(store.t("connected"))
                                .foregroundColor(.tSuccess)
                            Spacer()
                            Button(store.t("btn_logout")) {
                                showLogoutAlert = true
                            }
                            .foregroundColor(.tDanger)
                        }
                    } else {
                        Text(store.t("not_connected"))
                            .foregroundColor(.tMuted)
                    }
                } header: {
                    Text(store.t("twitch_account"))
                }

                // ── Historique ──────────────────────────────────────
                Section {
                    HStack {
                        Text(store.t("vods"))
                        Spacer()
                        Text("\(vodCount)").foregroundColor(.tMuted)
                    }
                    HStack {
                        Text(store.t("channels"))
                        Spacer()
                        Text("\(channelCount)").foregroundColor(.tMuted)
                    }
                    Button {
                        store.history = []
                    } label: {
                        Text(store.t("btn_clear"))
                            .foregroundColor(.tDanger)
                    }
                } header: {
                    Text(store.t("history"))
                }

                // ── À propos ────────────────────────────────────────
                Section {
                    HStack {
                        Text("TwitchUnblock")
                            .fontWeight(.bold)
                        Spacer()
                        Text(store.t("version"))
                            .foregroundColor(.tMuted)
                    }
                    Button {
                        showLogs = true
                    } label: {
                        Text(store.t("show_logs"))
                            .foregroundColor(.tPrimary)
                    }
                } header: {
                    Text(store.t("about"))
                }
            }
            .navigationTitle(store.t("settings"))
            .scrollContentBackground(.hidden)
            .background(Color.tDark.ignoresSafeArea())
            .alert(store.t("btn_logout"), isPresented: $showLogoutAlert) {
                Button(store.t("cancel"), role: .cancel) {}
                Button(store.t("btn_logout"), role: .destructive) { store.logout() }
            } message: {
                Text(store.t("confirm_logout"))
            }
            .sheet(isPresented: $showLogs) {
                VStack(spacing: 0) {
                    HStack {
                        Text("Logs")
                            .font(.system(size: 16, weight: .bold)).foregroundColor(.white)
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
    }
}
