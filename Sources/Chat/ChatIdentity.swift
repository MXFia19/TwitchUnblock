import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════
//  Identité dans le chat : le badge montré à côté de son nom (fb_mwjodpzf).
//
//  Comme « Identité dans le chat » sur twitch.tv : un badge global (Prime
//  Gaming, Turbo, un événement…) parmi ceux du compte, montré dans tous les
//  chats, sur Twitch aussi ; et, pour la chaîne regardée, son badge à elle
//  (abonnement, bits…), qui y remplace le global. Comme le site (extension
//  TwitchUnblock Connect 0.5.0).
//
//  Demande la session web. La lecture passe sans jeton d'intégrité ; le choix,
//  une mutation, passe par TwitchGQL (jeton d'intégrité, nouvel essai s'il est
//  refusé). Champs et mutations vérifiés le 24/11 par une sonde publique sans
//  session : la validation du schéma accepte `currentUser { availableBadges
//  { setID version title imageURL } selectedBadge }`, `user(login) { self
//  { availableBadges selectedBadge } }`, `selectGlobalBadge(input:
//  { badgeSetID, badgeSetVersion }) { user }` et `selectChannelBadge(input:
//  { channelID, badgeSetID, badgeSetVersion }) { user }` (un champ inventé,
//  lui, est refusé), et Twitch répond « unauthenticated » sans rien changer.
// ═══════════════════════════════════════════════════════════════════════════

struct ChatBadgeChoice: Identifiable, Equatable {
    let setID: String
    let version: String
    let title: String
    let imageURL: String
    var id: String { "\(setID)/\(version)" }
}

enum ChatIdentity {
    /// Chaîne regardée (direct, VOD), tenue à jour par MainTabView : la
    /// feuille propose aussi le badge de cette chaîne.
    static var watchingLogin: String?

    private static let badgeFields = "availableBadges { setID version title imageURL } selectedBadge { setID version }"

    /// Badges globaux du compte, et celui qui est choisi (« setID/version »).
    /// nil : session refusée, réseau ou réponse illisible.
    static func globalBadges(token: String) async -> (available: [ChatBadgeChoice], selected: String?)? {
        let q = "query { currentUser { id \(badgeFields) } }"
        guard let json = await accountQuery(q, token: token),
              let user = (json["data"] as? [String: Any])?["currentUser"] as? [String: Any] else {
            logger.warn("CHAT", "Badges du compte indisponibles", nil)
            return nil
        }
        return (badges(user["availableBadges"]), selectedKey(user["selectedBadge"]))
    }

    /// Badges que le compte peut montrer sur une chaîne (abonnement, bits…),
    /// celui qui y est choisi, et l'id de la chaîne (pour le choix). nil :
    /// chaîne inconnue, session refusée, réseau ou réponse illisible.
    static func channelBadges(login: String, token: String) async
        -> (channelID: String, available: [ChatBadgeChoice], selected: String?)? {
        let q = "query($l: String!) { user(login: $l) { id self { \(badgeFields) } } }"
        guard let json = await accountQuery(q, variables: ["l": login], token: token),
              let user = (json["data"] as? [String: Any])?["user"] as? [String: Any],
              let id = user["id"] as? String, !id.isEmpty else {
            logger.warn("CHAT", "Badges de la chaîne indisponibles", login)
            return nil
        }
        let me = user["self"] as? [String: Any]
        return (id, badges(me?["availableBadges"]), selectedKey(me?["selectedBadge"]))
    }

    /// Choisit le badge global du compte. Vrai si Twitch l'a fait.
    @MainActor
    static func selectGlobal(_ badge: ChatBadgeChoice, token: String) async -> Bool {
        let input = "badgeSetID: \"\(gqlStr(badge.setID))\", badgeSetVersion: \"\(gqlStr(badge.version))\""
        return await select("ChatIdentity_SelectGlobalBadge", field: "selectGlobalBadge", input: input,
                            what: badge.id, token: token)
    }

    /// Choisit le badge montré sur une chaîne. Vrai si Twitch l'a fait.
    @MainActor
    static func selectChannel(_ badge: ChatBadgeChoice, channelID: String, login: String,
                              token: String) async -> Bool {
        let input = "channelID: \"\(gqlStr(channelID))\", badgeSetID: \"\(gqlStr(badge.setID))\", "
            + "badgeSetVersion: \"\(gqlStr(badge.version))\""
        return await select("ChatIdentity_SelectChannelBadge", field: "selectChannelBadge", input: input,
                            what: "\(login) · \(badge.id)", token: token)
    }

