import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════
//  Commandes des bots du chat (Nightbot, StreamElements, Fossabot, Moobot) :
//  les lire sans avoir à taper « !commands » dans le chat. Mêmes API publiques
//  que l'extension « View Twitch Commands In Chat » (1011025m).
// ═══════════════════════════════════════════════════════════════════════════

struct BotCommand: Identifiable, Hashable {
    let name: String       // avec le préfixe : « !discord »
    let response: String
    var id: String { name }
}

struct BotCommandSet: Identifiable {
    let bot: String
    let icon: String
    let commands: [BotCommand]
    var id: String { bot }
}

enum BotCommandsAPI {
    private static func json(_ url: String, headers: [String: String] = [:]) async -> Any? {
        guard let u = URL(string: url) else { return nil }
        var req = URLRequest(url: u, timeoutInterval: 10)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func prefixed(_ name: String) -> String {
        let n = name.trimmingCharacters(in: .whitespaces)
        return n.hasPrefix("!") ? n : "!" + n
    }

    static func nightbot(_ ch: String) async -> BotCommandSet? {
        guard let c = await json("https://api.nightbot.tv/1/channels/t/\(ch)") as? [String: Any],
              let id = (c["channel"] as? [String: Any])?["_id"] as? String,
              let r = await json("https://api.nightbot.tv/1/commands", headers: ["Nightbot-Channel": id]) as? [String: Any],
              let list = r["commands"] as? [[String: Any]] else { return nil }
        let cmds = list.compactMap { d -> BotCommand? in
            guard let n = d["name"] as? String else { return nil }
            return BotCommand(name: n, response: d["message"] as? String ?? "")
        }
        return cmds.isEmpty ? nil : BotCommandSet(bot: "Nightbot", icon: "https://static-cdn.jtvnw.net/jtv_user_pictures/nightbot-profile_image-2345338c09b4d468-50x50.png", commands: cmds)
    }

    static func streamElements(_ ch: String) async -> BotCommandSet? {
        guard let c = await json("https://api.streamelements.com/kappa/v2/channels/\(ch)") as? [String: Any],
              let id = c["_id"] as? String,
              let list = await json("https://api.streamelements.com/kappa/v2/bot/commands/\(id)/public") as? [[String: Any]] else { return nil }
        let cmds = list.compactMap { d -> BotCommand? in
            guard let n = d["command"] as? String,
                  d["enabled"] as? Bool != false, d["hidden"] as? Bool != true else { return nil }
            return BotCommand(name: prefixed(n), response: d["reply"] as? String ?? "")
        }
        return cmds.isEmpty ? nil : BotCommandSet(bot: "StreamElements", icon: "https://static-cdn.jtvnw.net/jtv_user_pictures/streamelements-profile_image-a89b9d61499d365f-50x50.png", commands: cmds)
    }

    static func fossabot(_ ch: String) async -> BotCommandSet? {
        guard let c = await json("https://api.fossabot.com/v2/cached/channels/by-slug/\(ch)") as? [String: Any],
              let id = (c["channel"] as? [String: Any])?["id"] as? String,
              let r = await json("https://api.fossabot.com/v2/cached/channels/\(id)/commands") as? [String: Any],
              let list = r["commands"] as? [[String: Any]] else { return nil }
        let cmds = list.compactMap { d -> BotCommand? in
            guard let n = d["name"] as? String, d["enabled_online"] as? Bool != false else { return nil }
            return BotCommand(name: prefixed(n), response: d["response"] as? String ?? "")
        }
        return cmds.isEmpty ? nil : BotCommandSet(bot: "Fossabot", icon: "https://static-cdn.jtvnw.net/jtv_user_pictures/719a0ffa-6c86-4321-83f1-44990fd644bc-profile_image-50x50.png", commands: cmds)
    }

    static func moobot(_ ch: String) async -> BotCommandSet? {
        guard let c = await json("https://api.moo.bot/1/channel/meta?name=\(ch)") as? [String: Any],
              let id = (c["channel"] as? [String: Any])?["userid"] as? String,
              let r = await json("https://api.moo.bot/1/channel/public/commands/list?channel=\(id)") as? [String: Any],
              let list = r["list"] as? [[String: Any]] else { return nil }
        let cmds = list.compactMap { d -> BotCommand? in
            guard let n = d["identifier"] as? String else { return nil }
            return BotCommand(name: prefixed(n), response: d["response"] as? String ?? "")
        }
        return cmds.isEmpty ? nil : BotCommandSet(bot: "Moobot", icon: "https://static-cdn.jtvnw.net/jtv_user_pictures/663db70b-80e7-424b-a54f-ed88f7ac9355-profile_image-50x50.png", commands: cmds)
    }

    /// Les quatre en parallèle ; seuls les bots qui ont des commandes restent.
    static func all(channel: String) async -> [BotCommandSet] {
        let ch = channel.lowercased().addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? channel
        async let n = nightbot(ch)
        async let s = streamElements(ch)
        async let f = fossabot(ch)
        async let m = moobot(ch)
        let sets = await [n, s, f, m].compactMap { $0 }
        return sets.map { set in
            BotCommandSet(bot: set.bot, icon: set.icon,
                          commands: set.commands.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
        }
    }
}

struct BotCommandsSheet: View {
    let channelName: String
    /// Toucher une commande la met dans le champ du chat (si on peut écrire),
    /// sinon la copie.
    var onUse: ((String) -> Void)? = nil

    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var sets: [BotCommandSet] = []
    @State private var loading = true
    @State private var filter = ""
    @State private var copied: String? = nil

    private var filtered: [BotCommandSet] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return sets }
        return sets.compactMap { set in
            let c = set.commands.filter { $0.name.lowercased().contains(q) || $0.response.lowercased().contains(q) }
            return c.isEmpty ? nil : BotCommandSet(bot: set.bot, icon: set.icon, commands: c)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: TSpace.sm) {
                Image(systemName: "terminal.fill").foregroundColor(.tPrimary)
                Text(store.t("bot_commands")).font(.tSection).foregroundColor(.tText)
                Spacer()
                TIconButton(icon: "xmark") { dismiss() }
            }
            .padding(.horizontal, TSpace.lg)
            .padding(.top, TSpace.lg)
            .padding(.bottom, TSpace.sm)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundColor(.tMuted)
                TextField(store.t("bot_commands_filter"), text: $filter)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .foregroundColor(.tText)
            }
            .padding(10)
            .background(Color.tSurface)
            .cornerRadius(10)
            .padding(.horizontal, TSpace.lg)
            .padding(.bottom, TSpace.sm)

