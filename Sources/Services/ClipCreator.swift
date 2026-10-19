import Foundation

// MARK: – Créer un clip du direct
//
// Helix ne crée un clip (POST /helix/clips) qu'avec la portée `clips:edit`,
// que la connexion de l'app ne demande pas : il faudrait se reconnecter. On
// passe donc par la session web (cookie auth-token), comme les points et les
// pronostics : mutation GQL `createClip`, avec un jeton d'intégrité
// (TwitchGQL). Twitch ne publie pas de requête enregistrée pour elle : elle
// part écrite en toutes lettres, puis sous une forme réduite si Twitch ne
// reconnaît pas un de ses champs (API web non documentée).
//
// ⚠️ Non officiel / hors-ToS Twitch — usage perso.

/// Issue d'une demande de clip.
enum ClipOutcome: Equatable {
    case created(url: String)
    /// Session web absente, ou refusée par Twitch : la connecter.
    case needsSession
    /// La chaîne n'est plus en direct.
    case offline
    /// Clips coupés sur cette chaîne, ou réservés à certains spectateurs.
    case disabled
    /// Trop de clips d'affilée.
    case rateLimited
    /// Pas de réponse lisible de Twitch (réseau, jeton d'intégrité).
    case network
    /// Autre refus : son code, ou les messages de Twitch.
    case refused(String)
}

/// Clip en cours, affiché par la feuille du lecteur (ClipSheet). Gardé ici et
/// pas dans la feuille : fermée pendant la création, le clip part quand même,
/// et son issue est notée au journal.
@MainActor
final class ClipCreator: ObservableObject {
    static let shared = ClipCreator()
    private init() {}

    enum State: Equatable {
        case idle
        case working
        case finished(ClipOutcome)
    }

    @Published private(set) var state: State = .idle
    /// Chaîne et instant demandés : gardés pour « Réessayer » et pour la
    /// reprise après la connexion de la session web (même instant).
    private var login = ""
    private var moment = Date()
    private var work: Task<Void, Never>? = nil

    /// Nouveau clip du direct de `login`. `moment` : date de l'image affichée
    /// (horloge de l'appareil moins la latence du direct).
    func start(login: String, moment: Date, store: AppStore) {
        // Clip en cours (double appui pendant que le menu se ferme) : un seul.
        // Le second annulait le premier, peut-être déjà parti chez Twitch :
        // deux clips au lieu d'un.
        guard state != .working else { return }
        self.login = login.lowercased()
        self.moment = moment
        run(store: store)
    }

    /// Même chaîne, même instant : après une erreur, ou la session connectée.
    func retry(store: AppStore) {
        guard !login.isEmpty, state != .working else { return }
        run(store: store)
    }

    private func run(store: AppStore) {
        work?.cancel()
        guard let web = store.twitchWebToken, !web.isEmpty else {
            logger.info("CLIP", "Session web absente : connexion proposée", "@\(login)")
            state = .finished(.needsSession)
            return
        }
        state = .working
        let login = self.login, moment = self.moment
        work = Task {
            var outcome = await createLiveClip(login: login, moment: moment, webToken: web)
            // Rien de lisible : la session a peut-être été refusée (jeton
            // expiré). Vérifiée : effacée si Twitch la refuse, et la
            // connexion est proposée au lieu d'un « réessaie ».
            if outcome == .network, !Task.isCancelled {
                await store.validateWebSession()
                if store.twitchWebToken == nil { outcome = .needsSession }
            }
            guard !Task.isCancelled else { return }
            self.state = .finished(outcome)
        }
    }
}

