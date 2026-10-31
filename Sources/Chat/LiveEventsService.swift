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
        /// Clé de fermeture (×) : un nouveau sondage a un autre id et réapparaît.
        var noticeKey: String { "poll:" + (id.isEmpty ? title : id) }
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
        /// Plus grosse mise de chaque issue (id → points), quand Twitch l'envoie.
        var topBets: [String: Int] = [:]
        var total: Int { max(1, outcomes.reduce(0) { $0 + $1.points }) }
        /// Cote d'une issue, comme Twitch : 1 point misé en rapporte `total / points`
        /// (mise comprise) si elle gagne ; nil tant que personne n'a misé dessus.
        func ratio(_ points: Int) -> Double? {
            points > 0 ? Double(outcomes.reduce(0) { $0 + $1.points }) / Double(points) : nil
        }
        /// Clé de fermeture (×) : la même jusqu'au résultat, une autre pour la suivante.
        var noticeKey: String { "pred:" + (id.isEmpty ? title : id) }
    }
    struct LiveHype {
        enum Phase { case approaching, running }
        enum Variant { case regular, golden, treasure }
        /// Message court qui remplace un moment le contenu de la carte.
        enum Flash: Equatable {
            /// Départ après l'approche : toutes les pastilles cochées (1,5 s).
            case kickoff
            /// Le train est parti (10 s).
            case departed
            /// Niveau N terminé (4 s).
            case levelDone(Int)
            /// Train terminé au niveau N, à P % du suivant (15 s).
            case ended(level: Int, percent: Int)
        }
        /// Id du train : le même pour l'approche et le train, et d'un niveau
        /// à l'autre.
        var id: String = ""
        var phase: Phase = .running
        var variant: Variant = .regular
        var level: Int = 1
        /// Avancée du niveau en cours (0…1).
        var percent: Double = 0
        /// Approche : soutiens qui manquent pour le lancer.
        var left: Int = 1
        /// Objectif > 5 : trois pastilles au lieu de deux, comme Twitch.
        var bigGoal = false
        /// Fin de l'approche ou du niveau en cours (nil sur l'écran de fin).
        var endsAt: Date? = nil
        var flash: Flash? = nil
        var flashUntil: Date? = nil
        /// Niveau terminé pendant le départ : montré à la fin de « parti ».
        var pendingLevelDone: Int? = nil
        /// Clé de fermeture (×) : un train fermé le reste jusqu'à sa fin.
        /// L'approche a la sienne (même id) : fermer l'annonce ne cache pas
        /// le départ qu'on attend.
        var noticeKey: String {
            let base = phase == .approaching ? "hype-approach" : "hype"
            return id.isEmpty ? base : base + ":" + id
        }
    }

    /// Choix pour lesquels on a voté (vide = pas encore voté sur ce sondage).
    @Published var votedChoiceIds: Set<String> = []
    var votedChoiceId: String? { votedChoiceIds.first }
    /// Une prédiction vient de se terminer : on montre l'issue gagnante une minute.
    private var resultUntil: Date? = nil
    @Published var voting = false
    /// Vote au sondage refusé (« NO_SESSION » : session web absente, sinon
    /// « REFUSED ») : la vue le dit — toucher un choix ne faisait rien.
    @Published var voteError: String? = nil
    /// Session web refusée par Twitch pour les lectures publiques (expirée) :
    /// elles se font sans elle jusqu'au prochain démarrage.
    private var tokenRefused = false
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

    // Hype train : sa propre boucle (5 s pendant une approche, 15 s sinon),
    // une relecture à l'échéance et la fin du message court en cours.
    /// Démarré (start) et pas encore arrêté.
    private(set) var running = false
    private var hypeEnabled = false
    private var hypeLoop: Task<Void, Never>? = nil
    private var hypeDeadlineTask: Task<Void, Never>? = nil
    private var hypeFlashTask: Task<Void, Never>? = nil
    /// Premier relevé fait : avant lui, aucune transition (comme Twitch).
    private var hypeRead = false
    /// Change à chaque arrêt : une réponse d'avant est ignorée.
    private var hypeGen = 0
    /// Numéro de chaque relevé parti, et du dernier appliqué : la boucle et
    /// la relecture à l'échéance peuvent se croiser, une réponse partie avant
    /// celle déjà appliquée est ignorée (sinon l'écran de fin clignote).
    private var hypeSeq = 0
    private var hypeApplied = 0

    private enum H {
        static let streak     = "7d04fbaa5bb32d193c742caa2c855dfde371a2a8cb25afed5b5c3d45f5ee9278"
        static let poll       = "e83188a3836c636393df3191665e543a03733d7c51d3ade3d85e42aa46c2bf55"
        static let prediction = "beb846598256b75bd7c1fe54a80431335996153e358ca9c7837ce7bb83d7d383"
        static let votePoll   = "1280e27b0f3c7ae60b5714bd569771ea50635778473182e6e959e2dcfcc16e3c"
        /// MakePrediction (client web) : { eventID, outcomeID, points, transactionID }.
        static let makePrediction = "b44682ecc88358817009f20e69d75081b1e58825bb40aa53d5dbadcc17c881d8"
    }

    /// `hype` : suivre le hype train (événements live affichés). Le service
    /// démarre aussi pour la seule série de visionnage : pas de relevé du
    /// train toutes les 5 s si personne ne le voit.
    func start(login: String, channelId: String, token: String?, viewerId: String = "",
               hype: Bool = true) {
        stop()
        self.login = login.lowercased(); self.channelId = channelId
        self.token = token; self.viewerId = viewerId
        tokenRefused = false
        running = true
        Task { await fetchAll() }
        timer = Timer.scheduledCommon(every: interval) { [weak self] _ in
            Task { await self?.fetchAll() }
        }
        hypeEnabled = hype
        if hype { startHypeLoop() }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        running = false; hypeEnabled = false
        stopHype()
        watchStreak = 0; poll = nil; prediction = nil
        votedChoiceIds = []; voting = false; voteError = nil; resultUntil = nil
        betting = false; betError = nil; localBets = [:]
    }

    /// Réglage des événements changé pendant le live : la boucle du train suit.
    func setHypeEnabled(_ on: Bool) {
        guard running, on != hypeEnabled else { return }
        hypeEnabled = on
        if on { startHypeLoop() } else { stopHype() }
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
            voteError = "NO_SESSION"
            return
        }
        voting = true
        voteError = nil
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
            let msgs = (res?["errors"] as? [[String: Any]] ?? []).compactMap { $0["message"] as? String }
            voteError = msgs.contains { $0.lowercased().contains("unauthenticated") } ? "NO_SESSION" : "REFUSED"
            logger.warn("EVENTS", "Vote refusé", msgs.joined(separator: " · "))
        }
    }

    /// Lecture publique (sondage, prédiction) : avec la session web (champs
    /// « self »), et sans elle si Twitch la refuse — expirée, elle faisait
    /// échouer toute la requête, et les bandeaux disparaissaient.
    private func publicQuery(_ op: String, variables: [String: Any], sha256: String) async -> [String: Any]? {
        if !tokenRefused, let tok = token, !tok.isEmpty {
            if let res = await TwitchGQL.shared.query(op, variables: variables, sha256: sha256, token: tok),
               res["data"] is [String: Any] { return res }
            tokenRefused = true
            logger.warn("EVENTS", "Session web refusée pour les événements : lecture sans elle", op)
        }
        return await TwitchGQL.shared.query(op, variables: variables, sha256: sha256, token: nil)
    }

    private func fetchAll() async {
        await fetchStreak()
        await fetchPoll()
        await fetchPrediction()
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
        guard let res   = await publicQuery("ChannelPollContext_GetViewablePoll",
                                            variables: ["login": login], sha256: H.poll),
              let data  = res["data"]    as? [String: Any],
              let chan  = data["channel"] as? [String: Any] else { return }
        guard let p = chan["viewablePoll"] as? [String: Any] else {
            if poll != nil { logger.debug("EVENTS", "Sondage terminé", nil) }
            poll = nil; votedChoiceIds = []; return
        }
        logger.debug("EVENTS", "Sondage brut", "\(p.keys.sorted())")
        let title = p["title"] as? String ?? ""   // vide : « Sondage » traduit par la vue
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
        if let d = f.date(from: s) ?? ISO8601DateFormatter().date(from: s) { return d }
        // 8 ou 9 décimales (hype train) : on ne garde que les millisecondes.
        guard let dot = s.firstIndex(of: "."),
              let end = s[dot...].firstIndex(where: { $0 != "." && !$0.isNumber }) else { return nil }
        let millis = String(s[s.index(after: dot)..<end].prefix(3))
        return f.date(from: String(s[..<dot]) + "." + millis + String(s[end...]))
    }

    // MARK: Prédiction
    private func fetchPrediction() async {
        guard let res   = await publicQuery("ChannelPointsPredictionContext",
                                            variables: ["count": 1, "channelLogin": login],
                                            sha256: H.prediction),
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
                    // Ton pari gagnant : ce gain n'est pas compté dans les
                    // points gagnés en regardant (Réglages → Points de chaîne).
                    if prev.myOutcomeId == winner, prev.myPoints > 0,
                       let won = prev.outcomes.first(where: { $0.id == winner }), let r = prev.ratio(won.points) {
                        PointsTracker.shared.expectPayout(Int(Double(prev.myPoints) * r), login)
                    }
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
        let title = ev["title"] as? String ?? ""   // vide : « Prédiction » traduit par la vue
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
        // Plus grosse mise de chaque issue (« topPredictors » de Twitch).
        for o in ev["outcomes"] as? [[String: Any]] ?? [] {
            guard let id = o["id"] as? String,
                  let best = (o["topPredictors"] as? [[String: Any]])?.compactMap({ $0["points"] as? Int }).max(),
                  best > 0 else { continue }
            newPred?.topBets[id] = best
        }
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

    // MARK: Hype train : approche, départ, niveaux, fin
    /// Requête en clair, SANS jeton : la lecture est publique, et un jeton
    /// web invalide la faisait échouer (401) en figeant le bandeau. Environ
    /// 1 Ko au lieu de 24 pour la requête persistée, avec `remainingSeconds`.
    private static let hypeQuery = "query($l: String!) { user(login: $l) { channel { hypeTrain { "
        + "approaching { id goal participants expiresAt eventsRemaining { events secondsRemaining } isGoldenKappaTrain isTreasureTrain } "
        + "execution { id expiresAt endedAt isGoldenKappaTrain isTreasureTrain "
        + "progress { goal progression total remainingSeconds level { value goal } } } } } } }"

    private func startHypeLoop() {
        stopHype()
        hypeLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard let wait = await self?.hypeTick() else { return }
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
    }

    /// Un relevé, puis le délai avant le suivant : 5 s pendant une approche
    /// (5 min au plus) pour voir le départ, 15 s sinon.
    private func hypeTick() async -> TimeInterval {
        await fetchHype()
        return hype?.phase == .approaching ? 5 : 15
    }

    private func stopHype() {
        hypeLoop?.cancel(); hypeLoop = nil
        hypeDeadlineTask?.cancel(); hypeDeadlineTask = nil
        hypeFlashTask?.cancel(); hypeFlashTask = nil
        hypeGen += 1
        hypeSeq = 0; hypeApplied = 0
        hypeRead = false
        hype = nil
    }

    private func fetchHype() async {
        let gen = hypeGen
        hypeSeq += 1
        let seq = hypeSeq
        // Lecture ratée : rien ne change, rien n'est déduit.
        guard let d    = await rawGQL(Self.hypeQuery),
              let user = d["user"]       as? [String: Any],
              let chan = user["channel"] as? [String: Any],
              let ht   = chan["hypeTrain"] as? [String: Any],
              gen == hypeGen, seq > hypeApplied else { return }
        hypeApplied = seq
        let now = Date()
        applyHype(readHype(ht, now: now), now: now)
    }

    /// État affiché selon les règles de Twitch : le train s'il n'est pas fini
    /// et que son échéance est future, sinon l'approche si la sienne l'est.
    /// Les secondes restantes passent avant les dates (8 ou 9 décimales,
    /// heure de l'appareil décalée).
    private func readHype(_ ht: [String: Any], now: Date) -> LiveHype? {
        if let exec = ht["execution"] as? [String: Any], exec["endedAt"] as? String == nil {
            let progress = exec["progress"] as? [String: Any]
            let lvl   = progress?["level"] as? [String: Any]
            let level = lvl?["value"] as? Int ?? 1
            let goal  = progress?["goal"] as? Int ?? 0
            // `total` et `level.goal` sont cumulés sur tous les niveaux, `goal`
            // ne vaut que pour le niveau en cours : total/goal affichait 100 %
            // dès le niveau 2. `progression` est l'avancée dans le niveau.
            var done = progress?["progression"] as? Int
            if done == nil, let total = progress?["total"] as? Int, let all = lvl?["goal"] as? Int {
                done = total - (all - goal)
            }
            let ends = Self.number(progress?["remainingSeconds"]).map { now.addingTimeInterval($0) }
                    ?? (exec["expiresAt"] as? String).flatMap(isoDate)
            if ends.map({ $0 > now }) ?? true {
                return LiveHype(id: exec["id"] as? String ?? "", phase: .running,
                                variant: Self.hypeVariant(exec), level: level,
                                percent: goal > 0 ? min(1, max(0, Double(done ?? 0) / Double(goal))) : 0,
                                endsAt: ends)
            }
        }
        if let ap = ht["approaching"] as? [String: Any] {
            let goal = ap["goal"] as? Int ?? 0
            let big = goal > 5
            let steps = ap["eventsRemaining"] as? [[String: Any]] ?? []
            let joined = (ap["participants"] as? [Any])?.count ?? 0
            let fewest = steps.compactMap { $0["events"] as? Int }.filter { $0 > 0 }.min()
            // Échéance : celle de la dernière pastille (2e pour un objectif > 5).
            let step = steps.first { $0["events"] as? Int == (big ? 2 : 1) }
                    ?? steps.first { $0["events"] as? Int == fewest }
            let ends = Self.number(step?["secondsRemaining"]).map { now.addingTimeInterval($0) }
                    ?? (ap["expiresAt"] as? String).flatMap(isoDate)
            if ends.map({ $0 > now }) ?? true {
                return LiveHype(id: ap["id"] as? String ?? "", phase: .approaching,
                                variant: Self.hypeVariant(ap), left: fewest ?? max(1, goal - joined),
                                bigGoal: big, endsAt: ends)
            }
        }
        return nil
    }

    /// Transitions, comparées au relevé précédent de la même chaîne :
    /// départ (après l'approche ou direct), niveau terminé, fin.
    private func applyHype(_ read: LiveHype?, now: Date) {
        defer { scheduleHypeDeadline() }
        let prev = hype
        // Premier relevé : l'état tel quel, sans transition.
        guard hypeRead else {
            hypeRead = true
            if let read { logger.success("EVENTS", "🚄 Hype train", Self.describe(read)) }
            setHype(read)
            return
        }
        guard var next = read else {
            guard let prev else { return }
            if case .ended = prev.flash { return }       // écran de fin déjà affiché
            // Disparu à son échéance après le niveau 1 : terminé (COMPLETED).
            // Sinon (expiré au niveau 1, fin du live…), Twitch n'affiche rien.
            if prev.phase == .running, prev.level >= 2, let ends = prev.endsAt,
               now >= ends.addingTimeInterval(-3) {
                var done = prev
                done.endsAt = nil
                // Le même pourcentage que la barre qu'on vient de voir.
                done.flash = .ended(level: prev.level, percent: Int(prev.percent * 100))
                done.flashUntil = now.addingTimeInterval(15)
                logger.success("EVENTS", "🚄 Hype train terminé", "niveau \(prev.level)")
                setHype(done)
            } else {
                logger.debug("EVENTS", prev.phase == .approaching ? "Hype train : approche expirée"
                                                                  : "Hype train terminé", nil)
                setHype(nil)
            }
            return
        }
        if next.phase == .running {
            if let prev, prev.phase == .running, prev.id == next.id {
                let up = next.level > prev.level
                if up { logger.success("EVENTS", "🚄 Hype train", "niveau \(next.level)") }
                if case .ended = prev.flash {
                    // Relu après un faux départ de fin : il roule encore.
                    if up { next.flash = .levelDone(prev.level); next.flashUntil = now.addingTimeInterval(4) }
                } else if let f = prev.flash, (prev.flashUntil ?? .distantPast) > now {
                    if up, case .levelDone = f {
                        // Encore un niveau pendant « niveau terminé » : le dernier.
                        next.flash = .levelDone(prev.level)
                        next.flashUntil = now.addingTimeInterval(4)
                    } else {
                        // Départ en cours : le niveau terminé attend la fin de « parti ».
                        next.flash = f
                        next.flashUntil = prev.flashUntil
                        next.pendingLevelDone = up ? prev.level : prev.pendingLevelDone
                        if f == .kickoff { next.bigGoal = prev.bigGoal }
                    }
                } else if let n = up ? Optional(prev.level) : prev.pendingLevelDone {
                    // (« parti » échu juste avant sa minuterie : son niveau en attente.)
                    next.flash = .levelDone(n)
                    next.flashUntil = now.addingTimeInterval(4)
                }
            } else {
                // Départ : la dernière pastille se coche après une approche ;
                // sans approche vue (6 départs sur 9), carte « parti » d'emblée.
                let fromApproach = prev?.phase == .approaching
                next.flash = fromApproach ? .kickoff : .departed
                next.flashUntil = now.addingTimeInterval(fromApproach ? 1.5 : 10)
                if fromApproach, let prev { next.bigGoal = prev.bigGoal }
                logger.success("EVENTS", "🚄 Hype train parti", Self.describe(next))
            }
        } else if prev?.phase != .approaching || prev?.id != next.id {
            logger.success("EVENTS", "🚄 Hype train", Self.describe(next))
        }
        setHype(next)
    }

    /// Publie l'état et programme la fin du message court en cours.
    private func setHype(_ h: LiveHype?) {
        hype = h
        hypeFlashTask?.cancel(); hypeFlashTask = nil
        guard let h, h.flash != nil, let until = h.flashUntil else { return }
        let gen = hypeGen
        let delay = max(0, until.timeIntervalSinceNow)
        hypeFlashTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, gen == self.hypeGen else { return }
            self.endHypeFlash()
        }
    }

    private func endHypeFlash() {
        guard var h = hype, let f = h.flash else { return }
        switch f {
        case .kickoff:
            h.flash = .departed
            h.flashUntil = Date().addingTimeInterval(10)
            setHype(h)
        case .ended:
            setHype(nil)
        case .departed where h.pendingLevelDone != nil:
            h.flash = .levelDone(h.pendingLevelDone ?? h.level)
            h.flashUntil = Date().addingTimeInterval(4)
            h.pendingLevelDone = nil
            setHype(h)
        case .departed, .levelDone:
            h.flash = nil
            h.flashUntil = nil
            setHype(h)
        }
    }

    /// Relecture juste après l'échéance, au lieu d'effacer à l'aveugle : un
    /// niveau monté (+5 min) ou un départ entre deux relevés la repousse.
    private func scheduleHypeDeadline() {
        hypeDeadlineTask?.cancel(); hypeDeadlineTask = nil
        guard hypeEnabled, let ends = hype?.endsAt else { return }
        let gen = hypeGen
        let delay = max(0, ends.timeIntervalSinceNow) + 1
        hypeDeadlineTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, gen == self.hypeGen else { return }
            await self.fetchHype()
        }
    }

    private static func hypeVariant(_ d: [String: Any]) -> LiveHype.Variant {
        if d["isGoldenKappaTrain"] as? Bool == true { return .golden }
        if d["isTreasureTrain"] as? Bool == true { return .treasure }
        return .regular
    }

    private static func number(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }

    private static func describe(_ h: LiveHype) -> String {
        h.phase == .approaching ? "en approche, encore \(h.left)" : "niveau \(h.level) · \(Int(h.percent * 100)) %"
    }
}

