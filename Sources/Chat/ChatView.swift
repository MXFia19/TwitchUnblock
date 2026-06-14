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
                            // Messages are inserted at index 0 (newest first), display reversed
                            ForEach(chat.messages.reversed()) { msg in
                                ChatMessageRow(message: msg)
                                    .id(msg.id)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    // ✨ CORRECTION : Syntaxe compatible avec iOS 16
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

                FlowMessageView(message: message)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }
        }
        .background(message.isHighlight ? Color.tWarning.opacity(0.08) : Color.clear)
    }
}

// MARK: – Flow layout for badges + username + tokens
struct FlowMessageView: View {
    let message: ChatMessage

    var body: some View {
        // We build a single line-wrapping layout using a custom approach
        MessageContentView(message: message)
    }
}

// MARK: – Message content using Text + attachments
struct MessageContentView: View {
    let message: ChatMessage
    @State private var height: CGFloat = 20

    var body: some View {
        // Build inline content
        TokenFlowView(message: message)
    }
}

// MARK: – Token Flow (wrapping layout)
struct TokenFlowView: View {
    let message: ChatMessage

    var body: some View {
        // We use a modified approach: HStack with wrapping via GeometryReader
        WrappingHStack(message: message)
    }
}

// MARK: – Wrapping HStack (manual flow layout)
struct WrappingHStack: View {
    let message: ChatMessage

    var body: some View {
        // Build all "blocks" (badge images, username, text spans, emote images)
        let blocks = buildBlocks()

        // Use a flow layout via embedded VStack+HStack
        FlowLayout(spacing: 2) {
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

// MARK: – Flow Layout (wrapping)
struct FlowLayout<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: Content

    @State private var totalHeight: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            self.generateContent(in: geo)
        }
        .frame(height: totalHeight)
    }

    private func generateContent(in geo: GeometryProxy) -> some View {
        var width  = CGFloat.zero
        var height = CGFloat.zero
        var lastHeight = CGFloat.zero

        return ZStack(alignment: .topLeading) {
            content
                .fixedSize(horizontal: false, vertical: true)
                .alignmentGuide(.leading) { d in
                    if abs(width - d.width) > geo.size.width {
                        width  = 0
                        height -= lastHeight + spacing
                    }
                    let result = width
                    if d[.leading] == d[.trailing] { width = 0 }
                    else { width -= d.width + spacing }
                    return result
                }
                .alignmentGuide(.top) { d in
                    lastHeight = d.height
                    let result = height
                    return result
                }
        }
        .background(GeometryReader { g -> Color in
            DispatchQueue.main.async {
                self.totalHeight = g.size.height
            }
            return Color.clear
        })
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
                    .font(.system(size: 11))
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
