import Foundation
import AuthenticationServices

final class TwitchAuthManager: NSObject, ASWebAuthenticationPresentationContextProviding {

    static let shared = TwitchAuthManager()
    private override init() {}

    private var session: ASWebAuthenticationSession?

    /// Opens Twitch OAuth flow and returns the access token if successful.
    func login() async -> String? {
        var comps = URLComponents(string: "https://id.twitch.tv/oauth2/authorize")!
        comps.queryItems = [
            .init(name: "client_id",     value: kHelixClientID),
            .init(name: "redirect_uri",  value: kRedirectURI),
            .init(name: "response_type", value: "token"),
            // chat:read  → se connecter en IRC avec son vrai compte
            // chat:edit  → envoyer des messages
            // user:read:follows → accès aux chaînes suivies (déjà présent)
            .init(name: "scope",         value: "user:read:follows chat:read chat:edit"),
            .init(name: "force_verify",  value: "false"),
        ]
        guard let authURL = comps.url else { return nil }

        return await withCheckedContinuation { continuation in
            let s = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: "twitchunblock"
            ) { callbackURL, error in
                guard error == nil,
                      let url = callbackURL,
                      let fragment = url.fragment,
                      let tokenRange = fragment.range(of: "access_token=") else {
                    if let url = callbackURL,
                       let token = url.absoluteString
                           .components(separatedBy: "access_token=").last?
                           .components(separatedBy: "&").first {
                        continuation.resume(returning: token)
                    } else {
                        continuation.resume(returning: nil)
                    }
                    return
                }
                let afterToken = String(fragment[tokenRange.upperBound...])
                let token = afterToken.components(separatedBy: "&").first
                continuation.resume(returning: token)
            }
            s.presentationContextProvider = self
            s.prefersEphemeralWebBrowserSession = false
            self.session = s
            DispatchQueue.main.async { s.start() }
        }
    }

    // MARK: ASWebAuthenticationPresentationContextProviding
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}
