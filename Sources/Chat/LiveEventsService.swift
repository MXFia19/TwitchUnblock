import Foundation
import SwiftUI

// MARK: – Événements live (série de visionnage, sondage, prédiction, hype train)
@MainActor
final class LiveEventsService: ObservableObject {
    @Published var watchStreak = 0
    @Published var poll: LivePoll? = nil
    @Published var prediction: LivePrediction? = nil
    @Published var hype: LiveHype? = nil

    struct LivePoll {
        let title: String
        let choices: [(title: String, votes: Int)]
        var total: Int { max(1, choices.reduce(0) { $0 + $1.votes }) }
    }
    struct LivePrediction {
        let title: String
        let locked: Bool
        let outcomes: [(title: String, color: String, points: Int)]
        var total: Int { max(1, outcomes.reduce(0) { $0 + $1.points }) }
    }
    struct LiveHype { let level: Int; let percent: Double }

    private var channelId = ""
    private var login = ""
    private var token: String? = nil
    private var timer: Timer?
    private let interval: TimeInterval = 15

    private enum H {
        static let streak     = "7d04fbaa5bb32d193c742caa2c855dfde371a2a8cb25afed5b5c3d45f5ee9278"
        static let poll       = "e83188a3836c636393df3191665e543a03733d7c51d3ade3d85e42aa46c2bf55"
        static let prediction = "beb846598256b75bd7c1fe54a80431335996153e358ca9c7837ce7bb83d7d383"
        static let hype       = "75ce00c56153ceba3be9f6772e1db11a9c5aed5029dc6243cfcc132460c56b23"
    }

    func start(login: String, channelId: String, token: String?) {
        stop()
        self.login = login.lowercased(); self.channelId = channelId; self.token = token
        Task { await fetchAll() }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { await self?.fetchAll() }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        watchStreak = 0; poll = nil; prediction = nil; hype = nil
    }

    private func fetchAll() async {
        await fetchStreak()
        await fetchPoll()
        await fetchPrediction()
        await fetchHype()
    }

    // MARK: Série de visionnage
    private func fetchStreak() async {
        guard let res  = await TwitchGQL.shared.query("BatchGetWatchStreaks", variables: [:],
                                                      sha256: H.streak, token: token),
              let data = res["data"] as? [String: Any],
              let arr  = data["batchGetWatchStreaks"] as? [[String: Any]] else { return }
        var v = 0
        for item in arr where (item["channel"] as? [String: Any])?["id"] as? String == channelId {
            v = item["value"] as? Int ?? 0
            break
        }
        if v != watchStreak {
            logger.success("EVENTS", "🔥 Série de visionnage", "\(v) pour \(login)")
        }
        watchStreak = v
    }

    // MARK: Sondage
    private func fetchPoll() async {
        guard let res   = await TwitchGQL.shared.query("ChannelPollContext_GetViewablePoll",
                                                       variables: ["login": login], sha256: H.poll, token: token),
              let data  = res["data"]    as? [String: Any],
              let chan  = data["channel"] as? [String: Any] else { return }
        guard let p = chan["viewablePoll"] as? [String: Any] else {
            if poll != nil { logger.debug("EVENTS", "Sondage terminé", nil) }
            poll = nil; return
        }
        logger.debug("EVENTS", "Sondage brut", "\(p.keys.sorted())")
        let title = p["title"] as? String ?? "Sondage"
        let raw = p["choices"] as? [[String: Any]] ?? []
        let choices = raw.map { c -> (String, Int) in
            let v = (c["totalVoters"] as? Int)
                 ?? ((c["votes"] as? [String: Any])?["total"] as? Int) ?? 0
            return (c["title"] as? String ?? "", v)
        }
        let newPoll = choices.isEmpty ? nil : LivePoll(title: title, choices: choices)
        if newPoll?.title != poll?.title, let np = newPoll {
            logger.success("EVENTS", "📊 Sondage actif", np.title)
        }
        poll = newPoll
    }

    // MARK: Prédiction
    private func fetchPrediction() async {
        guard let res   = await TwitchGQL.shared.query("ChannelPointsPredictionContext",
                                                       variables: ["count": 1, "channelLogin": login],
                                                       sha256: H.prediction, token: token),
              let data  = res["data"]        as? [String: Any],
              let comm  = data["community"]  as? [String: Any],
              let chan  = comm["channel"]    as? [String: Any] else { return }
        let active = chan["activePredictionEvents"] as? [[String: Any]] ?? []
        let locked = chan["lockedPredictionEvents"] as? [[String: Any]] ?? []
        guard let ev = active.first ?? locked.first else {
            if prediction != nil { logger.debug("EVENTS", "Prédiction terminée", nil) }
            prediction = nil; return
        }
        let title = ev["title"] as? String ?? "Prédiction"
        let isLocked = active.isEmpty || (ev["status"] as? String) == "LOCKED"
        let outcomes = (ev["outcomes"] as? [[String: Any]] ?? []).map { o -> (String, String, Int) in
            (o["title"] as? String ?? "",
             o["color"] as? String ?? "BLUE",
             o["totalPoints"] as? Int ?? 0)
        }
        let newPred = outcomes.isEmpty ? nil
                    : LivePrediction(title: title, locked: isLocked, outcomes: outcomes)
        if newPred?.title != prediction?.title, let np = newPred {
            logger.success("EVENTS", "🔮 Prédiction active\(np.locked ? " (verrouillée)" : "")", np.title)
        }
        prediction = newPred
    }

