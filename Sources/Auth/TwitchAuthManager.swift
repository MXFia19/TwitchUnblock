import Foundation
import AuthenticationServices

final class TwitchAuthManager: NSObject, ASWebAuthenticationPresentationContextProviding {

    static let shared = TwitchAuthManager()
    private override init() {}

    private var session: ASWebAuthenticationSession?

    /// Ouvre le flow OAuth Twitch et retourne le token si succès.
    /// - Parameter forceVerify: false = silencieux si déjà connecté dans Safari (< 1s)
    ///                          true  = re-login visible garanti (token fraîchement émis)
    func login(forceVerify: Bool = false) async -> String? {
        let expectedState = UUID().uuidString
        var comps = URLComponents(string: "https://id.twitch.tv/oauth2/authorize")!
        comps.queryItems = [
            .init(name: "client_id",     value: kHelixClientID),
            .init(name: "redirect_uri",  value: kRedirectURI),
            .init(name: "response_type", value: "token"),
            // user:manage:chat_color : Twitch a retiré les commandes /color de l'IRC
            // en 2023, la couleur passe désormais par l'API Helix.
            .init(name: "scope",         value: "user:read:follows chat:read chat:edit user:manage:chat_color"),
            .init(name: "force_verify",  value: forceVerify ? "true" : "false"),
            // Valeur aléatoire vérifiée au retour : seul le retour de CETTE
            // demande de connexion est accepté.
            .init(name: "state",         value: expectedState),
        ]
        guard let authURL = comps.url else { return nil }

        logger.info("AUTH", forceVerify ? "Login Twitch (force_verify: true)…"
                                        : "Login Twitch silencieux (force_verify: false)…", nil)

        return await withCheckedContinuation { continuation in
            let s = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: "twitchunblock"
            ) { callbackURL, error in
                guard error == nil,
                      let url = callbackURL else {
                    logger.warn("AUTH", "OAuth annulé ou erreur",
                                error?.localizedDescription ?? "callbackURL nil")
                    continuation.resume(returning: nil)
                    return
                }

                // Paramètres lus proprement, dans le fragment (#access_token=…)
                // ou la query (?access_token=…). L'ancien découpage par texte
                // prenait l'adresse entière pour un jeton quand il manquait
                // (par ex. « twitchunblock://auth?error=… »).
                var fragmentComps = URLComponents()
                fragmentComps.query = url.fragment
                let items: [URLQueryItem] =
                    (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                    + (fragmentComps.queryItems ?? [])
                func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
                if let token = value("access_token"), !token.isEmpty,
                   token.allSatisfy({ $0.isLetter || $0.isNumber }),
                   // Absent : ancienne page auth.html encore en cache, qui ne
                   // le transmettait pas. Présent, il doit correspondre.
                   value("state") == nil || value("state") == expectedState {
                    logger.debug("AUTH", "Token reçu", nil)
                    continuation.resume(returning: token)
                    return
                }

                logger.error("AUTH", "Token absent ou state invalide",
                             value("error_description") ?? value("error"))
                continuation.resume(returning: nil)
            }
            s.presentationContextProvider = self
            // false = partage la session Safari (l'utilisateur reste connecté entre les logins)
            s.prefersEphemeralWebBrowserSession = false
            self.session = s
            DispatchQueue.main.async { s.start() }
        }
    }

    // MARK: – ASWebAuthenticationPresentationContextProviding
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}
