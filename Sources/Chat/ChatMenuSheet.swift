import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════
//  Menu « … » de la barre du chat : les actions qui n'ont pas leur place en
//  permanence à l'écran mais qu'on cherche à portée de pouce pendant un direct.
// ═══════════════════════════════════════════════════════════════════════════

struct ChatMenuSheet: View {
    let channelName: String
    /// Peut-on agir sur le compte (couleur du pseudo) ?
    let isAuthenticated: Bool
    @Binding var chatOnly: Bool
    /// Service IRC : sert à lister les personnes présentes (tags `membership`).
    @ObservedObject var chat: ChatService

    var onReloadEmotes: () -> Void
    var onReconnect:    () -> Void

    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var showChatters = false
    @State private var showColors   = false
    @State private var busyLabel: String? = nil

    var body: some View {
        VStack(spacing: 0) {

            // ── En-tête ─────────────────────────────────────────────
            HStack(spacing: TSpace.sm) {
                Text("#\(channelName)")
                    .font(.tSection).foregroundColor(.tPrimary)
                Spacer()
                TIconButton(icon: "xmark") { dismiss() }
            }
            .padding(.horizontal, TSpace.lg)
            .padding(.top, TSpace.lg)
            .padding(.bottom, TSpace.md)

            Divider().background(Color.tBorder)

            ScrollView {
                VStack(spacing: 0) {

                    // Chat seul : coupe la vidéo, garde la conversation.
                    row(icon: chatOnly ? "bubble.left.fill" : "bubble.left",
                        title: store.t("menu_chat_only"),
                        subtitle: store.t("menu_chat_only_sub"),
                        trailing: .toggle($chatOnly))

                    divider

                    row(icon: "arrow.triangle.2.circlepath",
                        title: store.t("menu_reload_emotes"),
                        subtitle: store.t("menu_reload_emotes_sub")) {
                        busyLabel = store.t("menu_reload_emotes")
                        onReloadEmotes()
                        finish()
                    }

                    divider

                    row(icon: "wifi.exclamationmark",
                        title: store.t("menu_reconnect"),
                        subtitle: store.t("menu_reconnect_sub")) {
                        busyLabel = store.t("menu_reconnect")
                        onReconnect()
                        finish()
                    }

                    divider

                    row(icon: "paintpalette.fill",
                        title: store.t("menu_color"),
                        subtitle: isAuthenticated ? store.t("menu_color_sub")
                                                  : store.t("menu_needs_login"),
                        trailing: .chevron) {
                        guard isAuthenticated else { return }
                        showColors = true
                    }
                    .disabled(!isAuthenticated)
                    .opacity(isAuthenticated ? 1 : 0.5)

                    divider

                    row(icon: "person.2.fill",
                        title: store.t("menu_chatters"),
                        subtitle: store.t("menu_chatters_sub"),
                        trailing: .chevron) {
                        showChatters = true
                    }
                }
                .padding(.vertical, TSpace.sm)
            }
        }
        .background(Color.tDark)
        .overlay(alignment: .bottom) {
            if let busy = busyLabel {
                Text("\(busy) ✓")
                    .font(.tLabel).foregroundColor(.white)
                    .padding(.horizontal, TSpace.lg).padding(.vertical, TSpace.sm)
                    .background(Color.tPrimary).clipShape(Capsule())
                    .padding(.bottom, TSpace.xl)
                    .transition(.opacity)
            }
        }
        .sheet(isPresented: $showChatters) {
            ChattersSheet(chat: chat)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showColors) {
            UsernameColorSheet { color in
                // Depuis 2023 la commande IRC `/color` renvoie « Unrecognized
                // command » : Twitch impose l'API Helix (scope
                // user:manage:chat_color).
                guard let token = store.twitchToken, let uid = store.twitchUserId else {
                    return "color_needs_relogin"
                }
                return await setChatColor(token: token, userId: uid, color: color)
            }
            .presentationDetents([.medium, .large])
        }
    }

    /// Confirme l'action puis referme la feuille.
    private func finish() {
        Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            await MainActor.run { busyLabel = nil; dismiss() }
        }
    }

    // MARK: – Briques
    private var divider: some View {
        Divider().background(Color.tBorder).padding(.leading, 56)
    }

    private enum RowTrailing {
        case none, chevron
        case toggle(Binding<Bool>)
    }

    @ViewBuilder
    private func row(icon: String, title: String, subtitle: String? = nil,
                     trailing: RowTrailing = .none,
                     action: (() -> Void)? = nil) -> some View {
        let content = HStack(spacing: TSpace.md) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundColor(.tPrimary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.tCardTitle).foregroundColor(.tText)
                if let subtitle {
                    Text(subtitle).font(.tMeta).foregroundColor(.tMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            switch trailing {
            case .none:
                EmptyView()
            case .chevron:
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(.tMuted)
            case .toggle(let binding):
                Toggle("", isOn: binding).labelsHidden().tint(.tPrimary)
            }
        }
        .padding(.horizontal, TSpace.lg)
        .padding(.vertical, TSpace.md)
        .contentShape(Rectangle())

        if let action {
            Button(action: action) { content }.buttonStyle(.plain)
        } else {
            content
        }
    }
}

