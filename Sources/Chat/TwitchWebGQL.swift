import Foundation
import WebKit

// MARK: – Minteur de token Client-Integrity (WebView éphémère)
//
// Les mutations Twitch « points » (claim coffre, redeem) exigent un header
// `Client-Integrity` VALIDE, généré par le défi Kasada (JS) de twitch.tv.
// On ne peut pas le produire en natif. MAIS, une fois le token obtenu, la
// mutation elle-même se fait très bien en natif (le token suffit, pas besoin
// des x-kpsdk-*).
//
// Donc : on ouvre une WKWebView éphémère, on génère un token via /integrity
// (Kasada y ajoute les x-kpsdk-* automatiquement), on récupère le token + le
// device-id, puis on DÉTRUIT la WebView. Le token est valide ~1h → aucune
// WebView en arrière-plan le reste du temps.
//
// ⚠️ Non officiel / hors-ToS Twitch — usage perso.
@MainActor
final class TwitchWebGQL: NSObject, WKNavigationDelegate {

    static let shared = TwitchWebGQL()
    private override init() {}

    private static let webUA =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1"

    private var webView: WKWebView?
    private var loadCont: CheckedContinuation<Bool, Never>?
    private var minting = false

    struct Integrity { let token: String; let deviceId: String; let expiry: Date }

    /// Génère un token Client-Integrity via une WebView éphémère, puis se détruit.
    func mintIntegrity(token: String) async -> Integrity? {
        guard !minting else { return nil }   // une seule génération à la fois
        minting = true
        defer { minting = false; teardown() }

        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()   // partage les cookies (auth-token, unique_id)
        cfg.mediaTypesRequiringUserActionForPlayback = .all
        cfg.allowsInlineMediaPlayback = false
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: cfg)
        wv.navigationDelegate = self
        wv.customUserAgent = Self.webUA
        wv.isHidden = true
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first { $0.isKeyWindow }?
            .addSubview(wv)
        webView = wv

        logger.info("INTEGRITY", "Génération du token…", "WebView éphémère sur twitch.tv")
        guard let url = URL(string: "https://www.twitch.tv/") else { return nil }
        wv.load(URLRequest(url: url))

        // Attend le chargement (avec garde-fou 15s).
        let loaded = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            loadCont = c
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                self?.loadCont?.resume(returning: false); self?.loadCont = nil
            }
        }
        guard loaded else { logger.warn("INTEGRITY", "Page twitch.tv non chargée", nil); return nil }

        // Laisse ~3s au SDK Kasada pour s'initialiser.
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        guard let wv2 = webView else { return nil }

        let js = """
        const did = (document.cookie.match(/unique_id=([^;]+)/) || [])[1] || '';
        try {
            const r = await fetch('https://gql.twitch.tv/integrity', {
                method: 'POST',
                headers: { 'Client-ID': clientId, 'Authorization': 'OAuth ' + token, 'X-Device-Id': did }
            });
            const j = await r.json();
            return JSON.stringify({ token: j.token || '', expiration: j.expiration || 0, deviceId: did });
        } catch (e) {
            return JSON.stringify({ token: '', expiration: 0, deviceId: did });
        }
        """
        do {
            let result = try await wv2.callAsyncJavaScript(
                js,
                arguments: ["clientId": kGQLClientID, "token": token],
                contentWorld: .page
            )
            guard let s = result as? String, let d = s.data(using: .utf8),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let tok = j["token"] as? String, !tok.isEmpty else {
                logger.warn("INTEGRITY", "Token vide", "Kasada n'a pas validé l'environnement")
                return nil
            }
            let did    = (j["deviceId"] as? String) ?? ""
            let expMs  = (j["expiration"] as? Double) ?? 0
            let expiry = expMs > 0 ? Date(timeIntervalSince1970: expMs / 1000)
                                   : Date().addingTimeInterval(3000)
            logger.success("INTEGRITY", "Token généré ✓",
                           "expire dans \(Int(expiry.timeIntervalSinceNow))s")
            return Integrity(token: tok, deviceId: did, expiry: expiry)
        } catch {
            logger.error("INTEGRITY", "JS échoué", error.localizedDescription)
            return nil
        }
    }

    private func teardown() {
        webView?.removeFromSuperview()
        webView?.navigationDelegate = nil
        webView = nil
    }

    // MARK: WKNavigationDelegate
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadCont?.resume(returning: true); loadCont = nil
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadCont?.resume(returning: false); loadCont = nil
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadCont?.resume(returning: false); loadCont = nil
    }
}