    /// Mutation de l'app, valeurs écrites dans la requête. Réussie si son
    /// champ rend un `user`, sans erreur.
    @MainActor
    private static func select(_ op: String, field: String, input: String, what: String,
                               token: String) async -> Bool {
        let q = "mutation { \(field)(input: { \(input) }) { user { id } } }"
        let res = await TwitchGQL.shared.rawMutation(op, query: q, variables: [:], token: token)
        let user = ((res?["data"] as? [String: Any])?[field] as? [String: Any])?["user"] as? [String: Any]
        guard user != nil, res?["errors"] == nil else {
            let messages = ((res?["errors"] as? [[String: Any]]) ?? []).compactMap { $0["message"] as? String }
            let why = res == nil ? "jeton d'intégrité ou réseau" : messages.joined(separator: " · ")
            logger.warn("CHAT", "Badge du chat refusé", why.isEmpty ? what : "\(what) · \(why)")
            return false
        }
        logger.success("CHAT", "Badge du chat choisi", what)
        return true
    }

    /// Liste de Twitch → choix, sans doublon (ForEach veut des id uniques).
    private static func badges(_ raw: Any?) -> [ChatBadgeChoice] {
        var seen = Set<String>()
        return ((raw as? [[String: Any]]) ?? []).compactMap { b -> ChatBadgeChoice? in
            guard let set = b["setID"] as? String, let version = b["version"] as? String,
                  seen.insert("\(set)/\(version)").inserted else { return nil }
            return ChatBadgeChoice(setID: set, version: version,
                                   title: (b["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? set,
                                   imageURL: b["imageURL"] as? String ?? "")
        }
    }

    /// Badge choisi, « setID/version ».
    private static func selectedKey(_ raw: Any?) -> String? {
        guard let s = raw as? [String: Any], let set = s["setID"] as? String,
              let version = s["version"] as? String else { return nil }
        return "\(set)/\(version)"
    }

    /// Lecture au nom du compte (session web), sans jeton d'intégrité.
    private static func accountQuery(_ query: String, variables: [String: Any] = [:],
                                     token: String) async -> [String: Any]? {
        var payload: [String: Any] = ["query": query]
        if !variables.isEmpty { payload["variables"] = variables }
        guard let url = URL(string: "https://gql.twitch.tv/gql"),
              let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.httpMethod = "POST"
        req.setValue(kGQLClientID, forHTTPHeaderField: "Client-ID")
        req.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

/// Rangée des Réglages → Chat : ouvre le choix du badge (session web).
struct ChatIdentityRow: View {
    @EnvironmentObject private var store: AppStore
    @State private var showSheet = false

    var body: some View {
        let ready = store.twitchWebToken != nil
        Button {
            if ready { showSheet = true }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.t("chat_identity"))
                        .font(.tCardTitle).foregroundColor(.tText)
                    Text(store.t(ready ? "chat_identity_sub" : "chat_identity_web"))
                        .font(.tMeta).foregroundColor(.tMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if ready {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.tMuted)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!ready)
        .sheet(isPresented: $showSheet) {
            ChatIdentitySheet()
                .environmentObject(store)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}

/// Badges du compte : le global, puis celui de la chaîne regardée. Celui qui
/// est choisi est coché ; en toucher un le choisit (sur Twitch aussi).
struct ChatIdentitySheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var badges: [ChatBadgeChoice] = []
    @State private var selected: String?
    @State private var loading = true
    @State private var loadFailed = false
    /// Choix en cours : « global:setID/version » ou « channel:setID/version ».
    @State private var saving: String?
    @State private var refused = false
    // Badge de la chaîne regardée à l'ouverture (aucune : une phrase).
    @State private var channelLogin: String? = ChatIdentity.watchingLogin
    @State private var channelID: String?
    @State private var channelBadges: [ChatBadgeChoice] = []
    @State private var channelSelected: String?
    @State private var channelLoading = true
    @State private var channelFailed = false
    @State private var channelRefused = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if loading {
                        spinner
                    } else if loadFailed {
                        failed { await loadGlobal() }
                    } else if badges.isEmpty {
                        Text(store.t("chat_identity_empty"))
                            .font(.tMeta).foregroundColor(.tMuted)
                    } else {
                        ForEach(badges) { badge in row(badge, channel: false) }
                    }
                } header: {
                    Text(store.t("chat_identity_global"))
                } footer: {
                    Text(store.t(refused ? "chat_identity_failed" : "chat_identity_footer"))
                        .font(.tMeta).foregroundColor(refused ? .tWarning : .tMuted)
                }
                .listRowBackground(Color.tCard)

                Section {
                    if channelLogin == nil {
                        Text(store.t("chat_identity_channel_hint"))
                            .font(.tMeta).foregroundColor(.tMuted)
                    } else if channelLoading {
                        spinner
                    } else if channelFailed {
                        failed { await loadChannel() }
                    } else if channelBadges.isEmpty {
                        Text(store.t("chat_identity_channel_empty"))
                            .font(.tMeta).foregroundColor(.tMuted)
                    } else {
                        ForEach(channelBadges) { badge in row(badge, channel: true) }
                    }
                } header: {
                    Text(channelLogin.map { store.t("chat_identity_channel").replacingOccurrences(of: "{c}", with: $0) }
                         ?? store.t("chat_identity_channel_any"))
                } footer: {
                    if channelLogin != nil {
                        Text(store.t(channelRefused ? "chat_identity_failed" : "chat_identity_channel_footer"))
                            .font(.tMeta).foregroundColor(channelRefused ? .tWarning : .tMuted)
                    }
                }
                .listRowBackground(Color.tCard)
            }
            .scrollContentBackground(.hidden)
            .background(Color.tDark)
            .navigationTitle(store.t("chat_identity"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(store.t("close")) { dismiss() }
                }
            }
            .task { await loadGlobal() }
            .task { await loadChannel() }
        }
        .preferredColorScheme(.dark)
    }

    private var spinner: some View {
        HStack { Spacer(); ProgressView().tint(.tPrimary); Spacer() }
    }

    private func failed(retry: @escaping () async -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(store.t("chat_identity_load_failed"))
                .font(.tMeta).foregroundColor(.tMuted)
            Button(store.t("retry")) { Task { await retry() } }
                .font(.system(size: 14, weight: .semibold)).foregroundColor(.tPrimary)
        }
    }

