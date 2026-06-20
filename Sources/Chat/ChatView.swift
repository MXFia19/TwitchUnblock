import SwiftUI

// MARK: – Main Chat View
struct ChatView: View {
    let channelName: String
    let channelId: String?
    let token: String?
    let login: String?

    @StateObject private var chat = ChatService()
    @State private var autoScroll      = true
    @State private var messageText     = ""
    @State private var showEmotePicker = false
    @FocusState private var isInputFocused: Bool

    private var canSendMessages: Bool { token != nil && login != nil }
    private var canSend: Bool {
        chat.isConnected && chat.isAuthenticated &&
        !messageText.trimmingCharacters(in: .whitespaces).isEmpty &&
        messageText.count <= 500
    }

    var body: some View {
        VStack(spacing: 0) {

            // ── Barre de statut ─────────────────────────────────────
            HStack(spacing: 6) {
                Circle()
                    .fill(chat.isConnected ? Color.tSuccess : Color.tDanger)
                    .frame(width: 6, height: 6)
                Text(chat.isConnected ? "Chat connecté" : "Connexion...")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.tMuted)
                Spacer()
                if chat.isAuthenticated, let l = login {
                    Text("✏️ @\(l)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.tPrimary)
                }
                Text("#\(channelName)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.tPrimary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.tCard)
            .overlay(Divider().background(Color.tBorder), alignment: .bottom)

            // ── Zone principale : messages OU picker ────────────────
            if showEmotePicker && canSendMessages {
                EmotePickerView(channelId: channelId) { emote in
                    insertEmote(emote)
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal:   .move(edge: .bottom).combined(with: .opacity)
                ))
            } else {
                GeometryReader { geo in
                    ZStack(alignment: .bottomTrailing) {
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 0) {
                                    ForEach(chat.messages.reversed()) { msg in
                                        ChatMessageRow(
                                            message: msg,
                                            availableWidth: geo.size.width
                                        )
                                        .id(msg.id)
                                    }
                                }
                                .frame(width: geo.size.width, alignment: .leading)
                                .padding(.vertical, 4)
                            }
                            .onChange(of: chat.messages.first?.id) { newId in
                                guard autoScroll, let id = newId else { return }
                                withAnimation(.linear(duration: 0.1)) {
                                    proxy.scrollTo(id, anchor: .bottom)
                                }
                            }
                        }

                        if !autoScroll {
                            Button { autoScroll = true } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.down")
                                    Text("Suivre").font(.system(size: 11, weight: .bold))
                                }
                                .foregroundColor(.white)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Color.tPrimary)
                                .cornerRadius(20)
                            }
                            .padding(10)
                        }
                    }
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .top).combined(with: .opacity),
                    removal:   .move(edge: .top).combined(with: .opacity)
                ))
            }

            // ── Barre d'envoi ───────────────────────────────────────
            if canSendMessages { inputBar }
        }
        .background(Color.tDark)
        .onAppear {
            Task {
                await EmoteService.shared.loadGlobals()
                if let cid = channelId {
                    await EmoteService.shared.loadChannel(channelId: cid, channelName: channelName)
                }
                chat.channelId = channelId
                chat.connect(channel: channelName, token: token, login: login)
            }
        }
        .onDisappear { chat.disconnect() }
    }

    // MARK: – Input bar
    @ViewBuilder
    private var inputBar: some View {
        VStack(spacing: 0) {
            Divider().background(Color.tBorder)
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            if showEmotePicker {
                                showEmotePicker = false
                            } else {
                                isInputFocused  = false
                                showEmotePicker = true
                            }
                        }
                    } label: {
                        Image(systemName: showEmotePicker ? "keyboard" : "face.smiling")
                            .font(.system(size: 20))
                            .foregroundColor(showEmotePicker ? .tPrimary : .tMuted)
                            .frame(width: 36, height: 44)
                    }

                    TextField(
                        chat.isConnected ? "Envoyer un message…" : "Connexion en cours…",
                        text: $messageText
                    )
                    .focused($isInputFocused)
                    .autocorrectionDisabled()
                    .autocapitalization(.sentences)
                    .foregroundColor(.tText)
                    .submitLabel(.send)
                    .onSubmit { sendMessage() }
                    .disabled(!chat.isConnected || !chat.isAuthenticated)
                    .onChange(of: isInputFocused) { focused in
                        if focused && showEmotePicker {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                showEmotePicker = false
                            }
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(Color.tSurface)
                    .cornerRadius(10)
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .stroke(isInputFocused ? Color.tPrimary : Color.tBorder, lineWidth: 1))

                    Button(action: sendMessage) {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(canSend ? Color.tPrimary : Color.tMuted.opacity(0.35))
                            .cornerRadius(10)
                    }
                    .disabled(!canSend)
                }

                if messageText.count > 400 {
                    HStack {
                        Spacer()
                        Text("\(messageText.count)/500")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(messageText.count > 480 ? .tDanger : .tWarning)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 10)
            .background(Color.tCard)
        }
    }

    // MARK: – Actions
    private func sendMessage() {
        let trimmed = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 500 else { return }
        messageText = ""
        autoScroll  = true
        Task { await chat.sendMessage(trimmed) }
    }

    private func insertEmote(_ emote: TwitchEmote) {
        messageText += (messageText.isEmpty || messageText.hasSuffix(" ") ? "" : " ")
            + emote.name + " "
    }
}

