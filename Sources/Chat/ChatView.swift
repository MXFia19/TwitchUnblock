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
                    .onChange(of: chat.messages.first?.id) { _, newId in
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
        .background(message.isHighlight ? Color.tWarning.opacity(0.08) : Color.clear)
    }
}

// MARK: – Wrapping HStack (Native iOS 16 Layout)
struct WrappingHStack: View {
    let message: ChatMessage

    var body: some View {
        let blocks = buildBlocks()

        // ✨ CORRECTION LAYOUT : On utilise la puissance native d'iOS 16 !
        MessageFlowLayout(spacing: 4, lineSpacing: 4) {
            // Badges
            ForEach(message.badges) { badge in
                AsyncImage(url: URL(string: badge.url)) { img in
                    img.resizable().interpolation(.medium)
                } placeholder: { Color.clear }
                .frame(width: 18, height: 18)
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
        let result = FlowResult(in: proposal.width ?? UIScreen.main.bounds.width, subviews: subviews, spacing: spacing, lineSpacing: lineSpacing)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing, lineSpacing: lineSpacing)
        for (index, subview) in subviews.enumerated() {
            let point = result.points[index]
            subview.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    struct FlowResult {
        var size: CGSize = .zero
        var points: [CGPoint] = []

        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat, lineSpacing: CGFloat) {
            var currentX: CGFloat = 0
            var currentY: CGFloat = 0
            var lineHeight: CGFloat = 0
            var maxLineWidth: CGFloat = 0

            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                
                // Passe à la ligne si on dépasse
                if currentX + size.width > maxWidth && currentX > 0 {
                    currentX = 0
                    currentY += lineHeight + lineSpacing
                    lineHeight = 0
                }
                
                points.append(CGPoint(x: currentX, y: currentY))
                lineHeight = max(lineHeight, size.height)
                currentX += size.width + spacing
                maxLineWidth = max(maxLineWidth, currentX)
            }
            
            size = CGSize(width: maxWidth > 0 ? maxWidth : maxLineWidth, height: currentY + lineHeight)
        }
    }
}

// MARK: – Cached Emote Image
struct CachedEmoteImage: View {
    let url: String
    let name: String

    var body: some View {
        AsyncImage(url: URL(string: url)) { phase in
            switch phase {
            case .success(let img):
                img.resizable()
                    .interpolation(.medium)
                    .scaledToFit()
                    .frame(height: 22)
            case .failure:
                Text(name)
                    .font(.system(size: 13))
                    .foregroundColor(.tMuted)
            case .empty:
                Color.clear.frame(width: 22, height: 22)
            @unknown default:
                EmptyView()
            }
        }
        .frame(height: 22)
    }
}
