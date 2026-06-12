import SwiftUI

struct DiscoveryView: View {
    let onPlayStream: (String) -> Void
    let onPlayVod:    (String, String?, String?, String?) -> Void

    @EnvironmentObject private var store: AppStore

    @State private var followedStreams: [TwitchStream] = []
    @State private var topStreams:      [TwitchStream] = []
    @State private var topLang: TopLang = .fr
    @State private var loadingFollowed  = false
    @State private var loadingTop       = false
    @State private var errorFollowed: String? = nil
    @State private var isRefreshing     = false

    enum TopLang { case fr, all }

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // VOD history row
                VodHistoryRowView { item in
                    onPlayVod(item.term, item.display, item.thumb, item.streamer)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                if store.twitchToken == nil {
                    loginPrompt
                } else {
                    loggedInContent
                }
            }
        }
        .background(Color.tDark)
        .refreshable { await refresh() }
        .onAppear {
            if store.twitchToken != nil && followedStreams.isEmpty {
                Task { await loadAll() }
            }
        }
        .onChange(of: store.twitchToken) { token in
            if token != nil { Task { await loadAll() } }
            else { followedStreams = []; topStreams = [] }
        }
    }

    // MARK: – Login state
    @ViewBuilder private var loginPrompt: some View {
        VStack(spacing: 20) {
            Text(store.t("login_prompt"))
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Color(hex: "e0ccff"))
                .multilineTextAlignment(.center)
            Button {
                Task { await handleLogin() }
            } label: {
                Text(store.t("btn_login_twitch"))
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.vertical, 14).padding(.horizontal, 28)
                    .background(Color.tPrimary).cornerRadius(10)
            }
        }
        .padding(24)
        .background(Color.tPrimary.opacity(0.1))
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.tPrimary.opacity(0.27), lineWidth: 1))
        .padding(.horizontal, 16).padding(.top, 12)
    }

    // MARK: – Logged-in state
    @ViewBuilder private var loggedInContent: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Followed channels
            Text(store.t("followed_channels"))
                .font(.system(size: 16, weight: .bold)).foregroundColor(.tPurple)
                .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 12)

            if loadingFollowed {
                ProgressView().tint(.tPrimary).frame(maxWidth: .infinity).padding(.vertical, 24)
            } else if let err = errorFollowed {
                Text(err).foregroundColor(.tDanger).fontWeight(.semibold)
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
            } else if followedStreams.isEmpty {
                Text(store.t("no_live")).foregroundColor(.tMuted)
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(followedStreams) { stream in
                        StreamCardView(stream: stream) { onPlayStream(stream.userLogin) }
                    }
                }
                .padding(.horizontal, 16)
            }

            // ── Top streams header
            HStack {
                Text(store.t("top_streams"))
                    .font(.system(size: 16, weight: .bold)).foregroundColor(.tPurple)
                Spacer()
                HStack(spacing: 3) {
                    ForEach([TopLang.fr, .all], id: \.self) { l in
                        Button {
                            topLang = l
                            Task { await loadTopStreams(l) }
                        } label: {
                            Text(l == .fr ? store.t("top_fr") : store.t("top_world"))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(topLang == l ? .white : .tMuted)
                                .padding(.horizontal, 12).padding(.vertical, 5)
                                .background(topLang == l ? Color.tCard : .clear)
                                .cornerRadius(6)
                        }
                    }
                }
                .padding(3).background(Color.tSurface).cornerRadius(8)
            }
            .padding(.horizontal, 16).padding(.top, 24).padding(.bottom, 12)

            if loadingTop {
                ProgressView().tint(.tPrimary).frame(maxWidth: .infinity).padding(.vertical, 24)
            } else if topStreams.isEmpty {
                Text(store.t("no_live")).foregroundColor(.tMuted)
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(topStreams) { stream in
                        StreamCardView(stream: stream) { onPlayStream(stream.userLogin) }
                    }
                }
                .padding(.horizontal, 16)
            }

            Spacer(minLength: 40)
        }
    }

    // MARK: – Actions
    private func handleLogin() async {
        if let token = await TwitchAuthManager.shared.login() {
            store.twitchToken = token
        }
    }

    private func loadFollowedStreams() async {
        guard let token = store.twitchToken else { return }
        loadingFollowed = true; errorFollowed = nil
        do {
            if let user = await getTwitchUser(token: token) {
                store.twitchUserId = user.id
                await store.pullFromCloud(userId: user.id)
                followedStreams = try await getFollowedStreams(token: token, userId: user.id)
            } else {
                store.logout()
                errorFollowed = store.t("session_expired")
            }
        } catch {
            errorFollowed = store.t("err_loading")
            if error.localizedDescription.contains("Token") { store.logout() }
        }
        loadingFollowed = false
    }

    private func loadTopStreams(_ l: TopLang) async {
        guard let token = store.twitchToken else { return }
        loadingTop = true
        topStreams = (try? await getTopStreams(token: token, lang: l == .fr ? "fr" : nil)) ?? []
        loadingTop = false
    }

    private func loadAll() async {
        await loadFollowedStreams()
        await loadTopStreams(topLang)
    }

    private func refresh() async {
        await loadAll()
    }
}

extension DiscoveryView.TopLang: Hashable {}