    // MARK: Hype train (structure active jamais capturée → parse défensif + log)
    private func fetchHype() async {
        guard let res  = await TwitchGQL.shared.query("GetHypeTrainExecution",
                                                      variables: ["userLogin": login], sha256: H.hype, token: token),
              let data = res["data"]    as? [String: Any],
              let user = data["user"]   as? [String: Any],
              let chan = user["channel"] as? [String: Any],
              let ht   = chan["hypeTrain"] as? [String: Any] else { return }
        guard let exec = ht["execution"] as? [String: Any] else {
            if hype != nil { logger.debug("EVENTS", "Hype train terminé", nil) }
            hype = nil; return
        }
        logger.debug("EVENTS", "Hype train brut", "\(exec.keys.sorted())")
        let progress = exec["progress"] as? [String: Any]
        let level = (progress?["level"] as? [String: Any])?["value"] as? Int
                 ?? (exec["level"] as? [String: Any])?["value"] as? Int ?? 1
        let total = progress?["total"] as? Int ?? 0
        let goal  = (progress?["goal"] as? Int)
                 ?? ((progress?["level"] as? [String: Any])?["goal"] as? Int) ?? 0
        if hype?.level != level {
            logger.success("EVENTS", "🚄 Hype train actif", "niveau \(level)")
        }
        hype = LiveHype(level: level, percent: goal > 0 ? min(1, Double(total) / Double(goal)) : 0)
    }
}

// MARK: – Bandeau des événements live
struct LiveEventsBanner: View {
    @ObservedObject var events: LiveEventsService
    @EnvironmentObject private var store: AppStore

    private func predColor(_ c: String) -> Color {
        switch c.uppercased() {
        case "BLUE": return Color(hex: "3d7dff")
        case "PINK": return Color(hex: "f5009b")
        case "GRAY", "GREY": return .tMuted
        default: return .tPrimary
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let poll = events.poll {
                banner(icon: "chart.bar.fill", tint: .tPrimary) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("📊 \(poll.title)").font(.system(size: 12, weight: .bold)).foregroundColor(.tText)
                        ForEach(Array(poll.choices.enumerated()), id: \.offset) { _, c in
                            bar(label: c.title, value: c.votes, total: poll.total, color: .tPrimary)
                        }
                    }
                }
            }
            if let pred = events.prediction {
                banner(icon: "sparkles", tint: .tPurple) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("🔮 \(pred.title)\(pred.locked ? " 🔒" : "")")
                            .font(.system(size: 12, weight: .bold)).foregroundColor(.tText)
                        ForEach(Array(pred.outcomes.enumerated()), id: \.offset) { _, o in
                            bar(label: o.title, value: o.points, total: pred.total,
                                color: predColor(o.color), suffix: "pts")
                        }
                    }
                }
            }
            if let hype = events.hype {
                banner(icon: "flame.fill", tint: .tLive) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("🚄 Hype Train — \(store.t("hype_level")) \(hype.level)")
                            .font(.system(size: 12, weight: .bold)).foregroundColor(.tText)
                        ProgressView(value: hype.percent).tint(.tLive)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func banner<Content: View>(icon: String, tint: Color, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).font(.system(size: 12)).foregroundColor(tint).padding(.top, 2)
            content()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(tint.opacity(0.10))
        .overlay(Divider().background(Color.tBorder), alignment: .bottom)
    }

    @ViewBuilder
    private func bar(label: String, value: Int, total: Int, color: Color, suffix: String = "") -> some View {
        let pct = Double(value) / Double(total)
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(label).font(.system(size: 11, weight: .semibold)).foregroundColor(.tText).lineLimit(1)
                Spacer()
                Text("\(Int(pct * 100))%").font(.system(size: 10, weight: .bold)).foregroundColor(.tMuted)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.tSurface).frame(height: 5)
                    Capsule().fill(color).frame(width: max(3, geo.size.width * pct), height: 5)
                }
            }
            .frame(height: 5)
        }
    }
}
