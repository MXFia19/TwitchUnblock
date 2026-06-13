import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    
    // ✨ AppStorage permet de sauvegarder le réglage sans devoir modifier AppStore.swift !
    @AppStorage("liveSource") private var liveSource: LiveSource = .auto

    private var vodCount: Int { store.history.filter { $0.type == .vod }.count }
    private var channelCount: Int { store.history.filter { $0.type == .channel }.count }

    var body: some View {
        NavigationView {
            Form {
                // Section Choix du Serveur
                Section(header: Text(store.t("settings_source"))) {
                    Picker(store.t("settings_source"), selection: $liveSource) {
                        Text(store.t("source_auto")).tag(LiveSource.auto)
                        Text(store.t("source_luminous")).tag(LiveSource.luminous)
                        Text(store.t("source_twitch")).tag(LiveSource.twitch)
                        Text(store.t("source_cloudflare")).tag(LiveSource.cloudflare)
                    }
                    .tint(.tPrimary)
                }

                // Section Langue
                Section(header: Text(store.t("settings_lang"))) {
                    Picker(store.t("settings_lang"), selection: $store.lang) {
                        ForEach(Lang.allCases) { lang in
                            Text("\(lang.flag) \(lang.label)").tag(lang)
                        }
                    }
                    .tint(.tPrimary)
                }

                // Section Historique
                Section(header: Text(store.t("history"))) {
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
                    Button(action: { store.clearHistory() }) {
                        Text(store.t("clear_history"))
                            .foregroundColor(.tDanger)
                    }
                }
            }
            .navigationTitle(store.t("settings"))
            .scrollContentBackground(.hidden)
            .background(Color.tDark.ignoresSafeArea())
        }
    }
}
