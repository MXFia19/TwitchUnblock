import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════
//  Réglages → Personnaliser : ce que l'app montre, et dans quel ordre.
//  Onglets, accueil, boutons du lecteur et bandeaux du chat. La liste reste
//  en mode édition : l'ordre se change en faisant glisser ≡, chaque élément
//  s'affiche ou se masque d'un interrupteur. Modèle : Customization.swift.
// ═══════════════════════════════════════════════════════════════════════════

struct CustomizeView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmReset = false

    var body: some View {
        let c = store.customization
        NavigationStack {
            List {
                Section {
                    Text(store.t("cust_sub"))
                        .font(.tMeta).foregroundColor(.tMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .listRowBackground(Color.tCard)
                }

                // ── Onglets ─────────────────────────────────────────
                Section {
                    ForEach(c.tabs, id: \.self) { key in
                        visibilityRow(key, in: \.hiddenTabs,
                                      locked: c.visibleTabs == [key] && !c.hiddenTabs.contains(key))
                    }
                    .onMove { move(\.tabOrder, c.tabs, from: $0, to: $1) }

                    Picker(store.t("cust_launch_tab"), selection: launchTab) {
                        ForEach(c.visibleTabs, id: \.self) { key in
                            Text(item(key).title).tag(key)
                        }
                    }
                    .tint(.tPrimary)
                    .listRowBackground(Color.tCard)
                } header: {
                    Text(store.t("cust_tabs"))
                } footer: {
                    Text(store.t("cust_tabs_foot"))
                }

                // ── Accueil : onglets des lives, puis cartes ────────
                Section {
                    ForEach(c.homeChips, id: \.self) { key in
                        visibilityRow(key, in: \.hiddenHome,
                                      locked: c.visibleHomeChips == [key] && c.shows(home: key))
                    }
                    .onMove { move(\.homeOrder, c.homeChips, from: $0, to: $1) }
                } header: {
                    Text(store.t("cust_home_tabs"))
                }

                Section {
                    ForEach(UICustomization.homeCards, id: \.self) { key in
                        visibilityRow(key, in: \.hiddenHome)
                    }
                } header: {
                    Text(store.t("cust_home_cards"))
                } footer: {
                    Text(store.t("cust_home_foot"))
                }

                // ── Lecteur : barre du bas, AirPlay en haut ─────────
                Section {
                    ForEach(c.playerButtons, id: \.self) { key in
                        visibilityRow(key, in: \.hiddenPlayer)
                    }
                    .onMove { move(\.playerOrder, c.playerButtons, from: $0, to: $1) }
                    visibilityRow("airplay", in: \.hiddenPlayer)
                } header: {
                    Text(store.t("cust_player"))
                } footer: {
                    Text(store.t("cust_player_foot"))
                }

                // ── Chat : bandeaux au-dessus des messages ──────────
                Section {
                    toggle(store.t("cfg_pinned"), icon: "pin.fill",
                           $store.showPinnedMessages, log: "Messages épinglés")
                    toggle(store.t("cfg_drops_notice"), icon: "gift.fill",
                           $store.showDropsNotice, log: "Carte des drops")
                    toggle(store.t("cust_live_events"), icon: "bolt.fill",
                           $store.showLiveEvents, log: "Événements live")
                    // Un par un, sous « Événements du live ».
                    Group {
                        toggle(store.t("cust_polls"), icon: "chart.bar.fill",
                               $store.showPolls, log: "Sondages du chat")
                        toggle(store.t("cust_predictions"), icon: "sparkles",
                               $store.showPredictions, log: "Prédictions du chat")
                        toggle(store.t("hype_train"), icon: "tram.fill",
                               $store.showHypeTrain, log: "Hype train")
                    }
                    .padding(.leading, TSpace.lg)
                    .disabled(!store.showLiveEvents)
                    toggle(store.t("cfg_raids"), icon: "person.3.fill",
                           $store.enableRaids, log: "Système de raid")
                    toggle(store.t("cfg_streak"), icon: "flame.fill",
                           $store.showWatchStreak, log: "Série de visionnage")
                    toggle(store.t("cfg_follow"), icon: "heart.fill",
                           $store.showFollowButton, log: "Bouton suivre")
                } header: {
                    Text(store.t("cust_chat"))
                }

                Section {
                    Button(role: .destructive) { confirmReset = true } label: {
                        Label(store.t("cust_reset"), systemImage: "arrow.counterclockwise")
                    }
                    .listRowBackground(Color.tCard)
                }
            }
            // Toujours en édition : les poignées ≡ sans bouton « Modifier ».
            .environment(\.editMode, .constant(.active))
            .scrollContentBackground(.hidden)
            .background(Color.tDark)
            .navigationTitle(store.t("cust_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(store.t("close")) { dismiss() }
                }
            }
            .alert(store.t("cust_reset"), isPresented: $confirmReset) {
                Button(store.t("cancel"), role: .cancel) {}
                Button(store.t("cust_reset"), role: .destructive) {
                    logger.settingChanged("Personnaliser", value: "disposition d'origine")
                    withAnimation { store.resetCustomization() }
                }
            } message: {
                Text(store.t("cust_reset_confirm"))
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: – Lignes

    /// Affiché ou masqué. `locked` : le dernier affiché d'une liste qui en
    /// garde toujours un (onglets, onglets des lives).
    private func visibilityRow(_ key: String, in list: WritableKeyPath<UICustomization, [String]>,
                               locked: Bool = false) -> some View {
        let it = item(key)
        return Toggle(isOn: Binding(
            get: { !store.customization[keyPath: list].contains(key) },
            set: { on in
                logger.settingChanged("Personnaliser · \(key)", value: on ? "affiché" : "masqué")
                withAnimation { store.customization.set(key, hidden: !on, in: list) }
            })) {
            Label(it.title, systemImage: it.icon).foregroundColor(.tText)
        }
        .tint(.tPrimary)
        .disabled(locked)
        .listRowBackground(Color.tCard)
    }

    private func toggle(_ title: String, icon: String, _ value: Binding<Bool>, log: String) -> some View {
        Toggle(isOn: Binding(
            get: { value.wrappedValue },
            set: { on in
                logger.settingChanged(log, value: on ? "activé" : "désactivé")
                value.wrappedValue = on
            })) {
            Label(title, systemImage: icon).foregroundColor(.tText)
        }
        .tint(.tPrimary)
        .listRowBackground(Color.tCard)
    }

    /// Ordre changé en faisant glisser ≡.
    private func move(_ order: WritableKeyPath<UICustomization, [String]>, _ current: [String],
                      from: IndexSet, to: Int) {
        var list = current
        list.move(fromOffsets: from, toOffset: to)
        logger.settingChanged("Personnaliser · ordre", value: list.joined(separator: ", "))
        store.customization[keyPath: order] = list
    }

    /// L'onglet du lancement, parmi ceux affichés.
    private var launchTab: Binding<String> {
        Binding(get: { store.customization.startTab },
                set: { tab in
                    logger.settingChanged("Onglet au lancement", value: tab)
                    store.customization.launchTab = tab
                })
    }

    /// Libellé et icône d'un élément (clés de UICustomization).
    private func item(_ key: String) -> (title: String, icon: String) {
        switch key {
        // Accueil
        case "followed":     return (store.t("home_followed"), "heart.fill")
        case "top":          return (store.t("top_streams"), "chart.line.uptrend.xyaxis")
        case "offline":      return (store.t("offline_channels"), "moon.fill")
        case "announcement": return (store.t("cust_announcement"), "megaphone.fill")
        case "poll":         return (store.t("cust_dev_poll"), "checklist")
        case "login":        return (store.t("cust_login_card"), "person.crop.circle.badge.plus")
        case "web":          return (store.t("cust_web_banner"), "globe")
        case "categories":   return (store.t("cust_categories"), "square.grid.2x2.fill")
        // Lecteur
        case "mute":         return (store.t("pb_mute"), "speaker.wave.2.fill")
        case "pip":          return (store.t("pb_pip"), "pip.enter")
        case "refresh":      return (store.t("pb_refresh"), "arrow.clockwise")
        case "chat":         return (store.t("pb_chat"), "sidebar.right")
        case "rotate":       return (store.t("pb_rotate"), "rectangle.landscape.rotate")
        case "sleep":        return (store.t("sleep_timer"), "moon.zzz")
        case "multi":        return (store.t("multi_title"), "square.grid.2x2")
        case "rewind":       return (store.t("rewind"), "gobackward")
        case "airplay":      return (store.t("pb_airplay"), "airplayvideo")
        // Onglets
        default:
            let tab = MainTabView.TabName(rawValue: key)
            return (tab?.label(store) ?? key, tab?.iconFilled ?? "square")
        }
    }
}
