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
        var comps = URLComponents(string: "https://id.twitch.tv/oauth2/authorize")!
        comps.queryItems = [
            .init(name: "client_id",     value: kHelixClientID),
            .init(name: "redirect_uri",  value: kRedirectURI),
            .init(name: "response_type", value: "token"),
            .init(name: "scope",         value: "user:read:follows chat:read chat:edit"),
            .init(name: "force_verify",  value: forceVerify ? "true" : "false"),
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

                // Cherche access_token dans le fragment (#access_token=xxx)
                if let fragment = url.fragment,
                   let range = fragment.range(of: "access_token=") {
                    let afterToken = String(fragment[range.upperBound...])
                    let token = afterToken.components(separatedBy: "&").first
                    logger.debug("AUTH", "Token extrait depuis fragment", String(token?.prefix(8) ?? "nil") + "…")
                    continuation.resume(returning: token)
                    return
                }

                // Fallback : cherche dans la query string complète
                if let token = url.absoluteString
                    .components(separatedBy: "access_token=").last?
                    .components(separatedBy: "&").first,
                   !token.isEmpty {
                    logger.debug("AUTH", "Token extrait depuis query string (fallback)",
                                 String(token.prefix(8)) + "…")
                    continuation.resume(returning: token)
                    return
                }

                logger.error("AUTH", "Token introuvable dans la callback URL",
                             url.absoluteString.prefix(100).description)
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
