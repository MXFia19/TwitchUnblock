import SwiftUI

// MARK: – Main Chat View
struct ChatView: View {
    let channelName: String
    let channelId: String?
    let token: String?

    @StateObject private var chat = ChatService()
    @State private var autoScroll = true

    var body: some View {
        VStack(spacing: 0) {
            // ── Status bar ─────────────────────────────────────────
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

            // ── Messages ───────────────────────────────────────────
            // GeometryReader ici pour avoir la largeur exacte du conteneur
            GeometryReader { geo in
                ZStack(alignment: .bottomTrailing) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(chat.messages.reversed()) { msg in
                                    ChatMessageRow(message: msg, availableWidth: geo.size.width)
                                        .id(msg.id)
                                }
                            }
                            // ✅ Force le LazyVStack à la largeur exacte
                            .frame(width: geo.size.width, alignment: .leading)
                            .padding(.vertical, 6)
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
                                Text("Suivre le chat").font(.system(size: 11, weight: .bold))
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
        .onDisappear { chat.disconnect() }
    }
}

// MARK: – Single Message Row
struct ChatMessageRow: View {
    let message: ChatMessage
    let availableWidth: CGFloat  // ✅ Largeur explicite passée depuis le parent

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

            // Message content
            HStack(alignment: .top, spacing: 0) {
                if message.isHighlight {
                    Rectangle().fill(Color.tWarning).frame(width: 3)
                }
                // ✅ Largeur explicite = largeur container - padding horizontal
                WrappingHStack(message: message,
                               availableWidth: availableWidth - 24)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }
            // ✅ Frame explicite = largeur exacte du container
            .frame(width: availableWidth, alignment: .leading)
        }
        // ✅ Frame explicite sur le VStack aussi
        .frame(width: availableWidth, alignment: .leading)
        .background(message.isHighlight ? Color.tWarning.opacity(0.08) : Color.clear)
    }
}

// MARK: – Wrapping HStack
struct WrappingHStack: View {
    let message: ChatMessage
    let availableWidth: CGFloat  // ✅ Largeur explicite

    var body: some View {
        let blocks = buildBlocks()

        MessageFlowLayout(spacing: 4, lineSpacing: 4, width: availableWidth) {
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

            Text(message.displayName + ":")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(message.color)

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
        // ✅ Frame explicite = largeur exacte sans ambiguïté
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

// MARK: – Flow Layout (Layout protocol)
struct MessageFlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat
    var width: CGFloat  // ✅ Largeur connue à l'avance

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        computeLayout(width: width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = computeLayout(width: width, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            let pos = layout.positions[index]
            let subSize = subview.sizeThatFits(.unspecified)
            // Centrage vertical par ligne, ancrage top-left strict
            let yOffset = max(0, (layout.lineHeights[index] - subSize.height) / 2)
            subview.place(
                at: CGPoint(x: bounds.minX + pos.x, y: bounds.minY + pos.y + yOffset),
                anchor: .topLeading,  // ✅ Toujours ancré au coin supérieur gauche
                proposal: .unspecified
            )
        }
    }

    private func computeLayout(width: CGFloat, subviews: Subviews)
        -> (size: CGSize, positions: [CGPoint], lineHeights: [CGFloat])
    {
        let safeWidth = max(width, 1)
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var maxLineHeight: CGFloat = 0
        var positions: [CGPoint] = []
        var lineHeights: [CGFloat] = Array(repeating: 0, count: subviews.count)
        var lineStart = 0

        for (i, sub) in subviews.enumerated() {
            let size = sub.sizeThatFits(.unspecified)
            if currentX > 0 && currentX + size.width > safeWidth {
                for j in lineStart..<i { lineHeights[j] = maxLineHeight }
                currentX = 0
                currentY += maxLineHeight + lineSpacing
                maxLineHeight = 0
                lineStart = i
            }
            positions.append(CGPoint(x: currentX, y: currentY))
            maxLineHeight = max(maxLineHeight, size.height)
            currentX += size.width + spacing
        }
        for j in lineStart..<subviews.count { lineHeights[j] = maxLineHeight }

        return (CGSize(width: safeWidth, height: currentY + maxLineHeight), positions, lineHeights)
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
