import SwiftUI
import UIKit
import CoreImage.CIFilterBuiltins

// ═══════════════════════════════════════════════════════════════════════════
//  Compte et réglages de l'app Apple TV.
//
//  Connexion par code (Device Code Flow de Twitch) : l'Apple TV affiche un
//  code et un QR code, on valide sur twitch.tv/activate depuis un téléphone.
//  Même client Twitch que l'app iPhone (kHelixClientID, client public : pas
//  de secret à garder) ; le jeton sert à Helix (chaînes suivies) comme là-bas.
// ═══════════════════════════════════════════════════════════════════════════

@MainActor
final class TVSession: ObservableObject {
    static let shared = TVSession()

    @Published private(set) var token: String?
    @Published private(set) var user: TwitchUser?
    @Published var lang: Lang {
        didSet { UserDefaults.standard.set(lang.rawValue, forKey: "lang") }
    }
    /// Source du direct préférée, lue aussi par getLive (même clé que l'iPhone).
    @Published var liveSource: String {
        didSet { UserDefaults.standard.set(liveSource, forKey: "liveSource") }
    }
    /// Chat affiché sur l'image par défaut (Compte, ou « Garder pour toutes
    /// les chaînes » dans le lecteur).
    @Published var tvChat: Bool {
        didSet { UserDefaults.standard.set(tvChat, forKey: "tv_chat") }
    }
    /// Chat affiché ou masqué dans le lecteur pour une chaîne (login →
    /// affiché) : prime sur le réglage par défaut — un streamer qui incruste
    /// déjà son chat n'a pas besoin du nôtre, les autres si. Disparaît quand
    /// il redevient égal au défaut.
    @Published private(set) var channelChatShown: [String: Bool] {
        didSet { UserDefaults.standard.set(channelChatShown, forKey: "tv_chat_shown") }
    }
    /// Place du chat par défaut (Compte, ou « Garder pour toutes les chaînes »
    /// dans le lecteur).
    @Published var chatLayout: TVChatLayout {
        didSet { UserDefaults.standard.set(chatLayout.raw, forKey: "tv_chat_layout") }
    }
    /// Place choisie dans le lecteur pour une chaîne (login → place) : elle
    /// prime sur celle par défaut, et disparaît quand elle lui redevient égale.
    @Published private(set) var channelChatLayouts: [String: String] {
        didSet { UserDefaults.standard.set(channelChatLayouts, forKey: "tv_chat_layouts") }
    }
    /// Qualité préférée (`kQualityPrefs`), même règle que l'iPhone : si elle
    /// manque, la plus proche en dessous. Choisir une qualité dans le lecteur
    /// la remplace.
    @Published var qualityPref: String {
        didSet { UserDefaults.standard.set(qualityPref, forKey: "tv_quality_pref") }
    }
    /// Chaînes et catégories masquées du top et des catégories, propres à
    /// cette Apple TV (même fichier partagé que l'iPhone, HiddenContent).
    @Published var hidden = HiddenContent.load() {
        didSet { if hidden != oldValue { hidden.save() } }
    }

    private static let scopes = "user:read:follows"
    private static let tokenKey = "tv_token"
    private static let refreshKey = "tv_refresh"

    private init() {
        let ud = UserDefaults.standard
        if let saved = ud.string(forKey: "lang"), let l = Lang(rawValue: saved) {
            lang = l
        } else {
            let code = String((Locale.preferredLanguages.first ?? "en").prefix(2)).lowercased()
            lang = Lang(rawValue: code) ?? .en
        }
        let source = ud.string(forKey: "liveSource") ?? "auto"
        liveSource = kLiveSourceChoices.contains(source) ? source : "auto"
        tvChat = ud.object(forKey: "tv_chat") as? Bool ?? true
        channelChatShown = ud.dictionary(forKey: "tv_chat_shown") as? [String: Bool] ?? [:]
        chatLayout = TVChatLayout(raw: ud.string(forKey: "tv_chat_layout") ?? "") ?? TVChatLayout()
        channelChatLayouts = ud.dictionary(forKey: "tv_chat_layouts") as? [String: String] ?? [:]
        // Avant : le nom exact de la dernière qualité choisie (« 720p60 »),
        // qui ne servait que s'il existait sur la chaîne suivante.
        if let pref = ud.string(forKey: "tv_quality_pref"), kQualityPrefs.contains(pref) {
            qualityPref = pref
        } else if let old = ud.string(forKey: "tv_quality"), !old.isEmpty {
            qualityPref = qualityPreference(for: old, among: []) ?? "source"
        } else {
            qualityPref = "source"
        }
        token = Keychain.loadToken(Self.tokenKey)
    }

    func t(_ key: String) -> String { tvTranslate(key, lang) }

    // MARK: Place du chat
    /// Place du chat pour une chaîne : la sienne si on l'a déplacé en la
    /// regardant, sinon celle par défaut.
    func chatLayout(for channel: String) -> TVChatLayout {
        channelChatLayouts[channel].flatMap(TVChatLayout.init(raw:)) ?? chatLayout
    }

