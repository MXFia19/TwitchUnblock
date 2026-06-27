import Foundation
import WebKit

// MARK: – Exécuteur GQL via WebView (pour franchir l'anti-bot Kasada/integrity)
//
// Certaines mutations Twitch (claim de coffre, redeem de récompense) exigent un
// header `Client-Integrity` VALIDE, généré par le défi JavaScript Kasada de la
// page twitch.tv. Un simple POST natif vers /integrity renvoie un token mais
// celui-ci est rejeté (« failed integrity check »).
//
// Astuce : on garde une WKWebView cachée chargée sur twitch.tv, et on exécute la
// requête GQL via `fetch()` DANS le contexte de la page. Le SDK Kasada y intercepte
// `fetch` et injecte automatiquement les headers requis → la mutation passe.
//
// ⚠️ Non officiel / hors-ToS Twitch — usage perso.
@MainActor
final class TwitchWebGQL: NSObject, WKNavigationDelegate {

    static let shared = TwitchWebGQL()
    private override init() {}

    private var webView: WKWebView?
    private var isReady = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private static let webUA =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1"

    // MARK: Setup
    private func ensureWebView() {
        guard webView == nil else { return }
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()   // partage les cookies (auth-token) avec le login
        // Empêche l'autoplay (sinon une vidéo Twitch pourrait jouer du son en fond).
        cfg.mediaTypesRequiringUserActionForPlayback = .all
        cfg.allowsInlineMediaPlayback = false
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: cfg)
        wv.navigationDelegate = self
        wv.customUserAgent = Self.webUA
        wv.isHidden = true
        // Attaché à la fenêtre (invisible) pour éviter la suspension JS hors-écran.
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first { $0.isKeyWindow }?
            .addSubview(wv)
        webView = wv
        if let url = URL(string: "https://www.twitch.tv/") {
            wv.load(URLRequest(url: url))
        }
        logger.debug("WEBGQL", "WebView Kasada initialisée", nil)
    }

    private func waitReady() async {
        ensureWebView()
        if isReady { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !isReady else { return }
        // Laisse ~3s au SDK Kasada pour s'initialiser après le chargement.
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            isReady = true
            logger.success("WEBGQL", "WebView prête (Kasada init)", nil)
            let pending = waiters; waiters.removeAll()
            pending.forEach { $0.resume() }
        }
    }

    // MARK: Exécution
    /// Mutation en query brute (ex: redeem).
    func run(_ query: String, token: String, tag: String) async -> [String: Any]? {
        guard let data = try? JSONSerialization.data(withJSONObject: ["query": query]),
              let bodyString = String(data: data, encoding: .utf8) else { return nil }
        return await execute(bodyString: bodyString, token: token, tag: tag)
    }

    /// Mutation via *persisted query* (identique au client web Twitch).
    func runPersisted(operationName: String, variables: [String: Any],
                      sha256: String, token: String, tag: String) async -> [String: Any]? {
        let payload: [[String: Any]] = [[
            "operationName": operationName,
            "variables":     variables,
            "extensions":    ["persistedQuery": ["version": 1, "sha256Hash": sha256]]
        ]]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let bodyString = String(data: data, encoding: .utf8) else { return nil }
        return await execute(bodyString: bodyString, token: token, tag: tag)
    }

    /// Envoie le body GQL via `fetch()` DANS la page (headers Kasada auto-injectés).
    /// Retourne l'objet `{data, errors}` (déballe le tableau si réponse batchée).
    private func execute(bodyString: String, token: String, tag: String) async -> [String: Any]? {
        await waitReady()
        guard let wv = webView else { return nil }

        // On lit le device-id (cookie unique_id) de la page : le token integrity de
        // Kasada y est lié, donc il DOIT figurer dans la requête sinon mismatch.
        let jsBody = """
        const did = (document.cookie.match(/unique_id=([^;]+)/) || [])[1];
        const headers = {
            'Content-Type': 'text/plain;charset=UTF-8',
            'Client-ID': clientId,
            'Authorization': 'OAuth ' + token
        };
        if (did) headers['X-Device-Id'] = did;
        const r = await fetch('https://gql.twitch.tv/gql', {
            method: 'POST',
            headers: headers,
            body: bodyString
        });
        return await r.text();
        """
        do {
            let result = try await wv.callAsyncJavaScript(
                jsBody,
                arguments: ["clientId": kGQLClientID, "token": token, "bodyString": bodyString],
                contentWorld: .page
            )
            guard let text = result as? String,
                  let data = text.data(using: .utf8),
                  let obj  = try? JSONSerialization.jsonObject(with: data) else {
                logger.warn("WEBGQL", "Réponse illisible (\(tag))", nil)
                return nil
            }
            // Twitch renvoie un objet pour {query}, un tableau pour les persisted queries.
            let json: [String: Any]? = (obj as? [[String: Any]])?.first ?? (obj as? [String: Any])
            guard let json = json else { return nil }
            if let errors = json["errors"] as? [[String: Any]], !errors.isEmpty {
                let msgs = errors.compactMap { $0["message"] as? String }.joined(separator: " · ")
                logger.warn("WEBGQL", "Erreurs GQL (\(tag))", msgs)
            } else {
                logger.debug("WEBGQL", "← \(tag) OK", nil)
            }
            return json
        } catch {
            logger.error("WEBGQL", "callAsyncJavaScript échoué (\(tag))", error.localizedDescription)
            return nil
        }
    }
}
