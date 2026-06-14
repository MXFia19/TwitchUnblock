import SwiftUI
import AVKit
import AVFoundation
import WebKit

// MARK: – Chat WebView (Mode Popout Twitch)
struct ChatWebView: UIViewRepresentable {
    let channel: String

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Garde les cookies pour rester connecté à Twitch !
        config.websiteDataStore = WKWebsiteDataStore.default() 
        
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.uiDelegate = context.coordinator
        webView.navigationDelegate = context.coordinator
        
        // Force la vue mobile pour un meilleur affichage du chat
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1"
        
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Lien officiel du chat Twitch Popout
        let urlString = "https://www.twitch.tv/popout/\(channel.lowercased())/chat"
        if context.coordinator.loadedURL != urlString {
            context.coordinator.loadedURL = urlString
            if let url = URL(string: urlString) {
                webView.load(URLRequest(url: url))
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject, WKUIDelegate, WKNavigationDelegate {
        var loadedURL: String?
        
        // Permet d'ouvrir la page de connexion si Twitch demande un popup
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }
    }
}

// MARK: – AVPlayerViewController wrapper
struct NativeVideoPlayer: UIViewControllerRepresentable {
    let url: URL
    let savedTime: Double
    let onProgress: (Double) -> Void

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let player = AVPlayer(url: url)
        let vc = AVPlayerViewController()
        vc.player = player
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        vc.showsPlaybackControls = true
        context.coordinator.playerVC = vc
        context.coordinator.setupObserver(player: player, onProgress: onProgress)
        if savedTime > 5 {
            player.seek(to: CMTime(seconds: savedTime, preferredTimescale: 600))
        }
        player.play()
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        let currentURL = (vc.player?.currentItem?.asset as? AVURLAsset)?.url
        if currentURL != url {
            vc.player?.pause() // Stoppe l'ancien son
            
            let player = AVPlayer(url: url)
            vc.player = player
            context.coordinator.setupObserver(player: player, onProgress: onProgress)
            if savedTime > 5 {
                player.seek(to: CMTime(seconds: savedTime, preferredTimescale: 600))
            }
            player.play()
        }
    }

    static func dismantleUIViewController(_ vc: AVPlayerViewController, coordinator: Coordinator) {
        vc.player?.pause()
        vc.player = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var playerVC: AVPlayerViewController?
        private var timeObserver: Any?
        private var playerRef: AVPlayer?

        init() {
            NotificationCenter.default.addObserver(forName: NSNotification.Name("ForceStopVideo"), object: nil, queue: .main) { [weak self] _ in
                self?.playerVC?.player?.pause()
                self?.playerVC?.player = nil
            }
        }

        func setupObserver(player: AVPlayer, onProgress: @escaping (Double) -> Void) {
            if let existing = timeObserver { playerRef?.removeTimeObserver(existing) }
            playerRef = player
            let interval = CMTime(seconds: 5, preferredTimescale: 600)
            timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
                onProgress(time.seconds)
            }
        }

        deinit {
            if let obs = timeObserver { playerRef?.removeTimeObserver(obs) }
            NotificationCenter.default.removeObserver(self)
        }
    }
}

// MARK: – Full Video Player View (Style Frosty)
enum PlayerTab { case chat, options }

struct VideoPlayerView<InfoContent: View>: View {
    let qualityLinks: QualityLinks
    let vodId: String?
    let channelName: String?
    let infoContent: InfoContent

    @EnvironmentObject private var store: AppStore
    @State private var selectedQuality: String = ""
    @State private var currentTime: Double = 0
    @State private var currentTab: PlayerTab = .options

    private var qualities: [String] { sortQualities(Array(qualityLinks.keys)) }
    private var currentURL: URL? { qualityLinks[selectedQuality].flatMap(URL.init) }

    init(qualityLinks: QualityLinks, vodId: String?, channelName: String?, @ViewBuilder infoContent: () -> InfoContent) {
        self.qualityLinks = qualityLinks
        self.vodId = vodId
        self.channelName = channelName
        self.infoContent = infoContent()
    }