    /// Place choisie dans le lecteur : retenue pour cette chaîne seulement.
    func setChatLayout(_ layout: TVChatLayout, for channel: String) {
        guard !channel.isEmpty else { return }
        var all = channelChatLayouts
        if layout == chatLayout {
            all.removeValue(forKey: channel)
        } else {
            all[channel] = layout.raw
            // tvOS limite le stockage local : 200 chaînes suffisent.
            if all.count > 200, let any = all.keys.first(where: { $0 != channel }) { all.removeValue(forKey: any) }
        }
        if all != channelChatLayouts { channelChatLayouts = all }
    }

    /// Chat affiché pour une chaîne : son choix dans le lecteur, sinon le défaut.
    func chatShown(for channel: String) -> Bool { channelChatShown[channel] ?? tvChat }

    /// « Afficher le chat » dans le lecteur : retenu pour cette chaîne seulement.
    func setChatShown(_ shown: Bool, for channel: String) {
        guard !channel.isEmpty else { return }
        var all = channelChatShown
        if shown == tvChat {
            all.removeValue(forKey: channel)
        } else {
            all[channel] = shown
            if all.count > 200, let any = all.keys.first(where: { $0 != channel }) { all.removeValue(forKey: any) }
        }
        if all != channelChatShown { channelChatShown = all }
    }

    /// Chaîne avec ses propres réglages du chat (place ou affichage).
    func hasOwnChatSettings(_ channel: String) -> Bool {
        channelChatLayouts[channel] != nil || channelChatShown[channel] != nil
    }

    /// Nombre de chaînes avec leurs propres réglages du chat.
    var channelsWithOwnChat: Int { Set(channelChatLayouts.keys).union(channelChatShown.keys).count }

    /// « Garder pour toutes les chaînes » : place et affichage du chat de
    /// cette chaîne deviennent ceux par défaut.
    func makeDefaultChatLayout(from channel: String) {
        let layout = chatLayout(for: channel)
        let shown = chatShown(for: channel)
        channelChatLayouts.removeValue(forKey: channel)
        channelChatShown.removeValue(forKey: channel)
        chatLayout = layout
        tvChat = shown
    }

    /// « Revenir au réglage par défaut » : place et affichage par défaut.
    func resetChatSettings(for channel: String) {
        channelChatLayouts.removeValue(forKey: channel)
        channelChatShown.removeValue(forKey: channel)
    }

    /// Compte : toutes les chaînes reprennent les réglages par défaut.
    func forgetChannelChatLayouts() {
        channelChatLayouts = [:]
        channelChatShown = [:]
    }

    // MARK: Session
    /// Vérification du lancement en cours : la vue racine et l'onglet Suivies
    /// la demandent ensemble (jusqu'à 3 fois) ; une seule part, les autres
    /// l'attendent.
    private var restoring: Task<Void, Never>?
    /// Renouvellement en cours, partagé de même. Chacun envoyait le même jeton
    /// de renouvellement : si Twitch le refuse une fois utilisé, le suivant
    /// recevait un refus, et la déconnexion effaçait le jeton tout juste
    /// renouvelé (Apple TV déconnectée au lancement).
    private var renewing: Task<Renewal, Never>?

    /// Au lancement : jeton vérifié, renouvelé s'il a expiré, compte chargé.
    func restore() async {
        if let restoring { await restoring.value; return }
        let task = Task { await self.performRestore() }
        restoring = task
        await task.value
        restoring = nil
    }

    private func performRestore() async {
        guard let current = token else { return }
        if await Self.isValid(current) == false {
            switch await renew() {
            case .renewed: break
            case .refused: logout(); return
            // Réseau instable : la session reste (il fallait refaire la
            // connexion par code) ; nouvel essai au prochain passage.
            case .unreachable: return
            }
        }
        if let t = token { user = await getTwitchUser(token: t) }
    }

    enum Renewal { case renewed, refused, unreachable }

    /// Nouveau jeton à partir du jeton de renouvellement (les jetons Twitch
    /// expirent au bout de quelques heures). `refused` : Twitch n'en veut
    /// plus ; `unreachable` : pas de réponse (rien n'est effacé).
    func renew() async -> Renewal {
        if let renewing { return await renewing.value }
        let task = Task { await self.performRenew() }
        renewing = task
        let result = await task.value
        renewing = nil
        return result
    }

    private func performRenew() async -> Renewal {
        guard let refresh = Keychain.loadToken(Self.refreshKey) else { return .refused }
        guard let json = await Self.post("https://id.twitch.tv/oauth2/token", [
            "client_id": kHelixClientID,
            "grant_type": "refresh_token",
            "refresh_token": refresh,
        ]) else { return .unreachable }
        guard let access = json["access_token"] as? String else {
            // Refus explicite (400 « Invalid refresh token ») seulement : une
            // erreur du serveur de Twitch n'efface rien.
            let status = json["status"] as? Int ?? 400
            return (400 ..< 500).contains(status) ? .refused : .unreachable
        }
        save(access: access, refresh: json["refresh_token"] as? String)
        return .renewed
    }

    /// Nouveau jeton, ou nil si c'est impossible (refus ou pas de réponse).
    @discardableResult
    func renewToken() async -> String? {
        await renew() == .renewed ? token : nil
    }