            if loading {
                Spacer(); TLoader(); Spacer()
            } else if sets.isEmpty {
                Spacer()
                TEmptyState(icon: "terminal", title: store.t("bot_commands_none"),
                            message: store.t("bot_commands_none_msg"))
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: TSpace.md, pinnedViews: [.sectionHeaders]) {
                        ForEach(filtered) { set in
                            Section {
                                ForEach(set.commands) { cmd in commandRow(cmd) }
                            } header: {
                                HStack(spacing: 8) {
                                    CachedEmoteImage(url: set.icon, name: "", height: 20, showsNameFallback: false)
                                        .clipShape(Circle())
                                    Text(set.bot).font(.system(size: 14, weight: .bold)).foregroundColor(.tText)
                                    Text("\(set.commands.count)").font(.tMeta).foregroundColor(.tMuted)
                                    Spacer()
                                }
                                .padding(.vertical, 6)
                                .padding(.horizontal, TSpace.lg)
                                .background(Color.tDark)
                            }
                        }
                    }
                    .padding(.bottom, TSpace.xl)
                }
            }
        }
        .background(Color.tDark)
        .overlay(alignment: .bottom) {
            if let copied {
                Text(copied)
                    .font(.tLabel).foregroundColor(.white)
                    .padding(.horizontal, TSpace.lg).padding(.vertical, TSpace.sm)
                    .background(Color.tPrimary).clipShape(Capsule())
                    .padding(.bottom, TSpace.xl)
                    .transition(.opacity)
            }
        }
        .task {
            sets = await BotCommandsAPI.all(channel: channelName)
            loading = false
        }
    }

    /// Une commande : la toucher l'utilise (ou la copie). Les liens de sa
    /// réponse s'ouvrent, eux, dans Safari : la réponse n'est alors pas dans
    /// le bouton, qui avalerait le toucher.
    private func commandRow(_ cmd: BotCommand) -> some View {
        let response = richText(cmd.response)
        let hasLinks = response.runs.contains { $0.link != nil }
        return VStack(alignment: .leading, spacing: 3) {
            Button { use(cmd) } label: {
                Text(cmd.name)
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(.tPurple)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !cmd.response.isEmpty {
                if hasLinks {
                    Text(response)
                        .font(.system(size: 13))
                        .foregroundColor(.tMuted)
                        .tint(.tPrimary)
                        .lineLimit(4)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(cmd.response)
                        .font(.system(size: 13))
                        .foregroundColor(.tMuted)
                        .lineLimit(4)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { use(cmd) }
                }
            }
        }
        .padding(.horizontal, TSpace.lg)
    }

    private func use(_ cmd: BotCommand) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if let onUse {
            onUse(cmd.name)
            dismiss()
        } else {
            UIPasteboard.general.string = cmd.name
            withAnimation { copied = store.t("copied_cmd").replacingOccurrences(of: "{c}", with: cmd.name) }
            Task {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                await MainActor.run { withAnimation { copied = nil } }
            }
        }
    }
}