/// Crée un clip du direct de `login` à l'instant `moment`, avec la session web.
@MainActor
func createLiveClip(login: String, moment: Date, webToken: String) async -> ClipOutcome {
    // Chaîne et diffusion en cours : l'instant se compte depuis son début.
    guard let live = await getLiveBroadcast(login: login) else {
        logger.warn("CLIP", "Direct illisible : pas de clip", "@\(login)")
        return .network
    }
    guard let broadcastId = live.broadcastId else {
        logger.warn("CLIP", "Chaîne hors ligne : pas de clip", "@\(login)")
        return .offline
    }
    guard let started = live.startedAt else {
        logger.warn("CLIP", "Début du direct inconnu : pas de clip", "@\(login)")
        return .refused("createdAt")
    }
    let offset = max(0, moment.timeIntervalSince(started)).rounded()
    logger.info("CLIP", "Création d'un clip…", "@\(login) · \(Int(offset)) s")
    // Forme complète d'abord (diffusion visée, code du refus), puis réduite si
    // Twitch ne reconnaît pas un de ses champs.
    let full: [String: Any] = ["broadcasterID": live.channelId, "broadcastID": broadcastId,
                               "offsetSeconds": offset]
    if let outcome = await sendCreateClip(query: clipQueryFull, input: full, token: webToken) {
        return outcome
    }
    logger.warn("CLIP", "Requête de clip non reconnue : forme réduite", nil)
    let bare: [String: Any] = ["broadcasterID": live.channelId, "offsetSeconds": offset]
    if let outcome = await sendCreateClip(query: clipQueryBare, input: bare, token: webToken) {
        return outcome
    }
    logger.error("CLIP", "Requête de clip refusée par Twitch", "forme réduite non reconnue")
    return .refused("schema")
}

private let clipQueryFull = """
mutation CreateClip($input: CreateClipInput!) {
  createClip(input: $input) { clip { slug } error { code } }
}
"""

private let clipQueryBare = """
mutation CreateClip($input: CreateClipInput!) {
  createClip(input: $input) { clip { slug } }
}
"""

/// Une tentative. nil : requête refusée avant d'être exécutée (champ ou
/// argument que Twitch ne connaît pas).
@MainActor
private func sendCreateClip(query: String, input: [String: Any], token: String) async -> ClipOutcome? {
    guard let res = await TwitchGQL.shared.rawMutation("CreateClip", query: query,
                                                       variables: ["input": input], token: token) else {
        logger.warn("CLIP", "Pas de réponse de Twitch", "réseau ou jeton d'intégrité")
        return .network
    }
    let payload = (res["data"] as? [String: Any])?["createClip"] as? [String: Any]
    if let slug = (payload?["clip"] as? [String: Any])?["slug"] as? String, !slug.isEmpty {
        let url = "https://clips.twitch.tv/\(slug)"
        logger.success("CLIP", "Clip créé ✓", url)
        return .created(url: url)
    }
    let code = (payload?["error"] as? [String: Any])?["code"] as? String ?? ""
    let messages = ((res["errors"] as? [[String: Any]]) ?? [])
        .compactMap { $0["message"] as? String }
        .joined(separator: " · ")
    if payload == nil, code.isEmpty, isSchemaError(messages) { return nil }
    logger.warn("CLIP", "Clip refusé", code.isEmpty ? (messages.isEmpty ? "réponse inattendue" : messages) : code)
    return clipOutcome(code: code, messages: messages)
}

/// Erreur de validation GraphQL : la requête n'a pas été exécutée.
private func isSchemaError(_ messages: String) -> Bool {
    let m = messages.lowercased()
    return ["cannot query field", "unknown field", "unknown argument", "is not defined",
            "invalid value", "unknown type", "expected type"].contains { m.contains($0) }
}

/// Refus de Twitch rangé par cause (codes de l'API web non documentés : on
/// lit des mots, pas une liste).
private func clipOutcome(code: String, messages: String) -> ClipOutcome {
    let text = (code + " " + messages).uppercased()
    func has(_ words: [String]) -> Bool { words.contains { text.contains($0) } }
    if has(["NOT_LIVE", "NOT LIVE", "OFFLINE", "NOT_BROADCASTING", "NO_BROADCAST", "BROADCAST_NOT_FOUND"]) {
        return .offline
    }
    if has(["RATE", "LIMIT", "THROTTL", "TOO_MANY", "TOO MANY"]) { return .rateLimited }
    if has(["DISABLED", "RESTRICT", "FORBIDDEN", "NOT_ALLOWED", "BANNED", "PERMISSION",
            "FOLLOW", "SUBSCRI", "INELIGIBLE"]) {
        return .disabled
    }
    return .refused(code.isEmpty ? messages : code)
}