// MARK: – Bandeau des événements live
struct LiveEventsBanner: View {
    @ObservedObject var events: LiveEventsService
    /// Solde et session web : pour parier sur les prédictions.
    @ObservedObject var points: ChannelPointsService
    /// Bandeaux fermés (×), par clé d'événement (`noticeKey`) : un nouveau
    /// sondage ou une nouvelle prédiction a une autre clé et réapparaît.
    var closed: Set<String> = []
    var onClose: (String) -> Void = { _ in }
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(spacing: 0) {
            // Chacun masquable à part (Réglages → Personnaliser).
            if store.showPolls, let poll = events.poll, !closed.contains(poll.noticeKey) {
                banner(icon: "chart.bar.fill", tint: .tPrimary, onClose: { onClose(poll.noticeKey) }) {
                    PollCard(poll: poll, events: events)
                }
            }
            if store.showPredictions, let pred = events.prediction, !closed.contains(pred.noticeKey) {
                banner(icon: "sparkles", tint: .tPurple, onClose: { onClose(pred.noticeKey) }) {
                    PredictionCard(pred: pred, events: events, points: points)
                }
            }
            if store.showHypeTrain, let hype = events.hype, !closed.contains(hype.noticeKey) {
                banner(icon: "tram.fill", tint: .tLive, onClose: { onClose(hype.noticeKey) }) {
                    HypeTrainCard(hype: hype)
                }
            }
        }
    }

    @ViewBuilder
    private func banner<Content: View>(icon: String, tint: Color, onClose: @escaping () -> Void,
                                       @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).font(.system(size: 12)).foregroundColor(tint).padding(.top, 2)
            content()
            Spacer(minLength: 0)
            // × comme celui des drops : le bandeau se range dans la pastille
            // groupée de la barre de statut (ou du repli en paysage).
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold)).foregroundColor(.tMuted)
                    .frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(store.t("close"))
            // Zone de toucher pleine, sans grandir un bandeau d'une ligne.
            .padding(.vertical, -5)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(tint.opacity(0.10))
        .overlay(Divider().background(Color.tBorder), alignment: .bottom)
    }
}

