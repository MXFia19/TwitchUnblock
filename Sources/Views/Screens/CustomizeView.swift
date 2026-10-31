import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════
//  Réglages → Personnaliser : ce que l'app montre, et dans quel ordre.
//  Onglets, accueil, page d'une chaîne, boutons du lecteur et bandeaux du
//  chat. La liste reste en mode édition : l'ordre se change en faisant
//  glisser ≡, chaque élément s'affiche ou se masque d'un interrupteur.
//  Modèle : Customization.swift.
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

                // ── Sans compte Twitch : ce qui y invite disparaît ──
                // Rien ne se masque pour quelqu'un de connecté (accountHidden).
                Section {
                    toggle(store.t("cust_no_account"), icon: "person.crop.circle.badge.xmark",
                           $store.customization.hideAccount, log: "Sans compte Twitch")
                        .disabled(signedIn)
                } footer: {
                    Text(store.t(signedIn ? "cust_no_account_signed_in" : "cust_no_account_foot"))
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
                    // Directs des chaînes épinglées, en tête des Suivies.
                    toggle(store.t("cust_pinned_viewers"), icon: "pin.fill",
                           $store.customization.pinnedByViewers, log: "Épinglées triées par spectateurs")
                } header: {
                    Text(store.t("cust_home_tabs"))
                } footer: {
                    Text(store.t("cust_pinned_viewers_foot"))
                }

                Section {
                    // Cartes de connexion : déjà masquées sans compte Twitch.
                    ForEach(UICustomization.homeCards, id: \.self) { key in
                        visibilityRow(key, in: \.hiddenHome,
                                      locked: store.accountHidden && ["login", "web"].contains(key))
                    }
                } header: {
                    Text(store.t("cust_home_cards"))
                } footer: {
                    Text(store.t("cust_home_foot"))
                }

                // ── Catégories suivies : taille des jaquettes, ordre ─
                Section {
                    Picker(selection: compactCategories) {
                        Text(store.t("cust_cat_normal")).tag(false)
                        Text(store.t("cust_cat_compact")).tag(true)
                    } label: {
                        Label(store.t("cust_cat_size"), systemImage: "square.grid.3x3.fill").foregroundColor(.tText)
                    }
                    .tint(.tPrimary)
                    .listRowBackground(Color.tCard)
                    Picker(selection: categorySort) {
                        ForEach(FollowedCategorySort.allCases) { sort in
                            Text(store.t(sort.labelKey)).tag(sort)
                        }
                    } label: {
                        Label(store.t("cust_cat_sort"), systemImage: "arrow.up.arrow.down").foregroundColor(.tText)
                    }
                    .tint(.tPrimary)
                    .listRowBackground(Color.tCard)
                } header: {
                    Text(store.t("cust_followed_cats"))
                } footer: {
                    Text(store.t("cust_followed_cats_foot"))
                }

                // ── Page d'une chaîne : ses onglets ─────────────────
                Section {
                    ForEach(c.channelTabs, id: \.self) { key in
                        visibilityRow(key, in: \.hiddenChannelTabs, locked: lastChannelTab(key))
                    }
                    .onMove { move(\.channelTabOrder, c.channelTabs, from: $0, to: $1) }
                } header: {
                    Text(store.t("cust_channel_tabs"))
                } footer: {
                    Text(store.t("cust_channel_tabs_foot"))
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
                CustomizeChatSection()

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

    /// Compte de l'app ou session web : « Sans compte Twitch » ne masquerait
    /// rien, l'interrupteur est grisé et sa note dit pourquoi.
    private var signedIn: Bool { store.twitchToken != nil || store.twitchWebToken != nil }

    // MARK: – Lignes

    /// Affiché ou masqué. `locked` : le dernier affiché d'une liste qui en
    /// garde toujours un (onglets, onglets des lives, d'une chaîne).
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

    /// Dernier onglet affiché de la page d'une chaîne, sans compter le
    /// planning (seulement pour les chaînes qui en ont un) : il reste.
    private func lastChannelTab(_ key: String) -> Bool {
        let c = store.customization
        return c.visibleChannelTabs.filter { $0 != "schedule" } == [key] && !c.hiddenChannelTabs.contains(key)
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

    /// Catégories suivies en jaquettes compactes (3 par ligne, 4 sur iPad).
    private var compactCategories: Binding<Bool> {
        Binding(get: { store.customization.compactFollowedCategories },
                set: { on in
                    logger.settingChanged("Catégories suivies · taille", value: on ? "compacte" : "normale")
                    store.customization.compactFollowedCategories = on
                })
    }

    /// Ordre des catégories suivies : les plus regardées d'abord, ou A → Z.
    private var categorySort: Binding<FollowedCategorySort> {
        Binding(get: { store.customization.followedCategoriesSort },
                set: { sort in
                    logger.settingChanged("Catégories suivies · ordre", value: sort == .name ? "alphabétique" : "spectateurs")
                    store.customization.followedCategoriesSort = sort
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
        case "continue":     return (store.t("continue_watching"), "play.circle.fill")
        case "categories":   return (store.t("cust_categories"), "square.grid.2x2.fill")
        // Page d'une chaîne
        case "vods":         return (store.t("vods"), "film")
        case "highlights":   return (store.t("highlights"), "star")
        case "playlists":    return (store.t("playlists"), "list.bullet.rectangle")
        case "clips":        return (store.t("clips"), "scissors")
        case "schedule":     return (store.t("sched_tab"), "calendar")
        case "about":        return (store.t("about"), "info.circle")
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

// MARK: – Chat
/// Section « Chat · bandeaux » : bandeaux au-dessus des messages et ce qui
/// entoure le chat. Struct à part : la liste de CustomizeView porte déjà
/// toutes les autres sections, et sur iOS 18 un type de vue trop imbriqué
/// fait déborder la pile à son décodage (voir SettingsView.sectionPage).
private struct CustomizeChatSection: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Section {
            toggle(store.t("cfg_pinned"), icon: "pin.fill",
                   $store.showPinnedMessages, log: "Messages épinglés")
            toggle(store.t("cfg_drops_notice"), icon: "gift.fill",
                   $store.showDropsNotice, log: "Carte des drops")
            // Sous les drops de la chaîne : les campagnes de Twitch rangées
            // dans « Special Events », à masquer à part.
            toggle(store.t("cust_special_events"), icon: "ticket.fill",
                   $store.showSpecialEvents, log: "Cartes Special Events")
                .padding(.leading, TSpace.lg)
                .disabled(!store.showDropsNotice)
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
            // Boutons et pastilles autour des messages : en groupe, la
            // section reste sous les dix vues d'un ViewBuilder (iOS 16).
            Group {
                toggle(store.t("cfg_follow"), icon: "heart.fill",
                       $store.showFollowButton, log: "Bouton suivre")
                toggle(store.t("cust_chat_bell"), icon: "bell.fill",
                       $store.showChatBell, log: "Cloche du chat")
                toggle(store.t("cust_chat_modes"), icon: "exclamationmark.bubble.fill",
                       $store.showChatModes, log: "Mode du chat")
                toggle(store.t("cust_chat_points"), icon: "crown.fill",
                       $store.showChatPoints, log: "Bouton des points du chat")
            }
        } header: {
            Text(store.t("cust_chat"))
        } footer: {
            Text(store.t("cust_special_events_foot") + "\n" + store.t("cust_chat_buttons_foot"))
        }
    }

    /// Comme CustomizeView.toggle : la ligne, et le changement au journal.
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
}
