import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════
//  Chat d'une chaîne hors ligne (to-do du 05/11 : « pas d'option de chat »).
//
//  Twitch garde le chat ouvert hors direct : on y lit et on y écrit comme
//  pendant un live. La page de la chaîne, hors ligne, l'ouvre dans une
//  feuille, sans lecteur ; ses commandes de bots restent dans le menu ⋯.
//  Sans direct, pas de présence pour les points (ChannelPointsService ne
//  part qu'avec un identifiant de diffusion).
// ═══════════════════════════════════════════════════════════════════════════

struct OfflineChatButton: View {
    let channelName: String
    let channelId: String?

    @EnvironmentObject private var store: AppStore
    @State private var showSheet = false

    var body: some View {
        Button {
            showSheet = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                Text(store.t("sec_chat")).font(.tSystem(size: 13, weight: .bold))
            }
            .foregroundColor(.tPrimary)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(Color.tPrimary.opacity(0.14))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showSheet) {
            OfflineChatSheet(channelName: channelName, channelId: channelId)
                .environmentObject(store)
        }
    }
}

struct OfflineChatSheet: View {
    let channelName: String
    let channelId: String?

    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    /// Identifiant de la chaîne : celui de la page, sinon cherché ici. Sans
    /// lui, le chat se lit quand même (emotes et badges de la chaîne en moins).
    @State private var resolvedId: String? = nil
    @State private var ready = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text(store.t("chat_offline_open"))
                    .font(.tMeta).foregroundColor(.tMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, TSpace.lg).padding(.vertical, TSpace.sm)
                if ready {
                    ChatView(channelName: channelName, channelId: resolvedId,
                             token: store.twitchToken, login: store.twitchLogin,
                             chatOnly: .constant(false),
                             style: store.chatStyle(chrome: true, translucent: false),
                             // Feuille par-dessus la page : une autre page de
                             // chaîne s'ouvrirait dessous, sans qu'on la voie.
                             opensChannelPages: false,
                             allowsChatOnly: false)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Color.tDark.ignoresSafeArea())
            .navigationTitle(channelName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(store.t("close")) { dismiss() }
                }
            }
        }
        .task {
            var cid = channelId ?? ""
            if cid.isEmpty { cid = await getUserIdGQL(login: channelName) ?? "" }
            resolvedId = cid.isEmpty ? nil : cid
            ready = true
        }
    }
}
