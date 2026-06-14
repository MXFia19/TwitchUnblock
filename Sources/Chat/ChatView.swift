import SwiftUI

// MARK: – Main Chat View
struct ChatView: View {
    let channelName: String
    let channelId: String?
    let token: String?

    @StateObject private var chat = ChatService()
    @State private var autoScroll = true
    @State private var showScrollButton = false

    var body: some View {
        VStack(spacing: 0) {
            // ── Status bar ───────────────────────────────────────────
            HStack(spacing: 6) {
                Circle()
                    .fill(chat.isConnected ? Color.tSuccess : Color.tDanger)
                    .frame(width: 6, height: 6)
                Text(chat.isConnected ? "Chat connecté" : "Connexion...")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.tMuted)
                Spacer()
                Text("#\(channelName)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.tPrimary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.tCard)
            .overlay(Divider().background(Color.tBorder), alignment: .bottom)

            // ── Messages ─────────────────────────────────────────────
            ZStack(alignment: .bottomTrailing) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(chat.messages.reversed()) { msg in
                                ChatMessageRow(message: msg)
                                    .id(msg.id)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .onChange(of: chat.messages.first?.id) { newId in
                        guard autoScroll, let id = newId else { return }
                        withAnimation(.linear(duration: 0.1)) {
                            proxy.scrollTo(id, anchor: .bottom)
                        }
                    }
                }

                // Scroll to bottom button
                if !autoScroll {
                    Button {
                        autoScroll = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down")
                            Text("Suivre le chat")
                                .font(.system(size: 11, weight: .bold))
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
        .background(Color.tDark)
        .onAppear {
            Task {
                await EmoteService.shared.loadGlobals()
                if let cid = channelId {
                    await EmoteService.shared.loadChannel(channelId: cid, channelName: channelName)
                }
                chat.channelId = channelId
                chat.connect(channel: channelName, token: token)
            }
        }
        .onDisappear {
            chat.disconnect()
        }
    }
}

// MARK: – Single Message Row
struct ChatMessageRow: View {
    let message: ChatMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Reply indicator
            if let reply = message.replyTo {
                HStack(spacing: 4) {
                    Rectangle().fill(Color.tMuted).frame(width: 2)
                    Text("↩ \(reply)")
                        .font(.system(size: 11))
                        .foregroundColor(.tMuted)
                        .lineLimit(1)
                }
                .padding(.leading, 12)
            }

            // Main message
            HStack(alignment: .top, spacing: 0) {
                // Highlight bar
                if message.isHighlight {
                    Rectangle().fill(Color.tWarning).frame(width: 3)
                }

                WrappingHStack(message: message)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }
        }
        // ✨ CORRECTION 1 : Force la ligne entière à s'aligner à gauche
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(message.isHighlight ? Color.tWarning.opacity(0.08) : Color.clear)
    }
}

// MARK: – Wrapping HStack
struct WrappingHStack: View {
    let message: ChatMessage

    var body: some View {
        let blocks = buildBlocks()

        MessageFlowLayout(spacing: 4, lineSpacing: 4) {
            // Badges
            ForEach(message.badges) { badge in
                AsyncImage(url: URL(string: badge.url)) { phase in
                    if let img = phase.image {
                        img.resizable().interpolation(.medium).scaledToFit()
                    } else {
                        // ✨ CORRECTION 2 : Limite la taille de l'espace vide pour éviter de pousser le texte
                        Color.clear.frame(width: 16)
                    }
                }
                .frame(width: 16, height: 16)
            }

            // Username
            Text(message.displayName + ":")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(message.color)

            // Tokens
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
    }

    private func buildBlocks() -> [TokenBlock] {
        message.tokens.enumerated().map { idx, token in
            TokenBlock(id: idx, content: token)
        }
    }
}

struct TokenBlock: Identifiable {
    let id: Int
    let content: MessageToken
}

// MARK: – Native Message Layout Algorithm
struct MessageFlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // ✨ CORRECTION 3 : Sécurise la largeur max pour un calcul parfait des hauteurs
        let availableWidth = proposal.width ?? UIScreen.main.bounds.width
        let clampWidth = availableWidth > 10000 ? UIScreen.main.bounds.width : availableWidth
        return computeLayout(width: clampWidth, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = computeLayout(width: bounds.width, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            let point = layout.positions[index]
            let yOffset = (layout.lineHeights[index] - subview.sizeThatFits(.unspecified).height) / 2
            subview.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y + yOffset), proposal: .unspecified)
        }
    }

    private func computeLayout(width: CGFloat, subviews: Subviews) -> (size: CGSize, positions: [CGPoint], lineHeights: [CGFloat]) {
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var maxLineHeight: CGFloat = 0
        var actualMaxWidth: CGFloat = 0

        var positions: [CGPoint] = []
        var lineHeights: [CGFloat] = Array(repeating: 0, count: subviews.count)
        var lineStartIndex = 0

        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)

            if currentX > 0 && currentX + size.width > width {
                for j in lineStartIndex..<index { lineHeights[j] = maxLineHeight }
                currentX = 0
                currentY += maxLineHeight + lineSpacing
                maxLineHeight = 0
                lineStartIndex = index
            }

            positions.append(CGPoint(x: currentX, y: currentY))
            maxLineHeight = max(maxLineHeight, size.height)
            currentX += size.width + spacing
            actualMaxWidth = max(actualMaxWidth, currentX - spacing)
        }

        for j in lineStartIndex..<subviews.count { lineHeights[j] = maxLineHeight }

        return (CGSize(width: actualMaxWidth, height: currentY + maxLineHeight), positions, lineHeights)
    }
}

// MARK: – Cached Emote Image
struct CachedEmoteImage: View {
    let url: String
    let name: String

    var body: some View {
        AsyncImage(url: URL(string: url)) { phase in
            if let img = phase.image {
                img.resizable()
                    .interpolation(.medium)
                    .scaledToFit()
            } else if phase.error != nil {
                Text(name).font(.system(size: 13)).foregroundColor(.tMuted)
            } else {
                // ✨ CORRECTION 4 : Contraint l'espace vide à 24 pixels (Au lieu de l'infini)
                Color.clear.frame(width: 24)
            }
        }
        .frame(height: 24)
    }
}
