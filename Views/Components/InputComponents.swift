import SwiftUI

// MARK: – AutocompleteInputView (replaces AutocompleteInput.tsx)
struct AutocompleteInputView: View {
    @Binding var text: String
    let placeholder: String
    let onSubmit: () -> Void

    @EnvironmentObject private var store: AppStore
    @State private var suggestions: [AutocompleteSuggestion] = []
    @State private var loading = false
    @State private var showSuggestions = false
    @State private var debounceTask: Task<Void, Never>? = nil

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Input field
            HStack(spacing: 0) {
                TextField(placeholder, text: $text)
                    .autocorrectionDisabled()
                    .autocapitalization(.none)
                    .foregroundColor(.white)
                    .submitLabel(.search)
                    .onSubmit { showSuggestions = false; onSubmit() }
                    .onChange(of: text) { _, newValue in handleChange(newValue) }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)

                if loading {
                    ProgressView().tint(.tPrimary).scaleEffect(0.8).padding(.trailing, 10)
                }
            }
            .background(Color.tSurface)
            .cornerRadius(10)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.tBorder, lineWidth: 2))

            // Dropdown
            if showSuggestions && !suggestions.isEmpty {
                VStack(spacing: 0) {
                    ForEach(suggestions) { s in
                        Button {
                            text = s.login + " "
                            showSuggestions = false
                            onSubmit()
                        } label: {
                            HStack(spacing: 10) {
                                Group {
                                    if let avatarURL = s.avatar, let url = URL(string: avatarURL) {
                                        AsyncImage(url: url) { img in img.resizable().scaledToFill() }
                                            placeholder: { Color(hex: "111111") }
                                    } else {
                                        Color(hex: "111111").overlay(Text("👤").font(.system(size: 12)))
                                    }
                                }
                                .frame(width: 32, height: 32).clipShape(Circle())

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(s.name).font(.system(size: 14, weight: .bold)).foregroundColor(.white)
                                    if s.login != s.name.lowercased() {
                                        Text(s.login).font(.system(size: 11)).foregroundColor(.tMuted)
                                    }
                                }
                                Spacer()
                            }
                            .padding(10)
                        }
                        .buttonStyle(.plain)
                        if s.id != suggestions.last?.id {
                            Divider().background(Color.tBorder)
                        }
                    }
                }
                .background(Color.tSurface)
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.tPrimary, lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 8, y: 4)
                .offset(y: 52)
                .zIndex(200)
            }
        }
    }

    private func handleChange(_ newText: String) {
        let firstWord = newText.components(separatedBy: " ").first?.lowercased() ?? ""
        guard !firstWord.isEmpty && !newText.contains(" ") else {
            suggestions = []; showSuggestions = false; return
        }
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
            guard !Task.isCancelled else { return }
            await MainActor.run { loading = true }
            // Local history
            var results: [AutocompleteSuggestion] = store.history
                .filter { $0.type == .channel && $0.term.lowercased().contains(firstWord) }
                .map { AutocompleteSuggestion(login: $0.term, name: $0.display, avatar: nil) }
            // GQL
            let gql = await searchUsersGQL(firstWord)
            for s in gql where !results.contains(where: { $0.login == s.login }) {
                results.append(s)
            }
            await MainActor.run {
                suggestions     = Array(results.prefix(6))
                showSuggestions = !suggestions.isEmpty
                loading         = false
            }
        }
    }
}

// MARK: – ChannelHistoryTagsView (replaces ChannelHistoryTags.tsx)
struct ChannelHistoryTagsView: View {
    let onSelect: (String) -> Void
    @EnvironmentObject private var store: AppStore

    private var channels: [HistoryItem] {
        store.history.filter { $0.type == .channel }.prefix(8).map { $0 }
    }

    var body: some View {
        if channels.isEmpty { EmptyView() } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(store.t("lbl_channel_history"))
                        .font(.system(size: 13, weight: .bold)).foregroundColor(.tMuted)
                    Spacer()
                    Button {
                        store.clearChannelHistory()
                    } label: {
                        Text("🗑️ \(store.t("btn_clear"))")
                            .font(.system(size: 12, weight: .semibold)).foregroundColor(.tDanger)
                    }
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(channels) { item in
                            HStack(spacing: 6) {
                                Button {
                                    onSelect(item.term)
                                } label: {
                                    Text("👤 \(item.display)")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(Color(hex: "cccccc"))
                                }
                                Button {
                                    store.removeFromHistory(term: item.term)
                                } label: {
                                    Text("✕")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(.tDanger)
                                        .frame(width: 18, height: 18)
                                }
                            }
                            .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 6)
                            .background(Color.tSurface)
                            .cornerRadius(20)
                            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.tBorder, lineWidth: 1))
                        }
                    }
                }
            }
        }
    }
}

// MARK: – VodHistoryRowView (replaces VodHistoryRow.tsx)
struct VodHistoryRowView: View {
    let onSelect: (HistoryItem) -> Void
    @EnvironmentObject private var store: AppStore

    private var vods: [HistoryItem] {
        store.history.filter { $0.type == .vod }.prefix(10).map { $0 }
    }

    var body: some View {
        if vods.isEmpty { EmptyView() } else {
            VStack(alignment: .leading, spacing: 10) {
                Text(store.t("lbl_vod_history"))
                    .font(.system(size: 14, weight: .bold)).foregroundColor(.tPurple)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(vods) { item in
                            HStack(spacing: 10) {
                                AsyncImage(url: URL(string: item.thumb ?? "https://vod-secure.twitch.tv/_404/404_processing_320x180.png")) { img in
                                    img.resizable().aspectRatio(16/9, contentMode: .fill)
                                } placeholder: {
                                    Color(hex: "111111").aspectRatio(16/9, contentMode: .fill)
                                }
                                .frame(width: 80, height: 45)
                                .cornerRadius(6)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.display)
                                        .font(.system(size: 12, weight: .bold)).foregroundColor(.white).lineLimit(2)
                                    Text(item.streamer ?? "VOD")
                                        .font(.system(size: 11, weight: .semibold)).foregroundColor(.tPrimary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)

                                Button {
                                    store.removeFromHistory(term: item.term)
                                } label: {
                                    Text("✕").font(.system(size: 10, weight: .bold)).foregroundColor(.tDanger)
                                        .frame(width: 22, height: 22)
                                        .background(Color.tDanger.opacity(0.15))
                                        .clipShape(Circle())
                                }
                            }
                            .padding(8)
                            .frame(width: 240)
                            .background(Color.tSurface)
                            .cornerRadius(12)
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.tBorder, lineWidth: 1))
                            .onTapGesture { onSelect(item) }
                        }
                    }
                }
            }
        }
    }
}