    private func row(_ badge: ChatBadgeChoice, channel: Bool) -> some View {
        let key = (channel ? "channel:" : "global:") + badge.id
        let isOn = (channel ? channelSelected : selected) == badge.id
        return Button {
            Task {
                if channel { await chooseChannel(badge) } else { await choose(badge) }
            }
        } label: {
            HStack(spacing: 12) {
                AsyncImage(url: URL(string: badge.imageURL)) { img in
                    img.resizable().scaledToFit()
                } placeholder: {
                    RoundedRectangle(cornerRadius: 3).fill(Color.tSurface)
                }
                .frame(width: 22, height: 22)
                Text(badge.title)
                    .font(.system(size: 15, weight: .semibold)).foregroundColor(.tText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if saving == key {
                    ProgressView().tint(.tPrimary)
                } else if isOn {
                    Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundColor(.tPrimary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(saving != nil)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    @MainActor private func loadGlobal() async {
        guard let token = store.twitchWebToken else { loading = false; loadFailed = true; return }
        loading = true
        loadFailed = false
        let result = await ChatIdentity.globalBadges(token: token)
        loading = false
        guard let result else { loadFailed = true; return }
        badges = result.available
        selected = result.selected
    }

    @MainActor private func loadChannel() async {
        guard let login = channelLogin else { return }
        guard let token = store.twitchWebToken else { channelLoading = false; channelFailed = true; return }
        channelLoading = true
        channelFailed = false
        let result = await ChatIdentity.channelBadges(login: login, token: token)
        channelLoading = false
        guard let result else { channelFailed = true; return }
        channelID = result.channelID
        channelBadges = result.available
        channelSelected = result.selected
    }

    @MainActor private func choose(_ badge: ChatBadgeChoice) async {
        guard badge.id != selected, saving == nil, let token = store.twitchWebToken else { return }
        saving = "global:" + badge.id
        refused = false
        let ok = await ChatIdentity.selectGlobal(badge, token: token)
        saving = nil
        if ok { selected = badge.id } else { refused = true }
    }

    @MainActor private func chooseChannel(_ badge: ChatBadgeChoice) async {
        guard badge.id != channelSelected, saving == nil, let login = channelLogin, let id = channelID,
              let token = store.twitchWebToken else { return }
        saving = "channel:" + badge.id
        channelRefused = false
        let ok = await ChatIdentity.selectChannel(badge, channelID: id, login: login, token: token)
        saving = nil
        if ok { channelSelected = badge.id } else { channelRefused = true }
    }
}