// MARK: – Couleur du pseudo
/// Les couleurs nommées sont acceptées pour tous les comptes ; les teintes
/// libres (hex) restent réservées aux abonnés Turbo/Prime.
struct UsernameColorSheet: View {
    /// Applique la couleur et renvoie une clé d'erreur traduisible, ou nil.
    let apply: (String) async -> String?

    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var pending:  String? = nil
    @State private var applied:  String? = nil
    @State private var errorKey: String? = nil

    private let colors: [(name: String, hex: String)] = [
        ("blue", "0000FF"),          ("blue_violet", "8A2BE2"),
        ("cadet_blue", "5F9EA0"),    ("chocolate", "D2691E"),
        ("coral", "FF7F50"),         ("dodger_blue", "1E90FF"),
        ("firebrick", "B22222"),     ("golden_rod", "DAA520"),
        ("green", "008000"),         ("hot_pink", "FF69B4"),
        ("orange_red", "FF4500"),    ("red", "FF0000"),
        ("sea_green", "2E8B57"),     ("spring_green", "00FF7F"),
        ("yellow_green", "9ACD32"),
    ]

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: TSpace.sm)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(store.t("menu_color")).font(.tSection).foregroundColor(.tText)
                Spacer()
                TIconButton(icon: "xmark") { dismiss() }
            }
            .padding(TSpace.lg)

            Divider().background(Color.tBorder)

            ScrollView {
                LazyVGrid(columns: columns, spacing: TSpace.sm) {
                    ForEach(colors, id: \.name) { c in
                        Button { pick(c.name) } label: {
                            HStack(spacing: TSpace.sm) {
                                Circle().fill(Color(hex: c.hex))
                                    .frame(width: 14, height: 14)
                                Text(c.name.replacingOccurrences(of: "_", with: " "))
                                    .font(.tMeta)
                                    .foregroundColor(.tText)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                if pending == c.name {
                                    ProgressView().scaleEffect(0.6).tint(.tMuted)
                                } else if applied == c.name {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundColor(.tSuccess)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, TSpace.md)
                            .frame(height: 38)
                            .background(Color.tSurface)
                            .cornerRadius(TRadius.chip)
                        }
                        .buttonStyle(.plain)
                        .disabled(pending != nil)
                    }
                }
                .padding(TSpace.lg)
            }

            if let errorKey {
                Text(store.t(errorKey))
                    .font(.tMeta).foregroundColor(.tWarning)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, TSpace.lg)
                    .padding(.bottom, TSpace.lg)
            }
        }
        .background(Color.tDark)
    }

    private func pick(_ name: String) {
        guard pending == nil else { return }
        pending = name; errorKey = nil
        Task {
            let err = await apply(name)
            await MainActor.run {
                pending = nil
                errorKey = err
                if err == nil { applied = name }
            }
        }
    }
}

// MARK: – Liste des chatteurs
/// Twitch n'expose plus d'API publique de présence (voir TwitchAPI.swift) : la
/// seule source restante est la capacité IRC `membership`, que Twitch n'honore
/// que sur les canaux de taille modeste. On affiche donc ce que le chat nous a
/// réellement annoncé, et on le dit clairement quand il ne dit rien.
struct ChattersSheet: View {
    @ObservedObject var chat: ChatService

    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var filter = ""

    private var logins: [String] {
        let kw = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let all = chat.presentUsers.sorted()
        return kw.isEmpty ? all : all.filter { $0.contains(kw) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: TSpace.sm) {
                Text(store.t("menu_chatters")).font(.tSection).foregroundColor(.tText)
                if !chat.presentUsers.isEmpty {
                    Text("\(chat.presentUsers.count)")
                        .font(.tBadge).foregroundColor(.white)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.tPrimary).cornerRadius(8)
                }
                Spacer()
                TIconButton(icon: "xmark") { dismiss() }
            }
            .padding(TSpace.lg)

            Divider().background(Color.tBorder)

            if chat.presentUsers.isEmpty {
                Spacer()
                TEmptyState(
                    icon: "person.2.slash",
                    title: store.t(chat.presenceSupported ? "menu_chatters_empty"
                                                          : "menu_chatters_waiting"),
                    message: store.t("menu_chatters_note")
                )
                .padding(.horizontal, TSpace.lg)
                Spacer()
            } else {
                TSearchField(text: $filter, placeholder: store.t("menu_chatters_search"))
                    .padding(.horizontal, TSpace.lg)
                    .padding(.vertical, TSpace.md)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(logins, id: \.self) { login in
                            HStack(spacing: TSpace.sm) {
                                Image(systemName: "person.fill")
                                    .font(.system(size: 11)).foregroundColor(.tMuted)
                                Text(login).font(.tBody).foregroundColor(.tText)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, TSpace.lg)
                            .padding(.vertical, 7)
                        }

                        Text(store.t("menu_chatters_note"))
                            .font(.tMeta).foregroundColor(.tMuted)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, TSpace.lg)
                            .padding(.top, TSpace.lg)
                    }
                    .padding(.bottom, TSpace.xl)
                }
            }
        }
        .background(Color.tDark)
    }
}
