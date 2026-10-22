import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════
//  Emotes masquées : dans le chat (direct, VODs, multi-live, épinglé, fil
//  d'un message), une emote masquée s'affiche comme le mot tapé. On la
//  masque d'un appui long sur elle, ou depuis sa fiche ; Réglages → Chat les
//  liste, avec de quoi les réafficher. La liste (AppStore.hiddenEmotes) suit
//  le compte, comme sur le site (« hiddenEmotes »).
// ═══════════════════════════════════════════════════════════════════════════

/// Appui long sur une emote du chat : la masquer, ou la réafficher.
struct EmoteHideMenu: ViewModifier {
    let code: String
    @EnvironmentObject private var store: AppStore

    func body(content: Content) -> some View {
        content.contextMenu {
            let hidden = store.hidesEmote(code)
            Button {
                store.toggleHiddenEmote(code)
            } label: {
                Label(store.t(hidden ? "emote_unhide" : "emote_hide"),
                      systemImage: hidden ? "eye" : "eye.slash")
            }
        }
    }
}

/// Fiche d'une emote : « Masquer cette emote », ou la réafficher.
struct EmoteHideButton: View {
    let code: String
    @EnvironmentObject private var store: AppStore

    var body: some View {
        let hidden = store.hidesEmote(code)
        VStack(spacing: 6) {
            Button {
                store.toggleHiddenEmote(code)
            } label: {
                Label(store.t(hidden ? "emote_unhide" : "emote_hide"),
                      systemImage: hidden ? "eye" : "eye.slash")
            }
            .buttonStyle(.bordered)
            .tint(hidden ? .tPrimary : .tDanger)
            .font(.system(size: 14, weight: .semibold))
            if hidden {
                Text(store.t("emote_hidden_note"))
                    .font(.system(size: 12)).foregroundColor(.tMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Réglages → Chat : combien d'emotes sont masquées (les dernières en clair),
/// et la liste pour les réafficher.
struct HiddenEmotesRow: View {
    @EnvironmentObject private var store: AppStore
    @State private var showList = false

    var body: some View {
        let list = store.hiddenEmotes
        Button {
            showList = true
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.t("hidden_emotes"))
                        .font(.tCardTitle).foregroundColor(.tText)
                    if list.isEmpty {
                        Text(store.t("hidden_emotes_empty"))
                            .font(.tMeta).foregroundColor(.tMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(list.suffix(6).reversed().joined(separator: ", "))
                            .font(.tMeta).foregroundColor(.tMuted)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !list.isEmpty {
                    Text("\(list.count)")
                        .font(.tLabel).foregroundColor(.tMuted)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.tMuted)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showList) {
            HiddenEmotesSheet()
                .environmentObject(store)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}

/// Liste des emotes masquées, la plus récente en haut : une à une, ou toutes.
struct HiddenEmotesSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            List {
                if store.hiddenEmotes.isEmpty {
                    Text(store.t("hidden_emotes_empty"))
                        .font(.tMeta).foregroundColor(.tMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .listRowBackground(Color.tCard)
                } else {
                    Section {
                        ForEach(Array(store.hiddenEmotes.reversed()), id: \.self) { code in
                            HStack(spacing: 12) {
                                Text(code)
                                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.tText)
                                    .lineLimit(1)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Button {
                                    withAnimation { store.toggleHiddenEmote(code) }
                                } label: {
                                    Image(systemName: "eye")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundColor(.tPrimary)
                                        .frame(width: 44, height: 36)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(store.t("emote_unhide") + " " + code)
                            }
                        }
                    } footer: {
                        Text(store.t("hidden_emotes_sub"))
                            .font(.tMeta).foregroundColor(.tMuted)
                    }
                    .listRowBackground(Color.tCard)

                    Section {
                        Button(role: .destructive) { confirmClear = true } label: {
                            Text(store.t("hidden_emotes_clear"))
                        }
                    }
                    .listRowBackground(Color.tCard)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.tDark)
            .navigationTitle(store.t("hidden_emotes"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(store.t("close")) { dismiss() }
                }
            }
            .confirmationDialog(store.t("hidden_emotes_clear"), isPresented: $confirmClear,
                                titleVisibility: .visible) {
                Button(store.t("hidden_emotes_clear"), role: .destructive) {
                    store.hiddenEmotes = []
                    logger.settingChanged("Emotes masquées", value: "toutes réaffichées")
                }
                Button(store.t("cancel"), role: .cancel) {}
            }
        }
        .preferredColorScheme(.dark)
    }
}
