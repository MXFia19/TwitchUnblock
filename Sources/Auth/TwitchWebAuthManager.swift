import SwiftUI
import WebKit

// MARK: – Login web Twitch (capture du cookie `auth-token`)
//
// L'API GQL « community points » (solde, coffres, rachats) n'accepte QUE les
// tokens liés au Client-ID web officiel `kimne78kx3ncx6brgo4mv6wki5h1ko`.
// Un token OAuth émis pour un Client-ID custom renvoie `communityPoints: null`.
//
// La seule façon d'obtenir un token compatible est de récupérer le cookie de
// session `auth-token` d'une vraie connexion twitch.tv. C'est ce que fait cette
// WebView : elle charge la page de login et capture le cookie une fois connecté.
//
// ⚠️ Non officiel / hors-ToS Twitch — réservé à l'usage perso de cette app.

private let kMobileUA =
    "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 "
    + "(KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1"

// MARK: – Sheet présentable
struct TwitchWebLoginSheet: View {
    /// true  → on efface d'abord les cookies twitch (re-login forcé, ex: token expiré)
    /// false → on réutilise la session existante (capture instantanée si déjà connecté)
    let clearSession: Bool
    let onComplete: (_ token: String, _ login: String?) -> Void
    let onCancel: () -> Void

    @State private var isLoading = true

    var body: some View {
        NavigationView {
            ZStack {
                Color.tDark.ignoresSafeArea()

                TwitchWebLogin(
                    clearSession: clearSession,
                    onComplete: onComplete,
                    onLoadingChange: { isLoading = $0 }
                )
                .ignoresSafeArea(edges: .bottom)

                if isLoading {
                    VStack(spacing: 12) {
                        ProgressView().tint(.tPrimary).scaleEffect(1.3)
                        Text("Chargement de Twitch…")
                            .font(.system(size: 13))
                            .foregroundColor(.tMuted)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text("Connexion Twitch")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.tText)
                        Text("Requis pour les points de chaîne")
                            .font(.system(size: 10))
                            .foregroundColor(.tMuted)
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { onCancel() }
                        .foregroundColor(.tPrimary)
                }
            }
        }
    }
}

// MARK: – WKWebView wrapper
private struct TwitchWebLogin: UIViewRepresentable {
    let clearSession: Bool
    let onComplete: (_ token: String, _ login: String?) -> Void
    let onLoadingChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero)
        webView.navigationDelegate = context.coordinator
        webView.customUserAgent = kMobileUA
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.attach(webView)

        let load = {
            if let url = URL(string: "https://www.twitch.tv/login") {
                webView.load(URLRequest(url: url))
            }
        }

        if clearSession {
            let store = webView.configuration.websiteDataStore.httpCookieStore
            store.getAllCookies { cookies in
                let twitchCookies = cookies.filter { $0.domain.contains("twitch") }
                guard !twitchCookies.isEmpty else { load(); return }
                let group = DispatchGroup()
                for c in twitchCookies {
                    group.enter()
                    store.delete(c) { group.leave() }
                }
                group.notify(queue: .main) {
                    logger.debug("AUTH/WEB", "Cookies twitch effacés", "\(twitchCookies.count) supprimés")
                    load()
                }
            }
        } else {
            load()
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
    }

    // MARK: Coordinator
    final class Coordinator: NSObject, WKNavigationDelegate {
        private let parent: TwitchWebLogin
        private weak var webView: WKWebView?
        private var timer: Timer?
        private var done = false

        init(_ parent: TwitchWebLogin) { self.parent = parent }

        func attach(_ webView: WKWebView) {
            self.webView = webView
            // Filet de sécurité : certaines connexions SPA ne déclenchent pas didFinish.
            timer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in
                self?.captureToken()
            }
        }

        func stop() {
            timer?.invalidate(); timer = nil
        }

        // MARK: WKNavigationDelegate
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.onLoadingChange(true)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.onLoadingChange(false)
            captureToken()
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.onLoadingChange(false)
        }

        // MARK: Capture
        private func captureToken() {
            guard !done, let webView = webView else { return }
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self = self, !self.done else { return }
                guard let auth = cookies.first(where: { $0.name == "auth-token" })?.value,
                      auth.count >= 20 else { return }   // évite un cookie partiel/vide
                self.done = true
                self.stop()
                let login = cookies.first(where: { $0.name == "login" })?.value
                logger.success("AUTH/WEB", "Token de session capturé",
                               "\(String(auth.prefix(8)))… · @\(login ?? "?")")
                DispatchQueue.main.async { self.parent.onComplete(auth, login) }
            }
        }
    }
}
