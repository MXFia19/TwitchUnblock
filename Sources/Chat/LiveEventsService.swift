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
        let id: String
        let title: String
        let choices: [Choice]
        let endsAt: Date?
        /// Terminé (Twitch le renvoie encore 1 à 3 min) : résultats, plus de vote.
        var isActive: Bool = true
        /// Plusieurs choix possibles.
        var multichoice: Bool = false
        var total: Int { max(1, choices.reduce(0) { $0 + $1.votes }) }
        var winnerId: String? {
            guard !isActive, let best = choices.max(by: { $0.votes < $1.votes }), best.votes > 0 else { return nil }
            return best.id
        }
        struct Choice: Identifiable { let id: String; let title: String; let votes: Int }
    }
    struct LivePrediction {
        var id: String = ""
        let title: String
        let locked: Bool
        let outcomes: [(id: String, title: String, color: String, points: Int, users: Int)]
        /// Fin de la période de pari (prédiction encore ouverte).
        var closesAt: Date? = nil
        /// Résultat connu : l'issue gagnante (affichée un moment après la fin).
        var winnerId: String? = nil
        /// Ton pari (session web) : issue choisie et points misés au total.
        var myOutcomeId: String? = nil
        var myPoints: Int = 0
        var total: Int { max(1, outcomes.reduce(0) { $0 + $1.points }) }
    }
    struct LiveHype { let level: Int; let percent: Double }

    /// Choix pour lesquels on a voté (vide = pas encore voté sur ce sondage).
    @Published var votedChoiceIds: Set<String> = []
    var votedChoiceId: String? { votedChoiceIds.first }
    /// Une prédiction vient de se terminer : on montre l'issue gagnante une minute.
    private var resultUntil: Date? = nil
    @Published var voting = false
    /// Pari en cours d'envoi, et la dernière erreur (code Twitch, ou
    /// NO_SESSION / NETWORK) traduite par la vue.
    @Published var betting = false
    @Published var betError: String? = nil
    /// Paris envoyés d'ici (id de prédiction → issue, points) : affichés tout
    /// de suite, sans attendre que Twitch les renvoie.
    private var localBets: [String: (outcomeId: String, points: Int)] = [:]

    private var channelId = ""
    private var login = ""
    private var viewerId = ""
    private var token: String? = nil
    private var timer: Timer?
    private let interval: TimeInterval = 15

    private enum H {
        static let streak     = "7d04fbaa5bb32d193c742caa2c855dfde371a2a8cb25afed5b5c3d45f5ee9278"
        static let poll       = "e83188a3836c636393df3191665e543a03733d7c51d3ade3d85e42aa46c2bf55"
        static let prediction = "beb846598256b75bd7c1fe54a80431335996153e358ca9c7837ce7bb83d7d383"
        static let hype       = "75ce00c56153ceba3be9f6772e1db11a9c5aed5029dc6243cfcc132460c56b23"
        static let votePoll   = "1280e27b0f3c7ae60b5714bd569771ea50635778473182e6e959e2dcfcc16e3c"
        /// MakePrediction (client web) : { eventID, outcomeID, points, transactionID }.
        static let makePrediction = "b44682ecc88358817009f20e69d75081b1e58825bb40aa53d5dbadcc17c881d8"
    }

    func start(login: String, channelId: String, token: String?, viewerId: String = "") {
        stop()
        self.login = login.lowercased(); self.channelId = channelId
        self.token = token; self.viewerId = viewerId
        Task { await fetchAll() }
        timer = Timer.scheduledCommon(every: interval) { [weak self] _ in
            Task { await self?.fetchAll() }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        watchStreak = 0; poll = nil; prediction = nil; hype = nil
        votedChoiceIds = []; voting = false; resultUntil = nil
        betting = false; betError = nil; localBets = [:]
    }

    // MARK: Pari sur la prédiction
    /// Mise de `points` sur une issue, comme sur Twitch : 10 points minimum,
    /// 250 000 au plus par prédiction, une seule issue (on peut y rajouter).
    /// Mutation à jeton d'intégrité, avec la session web (celle des points).
    func predict(outcomeId: String, points: Int) async -> Bool {
        guard !betting, let p = prediction, !p.locked, p.winnerId == nil,
              !p.id.isEmpty, !outcomeId.isEmpty, points > 0 else { return false }
        guard let tok = token, !tok.isEmpty else {
            betError = "NO_SESSION"
            return false
        }
        betting = true
        betError = nil
        defer { betting = false }

        // transactionID : 32 caractères hexadécimaux, tirés au hasard.
        let tx = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let input: [String: Any] = [
            "eventID":       p.id,
            "outcomeID":     outcomeId,
            "points":        points,
            "transactionID": tx
        ]
        let res = await TwitchGQL.shared.mutation("MakePrediction", variables: ["input": input],
                                                  sha256: H.makePrediction, token: tok)
        guard let data = res?["data"] as? [String: Any],
              let made = data["makePrediction"] as? [String: Any] else {
            let msgs = (res?["errors"] as? [[String: Any]] ?? []).compactMap { $0["message"] as? String }
            betError = msgs.contains { $0.lowercased().contains("unauthenticated") } ? "NO_SESSION" : "NETWORK"
            logger.warn("EVENTS", "Pari refusé", msgs.joined(separator: " · "))
            return false
        }
        if let err = made["error"] as? [String: Any], let code = err["code"] as? String {
            betError = code
            logger.warn("EVENTS", "Pari refusé", code)
            return false
        }
        // Total misé sur cette issue (on peut y rajouter des points).
        let total = (p.myOutcomeId == outcomeId ? p.myPoints : 0) + points
        localBets[p.id] = (outcomeId, total)
        var updated = p
        updated.myOutcomeId = outcomeId
        updated.myPoints = total
        prediction = updated
        logger.success("EVENTS", "🔮 Pari enregistré", "\(points) pts · \(p.title)")
        await fetchPrediction()           // pourcentages à jour
        return true
    }

    // MARK: Vote au sondage
    func vote(choiceId: String) async {
        guard !voting, let p = poll, p.isActive, !p.id.isEmpty, !choiceId.isEmpty,
              !votedChoiceIds.contains(choiceId),
              p.multichoice || votedChoiceIds.isEmpty else { return }
        guard !viewerId.isEmpty, let tok = token, !tok.isEmpty else {
            logger.warn("EVENTS", "Vote impossible", "session web ou compte manquant")
            return
        }
        voting = true
        defer { voting = false }

        // voteID : identifiant client (UUID sans tirets), comme le site.
        let voteId = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let input: [String: Any] = [
            "pollID":   p.id,
            "choiceID": choiceId,
            "userID":   viewerId,
            "voteID":   voteId,
            "tokens":   NSNull()          // null = vote gratuit (sans points)
        ]
        let res = await TwitchGQL.shared.mutation("ChannelPollContext_VoteInPoll",
                                                  variables: ["input": input],
                                                  sha256: H.votePoll, token: tok)
        if let d = res?["data"] as? [String: Any], d["voteInPoll"] != nil,
           res?["errors"] == nil {
            votedChoiceIds.insert(choiceId)
            logger.success("EVENTS", "🗳️ Vote enregistré", p.title)
            await fetchPoll()             // rafraîchit les pourcentages
        } else {
            logger.warn("EVENTS", "Vote refusé", nil)
        }
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
            poll = nil; votedChoiceIds = []; return
        }
        logger.debug("EVENTS", "Sondage brut", "\(p.keys.sorted())")
        let title = p["title"] as? String ?? "Sondage"
        let raw = p["choices"] as? [[String: Any]] ?? []
        let choices = raw.map { c -> LivePoll.Choice in
            let v = (c["totalVoters"] as? Int)
                 ?? ((c["votes"] as? [String: Any])?["total"] as? Int) ?? 0
            return LivePoll.Choice(id: c["id"] as? String ?? "",
                                   title: c["title"] as? String ?? "", votes: v)
        }
        // Fin du sondage : plusieurs formes possibles selon la réponse → parse défensif.
        let endsAt = pollEndDate(p)
        let status = (p["status"] as? String)?.uppercased() ?? "ACTIVE"
        let settings = p["settings"] as? [String: Any]
        let multi = ((settings?["multichoice"] as? [String: Any])?["isEnabled"] as? Bool)
                 ?? (settings?["multichoice"] as? Bool) ?? false
        let newPoll = choices.isEmpty ? nil
                    : LivePoll(id: p["id"] as? String ?? "", title: title,
                               choices: choices, endsAt: endsAt,
                               isActive: status == "ACTIVE", multichoice: multi)
        if newPoll?.id != poll?.id {
            votedChoiceIds = []        // nouveau sondage → on peut revoter
            if let np = newPoll {
                logger.success("EVENTS", "📊 Sondage actif",
                               "\(np.title) · fin \(np.endsAt.map { "\($0)" } ?? "?")")
            }
        }
        poll = newPoll
    }

    /// Déduit l'heure de fin d'un sondage depuis les champs disponibles.
    private func pollEndDate(_ p: [String: Any]) -> Date? {
        if let ms = p["remainingDurationMilliseconds"] as? Int {
            return Date().addingTimeInterval(Double(ms) / 1000)
        }
        if let end = p["endedAt"] as? String, let d = isoDate(end) { return d }
        if let dur = p["durationSeconds"] as? Int, let startStr = p["startedAt"] as? String,
           let start = isoDate(startStr) {
            return start.addingTimeInterval(Double(dur))
        }
        return nil
    }

    private func isoDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
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
            // Disparue : terminée. On cherche l'issue gagnante pour l'afficher
            // une minute, au lieu de tout faire disparaître d'un coup.
            if let prev = prediction {
                if prev.winnerId == nil, !prev.id.isEmpty, let winner = await resolvedWinner(eventId: prev.id) {
                    var done = prev
                    done.winnerId = winner
                    done.closesAt = nil
                    prediction = done
                    resultUntil = Date().addingTimeInterval(60)
                    logger.success("EVENTS", "🏆 Prédiction résolue", prev.title)
                } else if prev.winnerId == nil || (resultUntil ?? .distantPast) < Date() {
                    logger.debug("EVENTS", "Prédiction terminée", nil)
                    prediction = nil; resultUntil = nil
                }
            }
            return
        }
        resultUntil = nil
        let title = ev["title"] as? String ?? "Prédiction"
        let isLocked = active.isEmpty || (ev["status"] as? String) == "LOCKED"
        let outcomes = (ev["outcomes"] as? [[String: Any]] ?? []).map { o -> (id: String, title: String, color: String, points: Int, users: Int) in
            (o["id"] as? String ?? "",
             o["title"] as? String ?? "",
             o["color"] as? String ?? "BLUE",
             o["totalPoints"] as? Int ?? 0,
             o["totalUsers"] as? Int ?? 0)
        }
        // Compte à rebours de la période de pari.
        var closesAt: Date? = nil
        if !isLocked, let created = (ev["createdAt"] as? String).flatMap(isoDate),
           let window = ev["predictionWindowSeconds"] as? Int {
            closesAt = created.addingTimeInterval(Double(window))
        }
        var newPred = outcomes.isEmpty ? nil
                    : LivePrediction(id: ev["id"] as? String ?? "", title: title, locked: isLocked,
                                     outcomes: outcomes, closesAt: closesAt)
        // Ton pari : celui que Twitch connaît, sinon celui envoyé d'ici à
        // l'instant (Twitch peut mettre quelques secondes à le renvoyer).
        if var np = newPred {
            let local = localBets[np.id]
            if let mine = await myPrediction(eventId: np.id) {
                np.myOutcomeId = mine.outcomeId
                np.myPoints = local?.outcomeId == mine.outcomeId ? max(mine.points, local?.points ?? 0) : mine.points
            } else if let local {
                np.myOutcomeId = local.outcomeId
                np.myPoints = local.points
            }
            newPred = np
        }
        if newPred?.title != prediction?.title, let np = newPred {
            logger.success("EVENTS", "🔮 Prédiction active\(np.locked ? " (verrouillée)" : "")", np.title)
        }
        prediction = newPred
    }

    /// Ton pari sur la prédiction en cours (`self`, session web requise).
    private func myPrediction(eventId: String) async -> (outcomeId: String, points: Int)? {
        guard let tok = token, !tok.isEmpty, !eventId.isEmpty else { return nil }
        let ev = "id self { prediction { points outcome { id } } }"
        let q = "query($l: String!) { channel(name: $l) { activePredictionEvents { \(ev) } lockedPredictionEvents { \(ev) } } }"
        guard let d = await rawGQL(q, token: tok),
              let chan = d["channel"] as? [String: Any] else { return nil }
        let events = (chan["activePredictionEvents"] as? [[String: Any]] ?? [])
                   + (chan["lockedPredictionEvents"] as? [[String: Any]] ?? [])
        for e in events where e["id"] as? String == eventId {
            let pred = (e["self"] as? [String: Any])?["prediction"] as? [String: Any]
            guard let pts = pred?["points"] as? Int,
                  let oid = (pred?["outcome"] as? [String: Any])?["id"] as? String else { return nil }
            return (oid, pts)
        }
        return nil
    }

    /// Requête GQL écrite en clair ; `token` pour les champs `self`. → `data`
    private func rawGQL(_ q: String, token: String? = nil) async -> [String: Any]? {
        guard let url = URL(string: "https://gql.twitch.tv/gql"),
              let body = try? JSONSerialization.data(withJSONObject: ["query": q, "variables": ["l": login]]) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(kGQLClientID, forHTTPHeaderField: "Client-ID")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { req.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization") }
        req.httpBody = body
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["data"] as? [String: Any]
    }

    /// Issue gagnante d'une prédiction terminée (requête GQL publique).
    private func resolvedWinner(eventId: String) async -> String? {
        let q = "query($l: String!) { channel(name: $l) { resolvedPredictionEvents(first: 3) { edges { node { id winningOutcome { id } } } } } }"
        guard let d = await rawGQL(q),
              let chan = d["channel"] as? [String: Any],
              let conn = chan["resolvedPredictionEvents"] as? [String: Any],
              let edges = conn["edges"] as? [[String: Any]] else { return nil }
        for e in edges {
            guard let n = e["node"] as? [String: Any], n["id"] as? String == eventId else { continue }
            return (n["winningOutcome"] as? [String: Any])?["id"] as? String
        }
        return nil
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
    /// Solde et session web : pour parier sur les prédictions.
    @ObservedObject var points: ChannelPointsService
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(spacing: 0) {
            if let poll = events.poll {
                banner(icon: "chart.bar.fill", tint: .tPrimary) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text("📊 \(poll.title)")
                                .font(.system(size: 12, weight: .bold)).foregroundColor(.tText)
                            Spacer(minLength: 4)
                            if !poll.isActive {
                                Text(store.t("poll_results"))
                                    .font(.system(size: 10, weight: .bold)).foregroundColor(.tMuted)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.tSurface).cornerRadius(5)
                            } else if let endsAt = poll.endsAt, endsAt > Date() {
                                HStack(spacing: 3) {
                                    Image(systemName: "clock.fill").font(.system(size: 9))
                                    Text(timerInterval: Date()...endsAt, countsDown: true)
                                        .font(.system(size: 11, weight: .bold).monospacedDigit())
                                }
                                .foregroundColor(.tPrimary)
                            }
                        }
                        if poll.multichoice && poll.isActive {
                            Text(store.t("poll_multi"))
                                .font(.system(size: 10)).foregroundColor(.tMuted)
                        }
                        ForEach(poll.choices) { c in
                            let voted = events.votedChoiceIds.contains(c.id)
                            Button {
                                Task { await events.vote(choiceId: c.id) }
                            } label: {
                                EventBar(label: c.title, value: c.votes, total: poll.total,
                                         color: poll.winnerId == c.id ? .tSuccess : .tPrimary,
                                         voted: voted, winner: poll.winnerId == c.id)
                            }
                            .buttonStyle(.plain)
                            .disabled(events.voting || !poll.isActive || voted || c.id.isEmpty
                                      || (!poll.multichoice && !events.votedChoiceIds.isEmpty))
                        }
                        Text("\(poll.choices.reduce(0) { $0 + $1.votes }) \(store.t("poll_votes"))")
                            .font(.system(size: 10)).foregroundColor(.tMuted)
                    }
                }
            }
            if let pred = events.prediction {
                banner(icon: "sparkles", tint: .tPurple) {
                    PredictionCard(pred: pred, events: events, points: points)
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
}

// MARK: – Prédiction : barres et pari
/// Les issues se touchent pour parier, comme sur Twitch : montant, solde, puis
/// « Parier ». Il faut la session web Twitch (celle des points de chaîne).
private struct PredictionCard: View {
    typealias Outcome = (id: String, title: String, color: String, points: Int, users: Int)

    let pred: LiveEventsService.LivePrediction
    @ObservedObject var events: LiveEventsService
    @ObservedObject var points: ChannelPointsService
    @EnvironmentObject private var store: AppStore
    @State private var selected: String? = nil
    @State private var amount = ""
    @FocusState private var amountFocused: Bool

    /// Règles de Twitch : 10 points au moins, 250 000 au plus par prédiction.
    private static let minBet = 10
    private static let maxTotal = 250_000

    private var open: Bool {
        !pred.locked && pred.winnerId == nil && (pred.closesAt.map { $0 > Date() } ?? true)
    }
    private var needsSession: Bool { store.twitchWebToken == nil || points.needsWebLogin }
    /// Mise possible : le solde, sans dépasser le plafond (paris déjà faits compris).
    private var maxBet: Int { max(0, min(points.balance, Self.maxTotal - pred.myPoints)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            ForEach(Array(pred.outcomes.enumerated()), id: \.offset) { _, o in
                outcomeRow(o)
            }
            if let mine = myOutcome {
                Text(store.t("pred_my_bet")
                        .replacingOccurrences(of: "{n}", with: points.formatted(pred.myPoints))
                        .replacingOccurrences(of: "{o}", with: mine.title))
                    .font(.system(size: 10, weight: .semibold)).foregroundColor(.tSuccess)
            }
            if open {
                if needsSession {
                    Text(store.t("pred_need_login"))
                        .font(.system(size: 10)).foregroundColor(.tMuted)
                } else if let o = pred.outcomes.first(where: { $0.id == selected }) {
                    betPanel(o)
                } else {
                    Text(store.t("pred_tap_to_bet"))
                        .font(.system(size: 10)).foregroundColor(.tMuted)
                }
            }
        }
        // Prédiction suivante : on repart de zéro.
        .onChange(of: pred.id) { _ in
            selected = nil
            amount = ""
            events.betError = nil
        }
    }

    private var myOutcome: Outcome? {
        guard pred.myPoints > 0, let id = pred.myOutcomeId else { return nil }
        return pred.outcomes.first { $0.id == id }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("🔮 \(pred.title)\(pred.locked && pred.winnerId == nil ? " 🔒" : "")")
                .font(.system(size: 12, weight: .bold)).foregroundColor(.tText)
            Spacer(minLength: 4)
            if let closes = pred.closesAt, closes > Date() {
                HStack(spacing: 3) {
                    Image(systemName: "clock.fill").font(.system(size: 9))
                    Text(timerInterval: Date()...closes, countsDown: true)
                        .font(.system(size: 11, weight: .bold).monospacedDigit())
                }
                .foregroundColor(.tPurple)
            } else if pred.winnerId != nil {
                Text(store.t("pred_result"))
                    .font(.system(size: 10, weight: .bold)).foregroundColor(.tSuccess)
            }
        }
    }

    /// Une issue : sa barre, qui se touche pour parier. Une seule issue par
    /// prédiction : après un pari, seule la sienne reste ouverte (on peut y
    /// rajouter des points).
    @ViewBuilder
    private func outcomeRow(_ o: Outcome) -> some View {
        let mine = pred.myOutcomeId == o.id && pred.myPoints > 0
        let tappable = open && (pred.myOutcomeId == nil || pred.myPoints == 0 || mine)
        let users = o.users > 0 ? " · \(o.users) 👤" : ""
        let tint = pred.winnerId == nil || pred.winnerId == o.id ? Self.color(o.color) : Color.tMuted
        Button {
            events.betError = nil
            withAnimation(.easeInOut(duration: 0.15)) { selected = selected == o.id ? nil : o.id }
        } label: {
            EventBar(label: o.title + users, value: o.points, total: pred.total, color: tint,
                     voted: mine, winner: pred.winnerId == o.id,
                     selected: tappable && selected == o.id)
        }
        .buttonStyle(.plain)
        .disabled(!tappable)
    }

    @ViewBuilder
    private func betPanel(_ o: Outcome) -> some View {
        let tint = Self.color(o.color)
        let value = Int(amount) ?? 0
        let valid = value >= Self.minBet && value <= maxBet
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(store.t("pred_bet_on").replacingOccurrences(of: "{o}", with: o.title))
                    .font(.system(size: 11, weight: .bold)).foregroundColor(tint).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(store.t("pred_balance")) \(points.formatted(points.balance))")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundColor(.tMuted)
            }
            HStack(spacing: 6) {
                ForEach(presets, id: \.self) { v in
                    Button { amount = "\(v)" } label: {
                        Text(v == maxBet ? store.t("pred_all") : Self.short(v))
                            .font(.system(size: 11, weight: .bold)).foregroundColor(.tText)
                            .padding(.horizontal, 8).frame(height: 26)
                            .background(Color.tSurface).cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 8) {
                TextField("\(Self.minBet)", text: $amount)
                    .keyboardType(.numberPad)
                    .focused($amountFocused)
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundColor(.tText)
                    .padding(.horizontal, 8).frame(height: 30)
                    .background(Color.tSurface).cornerRadius(6)
                    .onChange(of: amount) { v in
                        let digits = String(v.filter { $0.isASCII && $0.isNumber }.prefix(7))
                        if digits != v { amount = digits }
                    }
                Button { place(on: o.id, value: value) } label: {
                    ZStack {
                        if events.betting {
                            ProgressView().tint(.white).scaleEffect(0.7)
                        } else {
                            Text(store.t("pred_bet")).font(.system(size: 12, weight: .bold))
                        }
                    }
                    .foregroundColor(.white)
                    .frame(minWidth: 70).frame(height: 30)
                    .background(valid ? tint : Color.tMuted.opacity(0.5))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .disabled(!valid || events.betting)
            }
            if let code = events.betError {
                Text(errorLabel(code))
                    .font(.system(size: 10, weight: .semibold)).foregroundColor(.tLive)
            } else if value > 0 && value < Self.minBet {
                Text(store.t("pred_min")).font(.system(size: 10)).foregroundColor(.tMuted)
            } else if value > maxBet {
                Text(store.t(maxBet < points.balance ? "pred_max" : "err_not_enough"))
                    .font(.system(size: 10)).foregroundColor(.tLive)
            }
        }
        .padding(.top, 2)
    }

    private func place(on outcomeId: String, value: Int) {
        amountFocused = false
        Task {
            guard await events.predict(outcomeId: outcomeId, points: value) else { return }
            // Le solde suit tout de suite ; le service le relira de Twitch.
            points.balance = max(0, points.balance - value)
            amount = ""
            selected = nil
        }
    }

    /// Montants proposés (10, 100, 1k, 10k sous la limite), puis « Max ».
    private var presets: [Int] {
        var list = [10, 100, 1_000, 10_000].filter { $0 < maxBet }
        if maxBet >= Self.minBet { list.append(maxBet) }
        return list
    }

    private static func short(_ v: Int) -> String { v >= 1_000 ? "\(v / 1_000)k" : "\(v)" }

    private func errorLabel(_ code: String) -> String {
        let c = code.uppercased()
        if c == "NO_SESSION" { return store.t("pred_need_login") }
        if c == "NETWORK" { return store.t("pred_bet_failed") }
        if c.contains("NOT_ENOUGH") || c.contains("INSUFFICIENT") { return store.t("err_not_enough") }
        if c.contains("NOT_ACTIVE") || c.contains("LOCKED") || c.contains("CLOSED") || c.contains("ENDED") {
            return store.t("pred_closed")
        }
        if c.contains("OUTCOME") || c.contains("MULTIPLE") || c.contains("DIFFERENT") {
            return store.t("pred_one_outcome")
        }
        if c.contains("MAX") || c.contains("LIMIT") { return store.t("pred_max") }
        return "\(store.t("points_error")) : \(code)"
    }

    static func color(_ c: String) -> Color {
        switch c.uppercased() {
        case "BLUE": return Color(hex: "3d7dff")
        case "PINK": return Color(hex: "f5009b")
        case "GRAY", "GREY": return .tMuted
        default: return .tPrimary
        }
    }
}

// MARK: – Barre de résultat (sondage, prédiction)
struct EventBar: View {
    let label: String
    let value: Int
    let total: Int
    let color: Color
    var voted = false
    var winner = false
    /// Issue choisie pour parier : encadrée.
    var selected = false

    var body: some View {
        let pct = Double(value) / Double(max(total, 1))
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                if winner {
                    Image(systemName: "trophy.fill")
                        .font(.system(size: 10)).foregroundColor(.tWarning)
                }
                if voted {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10)).foregroundColor(.tSuccess)
                }
                Text(label).font(.system(size: 11, weight: .semibold))
                    .foregroundColor(voted ? .tSuccess : .tText).lineLimit(1)
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
        .contentShape(Rectangle())
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(color, lineWidth: selected ? 1.5 : 0)
                .padding(-4)
        )
    }
}