    var body: some View {
        VStack(spacing: 0) {
            
            // 1. LECTEUR VIDÉO (Fixé en haut)
            if let url = currentURL {
                NativeVideoPlayer(
                    url: url,
                    savedTime: vodId.map { store.getVodProgress($0) } ?? 0
                ) { time in
                    currentTime = time
                    if let id = vodId { store.setVodProgress(id, time: time) }
                }
                .aspectRatio(16/9, contentMode: .fit)
                .background(Color.black)
            }

            // 2. ONGLETS FROSTY (Chat / Options)
            HStack(spacing: 0) {
                if channelName != nil {
                    tabButton(title: "💬 Chat", tab: .chat)
                }
                tabButton(title: "⚙️ \(store.t("settings"))", tab: .options)
            }
            .background(Color.tCard)
            .overlay(Divider().background(Color.tBorder), alignment: .bottom)

            // 3. CONTENU (Plein écran en bas)
            if currentTab == .chat, let channel = channelName {
                ChatWebView(channel: channel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.tDark) // Évite les flashs blancs
            } else {
                ScrollView {
                    VStack(spacing: 24) {
                        // Infos du stream (Titre, Catégorie)
                        infoContent
                            .frame(maxWidth: .infinity, alignment: .leading)
                        
                        optionsTab
                    }
                    .padding(16)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.tDark)
            }
        }
        .onAppear {
            if selectedQuality.isEmpty { selectedQuality = qualities.first ?? "" }
            // Ouvre le chat par défaut si c'est un live !
            if channelName != nil { currentTab = .chat } else { currentTab = .options }
        }
    }

    @ViewBuilder
    private func tabButton(title: String, tab: PlayerTab) -> some View {
        Button {
            currentTab = tab
        } label: {
            VStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(currentTab == tab ? .tPrimary : .tMuted)
                
                Rectangle()
                    .fill(currentTab == tab ? Color.tPrimary : Color.clear)
                    .frame(height: 3)
            }
            .padding(.top, 14)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var optionsTab: some View {
        VStack(spacing: 20) {
            
            // Sélecteur de qualité intégré
            VStack(alignment: .leading, spacing: 8) {
                Text("🎬 Qualité Vidéo").font(.system(size: 13, weight: .bold)).foregroundColor(.tMuted)
                VStack(spacing: 0) {
                    ForEach(qualities, id: \.self) { q in
                        Button {
                            currentTime = 0
                            selectedQuality = q
                        } label: {
                            HStack {
                                Text(q == selectedQuality ? "✓  " : "    ")
                                    .foregroundColor(q == selectedQuality ? .tPrimary : .clear)
                                Text(qualityLabel(q))
                                    .foregroundColor(q == selectedQuality ? .tPrimary : .tText)
                                    .fontWeight(q == selectedQuality ? .bold : .semibold)
                                Spacer()
                            }
                            .padding(.horizontal, 16).padding(.vertical, 14)
                        }
                        if q != qualities.last {
                            Divider().background(Color.tBorder)
                        }
                    }
                }
                .background(Color.tSurface)
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.tBorder, lineWidth: 1))
            }

            // Boutons d'exportation
            VStack(alignment: .leading, spacing: 8) {
                Text("📤 Exporter vers...").font(.system(size: 13, weight: .bold)).foregroundColor(.tMuted)
                VStack(spacing: 12) {
                    if let rawURL = qualityLinks[selectedQuality] {
                        extButton("🟠 \(store.t("open_vlc"))", color: .tVLC) { open(scheme: "vlc://\(rawURL)") }
                        extButton("🔵 \(store.t("open_outplayer"))", color: .tOutplayer) { open(scheme: "outplayer://\(rawURL)") }
                        extButton("🔴 \(store.t("open_infuse"))", color: .tInfuse) {
                            let encoded = rawURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? rawURL
                            open(scheme: "infuse://x-callback-url/play?url=\(encoded)")
                        }
                        extButton("📋 \(store.t("btn_copy"))", color: .tSurface) {
                            UIPasteboard.general.string = rawURL
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func extButton(_ label: String, color: Color, textColor: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(textColor)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(color)
                .cornerRadius(10)
        }
    }

    private func open(scheme: String) {
        guard let url = URL(string: scheme) else { return }
        UIApplication.shared.open(url)
    }

    private func qualityLabel(_ q: String) -> String {
        q.replacingOccurrences(of: "chunked", with: "Source")
         .replacingOccurrences(of: "source",  with: "Source")
    }
}
