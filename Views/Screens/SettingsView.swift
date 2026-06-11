import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showLogs        = false
    @State private var showLogoutAlert = false

    private var vodCount:     Int { store.history.filter { $0.type == .vod }.count }
    private var channelCount: Int { store.history.filter { $0.type == .channel }.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("⚙️ \(store.t("settings"))")
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundColor(.tPurple)
                    .padding(.top, 8)

                // ── Language ────────────────────────────────────────
                section(title: store.t("language")) {
                    VStack(spacing: 8) {
                        ForEach(Lang.allCases) { l in
                            Button { store.lang = l } label: {
                                HStack {
                                    Text("\(l.flag) \(l.label)")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundColor(store.lang == l ? .tPrimary : .tMuted)
                                    Spacer()
                                    if store.lang == l { Image(systemName: "checkmark").foregroundColor(.tPrimary) }
                                }
                                .padding(.vertical, 12).padding(.horizontal, 16)
                                .background(store.lang == l ? Color.tPrimary.opacity(0.13) : Color.tSurface)
                                .cornerRadius(10)
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(store.lang == l ? Color.tPrimary : Color.tBorder, lineWidth: 1))
                            }
                        }
                    }
                }

                // ── Proxy ────────────────────────────────────────────
                section(title: store.t("proxy")) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(store.t("proxy_enable"))
                                .font(.system(size: 15, weight: .semibold)).foregroundColor(.tText)
                            Text(store.t("proxy_sub"))
                                .font(.system(size: 12)).foregroundColor(.tMuted).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Toggle("", isOn: $store.useProxy)
                            .labelsHidden()
                            .tint(.tPrimary)
                    }
                }

                // ── Twitch Account ───────────────────────────────────
                section(title: store.t("twitch_account")) {
                    if store.twitchToken != nil {
                        HStack {
                            Text(store.t("connected"))
                                .font(.system(size: 15, weight: .bold)).foregroundColor(.tSuccess)
                            Spacer()
                            Button {
                                showLogoutAlert = true
                            } label: {
                                Text(store.t("btn_logout"))
                                    .font(.system(size: 13, weight: .bold)).foregroundColor(.tDanger)
                                    .padding(.horizontal, 14).padding(.vertical, 8)
                                    .background(Color.tDanger.opacity(0.15))
                                    .cornerRadius(8)
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.tDanger, lineWidth: 1))
                            }
                        }
                    } else {
                        Text(store.t("not_connected"))
                            .font(.system(size: 14)).foregroundColor(.tMuted)
                    }
                }

                // ── History stats ────────────────────────────────────
                section(title: store.t("history")) {
                    HStack(spacing: 12) {
                        statBox(value: vodCount, label: store.t("vods"))
                        statBox(value: channelCount, label: store.t("channels"))
                    }
                }

                // ── About ────────────────────────────────────────────
                section(title: store.t("about")) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("TwitchUnblock")
                            .font(.system(size: 18, weight: .heavy)).foregroundColor(.white)
                        Text(store.t("version"))
                            .font(.system(size: 12)).foregroundColor(.tMuted)
                        Text(store.t("about_desc"))
                            .font(.system(size: 13)).foregroundColor(.tMuted).fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 8)
                        Button { showLogs = true } label: {
                            Text(store.t("show_logs"))
                                .font(.system(size: 13, weight: .semibold)).foregroundColor(.tPrimary)
                                .frame(maxWidth: .infinity).padding(.vertical, 10)
                                .background(Color.tSurface).cornerRadius(8)
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.tBorder, lineWidth: 1))
                        }
                        .padding(.top, 16)
                    }
                }

                Spacer(minLength: 40)
            }
            .padding(16)
        }
        .background(Color.tDark)
        .alert(store.t("btn_logout"), isPresented: $showLogoutAlert) {
            Button(store.t("cancel"), role: .cancel) {}
            Button(store.t("btn_logout"), role: .destructive) { store.logout() }
        } message: {
            Text(store.t("confirm_logout"))
        }
        .sheet(isPresented: $showLogs) {
            VStack(spacing: 0) {
                HStack {
                    Text("Logs Système")
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

    // MARK: – Subviews
    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title.uppercased())
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.tPurple)
                .tracking(0.5)
            content()
        }
        .padding(16)
        .background(Color.tCard)
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.tBorder, lineWidth: 1))
    }

    @ViewBuilder
    private func statBox(value: Int, label: String) -> some View {
        VStack(spacing: 4) {
            Text("\(value)")
                .font(.system(size: 28, weight: .heavy)).foregroundColor(.tPrimary)
            Text(label)
                .font(.system(size: 12, weight: .semibold)).foregroundColor(.tMuted)
        }
        .frame(maxWidth: .infinity).padding(16)
        .background(Color.tSurface).cornerRadius(10)
    }
}
