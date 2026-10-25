import Foundation
import Combine
import SwiftUI

@MainActor
final class ChatService: NSObject, ObservableObject {

    @Published var messages: [ChatMessage] = []
    @Published var isConnected     = false
    @Published var isAuthenticated = false
    @Published var channelId: String? = nil

    private var webSocketTask: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .default)
    private(set) var channelName = ""
    /// Modes du salon qui limitent qui peut écrire (abonnés, followers…) :
    /// les réglages du chat (GQL), puis le ROOMSTATE au fil du direct.
    @Published private(set) var roomModes = ChatRoomModes()
    /// Règles du chat de la chaîne, à accepter avant le premier message.
    @Published private(set) var rules: [String] = []
    private var pingTimer: Timer?
    private var connectionTimeoutTask: Task<Void, Never>?
    private let maxMessages = 200
    private let maxMessagesPaused = 600   // plafond dur quand la purge est en pause (lecture)
    /// Quand true (utilisateur remonté pour lire l'historique), on ne purge pas les
    /// plus anciens messages : ça éviterait de faire « descendre » la vue pendant la lecture.
    var pauseTrim = false

    /// Chat du lecteur principal : les messages reçus attendent que l'image les
    /// rejoigne (ChatSync). Faux en multi-live. Réglés par ChatView, avec
    /// l'interrupteur et la retouche des réglages.
    var syncsWithPlayer = false
    var syncEnabled = true
    var syncNudge: Double = 0

    /// Message reçu en attente du retard du chat, avec son heure d'arrivée.
    private struct PendingMessage {
        let message: ChatMessage
        let arrivedAt: Date
    }
    /// File d'attente, dans l'ordre d'arrivée. Jamais nos messages, ni les
    /// lignes de l'app (⚠️) : affichés tout de suite.
    private var pending: [PendingMessage] = []
    /// Au-delà (chat très rapide retardé d'une minute), les plus anciens
    /// sortent en avance, à la sortie suivante (0,15 s). Jetés, ils laissaient
    /// en tête de file des messages jamais échus : plus rien ne s'affichait.
    private let maxPending = 1500
    /// Sortie de la file au fil du temps ; nil quand elle est vide (une file
    /// vide ne fait tourner aucun minuteur).
    private var releaseTask: Task<Void, Never>?
    /// Retard appliqué à la file (lissé), sa dernière mise à jour, et la
    /// vitesse du rattrapage en cours (s regagnées par seconde ; 0 : aucun).
    private var appliedDelay: Double = 0
    private var appliedAt = Date.distantPast
    private var catchUpRate: Double = 0
    /// Une baisse du retard se rattrape en `catchUpTime` s environ, et jamais
    /// à moins de `minCatchUpRate` s par seconde.
    private static let catchUpTime: Double = 4
    private static let minCatchUpRate: Double = 2

    /// Incrémenté à chaque (re)connexion : les tâches d'une session précédente
    /// (lecture, délai, reconnexion) s'arrêtent.
    private var generation = 0
    /// Messages en attente du délai de synchro : abandonnés seulement si la
    /// chaîne change (ou si on quitte le chat). Une reconnexion à la même
    /// chaîne (réseau coupé) jetait jusqu'à 15 s de chat déjà reçu.
    private var publishGeneration = 0

    /// Identifiants de la dernière connexion, pour la reconnexion automatique.
    private var lastToken: String?
    private var lastLogin: String?
    /// Attente avant la prochaine reconnexion automatique (recul progressif).
    private var reconnectDelay: Double = 2
    private var reconnectTask: Task<Void, Never>?
    /// Échecs d'affilée (délai dépassé, connexion perdue) depuis le dernier
    /// « 001 » : au troisième, on le dit dans le chat au lieu de rester muet.
    private var failures = 0

    /// Lecture seule : Twitch refuse le compte dans ce salon (NOTICE
    /// `msg_banned` au JOIN), le chat continue sans compte. Rien ne s'envoie.
    @Published private(set) var readOnly = false
    /// Couples « compte#chaîne » refusés pendant cette séance : rouvrir le
    /// chat (multi-live, mini-lecteur, retour) repart directement sans compte.
    private static var readOnlyKeys = Set<String>()
    /// Dernière reconnexion sur un PART ou un CLEARCHAT à notre nom : une
    /// seule par 15 s, si Twitch en renvoyait en boucle.
    private var lastRejoin: Date?

    /// Garder à l'écran les messages supprimés par la modération, barrés, au
    /// lieu de les faire disparaître. Piloté par les réglages.
    var keepDeleted = false
    /// Charger au démarrage les derniers messages du canal (API tierce).
    var loadRecent = false

    /// Personnes présentes dans le chat, tenues à jour depuis l'IRC.
    ///
    /// C'est la seule source qui reste : l'endpoint tmi.twitch.tv des chatters
    /// est fermé, la requête GQL exige un jeton d'intégrité signé, et Helix
    /// impose d'être modérateur du canal. Twitch n'envoie NAMES/JOIN/PART que
    /// pour les canaux de taille modeste — d'où `presenceSupported`.
    @Published private(set) var presentUsers: Set<String> = []
    /// Twitch a-t-il envoyé au moins une liste de noms pour ce canal ?
    @Published private(set) var presenceSupported = false

    private func trimIfNeeded() {
        let cap = pauseTrim ? maxMessagesPaused : maxMessages
        if messages.count > cap { messages = Array(messages.prefix(cap)) }
    }

    /// Insère un message reçu, tout de suite ou une fois rejoint par l'image.
    private func publish(_ message: ChatMessage) {
        let now = Date()
        // Sans retard et rien en attente : affiché tout de suite. Sinon il
        // passe par la file, derrière ceux qui y sont déjà.
        guard currentDelay(now) >= 0.5 || !pending.isEmpty else { insert(message); return }
        pending.append(PendingMessage(message: message, arrivedAt: now))
        startRelease()
    }

    /// Retard voulu : celui de l'image (ChatSync), moins la marge de réaction,
    /// plus la retouche ; 0 si la synchro est coupée ou le retard inconnu.
    private func syncTarget(_ now: Date) -> Double {
        guard syncsWithPlayer, syncEnabled,
              let player = ChatSync.shared.playerDelay(at: now) else { return 0 }
        return ChatSync.chatDelay(player: player, nudge: syncNudge)
    }

    /// Retard appliqué à la file. Une hausse (calage, recul) est suivie tout de
    /// suite : les messages attendent un peu plus, rien ne bouge à l'écran.
    /// Une baisse (« Direct », glissé, rattrapage, synchro coupée) l'est en
    /// quelques secondes : les messages en attente sortent dans l'ordre, en
    /// accéléré, sans tout lâcher d'un coup. File vide : rien à lisser.
    private func currentDelay(_ now: Date) -> Double {
        let target = syncTarget(now)
        let elapsed = min(max(0, now.timeIntervalSince(appliedAt)), 1)
        appliedAt = now
        if pending.isEmpty || target >= appliedDelay {
            appliedDelay = target
            catchUpRate = 0
        } else {
            // Vitesse fixée au début du rattrapage : régulier plutôt qu'une
            // rafale au départ. Une nouvelle baisse en route l'accélère.
            catchUpRate = max(catchUpRate, Self.minCatchUpRate, (appliedDelay - target) / Self.catchUpTime)
            appliedDelay = max(target, appliedDelay - catchUpRate * elapsed)
        }
        return appliedDelay
    }

    /// Fait sortir la file au fil du temps, et s'arrête dès qu'elle est vide.
    private func startRelease() {
        guard releaseTask == nil, !pending.isEmpty else { return }
        let gen = publishGeneration
        releaseTask = Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard let self, !Task.isCancelled, self.publishGeneration == gen else { return }
                self.releaseDue()
                guard !self.pending.isEmpty else { self.releaseTask = nil; return }
            }
        }
    }

    /// Rend, dans leur ordre d'arrivée, les messages dont l'heure est venue :
    /// arrivée + retard appliqué. File trop longue : les plus anciens aussi,
    /// en avance (voir `maxPending`).
    private func releaseDue() {
        let now = Date()
        let horizon = now.addingTimeInterval(-currentDelay(now))
        let ripe = pending.firstIndex(where: { $0.arrivedAt > horizon }) ?? pending.count
        let count = max(ripe, pending.count - maxPending)
        guard count > 0 else { return }
        let due = pending.prefix(count).map(\.message)
        pending.removeFirst(count)
        insert(due)
    }

    /// Modération arrivée pendant que des messages attendaient le délai de
    /// synchro (jusqu'à 60 s) : appliquée à leur affichage. Sans elle, un spam
    /// supprimé 2 s après son envoi s'affichait intact 8 s plus tard.
    private var deletedIds: [String: Date] = [:]
    private var bannedUsers: [String: Date] = [:]
    private var purgedAt: Date? = nil

    /// Retenu au-delà du plus long délai de synchro, puis oublié.
    private static func rememberModeration(_ store: inout [String: Date], _ key: String) {
        let now = Date()
        store = store.filter { now.timeIntervalSince($0.value) < 90 }
        store[key] = now
    }

    private func insert(_ message: ChatMessage) { insert([message]) }

    /// Ajoute des messages en tête de liste (le plus récent en premier), en un
    /// seul changement : une seule mise à jour de l'affichage, même quand la
    /// file de la synchro en rend une rafale.
    private func insert(_ batch: [ChatMessage]) {
        var list = messages
        var added = false
        for var message in batch {
            // Déjà affiché (historique rejoué, puis le même message sorti de la
            // file de synchro) : pas deux fois.
            guard !list.prefix(300).contains(where: { $0.id == message.id }) else { continue }
            if let purgedAt, message.timestamp <= purgedAt { continue }
            if deletedIds[message.id] != nil
                || bannedUsers[message.userName].map({ message.timestamp <= $0 }) == true {
                guard keepDeleted else { continue }
                message.isDeleted = true
            }
            // Toujours en tête : la file rend les messages dans leur ordre
            // d'arrivée. Sorti après un message à nous (jamais retardé), un
            // message s'affiche dessous, quand l'image le rejoint ; rangé à son
            // heure d'envoi, il se glissait au-dessus, hors de vue.
            list.insert(message, at: 0)
            added = true
        }
        guard added else { return }
        // Plafond appliqué avant la publication : une seule copie de la liste
        // et une seule mise à jour de l'affichage par lot (trimIfNeeded en
        // refaisait une à chaque message, une fois la liste pleine).
        let cap = pauseTrim ? maxMessagesPaused : maxMessages
        if list.count > cap { list.removeLast(list.count - cap) }
        messages = list
    }

    // Infos du compte connecté (GLOBALUSERSTATE / USERSTATE)
    private var localLogin       = ""
    private var localDisplayName = ""
    private var localColor       = Color(hex: "9146ff")
    private var localBadges: [TwitchBadge] = []

    // MARK: – Connect
    func connect(channel: String, token: String? = nil, login: String? = nil) {
        // Même chaîne (reconnexion, autre compte) : les messages encore en
        // attente du délai et la modération retenue restent.
        disconnect(keepPending: channel.lowercased() == channelName)
        channelName = channel.lowercased()
        lastToken = token
        lastLogin = login
        // Remis à jour à chaque connexion : autre chaîne ou autre compte,
        // l'état d'avant ne vaut plus.
        prepare(channel: channelName, login: login)
        let asAccount = !readOnly
        roomModes = ChatRoomModes()
        rules = []
        let name = channelName
        Task { await loadChatSettings(name) }
        logger.info("CHAT", "Connexion IRC → #\(channelName)", readOnly ? "lecture seule (compte refusé)" : nil)

        guard let url = URL(string: "wss://irc-ws.chat.twitch.tv:443") else { return }
        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()

        connectionTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let self, !Task.isCancelled, !self.isConnected else { return }
            logger.warn("CHAT", "Timeout IRC (10 s)", "nouvel essai")
            // Réseau lent ou coupé : nouvel essai avec le même compte. Seul un
            // refus de Twitch (NOTICE « Login authentication failed ») fait
            // passer en anonyme — le délai le faisait en silence, et le compte
            // restait perdu jusqu'à la réouverture du chat.
            self.connectionTimeoutTask = nil
            self.webSocketTask?.cancel(with: .goingAway, reason: nil)
            self.webSocketTask = nil
            self.scheduleReconnect(gen: self.generation, reason: "pas de réponse de l'IRC en 10 s")
        }

        Task {
            await send("CAP REQ :twitch.tv/tags twitch.tv/commands twitch.tv/membership")
            if asAccount, let token = token, let login = login, !login.isEmpty,
               token.allSatisfy({ $0.isLetter || $0.isNumber }),
               login.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                await send("PASS oauth:\(token)")
                await send("NICK \(login.lowercased())")
                isAuthenticated = true
                localLogin = login.lowercased()
                logger.info("CHAT", "Auth IRC → \(login.lowercased())")
            } else {
                await send("NICK justinfan\(Int.random(in: 10000...99999))")
                isAuthenticated = false
            }
            await send("JOIN #\(channelName)")
            await receive()
        }

        // En parallèle de la connexion : l'historique n'a pas à attendre l'IRC,
        // et l'IRC n'a pas à attendre un service tiers.
        if loadRecent {
            let chan = channelName   // figé ici : une reconnexion le changerait
            Task { [weak self] in await self?.loadRecentMessages(channel: chan) }
        }

        pingTimer = Timer.scheduledCommon(every: 240) { [weak self] _ in
            Task { await self?.send("PING :tmi.twitch.tv") }
        }
    }

    /// Relance la connexion IRC sans quitter le direct (menu du chat).
    func reconnect(token: String?, login: String?) {
        guard !channelName.isEmpty else { return }
        logger.info("CHAT", "Reconnexion demandée → #\(channelName)")
        // Nouvel essai voulu : une nouvelle série d'échecs sera signalée.
        failures = 0
        reconnectDelay = 2
        // Retente avec le compte (bouton du bandeau, menu du chat) : débanni,
        // il repasse ; sinon le refus de Twitch remet la lecture seule.
        if let key = Self.readOnlyKey(channelName, login) { Self.readOnlyKeys.remove(key) }
        connect(channel: channelName, token: token, login: login)
    }

    /// Avant `connect` (le chat attend d'abord emotes et badges, jusqu'à
    /// 3,5 s) : un salon déjà refusé à ce compte montre le bandeau tout de
    /// suite au lieu du champ « Connecting… ».
    func prepare(channel: String, login: String?) {
        readOnly = Self.readOnlyKey(channel, login).map { Self.readOnlyKeys.contains($0) } ?? false
    }

    /// Clé de la mémoire de séance ; nil sans compte.
    private static func readOnlyKey(_ channel: String, _ login: String?) -> String? {
        guard let login, !login.isEmpty, !channel.isEmpty else { return nil }
        return "\(login.lowercased())#\(channel.lowercased())"
    }

    /// Twitch refuse le compte (banni) : on rouvre le salon sans lui, comme
    /// un spectateur déconnecté. Par `connect` et non `reconnectAnonymously` :
    /// nouvelle génération, présence et infos du compte remises à zéro.
    private func enterReadOnly() {
        guard !readOnly else { return }
        readOnly = true
        if let key = Self.readOnlyKey(channelName, lastLogin ?? localLogin) { Self.readOnlyKeys.insert(key) }
        insertSystemMessage(translate("chat_ban_switched", lang))
        logger.warn("CHAT", "Compte refusé dans #\(channelName) (banni)", "lecture seule, sans compte")
        connect(channel: channelName, token: lastToken, login: lastLogin ?? localLogin)
    }

    /// PART ou CLEARCHAT sans durée à notre nom : signal ambigu (ban, coupure,
    /// chat partagé). On rejoint avec le compte ; si le ban est réel, le
    /// `msg_banned` du JOIN fera passer en lecture seule.
    private func rejoinWithAccount(_ reason: String) {
        if let last = lastRejoin, Date().timeIntervalSince(last) < 15 {
            // Pas ignoré : un vrai ban peut suivre de près un premier signal
            // (chat partagé). Reporté à la fin de la fenêtre, une fois ; toute
            // reconnexion d'ici là (nouvelle génération) l'annule.
            guard reconnectTask == nil else { return }
            let wait = 15 - Date().timeIntervalSince(last)
            let gen = generation
            logger.info("CHAT", "\(reason) à notre nom", "reconnexion récente, reportée de \(Int(wait.rounded(.up))) s")
            reconnectTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(wait, 0) * 1_000_000_000))
                guard let self, !Task.isCancelled, self.generation == gen, !self.readOnly else { return }
                self.reconnectTask = nil
                self.rejoinWithAccount(reason)
            }
            return
        }
        lastRejoin = Date()
        logger.warn("CHAT", "\(reason) à notre nom → #\(channelName)", "reconnexion avec le compte")
        connect(channel: channelName, token: lastToken, login: lastLogin)
    }

    /// Langue de l'app, pour les lignes écrites par l'app dans le chat.
    private var lang: Lang {
        Lang(rawValue: UserDefaults.standard.string(forKey: "lang") ?? "en") ?? .en
    }

    /// Envoie une commande de chat telle quelle (/color, /me…).
    func sendCommand(_ command: String) async {
        guard isAuthenticated, isConnected, !channelName.isEmpty else { return }
        await send("PRIVMSG #\(channelName) :\(command)")
        logger.info("CHAT", "Commande envoyée", command)
    }

    // MARK: – Disconnect
    /// `keepPending` : reconnexion à la même chaîne — les messages en attente
    /// du délai de synchro (et la modération à leur appliquer) sont gardés.
    func disconnect(keepPending: Bool = false) {
        generation &+= 1
        if !keepPending {
            publishGeneration &+= 1   // abandonne les messages encore en attente de synchro
            pending.removeAll()
            releaseTask?.cancel(); releaseTask = nil
            deletedIds = [:]; bannedUsers = [:]; purgedAt = nil
        }
        reconnectTask?.cancel(); reconnectTask = nil
        presentUsers.removeAll()
        presenceSupported = false
        connectionTimeoutTask?.cancel(); connectionTimeoutTask = nil
        pingTimer?.invalidate(); pingTimer = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil); webSocketTask = nil
        isConnected = false; isAuthenticated = false
        localLogin = ""; localDisplayName = ""; localBadges = []
        logger.info("CHAT", "IRC déconnecté")
    }

    // MARK: – Fallback anonyme
    private func reconnectAnonymously() async {
        connectionTimeoutTask?.cancel(); connectionTimeoutTask = nil
        pingTimer?.invalidate(); pingTimer = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil); webSocketTask = nil
        isAuthenticated = false

        guard !channelName.isEmpty,
              let url = URL(string: "wss://irc-ws.chat.twitch.tv:443") else { return }
        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()
        // Même délai qu'à la connexion : sans lui, une connexion anonyme muette
        // laissait le chat sur « Connecting… » pour de bon.
        let gen = generation
        let task = webSocketTask
        connectionTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let self, !Task.isCancelled, !self.isConnected,
                  self.generation == gen, self.webSocketTask === task else { return }
            logger.warn("CHAT", "Timeout IRC anonyme (10 s)", "nouvel essai")
            self.webSocketTask?.cancel(with: .goingAway, reason: nil)
            self.webSocketTask = nil
            self.scheduleReconnect(gen: gen, reason: "connexion anonyme muette (10 s)")
        }
        await send("CAP REQ :twitch.tv/tags twitch.tv/commands twitch.tv/membership")
        await send("NICK justinfan\(Int.random(in: 10000...99999))")
        await send("JOIN #\(channelName)")
        pingTimer = Timer.scheduledCommon(every: 240) { [weak self] _ in
            Task { await self?.send("PING :tmi.twitch.tv") }
        }
        await receive()
    }

    // MARK: – Send message
    /// false si rien n'est parti (vide, plus de 500 caractères, chat pas
    /// connecté avec un compte) : l'appelant le dit au lieu de tout perdre.
    @discardableResult
    func sendMessage(_ text: String,
                     replyParentId: String? = nil,
                     replyRootId: String? = nil,
                     replyToName: String? = nil) async -> Bool {
        let sanitized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty, sanitized.count <= 500,
              isAuthenticated, isConnected else {
            logger.warn("CHAT", "Message non envoyé", sanitized.count > 500 ? "plus de 500 caractères" : "chat pas connecté avec un compte")
            return false
        }

        // Identifiant venu des balises IRC : vérifié, un retour à la ligne y
        // ajouterait une commande IRC.
        if let pid = replyParentId,
           pid.allSatisfy({ $0.isHexDigit || $0 == "-" }) {
            await send("@reply-parent-msg-id=\(pid) PRIVMSG #\(channelName) :\(sanitized)")
        } else {
            await send("PRIVMSG #\(channelName) :\(sanitized)")
        }
        logger.info("CHAT", "Message envoyé → #\(channelName)", String(sanitized.prefix(80)))

        // Écho : « /me texte » s'affiche comme une action, sans « /me » ; les
        // autres commandes (« /w », « /ban »…) n'en ont pas — ce ne sont pas
        // des messages, Twitch les exécute ou les refuse.
        let isMe = sanitized.lowercased().hasPrefix("/me ")
        if sanitized.hasPrefix("/"), !isMe { return true }
        let shownText = isMe ? String(sanitized.dropFirst(4)) : sanitized
        var tokens = await tokenizeText(shownText, channelId: channelId)
        // Emotes Twitch de notre propre message : l'écho n'a pas de balises,
        // elles s'affichaient en texte (« Kappa » choisi dans les suggestions).
        for i in tokens.indices {
            if case .text(let word) = tokens[i], let e = await EmoteService.shared.twitchEmote(named: word) {
                tokens[i] = .emote(e)
            }
        }
        let localMsg = ChatMessage(
            id: "local-\(UUID().uuidString)",
            userId: localLogin, userName: localLogin,
            displayName: localDisplayName.isEmpty ? localLogin : localDisplayName,
            color: localColor, badges: localBadges, tokens: tokens,
            timestamp: Date(), isAction: isMe, isHighlight: false,
            isFirstMessage: false,
            replyTo: replyToName, replyBody: nil,
            systemMsg: nil,
            parentMsgId: replyParentId,
            threadRootId: replyRootId ?? replyParentId
        )
        // Message envoyé par nous : affiché tout de suite, jamais retardé.
        insert(localMsg)
        return true
    }

    // MARK: – Fil de discussion (thread)
    /// Messages appartenant au fil dont la racine est `rootId`, du plus ancien au plus récent.
    func threadMessages(rootId: String) -> [ChatMessage] {
        messages
            .filter { $0.id == rootId || $0.threadRootId == rootId }
            .sorted { $0.timestamp < $1.timestamp }
    }

    /// Tout ce qu'une personne a écrit dans ce qu'on a en mémoire, du plus
    /// ancien au plus récent : ouvrir un message sert surtout à voir le fil de
    /// ce qu'elle raconte, pas ce seul message hors contexte.
    func messagesFrom(userName: String, limit: Int = 30) -> [ChatMessage] {
        let key = userName.lowercased()
        guard !key.isEmpty else { return [] }
        return messages
            .filter { $0.userName.lowercased() == key }
            .sorted { $0.timestamp < $1.timestamp }
            .suffix(limit)
            .map { $0 }
    }

    // MARK: – Send raw IRC
    private func send(_ text: String) async {
        guard let task = webSocketTask else { return }
        do { try await task.send(.string(text + "\r\n")) }
        catch { logger.warn("CHAT", "Erreur envoi IRC", error.localizedDescription) }
    }

    // MARK: – Receive loop
    // Boucle (et non plus récursion, qui gardait une trame par message reçu)
    // liée à SA connexion : si la connexion est remplacée (fallback anonyme,
    // reconnexion), l'ancienne boucle s'arrête au lieu de lire la nouvelle.
    private func receive() async {
        guard let task = webSocketTask else { return }
        let gen = generation
        while webSocketTask === task {
            do {
                let msg = try await task.receive()
                guard webSocketTask === task else { return }
                switch msg {
                case .string(let text):  await handleRaw(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) { await handleRaw(text) }
                @unknown default: break
                }
            } catch {
                guard webSocketTask === task, generation == gen else { return }
                logger.error("CHAT", "Connexion IRC perdue", error.localizedDescription)
                isConnected = false
                scheduleReconnect(gen: gen, reason: error.localizedDescription)
                return
            }
        }
    }

    /// Reconnexion automatique après une coupure (réseau, serveur), avec un
    /// recul progressif plafonné à 30 s.
    private func scheduleReconnect(gen: Int, reason: String) {
        guard !channelName.isEmpty else { return }
        countFailure(reason)
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 30)
        // Le compte est toujours gardé : une coupure de quelques secondes
        // (ascenseur, passage Wi-Fi/4G) le faisait oublier au troisième échec,
        // et le chat restait anonyme. Un vrai refus passe par le NOTICE.
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, self.generation == gen else { return }
            logger.info("CHAT", "Reconnexion automatique → #\(self.channelName)")
            self.connect(channel: self.channelName, token: self.lastToken, login: self.lastLogin)
        }
    }

    /// Un échec de plus ; au troisième d'affilée, une ligne dans le chat
    /// (VPN, réseau filtré…) qui renvoie à « Reconnecter le chat ».
    private func countFailure(_ reason: String) {
        failures += 1
        logger.warn("CHAT", "Échec de connexion n°\(failures) → #\(channelName)", reason)
        guard failures == 3 else { return }
        insertSystemMessage(translate("chat_unreachable", lang))
    }

    // MARK: – Handle raw IRC lines
    private func handleRaw(_ text: String) async {
        let lines = text.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        let gen = generation
        for line in lines {
            // Connexion remplacée en cours de trame (lecture seule, reconnexion) :
            // la suite appartient à l'ancienne socket, on ne la traite pas.
            guard generation == gen else { break }
            guard let irc = IRCParser.parse(line) else { continue }
            switch irc.command {
            case "001":
                isConnected = true
                connectionTimeoutTask?.cancel(); connectionTimeoutTask = nil
                reconnectDelay = 2
                failures = 0
                logger.success("CHAT", "IRC connecté à #\(channelName)")
            case "PING":
                await send("PONG :tmi.twitch.tv")
            case "PRIVMSG":
                await handlePrivmsg(irc)
            case "USERNOTICE":
                await handleUsernotice(irc)
            case "GLOBALUSERSTATE":
                handleUserInfo(irc)
            case "USERSTATE":
                handleUserInfo(irc)
                if let raw = irc.tags["badges"] {
                    // ← badges résolu via BadgeService (URLs Helix réelles)
                    localBadges = await parseBadges(raw, channelId: channelId)
                }
            case "353":
                // RPL_NAMREPLY : liste des présents, envoyée à l'arrivée.
                // Format : <nous> = #canal :nom1 nom2 nom3…
                // Le pseudo et le canal occupent params[0...2] : la liste est le
                // dernier paramètre, pas `text` (qui vaudrait « = » ici).
                if irc.params.count >= 4, let names = irc.params.last {
                    let logins = names.split(separator: " ").map { $0.lowercased() }
                    presentUsers.formUnion(logins)
                    presenceSupported = true
                }
            case "366":
                // RPL_ENDOFNAMES : Twitch a fini d'envoyer la liste (même vide).
                presenceSupported = true
            case "JOIN":
                if let who = irc.tags["login"] ?? irc.prefixNick { presentUsers.insert(who.lowercased()) }
            case "PART":
                if let who = (irc.tags["login"] ?? irc.prefixNick)?.lowercased() {
                    // Twitch nous sort du salon (ban en plein direct, ou coupure) :
                    // on y retourne avec le compte, le JOIN dira s'il est banni.
                    // En lecture seule, `localLogin` est vide : rien à faire.
                    if who == localLogin, !localLogin.isEmpty, isAuthenticated, !readOnly {
                        rejoinWithAccount("PART")
                    } else {
                        presentUsers.remove(who)
                    }
                }
            case "ROOMSTATE":
                applyRoomState(irc.tags)
            case "NOTICE":
                await handleNotice(irc)
            case "CLEARCHAT":
                await handleClearChat(irc)
            case "CLEARMSG":
                await handleClearMsg(irc)
            default: break
            }
        }
    }

    // MARK: – Mise à jour des infos locales
    private func handleUserInfo(_ irc: IRCMessage) {
        if let name = irc.tags["display-name"], !name.isEmpty { localDisplayName = name }
        if let hex  = irc.tags["color"], !hex.isEmpty {
            localColor = Color.readableChat(hex: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")))
        }
        // Jeux d'emotes du compte (abonnements, Turbo…) : le sélecteur les
        // montre dans « Mes emotes » et grise les emotes d'abonné de la chaîne
        // qui n'en font pas partie.
        if let raw = irc.tags["emote-sets"], !raw.isEmpty, !localLogin.isEmpty {
            let sets = Set(raw.split(separator: ",").map(String.init))
            let login = localLogin
            Task { await EmoteService.shared.setUserEmoteSets(sets, login: login) }
        }
    }

    // MARK: – PRIVMSG → ChatMessage
    private func handlePrivmsg(_ irc: IRCMessage) async {
        guard let message = await buildMessage(irc, historical: false) else { return }
        publish(message)
    }

    /// Analyse commune au direct et à l'historique rejoué : même format IRC,
    /// donc même chemin — seule l'heure diffère (tag `tmi-sent-ts` pour le
    /// rejeu, l'heure d'arrivée pour le direct, sur laquelle repose la synchro).
    private func buildMessage(_ irc: IRCMessage, historical: Bool) async -> ChatMessage? {
        guard var text = irc.text else { return nil }

        var isAction = false
        if text.hasPrefix("\u{0001}ACTION ") && text.hasSuffix("\u{0001}") {
            text = String(text.dropFirst(8).dropLast(1))
            isAction = true
        }

        let hexColor = irc.color.isEmpty
            ? "9146ff"
            : irc.color.trimmingCharacters(in: CharacterSet(charactersIn: "#"))

        let emoteRanges = IRCParser.parseEmoteRanges(raw: irc.emotesRaw, text: text)
        var twitchEmotesByRange: [Range<String.Index>: TwitchEmote] = [:]
        for (emoteId, range) in emoteRanges {
            let emoteName = String(text[range])
            let emote = TwitchEmote(
                id: emoteId, name: emoteName,
                url: "https://static-cdn.jtvnw.net/emoticons/v2/\(emoteId)/default/dark/2.0",
                source: .twitch
            )
            await EmoteService.shared.registerTwitchEmote(id: emoteId, name: emoteName)
            twitchEmotesByRange[range] = emote
        }

        // GIF du clavier GIF de Twitch : son texte (« [… GIF by …] ») laisse
        // la place à l'image.
        var gifsByRange: [Range<String.Index>: String] = [:]
        for g in IRCParser.parseGifRanges(raw: irc.gifsRaw, text: text) { gifsByRange[g.range] = g.url }

        let tokens = await tokenize(text: text, twitchRanges: twitchEmotesByRange, gifs: gifsByRange,
                                    channelId: channelId, userId: irc.userId)

        // Le rejeu n'a pas de tag `login` fiable : on retombe sur le préfixe IRC.
        let login = irc.tags["login"] ?? irc.prefixNick ?? ""
        let sentAt: Date = {
            guard historical, let ms = irc.tags["tmi-sent-ts"], let n = Double(ms) else {
                return Date()
            }
            return Date(timeIntervalSince1970: n / 1000)
        }()

        return ChatMessage(
            id: irc.msgId,
            userId: irc.userId,
            userName: login,
            displayName: irc.displayName.isEmpty ? login : irc.displayName,
            color: Color.readableChat(hex: hexColor),
            // ← badges résolus via BadgeService
            badges: await parseBadges(irc.badgesRaw, channelId: channelId),
            tokens: tokens,
            timestamp: sentAt,
            isAction: isAction,
            isHighlight: irc.tags["msg-id"] == "highlighted-message",
            isFirstMessage: irc.tags["first-msg"] == "1",
            replyTo: irc.replyUser,
            replyBody: irc.replyParentBody,
            systemMsg: nil,
            parentMsgId: irc.replyParentMsgId,
            threadRootId: irc.replyThreadRootId,
            isHistorical: historical
        )
    }

    // MARK: – USERNOTICE (abonnements, séries de visionnage, raids…)
    private func handleUsernotice(_ irc: IRCMessage) async {
        guard let message = await buildNotice(irc, historical: false) else { return }
        publish(message)
        logger.debug("CHAT", "USERNOTICE \(irc.tags["msg-id"] ?? "")", message.systemMsg ?? "")
    }

    /// Message d'un USERNOTICE, partagé par le direct et l'historique.
    private func buildNotice(_ irc: IRCMessage, historical: Bool) async -> ChatMessage? {
        let kind = irc.tags["msg-id"] ?? ""
        let systemMsg = kind == "announcement" ? "" : ircUnescape(irc.tags["system-msg"] ?? "")

        // Message écrit par l'utilisateur (resub avec texte), optionnel.
        var tokens: [MessageToken] = []
        if let text = irc.text, !text.isEmpty {
            let emoteRanges = IRCParser.parseEmoteRanges(raw: irc.emotesRaw, text: text)
            var byRange: [Range<String.Index>: TwitchEmote] = [:]
            for (emoteId, range) in emoteRanges {
                let name = String(text[range])
                byRange[range] = TwitchEmote(
                    id: emoteId, name: name,
                    url: "https://static-cdn.jtvnw.net/emoticons/v2/\(emoteId)/default/dark/2.0",
                    source: .twitch)
                await EmoteService.shared.registerTwitchEmote(id: emoteId, name: name)
            }
            tokens = await tokenize(text: text, twitchRanges: byRange, channelId: channelId,
                                    userId: irc.userId)
        }

        guard !systemMsg.isEmpty || !tokens.isEmpty else { return nil }

        let hexColor = irc.color.isEmpty
            ? "9146ff"
            : irc.color.trimmingCharacters(in: CharacterSet(charactersIn: "#"))

        let sentAt: Date = {
            guard historical, let ms = irc.tags["tmi-sent-ts"], let n = Double(ms) else { return Date() }
            return Date(timeIntervalSince1970: n / 1000)
        }()
        let raiderLogin = (irc.tags["msg-param-login"] ?? "").lowercased()
        let accents: [String: String] = ["PRIMARY": "9146ff", "BLUE": "387aff", "GREEN": "00c853",
                                         "ORANGE": "ff9a00", "PURPLE": "bf94ff"]

        var message = ChatMessage(
            id: irc.msgId,
            userId: irc.userId,
            userName: irc.tags["login"] ?? "",
            displayName: irc.displayName,
            color: Color.readableChat(hex: hexColor),
            badges: await parseBadges(irc.badgesRaw, channelId: channelId),
            tokens: tokens,
            timestamp: sentAt,
            isAction: false,
            isHighlight: kind != "raid",
            isFirstMessage: false,
            replyTo: nil, replyBody: nil,
            systemMsg: systemMsg.isEmpty ? nil : systemMsg
        )
        message.isHistorical = historical
        message.noticeKind = kind.isEmpty ? nil : kind
        if kind == "raid", raiderLogin.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }), !raiderLogin.isEmpty {
            message.raider = raiderLogin
        }
        if kind == "announcement" {
            message.accent = Color(hex: accents[irc.tags["msg-param-color"] ?? ""] ?? "9146ff")
        }
        return message
    }

    // MARK: – Badge parsing (async → BadgeService)
    /// Résout chaque badge via BadgeService pour obtenir l'URL Helix réelle.
    /// Fallback automatique vers CDN statique si les badges ne sont pas encore chargés.
    private func parseBadges(_ raw: String, channelId: String?) async -> [TwitchBadge] {
        guard !raw.isEmpty else { return [] }
        var result: [TwitchBadge] = []
        for part in raw.components(separatedBy: ",") {
            let kv = part.components(separatedBy: "/")
            guard kv.count == 2 else { continue }
            let id  = "\(kv[0])/\(kv[1])"
            let url = await BadgeService.shared.resolve(badgeId: id, channelId: channelId)
            guard !url.isEmpty else { continue }
            result.append(TwitchBadge(id: id, url: url))
        }
        return result
    }

    // MARK: – NOTICE
    private func handleNotice(_ irc: IRCMessage) async {
        guard let text = irc.text else { return }
        let msgId = irc.tags["msg-id"] ?? ""

        if msgId == "login_authentication_failed"
            || text.lowercased().contains("login authentication failed") {
            logger.warn("CHAT", "Auth IRC rejetée", "Passage en mode anonyme")
            isAuthenticated = false
            // Dit d'abord, dans la langue de l'app : la reconnexion anonyme ne
            // rend la main qu'à sa fermeture (elle lit sa connexion), le
            // message n'arrivait qu'à la fin. Lancée à part, sans l'attendre :
            // la boucle de lecture d'ici s'arrête (connexion remplacée).
            insertSystemMessage(translate("chat_auth_failed", lang))
            Task { [weak self] in await self?.reconnectAnonymously() }
            return
        }

        // Compte banni de ce salon : Twitch le refuse au JOIN (et à l'envoi).
        // Pas un message refusé : le chat continue en lecture seule, sans compte.
        if msgId == "msg_banned" {
            guard isAuthenticated, !readOnly else { return }
            removeRecentEcho()
            enterReadOnly()
            return
        }

        // Message refusé par Twitch (mode abonnés, followers, lent…) : la
        // raison dans la langue de l'app, et le message, affiché d'avance
        // comme envoyé, retiré — sinon on croyait qu'il était passé.
        if let key = Self.rejectionKeys[msgId] ?? (msgId.hasPrefix("msg_") ? "chat_rej_generic" : nil) {
            logger.warn("CHAT", "Message refusé : \(msgId)", text)
            removeRecentEcho()
            let minutes = roomModes.followersMinutes ?? 0
            insertSystemMessage(translate(key, lang)
                .replacingOccurrences(of: "{d}", with: minutes > 0 ? ChatRoomModes.duration(minutes, lang: lang) : "")
                .replacingOccurrences(of: "{t}", with: text))
            return
        }
        let chatErrorIds: Set<String> = ["no_permission", "unrecognized_cmd"]
        if chatErrorIds.contains(msgId) {
            logger.warn("CHAT", "NOTICE \(msgId)", text)
            insertSystemMessage(text)
        }
    }

    /// Refus de Twitch (msg-id du NOTICE) → texte traduit.
    private static let rejectionKeys: [String: String] = [
        "msg_followersonly": "chat_rej_followers", "msg_followersonly_zero": "chat_rej_followers",
        "msg_followersonly_followed": "chat_rej_followers_time",
        "msg_subsonly": "chat_rej_subs", "msg_emoteonly": "chat_rej_emotes", "msg_emotesonly": "chat_rej_emotes",
        "msg_slowmode": "chat_rej_slow", "msg_r9k": "chat_rej_unique", "msg_duplicate": "chat_rej_duplicate",
        "msg_verified_email": "chat_rej_verified", "msg_requires_verified_phone_number": "chat_rej_verified",
        "msg_timedout": "chat_rej_timeout",
        "msg_rejected": "chat_rej_automod", "msg_rejected_mandatory": "chat_rej_automod",
        "msg_ratelimit": "chat_rej_ratelimit", "msg_channel_suspended": "chat_rej_suspended",
        "msg_suspended": "chat_rej_suspended",
    ]

    // MARK: – Modes du salon et règles
    /// ROOMSTATE : complet à l'arrivée, puis seulement ce qui change.
    private func applyRoomState(_ tags: [String: String]) {
        var m = roomModes
        if let v = tags["followers-only"], let n = Int(v) { m.followersMinutes = n < 0 ? nil : n }
        if let v = tags["subs-only"] { m.subsOnly = v == "1" }
        if let v = tags["emote-only"] { m.emoteOnly = v == "1" }
        if let v = tags["slow"], let n = Int(v) { m.slowSeconds = n }
        if let v = tags["r9k"] { m.uniqueChat = v == "1" }
        roomModes = m
    }

    /// Règles et modes du chat (GQL public, sans compte).
    private func loadChatSettings(_ login: String) async {
        let q = "query { user(login: \"\(gqlStr(login))\") { chatSettings { rules followersOnlyDurationMinutes isSubscribersOnlyModeEnabled isEmoteOnlyModeEnabled slowModeDurationSeconds requireVerifiedAccount isUniqueChatModeEnabled } } }"
        guard let user = (await VodChatService.rawGQL(q)?["data"] as? [String: Any])?["user"] as? [String: Any],
              let cs = user["chatSettings"] as? [String: Any], login == channelName else { return }
        rules = (cs["rules"] as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var m = roomModes
        m.followersMinutes = cs["followersOnlyDurationMinutes"] as? Int
        m.subsOnly = cs["isSubscribersOnlyModeEnabled"] as? Bool ?? false
        m.emoteOnly = cs["isEmoteOnlyModeEnabled"] as? Bool ?? false
        m.slowSeconds = cs["slowModeDurationSeconds"] as? Int ?? 0
        m.uniqueChat = cs["isUniqueChatModeEnabled"] as? Bool ?? false
        m.verifiedOnly = cs["requireVerifiedAccount"] as? Bool ?? false
        roomModes = m
    }

    /// Retire notre dernier message, affiché d'avance comme envoyé, quand
    /// Twitch le refuse dans la foulée.
    private func removeRecentEcho() {
        if let i = messages.firstIndex(where: { $0.id.hasPrefix("local-") }),
           Date().timeIntervalSince(messages[i].timestamp) < 20 {
            messages.remove(at: i)
        }
    }

    private func insertSystemMessage(_ text: String) {
        messages.insert(ChatMessage(
            id: UUID().uuidString,
            userId: "system", userName: "system",
            displayName: "⚠️ " + translate("chat_system", lang),
            color: Color(hex: "fbbf24"), badges: [],
            tokens: [.text(text)], timestamp: Date(),
            isAction: false, isHighlight: false,
            isFirstMessage: false, replyTo: nil, replyBody: nil
        ), at: 0)
    }

    // MARK: – Tokenizer
    private func tokenize(
        text: String,
        twitchRanges: [Range<String.Index>: TwitchEmote],
        gifs: [Range<String.Index>: String] = [:],
        channelId: String?,
        userId: String? = nil
    ) async -> [MessageToken] {
        var tokens: [MessageToken] = []
        var currentIndex = text.startIndex
        let sortedRanges = (Array(twitchRanges.keys) + Array(gifs.keys)).sorted { $0.lowerBound < $1.lowerBound }

        for range in sortedRanges {
            guard range.lowerBound >= currentIndex else { continue }
            if range.lowerBound > currentIndex {
                tokens += await tokenizeText(String(text[currentIndex..<range.lowerBound]),
                                             channelId: channelId, userId: userId)
            }
            if let url = gifs[range] {
                tokens.append(.gif(url: url, alt: String(text[range])))
            } else if let emote = twitchRanges[range] {
                tokens.append(.emote(emote))
            }
            currentIndex = range.upperBound
        }
        if currentIndex < text.endIndex {
            tokens += await tokenizeText(String(text[currentIndex...]), channelId: channelId, userId: userId)
        }
        return tokens
    }

    private func tokenizeText(_ segment: String, channelId: String?, userId: String? = nil) async -> [MessageToken] {
        await tokenizeChatSegment(segment, channelId: channelId, userId: userId)
    }

    // MARK: – Moderation
    private func handleClearChat(_ irc: IRCMessage) async {
        if let target = irc.params.last, !target.hasPrefix("#") {
            // Exclusion / bannissement : tous les messages de la personne
            // (ceux encore retenus par le délai de synchro compris).
            mark(where: { $0.userName == target })
            Self.rememberModeration(&bannedUsers, target)
            // Nous visés, avec le compte (en lecture seule `localLogin` est
            // vide : les exclusions des autres ne nous concernent pas).
            guard target.lowercased() == localLogin, !localLogin.isEmpty,
                  isAuthenticated, !readOnly else { return }
            if let seconds = irc.tags["ban-duration"].flatMap({ Int($0) }) {
                // Exclusion temporaire : on reste dans le salon, Twitch
                // refusera les messages d'ici là (`msg_timedout`).
                logger.warn("CHAT", "Exclu de #\(channelName)", "\(seconds) s")
                insertSystemMessage(translate("chat_timed_out", lang)
                    .replacingOccurrences(of: "{d}", with: Self.duration(seconds: seconds, lang: lang)))
            } else {
                rejoinWithAccount("CLEARCHAT")
            }
        } else {
            // Purge complète du canal : même avec le réglage, garder l'écran
            // barré de bout en bout n'aurait aucun intérêt. Les messages qui
            // attendaient l'image partent avec.
            messages.removeAll()
            pending.removeAll()
            purgedAt = Date()
            logger.warn("CHAT", "Chat effacé par un modérateur")
        }
    }

    /// « 45 s », « 10 min », « 2 h 30 min », « 14 j » : `ban-duration` est en
    /// secondes et va jusqu'à deux semaines (ChatRoomModes.duration prend des minutes).
    private static func duration(seconds: Int, lang: Lang) -> String {
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        f.allowedUnits = seconds >= 86_400 ? [.day, .hour]
            : seconds >= 3_600 ? [.hour, .minute]
            : seconds >= 60 ? [.minute, .second] : [.second]
        f.maximumUnitCount = 2
        var calendar = Calendar.current
        calendar.locale = Locale(identifier: lang.rawValue)
        f.calendar = calendar
        return f.string(from: TimeInterval(seconds)) ?? "\(seconds) s"
    }

    private func handleClearMsg(_ irc: IRCMessage) async {
        guard let targetId = irc.tags["target-msg-id"] else { return }
        mark(where: { $0.id == targetId })
        Self.rememberModeration(&deletedIds, targetId)
    }

    /// Retire les messages visés, ou les barre si le réglage le demande.
    private func mark(where predicate: (ChatMessage) -> Bool) {
        guard keepDeleted else {
            messages.removeAll(where: predicate)
            return
        }
        for i in messages.indices where predicate(messages[i]) {
            messages[i].isDeleted = true
        }
    }

    // MARK: – Messages récents (avant notre arrivée)
    /// Twitch n'envoie rien de ce qui précède le JOIN : on arrive dans un chat
    /// vide même en plein débat. recent-messages.robotty.de rejoue les dernières
    /// lignes IRC brutes, qu'on fait passer par le même analyseur que le direct.
    ///
    /// Service tiers, hors de notre contrôle : un échec est silencieux, le chat
    /// démarre simplement vide comme avant.
    private func loadRecentMessages(channel: String, limit: Int = 60) async {
        let gen = generation
        guard let url = URL(string:
            "https://recent-messages.robotty.de/api/v2/recent-messages/\(channel)?limit=\(limit)")
        else { return }

        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw  = json["messages"] as? [String] else {
            logger.warn("CHAT", "Historique du chat indisponible", channel)
            return
        }

        var older: [ChatMessage] = []
        for line in raw {
            guard let irc = IRCParser.parse(line) else { continue }
            switch irc.command {
            case "PRIVMSG":
                guard var msg = await buildMessage(irc, historical: true) else { continue }
                // Supprimé depuis par la modération (signalé par le service).
                if irc.tags["rm-deleted"] == "1" {
                    guard keepDeleted else { continue }
                    msg.isDeleted = true
                }
                older.append(msg)
            case "USERNOTICE":
                if let msg = await buildNotice(irc, historical: true) { older.append(msg) }
            case "CLEARCHAT":
                // Banni ou exclu : ses messages déjà rejoués disparaissent aussi.
                guard let target = irc.text?.lowercased(), !target.isEmpty else { continue }
                if keepDeleted {
                    for i in older.indices where older[i].userName == target { older[i].isDeleted = true }
                } else {
                    older.removeAll { $0.userName == target }
                }
            case "CLEARMSG":
                guard let id = irc.tags["target-msg-id"] else { continue }
                if keepDeleted {
                    for i in older.indices where older[i].id == id { older[i].isDeleted = true }
                } else {
                    older.removeAll { $0.id == id }
                }
            default:
                continue
            }
        }
        // La connexion a pu changer de canal pendant le téléchargement.
        guard generation == gen, !older.isEmpty else { return }

        // La liste va du plus récent au plus ancien ; on fusionne puis on retrie
        // plutôt que d'insérer un par un, l'ordre d'arrivée n'étant pas garanti.
        let known = Set(messages.map(\.id))
        messages.append(contentsOf: older.filter { !known.contains($0.id) })
        messages.sort { $0.timestamp > $1.timestamp }
        trimIfNeeded()
        logger.success("CHAT", "Historique chargé", "\(older.count) messages")
    }
}