// MARK: – Single Message Row
struct ChatMessageRow: View {
    let message: ChatMessage
    let availableWidth: CGFloat

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private var timeString: String {
        Self.timeFormatter.string(from: message.timestamp)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── ✦ Premier message ────────────────────────────────────
            if message.isFirstMessage {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10, weight: .bold))
                    Text("Premier message")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(.tPurple)
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 4)
                .frame(width: availableWidth, alignment: .leading)
            }

            // ── Réponse avec prévisualisation ─────────────────────
            if let replyUser = message.replyTo {
                HStack(spacing: 0) {
                    // Barre verticale colorée
                    Color.tPrimary.opacity(0.5)
                        .frame(width: 2)
                        .padding(.leading, 12)

                    HStack(spacing: 5) {
                        Image(systemName: "arrowshape.turn.up.left.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.tMuted)

                        // "@user: corps du message" en une seule ligne tronquée
                        (
                            Text("@\(replyUser)")
                                .fontWeight(.bold)
                                .foregroundColor(.tMuted)
                            + Text(message.replyBody.map { ": \($0)" } ?? "")
                                .foregroundColor(.tMuted.opacity(0.75))
                        )
                        .font(.system(size: 11))
                        .lineLimit(1)
                    }
                    .padding(.leading, 8)

                    Spacer()
                }
                .padding(.top, 5)
                .padding(.bottom, 3)
                .frame(width: availableWidth, alignment: .leading)
            }

            // ── Message principal ────────────────────────────────────
            HStack(alignment: .top, spacing: 0) {
                if message.isHighlight {
                    Rectangle().fill(Color.tWarning).frame(width: 3)
                }
                WrappingHStack(
                    message: message,
                    timeString: timeString,
                    availableWidth: availableWidth - 24
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
            .frame(width: availableWidth, alignment: .leading)
        }
        .frame(width: availableWidth, alignment: .leading)
        .background(
            message.isHighlight     ? Color.tWarning.opacity(0.08) :
            message.isFirstMessage  ? Color.tPrimary.opacity(0.05) :
                                      Color.clear
        )
    }
}

// MARK: – Wrapping HStack (flow layout)
struct WrappingHStack: View {
    let message: ChatMessage
    let timeString: String          // ← passé depuis ChatMessageRow (1 formatter partagé)
    let availableWidth: CGFloat

    var body: some View {
        let blocks = buildBlocks()

        MessageFlowLayout(spacing: 4, lineSpacing: 4, width: availableWidth) {

            // ── Heure ─────────────────────────────────────────────
            Text(timeString)
                .font(.system(size: 11))
                .foregroundColor(.tMuted)

            // ── Badges ────────────────────────────────────────────
            ForEach(message.badges) { badge in
                AsyncImage(url: URL(string: badge.url)) { phase in
                    if let img = phase.image {
                        img.resizable().interpolation(.medium).scaledToFit()
                    } else {
                        Color.clear.frame(width: 16)
                    }
                }
                .frame(width: 16, height: 16)
            }

            // ── Nom d'utilisateur ─────────────────────────────────
            Text(message.displayName + ":")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(message.color)

            // ── Tokens ────────────────────────────────────────────
            ForEach(blocks) { block in
                switch block.content {
                case .text(let t):
                    Text(t)
                        .font(.system(size: 13))
                        .foregroundColor(message.isAction ? message.color : .tText)
                case .emote(let e):
                    CachedEmoteImage(url: e.url, name: e.name)
                case .mention(let m):
                    Text("@\(m)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.tPrimary)
                }
            }
        }
        .frame(width: availableWidth, alignment: .leading)
    }

    private func buildBlocks() -> [TokenBlock] {
        message.tokens.enumerated().map { idx, token in TokenBlock(id: idx, content: token) }
    }
}

struct TokenBlock: Identifiable {
    let id: Int
    let content: MessageToken
}

// MARK: – Flow Layout (Layout protocol, iOS 16+)
struct MessageFlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat
    var width: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        computeLayout(width: width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        let layout = computeLayout(width: width, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            let pos     = layout.positions[index]
            let subSize = subview.sizeThatFits(.unspecified)
            let yOffset = max(0, (layout.lineHeights[index] - subSize.height) / 2)
            subview.place(
                at: CGPoint(x: bounds.minX + pos.x, y: bounds.minY + pos.y + yOffset),
                anchor: .topLeading,
                proposal: .unspecified
            )
        }
    }

    private func computeLayout(width: CGFloat, subviews: Subviews)
        -> (size: CGSize, positions: [CGPoint], lineHeights: [CGFloat])
    {
        let safeWidth = max(width, 1)
        var currentX: CGFloat = 0, currentY: CGFloat = 0, maxLineH: CGFloat = 0
        var positions:   [CGPoint] = []
        var lineHeights: [CGFloat] = Array(repeating: 0, count: subviews.count)
        var lineStart = 0

        for (i, sub) in subviews.enumerated() {
            let size = sub.sizeThatFits(.unspecified)
            if currentX > 0 && currentX + size.width > safeWidth {
                for j in lineStart..<i { lineHeights[j] = maxLineH }
                currentX = 0; currentY += maxLineH + lineSpacing
                maxLineH = 0; lineStart = i
            }
            positions.append(CGPoint(x: currentX, y: currentY))
            maxLineH = max(maxLineH, size.height)
            currentX += size.width + spacing
        }
        for j in lineStart..<subviews.count { lineHeights[j] = maxLineH }
        return (CGSize(width: safeWidth, height: currentY + maxLineH), positions, lineHeights)
    }
}

// MARK: – Cached Emote Image
struct CachedEmoteImage: View {
    let url: String
    let name: String

    var body: some View {
        AsyncImage(url: URL(string: url)) { phase in
            if let img = phase.image {
                img.resizable().interpolation(.medium).scaledToFit()
            } else if phase.error != nil {
                Text(name).font(.system(size: 11)).foregroundColor(.tMuted)
            } else {
                Color.clear.frame(width: 24, height: 24)
            }
        }
        .frame(height: 24)
    }
}