// MARK: – Sondage : barres et vote
/// Les choix se touchent pour voter. Terminé (Twitch le renvoie encore 1 à
/// 3 min), il se replie sur son titre et le choix gagnant ; un toucher
/// montre toutes les barres.
private struct PollCard: View {
    let poll: LiveEventsService.LivePoll
    @ObservedObject var events: LiveEventsService
    @EnvironmentObject private var store: AppStore
    @State private var showResults = false

    private var folded: Bool { !poll.isActive && !showResults }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if poll.isActive {
                header
            } else {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { showResults.toggle() }
                } label: {
                    header.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if folded {
                if let w = poll.choices.first(where: { $0.id == poll.winnerId }) {
                    HStack(spacing: 4) {
                        Image(systemName: "trophy.fill")
                            .font(.system(size: 10)).foregroundColor(.tWarning)
                        Text("\(w.title) · \(Int(Double(w.votes) / Double(poll.total) * 100))%")
                            .font(.system(size: 11, weight: .semibold)).foregroundColor(.tText)
                            .lineLimit(1)
                    }
                }
            } else {
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
                let votes = poll.choices.reduce(0) { $0 + $1.votes }
                Text("\(votes) \(store.tn("poll_votes", votes))")
                    .font(.system(size: 10)).foregroundColor(.tMuted)
                if poll.isActive, let e = events.voteError {
                    Text(store.t(e == "NO_SESSION" ? "pred_need_login" : "poll_vote_failed"))
                        .font(.system(size: 10)).foregroundColor(.tDanger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        // Sondage suivant : replié d'office à son tour quand il se termine.
        .onChange(of: poll.id) { _ in showResults = false }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("📊 \(poll.title.isEmpty ? store.t("poll_default_title") : poll.title)")
                .font(.system(size: 12, weight: .bold)).foregroundColor(.tText)
            Spacer(minLength: 4)
            // Une seule lecture de l'heure : entre deux, la fin pourrait
            // passer et l'intervalle s'inverser.
            let now = Date()
            if !poll.isActive {
                Text(store.t("poll_results"))
                    .font(.system(size: 10, weight: .bold)).foregroundColor(.tMuted)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.tSurface).cornerRadius(5)
                Image(systemName: "chevron.down")
                    .rotationEffect(.degrees(showResults ? 180 : 0))
                    .font(.system(size: 10, weight: .bold)).foregroundColor(.tMuted)
            } else if let endsAt = poll.endsAt, endsAt > now {
                HStack(spacing: 3) {
                    Image(systemName: "clock.fill").font(.system(size: 9))
                    Text(timerInterval: now...endsAt, countsDown: true)
                        .font(.system(size: 11, weight: .bold).monospacedDigit())
                }
                .foregroundColor(.tPrimary)
            }
        }
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
    /// Barres d'une prédiction verrouillée, dépliées d'un toucher.
    @State private var showBars = false

    /// Règles de Twitch : 10 points au moins, 250 000 au plus par prédiction.
    private static let minBet = 10
    private static let maxTotal = 250_000

    private var open: Bool {
        !pred.locked && pred.winnerId == nil && (pred.closesAt.map { $0 > Date() } ?? true)
    }
    private var needsSession: Bool { store.twitchWebToken == nil || points.needsWebLogin }
    /// Mise possible : le solde, sans dépasser le plafond (paris déjà faits compris).
    private var maxBet: Int { max(0, min(points.balance, Self.maxTotal - pred.myPoints)) }
    /// Verrouillée, en attente du résultat (souvent 10 à 60 min) : plus de
    /// pari, les montants ne bougent plus. C'est l'état le plus courant.
    private var awaitingResult: Bool { pred.locked && pred.winnerId == nil }
    /// Repliée d'office sur son titre, « Paris fermés » et ton pari.
    private var folded: Bool { awaitingResult && !showBars }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if awaitingResult {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { showBars.toggle() }
                } label: {
                    header.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                header
            }
            if !folded {
                ForEach(Array(pred.outcomes.enumerated()), id: \.offset) { _, o in
                    outcomeRow(o)
                }
            }
            if let mine = myOutcome {
                // Gain possible si l'issue gagne : la mise × la cote (mise comprise).
                let win = pred.winnerId == nil ? pred.ratio(mine.points).map { Int((Double(pred.myPoints) * $0).rounded(.down)) } : nil
                Text(store.tn("pred_my_bet", pred.myPoints)
                        .replacingOccurrences(of: "{n}", with: points.formatted(pred.myPoints))
                        .replacingOccurrences(of: "{o}", with: mine.title)
                     + (win.map { " · " + store.tn("pred_potential", $0).replacingOccurrences(of: "{n}", with: points.formatted($0)) } ?? ""))
                    .font(.system(size: 10, weight: .semibold)).foregroundColor(.tSuccess)
            }
            if open {
                if needsSession {
                    // Sans compte Twitch : la prédiction se suit, sans rappel.
                    if !store.accountHidden {
                        Text(store.t("pred_need_login"))
                            .font(.system(size: 10)).foregroundColor(.tMuted)
                    }
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
            showBars = false
            events.betError = nil
        }
    }

    private var myOutcome: Outcome? {
        guard pred.myPoints > 0, let id = pred.myOutcomeId else { return nil }
        return pred.outcomes.first { $0.id == id }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("🔮 \(pred.title.isEmpty ? store.t("pred_default_title") : pred.title)\(pred.locked && pred.winnerId == nil ? " 🔒" : "")")
                .font(.system(size: 12, weight: .bold)).foregroundColor(.tText)
            Spacer(minLength: 4)
            // Une seule lecture de l'heure : entre deux, la fin pourrait
            // passer et l'intervalle s'inverser.
            let now = Date()
            if let closes = pred.closesAt, closes > now {
                HStack(spacing: 3) {
                    Image(systemName: "clock.fill").font(.system(size: 9))
                    Text(timerInterval: now...closes, countsDown: true)
                        .font(.system(size: 11, weight: .bold).monospacedDigit())
                }
                .foregroundColor(.tPurple)
            } else if pred.winnerId != nil {
                Text(store.t("pred_result"))
                    .font(.system(size: 10, weight: .bold)).foregroundColor(.tSuccess)
            } else if awaitingResult {
                Text(store.t("pred_closed"))
                    .font(.system(size: 10, weight: .bold)).foregroundColor(.tMuted)
                    .lineLimit(1).fixedSize()
                Image(systemName: "chevron.down")
                    .rotationEffect(.degrees(showBars ? 180 : 0))
                    .font(.system(size: 10, weight: .bold)).foregroundColor(.tMuted)
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
        let tint = pred.winnerId == nil || pred.winnerId == o.id ? Self.color(o.color) : Color.tMuted
        let stats = outcomeStats(o)
        Button {
            events.betError = nil
            withAnimation(.easeInOut(duration: 0.15)) { selected = selected == o.id ? nil : o.id }
        } label: {
            EventBar(label: o.title, value: o.points, total: pred.total, color: tint,
                     voted: mine, winner: pred.winnerId == o.id,
                     selected: tappable && selected == o.id, stats: stats)
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

    /// Sous la barre d'une issue, comme l'app Twitch : points misés, cote,
    /// votants et plus grosse mise (quand Twitch l'envoie).
    private func outcomeStats(_ o: Outcome) -> [(icon: String, text: String)] {
        var stats: [(icon: String, text: String)] = [("circle.circle", Self.compact(o.points))]
        if let r = pred.ratio(o.points) { stats.append(("trophy", "1:" + Self.ratioText(r))) }
        stats.append(("person.2", "\(o.users)"))
        if let top = pred.topBets[o.id] { stats.append(("crown", Self.compact(top))) }
        return stats
    }

    /// Comme Twitch : 950, 27.4K, 1.2M (une décimale, retirée si elle vaut 0).
    private static func compact(_ v: Int) -> String {
        func one(_ x: Double, _ unit: String) -> String {
            let t = (x * 10).rounded(.down) / 10
            return (t == t.rounded() ? String(Int(t)) : String(format: "%.1f", t)) + unit
        }
        if v >= 1_000_000 { return one(Double(v) / 1_000_000, "M") }
        if v >= 1_000 { return one(Double(v) / 1_000, "K") }
        return "\(v)"
    }

    /// Cote : deux décimales au plus (1.71, 2.4, 3).
    private static func ratioText(_ r: Double) -> String {
        var s = String(format: "%.2f", r)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

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
    /// Prédiction : chiffres sous la barre (points misés, cote, votants,
    /// plus grosse mise), comme dans l'app Twitch.
    var stats: [(icon: String, text: String)] = []

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
            if !stats.isEmpty {
                HStack(spacing: 10) {
                    ForEach(stats.indices, id: \.self) { i in
                        HStack(spacing: 3) {
                            Image(systemName: stats[i].icon).font(.system(size: 9, weight: .semibold))
                            Text(stats[i].text).font(.system(size: 10, weight: .semibold).monospacedDigit())
                        }
                    }
                }
                .foregroundColor(color)
                .lineLimit(1)
                .padding(.top, 2)
            }
        }
        .contentShape(Rectangle())
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(color, lineWidth: selected ? 1.5 : 0)
                .padding(-4)
        )
    }
}