    func logout() {
        token = nil
        user = nil
        Keychain.storeToken(nil, for: Self.tokenKey)
        Keychain.storeToken(nil, for: Self.refreshKey)
    }

    private func save(access: String, refresh: String?) {
        token = access
        Keychain.storeToken(access, for: Self.tokenKey)
        if let refresh { Keychain.storeToken(refresh, for: Self.refreshKey) }
    }

    // MARK: Connexion par code
    struct DeviceCode: Equatable {
        let deviceCode: String
        let userCode: String
        /// Lien qui préremplit le code (pour le QR code).
        let verificationURL: String
        let interval: Int
        let expiresAt: Date
    }

    func requestCode() async -> DeviceCode? {
        guard let json = await Self.post("https://id.twitch.tv/oauth2/device",
                                         ["client_id": kHelixClientID, "scopes": Self.scopes]),
              let device = json["device_code"] as? String,
              let userCode = json["user_code"] as? String,
              let uri = json["verification_uri"] as? String else { return nil }
        return DeviceCode(deviceCode: device, userCode: userCode, verificationURL: uri,
                          interval: json["interval"] as? Int ?? 5,
                          expiresAt: Date().addingTimeInterval(Double(json["expires_in"] as? Int ?? 1800)))
    }

    /// Connexion par code en cours, portée par la session : elle survit au
    /// passage dans un autre onglet (sur tvOS, l'onglet change dès que le
    /// focus passe dans la barre, et l'attente du code était annulée).
    @Published private(set) var pendingCode: DeviceCode?
    @Published private(set) var loginFailed = false
    private var loginTask: Task<Void, Never>?

    func startLogin() {
        loginFailed = false
        loginTask?.cancel()
        loginTask = Task { [weak self] in
            guard let self else { return }
            guard let c = await self.requestCode() else { self.loginFailed = true; return }
            self.pendingCode = c
            let ok = await self.waitForApproval(c)
            guard !Task.isCancelled else { return }
            self.pendingCode = nil
            if !ok { self.loginFailed = true }
        }
    }

    func cancelLogin() {
        loginTask?.cancel()
        loginTask = nil
        pendingCode = nil
    }

    /// Attend la validation sur le téléphone. true une fois connecté ; false
    /// si le code expire, est refusé, ou si l'attente est annulée.
    func waitForApproval(_ code: DeviceCode) async -> Bool {
        var interval = UInt64(max(code.interval, 1))
        while !Task.isCancelled, Date() < code.expiresAt {
            try? await Task.sleep(nanoseconds: interval * 1_000_000_000)
            if Task.isCancelled { return false }
            let json = await Self.post("https://id.twitch.tv/oauth2/token", [
                "client_id": kHelixClientID,
                "scopes": Self.scopes,
                "device_code": code.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ])
            if let access = json?["access_token"] as? String {
                save(access: access, refresh: json?["refresh_token"] as? String)
                user = await getTwitchUser(token: access)
                logger.success("TV/AUTH", "Connecté par code", user?.login)
                return true
            }
            let message = (json?["message"] as? String ?? "").lowercased()
            if message.contains("slow_down") {
                interval += 5
            } else if !message.isEmpty, !message.contains("authorization_pending") {
                logger.warn("TV/AUTH", "Connexion par code refusée", message)
                return false
            }
        }
        return false
    }

    // MARK: Réseau
    private static func post(_ address: String, _ form: [String: String]) async -> [String: Any]? {
        guard let url = URL(string: address) else { return nil }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form
            .map { key, value in "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)" }
            .joined(separator: "&")
            .data(using: .utf8)
        // Twitch répond en JSON même en erreur (« authorization_pending »…).
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// true : valide ; false : refusé par Twitch ; nil : pas de réponse.
    private static func isValid(_ token: String) async -> Bool? {
        guard let url = URL(string: "https://id.twitch.tv/oauth2/validate") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return nil }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 200 { return true }
        return code == 401 ? false : nil
    }
}

/// QR code d'une adresse, net à toutes les tailles (pixels agrandis tels quels).
func tvQRCode(_ text: String) -> UIImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(text.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
          let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
    return UIImage(cgImage: image)
}

// MARK: – Avancement des VODs (sur cet appareil)
enum TVProgress {
    private static let key = "tv_vod_progress"

    static func position(_ id: String?) -> Double {
        guard let id else { return 0 }
        return UserDefaults.standard.dictionary(forKey: key)?[id] as? Double ?? 0
    }

    static func save(_ id: String, at seconds: Double, duration: Double) {
        guard seconds.isFinite, seconds > 0 else { return }
        var all = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        // Terminée (moins de 2 min avant la fin) : elle reprendra du début.
        if duration > 0, duration - seconds < 120 {
            all.removeValue(forKey: id)
        } else {
            all[id] = seconds
        }
        // tvOS limite le stockage local : 200 VODs suffisent.
        if all.count > 200, let any = all.keys.first(where: { $0 != id }) { all.removeValue(forKey: any) }
        UserDefaults.standard.set(all, forKey: key)
    }
}
