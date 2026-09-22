import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════
//  Feuille ouverte en touchant un message.
//
//  Elle est centrée sur la personne, pas sur le message : seul, hors contexte,
//  un message ne dit pas grand-chose. On montre donc tout ce qu'elle a écrit
//  dans ce qu'on a en mémoire, et les actions (répondre, mentionner, copier)
//  s'appliquent au message touché.
// ═══════════════════════════════════════════════════════════════════════════

struct MessageSheet: View {
    let message: ChatMessage
    @ObservedObject var chat: ChatService
    let canSend: Bool
    var style: ChatStyle = .standard
    /// Insère « @pseudo » dans la barre d'envoi du chat et referme.
    var onMention: (String) -> Void = { _ in }

    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var avatar: String? = nil
    @State private var replying = false
    @State private var replyText = ""
    @State private var copied = false
    @FocusState private var focused: Bool

    private var rootId: String { message.threadRootId ?? message.id }
    private var canReply: Bool { !replyText.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Le fil quand il y en a un, sinon tout ce que la personne a écrit.
    private var displayed: [ChatMessage] {
        let thread = chat.threadMessages(rootId: rootId)
        if thread.count > 1 { return thread }
        let mine = chat.messagesFrom(userName: message.userName)
        return mine.isEmpty ? [message] : mine
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color.tBorder)
            messageList
            if replying, canSend { replyBar }
        }
        .background(Color.tDark)
        .overlay(alignment: .top) {
            if copied {
                Text(store.t("msg_copied"))
                    .font(.tLabel).foregroundColor(.white)
                    .padding(.horizontal, TSpace.lg).padding(.vertical, TSpace.sm)
                    .background(Color.tPrimary).clipShape(Capsule())
                    .padding(.top, TSpace.md)
                    .transition(.opacity)
            }
        }
        .task {
            // Le chat IRC ne transporte pas les photos de profil : une requête
            // Helix, mise en cache pour la session (voir AvatarCache).
            avatar = await AvatarCache.shared.avatar(login: message.userName,
                                                     token: store.twitchToken)
        }
    }

    // MARK: – En-tête : qui parle, et que faire
    @ViewBuilder private var header: some View {
        HStack(spacing: TSpace.md) {
            AsyncImage(url: URL(string: avatar ?? "")) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                // Repli sur l'initiale : la photo peut manquer (compte supprimé,
                // pas de jeton), et un rond vide n'aide personne.
                ZStack {
                    Circle().fill(message.color.opacity(0.25))
                    Text(String(message.displayName.prefix(1)).uppercased())
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(message.color)
                }
            }
            .frame(width: 46, height: 46)
            .clipShape(Circle())

            Text(message.displayName)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(message.color)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            if canSend {
                actionButton(icon: "arrowshape.turn.up.left.fill") {
                    replying = true
                    focused  = true
                }
            }
            Menu {
                Button {
                    UIPasteboard.general.string = plainText
                    withAnimation { copied = true }
                    Task {
                        try? await Task.sleep(nanoseconds: 900_000_000)
                        withAnimation { copied = false }
                    }
                } label: {
                    Label(store.t("copy_message"), systemImage: "doc.on.doc")
                }
                if canSend {
                    Button {
                        onMention(message.displayName)
                        dismiss()
                    } label: {
                        Label(store.t("mention_user"), systemImage: "at")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.tText)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, TSpace.lg)
        .padding(.vertical, TSpace.md)
    }

    @ViewBuilder
    private func actionButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(.tText)
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: – Messages
    @ViewBuilder private var messageList: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(displayed) { m in
                            ChatMessageRow(message: m, availableWidth: geo.size.width,
                                           style: style)
                                .id(m.id)
                                // Le message d'où l'on vient reste repérable au
                                // milieu des autres.
                                .background(m.id == message.id
                                            ? Color.tPrimary.opacity(0.12) : Color.clear)
                        }
                    }
                    .frame(width: geo.size.width, alignment: .leading)
                    .padding(.vertical, TSpace.xs)
                }
                .onAppear { proxy.scrollTo(message.id, anchor: .center) }
            }
        }
    }

    // MARK: – Réponse
    @ViewBuilder private var replyBar: some View {
        Divider().background(Color.tBorder)
        HStack(spacing: TSpace.sm) {
            TextField("\(store.t("thread_reply_to")) @\(message.displayName)",
                      text: $replyText)
                .focused($focused)
                .foregroundColor(.tText)
                .autocorrectionDisabled()
                .padding(.horizontal, TSpace.md).padding(.vertical, 10)
                .background(Color.tSurface).cornerRadius(TRadius.control)
                .overlay(RoundedRectangle(cornerRadius: TRadius.control)
                    .stroke(focused ? Color.tPrimary : Color.tBorder, lineWidth: 1))
                .submitLabel(.send).onSubmit(sendReply)

            Button(action: sendReply) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 15, weight: .bold)).foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(canReply ? Color.tPrimary : Color.tMuted.opacity(0.35))
                    .cornerRadius(TRadius.control)
            }
            .disabled(!canReply)
        }
        .padding(.horizontal, TSpace.md).padding(.vertical, TSpace.sm)
        .background(Color.tCard)
    }

    /// Texte brut du message, emotes remplacées par leur nom (c'est ce qu'on
    /// colle ailleurs de toute façon).
    private var plainText: String {
        message.tokens.map { token in
            switch token {
            case .text(let t):    return t
            case .emote(let e):   return e.name
            case .mention(let m): return "@\(m)"
            case .link(let l):    return l
            }
        }.joined(separator: " ")
    }

    private func sendReply() {
        let t = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        replyText = ""
        Task {
            await chat.sendMessage(t, replyParentId: message.id,
                                   replyRootId: rootId,
                                   replyToName: message.displayName)
        }
        dismiss()
    }
}
