import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════
//  Identité dans le chat : le badge montré à côté de son nom (fb_mwjodpzf).
//
//  Comme « Identité dans le chat » sur twitch.tv : un badge global (Prime
//  Gaming, Turbo, un événement…) parmi ceux du compte, montré dans tous les
//  chats, sur Twitch aussi. Les badges d'une chaîne (abonnement, bits) restent
//  à choisir sur twitch.tv.
//
//  Demande la session web. La lecture passe sans jeton d'intégrité ; le choix,
//  une mutation, passe par TwitchGQL (jeton d'intégrité, nouvel essai s'il est
//  refusé). Champs et mutation vérifiés le 24/11 par une sonde publique sans
//  session : la validation du schéma accepte `currentUser { availableBadges
//  { setID version title imageURL } selectedBadge }` et `selectGlobalBadge(
//  input: { badgeSetID, badgeSetVersion }) { user }` (un champ inventé, lui,
//  est refusé), et Twitch répond « unauthenticated » sans rien changer.
// ═══════════════════════════════════════════════════════════════════════════

struct ChatBadgeChoice: Identifiable, Equatable {
    let setID: String
    let version: String
    let title: String
    let imageURL: String
    var id: String { "\(setID)/\(version)" }
}

enum ChatIdentity {
    /// Badges globaux du compte, et celui qui est choisi (« setID/version »).
    /// nil : session refusée, réseau ou réponse illisible.
    static func globalBadges(token: String) async -> (available: [ChatBadgeChoice], selected: String?)? {
        let q = "query { currentUser { id availableBadges { setID version title imageURL } selectedBadge { setID version } } }"
        guard let json = await accountQuery(q, token: token),
              let user = (json["data"] as? [String: Any])?["currentUser"] as? [String: Any] else {
            logger.warn("CHAT", "Badges du compte indisponibles", nil)
            return nil
        }
        let list = ((user["availableBadges"] as? [[String: Any]]) ?? []).compactMap { b -> ChatBadgeChoice? in
            guard let set = b["setID"] as? String, let version = b["version"] as? String else { return nil }
            return ChatBadgeChoice(setID: set, version: version,
                                   title: (b["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? set,
                                   imageURL: b["imageURL"] as? String ?? "")
        }
        let selected = (user["selectedBadge"] as? [String: Any]).flatMap { s -> String? in
            guard let set = s["setID"] as? String, let version = s["version"] as? String else { return nil }
            return "\(set)/\(version)"
        }
        return (list, selected)
    }

    /// Choisit le badge global du compte. Vrai si Twitch l'a fait.
    @MainActor
    static func selectGlobal(_ badge: ChatBadgeChoice, token: String) async -> Bool {
        let q = "mutation { selectGlobalBadge(input: { badgeSetID: \"\(gqlStr(badge.setID))\", "
            + "badgeSetVersion: \"\(gqlStr(badge.version))\" }) { user { id } } }"
        let res = await TwitchGQL.shared.rawMutation("ChatIdentity_SelectGlobalBadge", query: q,
                                                     variables: [:], token: token)
        let user = ((res?["data"] as? [String: Any])?["selectGlobalBadge"] as? [String: Any])?["user"] as? [String: Any]
        guard user != nil, res?["errors"] == nil else {
            let messages = ((res?["errors"] as? [[String: Any]]) ?? []).compactMap { $0["message"] as? String }
            let why = res == nil ? "jeton d'intégrité ou réseau" : messages.joined(separator: " · ")
            logger.warn("CHAT", "Badge du chat refusé", why.isEmpty ? badge.id : "\(badge.id) · \(why)")
            return false
        }
        logger.success("CHAT", "Badge du chat choisi", badge.id)
        return true
    }

    /// Lecture au nom du compte (session web), sans jeton d'intégrité.
    private static func accountQuery(_ query: String, token: String) async -> [String: Any]? {
        guard let url = URL(string: "https://gql.twitch.tv/gql"),
              let body = try? JSONSerialization.data(withJSONObject: ["query": query]) else { return nil }
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

/// Badges globaux du compte : celui qui est choisi est coché ; en toucher un
/// le choisit (sur Twitch aussi).
struct ChatIdentitySheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var badges: [ChatBadgeChoice] = []
    @State private var selected: String?
    @State private var loading = true
    @State private var loadFailed = false
    @State private var saving: String?
    @State private var refused = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if loading {
                        HStack { Spacer(); ProgressView().tint(.tPrimary); Spacer() }
                    } else if loadFailed {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(store.t("chat_identity_load_failed"))
                                .font(.tMeta).foregroundColor(.tMuted)
                            Button(store.t("retry")) { Task { await load() } }
                                .font(.system(size: 14, weight: .semibold)).foregroundColor(.tPrimary)
                        }
                    } else if badges.isEmpty {
                        Text(store.t("chat_identity_empty"))
                            .font(.tMeta).foregroundColor(.tMuted)
                    } else {
                        ForEach(badges) { badge in row(badge) }
                    }
                } footer: {
                    Text(store.t(refused ? "chat_identity_failed" : "chat_identity_footer"))
                        .font(.tMeta).foregroundColor(refused ? .tWarning : .tMuted)
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
            .task { await load() }
        }
        .preferredColorScheme(.dark)
    }

    private func row(_ badge: ChatBadgeChoice) -> some View {
        Button {
            Task { await choose(badge) }
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
                if saving == badge.id {
                    ProgressView().tint(.tPrimary)
                } else if selected == badge.id {
                    Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundColor(.tPrimary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(saving != nil)
        .accessibilityAddTraits(selected == badge.id ? .isSelected : [])
    }

    @MainActor private func load() async {
        guard let token = store.twitchWebToken else { loading = false; loadFailed = true; return }
        loading = true
        loadFailed = false
        let result = await ChatIdentity.globalBadges(token: token)
        loading = false
        guard let result else { loadFailed = true; return }
        badges = result.available
        selected = result.selected
    }

    @MainActor private func choose(_ badge: ChatBadgeChoice) async {
        guard badge.id != selected, saving == nil, let token = store.twitchWebToken else { return }
        saving = badge.id
        refused = false
        let ok = await ChatIdentity.selectGlobal(badge, token: token)
        saving = nil
        if ok { selected = badge.id } else { refused = true }
    }
}
