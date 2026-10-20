import SwiftUI
import AVKit
import AVFoundation

// ═══════════════════════════════════════════════════════════════════════════
//  Lecteur de l'app Apple TV : le lecteur natif de tvOS (barre de lecture,
//  glissés de la télécommande, panneau d'infos), avec en plus dans sa barre
//  Qualité, Chat (le chat posé sur l'image, direct ou VOD, voir TVChat) et
//  pour un direct Source. Mêmes liens que l'iPhone :
//  sources sans pub pour les lives, passages coupés rétablis sur les VODs
//  récentes quand c'est possible, et le même bandeau pendant une pause pub
//  de la chaîne (compte à rebours).
// ═══════════════════════════════════════════════════════════════════════════

struct TVPlayerScreen: View {
    let item: TVPlayback
    /// Bouton « Chaîne » de la barre de lecture : la page de la chaîne (ses
    /// vidéos), que l'appelant ouvre une fois le lecteur fermé.
    var onChannel: ((String) -> Void)? = nil
    @EnvironmentObject private var session: TVSession
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = TVPlayerModel()
    @StateObject private var chat = TVChatModel()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player = model.player {
                TVPlayerController(player: player, model: model, session: session, chat: chat,
                                   channel: item.channel, onChannel: openChannel)
                    .ignoresSafeArea()
                    .overlay(alignment: .top) {
                        VStack(spacing: 24) {
                            // Avis passager (source qui ne répond pas) : la lecture continue.
                            if let notice = model.notice {
                                Text(notice)
                                    .font(.headline)
                                    .padding(.horizontal, 32).padding(.vertical, 16)
                                    .background(.ultraThinMaterial, in: Capsule())
                            }
                            // Pause pub de la chaîne (direct) : ce qu'est cet écran,
                            // et dans combien de temps le direct revient.
                            TVAdBreakBanner(watcher: model.adBreaks, session: session)
                        }
                        .padding(.top, 60)
                        .allowsHitTesting(false)
                    }
            } else if let error = model.error {
                VStack(spacing: 40) {
                    Text(error).font(.title3).multilineTextAlignment(.center)
                    Button(session.t("tv_back")) { dismiss() }
                }
                .padding(80)
            } else {
                ProgressView()
            }
        }
        .task {
            switch item {
            case .live(let login, _): chat.start(login)
            case .vod(let id, _, _):  chat.startVod(id)
            }
            await model.load(item, session: session)
        }
        // VOD : le chat suit la lecture (commentaires rejoués à leur instant).
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            guard case .vod = item, let time = model.player?.currentTime().seconds else { return }
            chat.update(offset: time)
        }
        .onDisappear {
            model.stop()
            chat.stop()
        }
        .onExitCommand { dismiss() }
    }

    /// « Chaîne » dans la barre de lecture : seulement si on sait laquelle
    /// (une VOD ouverte sans sa chaîne n'en a pas).
    private var openChannel: (() -> Void)? {
        guard let onChannel, !item.channel.isEmpty else { return nil }
        let login = item.channel
        return { onChannel(login) }
    }
}

@MainActor
final class TVPlayerModel: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var error: String?
    @Published private(set) var links: QualityLinks = [:]
    @Published private(set) var quality = ""
    /// Hauteur et cadence de chaque qualité (qualité préférée, ordre du menu).
    private(set) var variants: [String: VariantInfo] = [:]
    private(set) var isLive = false
    /// Source qui sert le direct : getLive passe aux suivantes quand la
    /// préférée ne répond pas. C'est elle que le menu Source coche.
    private(set) var liveSource: String?

    private var current: TVPlayback?
    private var title = ""
    private var subtitle = ""
    private var vodId: String?
    private var statusObs: NSKeyValueObservation?
    private var timeObs: Any?
    /// Siri, FaceTime… : la lecture mise en pause par tvOS repart à la fin
    /// (PlaybackInterruptions) — VOD à l'endroit, direct relu au bord.
    private var interruptions: PlaybackInterruptions?

    /// Avis passager par-dessus la lecture (source qui ne répond pas…).
    @Published private(set) var notice: String?
    private var noticeTask: Task<Void, Never>?
    /// Pause pub cousue par Twitch dans le direct : bandeau avec compte à
    /// rebours, comme sur l'iPhone. Le son n'y est pas coupé : le lecteur de
    /// tvOS n'a pas de bouton pour le remettre.
    let adBreaks = AdBreakWatcher(managesAudio: false)

    private func flash(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    /// false si rien n'a pu être lu.
    @discardableResult
    func load(_ item: TVPlayback, session: TVSession) async -> Bool {
        current = item
        error = nil
        switch item {
        case .live(let login, let name):
            isLive = true
            title = name
            vodId = nil
            let data = await getLive(channelName: login)
            guard let raw = data.links, !raw.isEmpty else {
                // Santé du direct (/stats) : hors ligne n'est pas un échec.
                if data.error != "offline" {
                    TVUsage.count("live_fail")
                    logger.error("TV/LECTEUR", "Direct impossible à lire : \(login)",
                                 "\(data.error ?? "?") · source \(session.liveSource)")
                }
                let message = session.t(data.error == "offline" ? "tv_offline" : "tv_error_live")
                // Changement de source pendant la lecture : elle continue sur
                // l'ancienne, l'avis passe par-dessus (rien ne s'affichait).
                if player != nil { flash(message) } else { error = message }
                return false
            }
            TVUsage.count("live_\(data.source ?? "unknown")")
            logger.info("TV/LECTEUR", "Direct : \(login)", "source \(data.source ?? "?")")
            subtitle = data.title
            liveSource = data.source
            // Playlists réécrites avec la vraie durée des segments (2 s) : le
            // lecteur tient le bord du direct au lieu de rester ~20 s derrière.
            links = LivePlaylistLoader.wrap(raw)
            variants = data.variants
        case .vod(let id, let videoTitle, _):
            isLive = false
            title = videoTitle
            subtitle = ""
            vodId = id
            async let markersTask = getVodMarkers(vodId: id)
            let data = await getM3U8(vodId: id)
            let markers = await markersTask
            guard !data.links.isEmpty else {
                TVUsage.count("vod_fail")
                logger.error("TV/LECTEUR", "VOD impossible à lire : \(id)", data.error ?? "?")
                // Code d'erreur (getM3U8) traduit : le texte venait en français.
                error = session.t(data.error.map(apiErrorKey) ?? "tv_error_vod")
                return false
            }
            TVUsage.count("vod")
            // VOD récente avec des passages coupés : le son d'origine est
            // peut-être encore sur le CDN (VodUnmuteLoader).
            links = VodUnmuteLoader.worthTrying(markers) ? VodUnmuteLoader.wrap(data.links) : data.links
            variants = data.variants
        }
        // Qualité préférée, sinon la plus proche en dessous (même règle que l'iPhone).
        quality = preferredQualityKey(Array(links.keys), pref: session.qualityPref, variants: variants)
        start(at: isLive ? 0 : TVProgress.position(vodId))
        return true
    }

    /// (Re)lance la qualité choisie, à `seconds` pour une VOD. `play` : false
    /// pour rester en pause (qualité changée pendant une pause).
    private func start(at seconds: Double, play: Bool = true) {
        guard let link = links[quality], let url = URL(string: link) else { return }
        let item = VodUnmuteLoader.playerItem(url: url)
        item.externalMetadata = metadata()
        // Chercher avant que la playlist soit chargée ne tient pas.
        statusObs = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .readyToPlay, seconds > 5, let model = self else { return }
            Task { @MainActor in
                model.player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                                   toleranceBefore: .zero, toleranceAfter: .zero)
                model.statusObs = nil
            }
        }
        let p = player ?? AVPlayer()
        p.replaceCurrentItem(with: item)
        if play { p.play() }
        interruptions?.settle()
        if player == nil {
            player = p
            interruptions = PlaybackInterruptions(name: "Apple TV") { [weak self] _ in
                Task { @MainActor in self?.resumeAfterInterruption() }
                return "lecture relancée (VOD à l'endroit, direct au bord)"
            }
            interruptions?.watch(p)
            // Direct : pauses pub suivies d'après l'image affichée.
            if isLive { adBreaks.attach(p) }
            // Avancement d'une VOD gardé toutes les 10 s (reprise au même endroit).
            if let id = vodId {
                timeObs = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 10, preferredTimescale: 1),
                                                    queue: .main) { [weak p] time in
                    let duration = p?.currentItem?.duration.seconds ?? 0
                    TVProgress.save(id, at: time.seconds, duration: duration.isFinite ? duration : 0)
                }
            }
        }
    }

    /// Qualité choisie dans la barre : elle devient la qualité préférée.
    func setQuality(_ key: String, session: TVSession) {
        guard key != quality, links[key] != nil else { return }
        quality = key
        if let pref = qualityPreference(for: key, among: Array(links.keys), variants: variants) {
            session.qualityPref = pref
        }
        // En pause : elle le reste (la qualité changée relançait la lecture).
        start(at: isLive ? 0 : (player?.currentTime().seconds ?? 0), play: (player?.rate ?? 1) != 0)
    }

    /// Source du direct changée : liens redemandés à la nouvelle source.
    /// false si elle n'a rien donné (la lecture reste sur l'ancienne).
    func reload(session: TVSession) async -> Bool {
        guard let current else { return false }
        return await load(current, session: session)
    }

    /// Fin d'une interruption du son : VOD à l'endroit (rien en fin de VOD),
    /// direct relu au bord (même qualité).
    private func resumeAfterInterruption() {
        guard let p = player, let item = p.currentItem, item.status != .failed,
              p.timeControlStatus == .paused else { return }
        if isLive { start(at: 0); return }
        let length = item.duration.seconds
        if length.isFinite, length > 0, p.currentTime().seconds >= length - 1 { return }
        p.play()
    }

    func stop() {
        // Lecteur fermé : une fin d'interruption ne doit plus le relancer.
        interruptions = nil
        adBreaks.detach()
        if let p = player, let id = vodId {
            let duration = p.currentItem?.duration.seconds ?? 0
            TVProgress.save(id, at: p.currentTime().seconds, duration: duration.isFinite ? duration : 0)
        }
        if let o = timeObs { player?.removeTimeObserver(o) }
        timeObs = nil
        statusObs = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
    }

    /// Titre et sous-titre du panneau d'infos de tvOS.
    private func metadata() -> [AVMetadataItem] {
        func entry(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
            let m = AVMutableMetadataItem()
            m.identifier = identifier
            m.value = value as NSString
            m.extendedLanguageTag = "und"
            return m
        }
        var out = [entry(.commonIdentifierTitle, title)]
        if !subtitle.isEmpty { out.append(entry(.iTunesMetadataTrackSubTitle, subtitle)) }
        return out
    }
}

@MainActor
struct TVPlayerController: UIViewControllerRepresentable {
    let player: AVPlayer
    @ObservedObject var model: TVPlayerModel
    @ObservedObject var session: TVSession
    let chat: TVChatModel
    /// Chaîne regardée : le chat y garde la place choisie dans le menu Chat.
    let channel: String
    /// Bouton « Chaîne » : sa page, pour voir ses vidéos sans passer par Recherche.
    let onChannel: (() -> Void)?

    final class Coordinator {
        var chatHost: UIHostingController<TVChatOverlay>?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        // Vitesse : le contrôle de tvOS sur une VOD, aucun sur un direct (il
        // n'y a rien à accélérer). L'écran est propre à un seul contenu.
        vc.speeds = model.isLive ? [] : AVPlaybackSpeed.systemDefaultSpeeds
        vc.transportBarCustomMenuItems = menus()
        // Chat dans le calque du lecteur : sur l'image, sous les commandes,
        // sans jamais prendre le focus.
        let host = UIHostingController(rootView: overlay())
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false
        if let overlay = vc.contentOverlayView {
            vc.addChild(host)
            host.view.frame = overlay.bounds
            host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            overlay.addSubview(host.view)
            host.didMove(toParent: vc)
        }
        context.coordinator.chatHost = host
        showChat(context)
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        if vc.player !== player { vc.player = player }
        vc.transportBarCustomMenuItems = menus()
        showChat(context)
    }

    /// Chat posé sur l'image, à la place retenue pour cette chaîne.
    private func overlay() -> TVChatOverlay {
        TVChatOverlay(model: chat, waitingText: session.t(model.isLive ? "tv_chat_waiting" : "tv_chat_loading"),
                      layout: session.chatLayout(for: channel), quietText: session.t("tv_chat_quiet"))
    }

    private func showChat(_ context: Context) {
        guard let host = context.coordinator.chatHost else { return }
        host.view.isHidden = !session.chatShown(for: channel)
        host.rootView = overlay()
    }

    /// Menus de la barre de lecture : Qualité, et Source pour un direct.
    private func menus() -> [UIMenuElement] {
        let model = self.model
        let session = self.session
        let qualities: [UIMenuElement] = sortQualities(Array(model.links.keys), variants: model.variants).map { key in
            UIAction(title: label(key), state: key == model.quality ? .on : .off) { _ in
                Task { @MainActor in model.setQuality(key, session: session) }
            }
        }
        var items: [UIMenuElement] = [
            UIMenu(title: session.t("quality"), image: UIImage(systemName: "slider.horizontal.3"),
                   children: qualities)
        ]
        if model.isLive {
            // Cochée : la source qui sert le direct — la préférée a pu ne pas
            // répondre et une suivante la remplacer, la coche restait sur elle.
            // « Automatique » tant que c'est le choix ; le Worker, absent du
            // menu, laisse le choix coché.
            let served = model.liveSource.flatMap { kLiveSourceChoices.contains($0) ? $0 : nil }
            let checked = session.liveSource == "auto" ? "auto" : (served ?? session.liveSource)
            let sources: [UIMenuElement] = kLiveSourceChoices.map { id in
                UIAction(title: session.t("src_\(id)"), state: id == checked ? .on : .off) { _ in
                    Task { @MainActor in
                        let before = session.liveSource
                        session.liveSource = id
                        // Rien sur cette source : l'ancienne reste cochée (et lue).
                        if !(await model.reload(session: session)) { session.liveSource = before }
                    }
                }
            }
            items.append(UIMenu(title: session.t("live_source"),
                                image: UIImage(systemName: "antenna.radiowaves.left.and.right"),
                                children: sources))
        }
        items.append(chatMenu())
        if let onChannel {
            items.append(UIAction(title: session.t("tv_open_channel"),
                                  image: UIImage(systemName: "person.crop.rectangle")) { _ in
                Task { @MainActor in onChannel() }
            })
        }
        return items
    }

    /// Menu Chat : affiché ou masqué, et sa place sur l'image — côté,
    /// hauteur —, retenus pour cette chaîne.
    private func chatMenu() -> UIMenu {
        let session = self.session
        let channel = self.channel
        let layout = session.chatLayout(for: channel)
        let shown = session.chatShown(for: channel)
        /// Place changée : chat affiché s'il était masqué, pour la voir.
        func place(_ change: @escaping (inout TVChatLayout) -> Void) {
            Task { @MainActor in
                var next = session.chatLayout(for: channel)
                change(&next)
                session.setChatLayout(next, for: channel)
                if !session.chatShown(for: channel) { session.setChatShown(true, for: channel) }
            }
        }
        let sides: [UIMenuElement] = TVChatLayout.Side.allCases.map { side in
            UIAction(title: session.t("tv_chat_\(side.rawValue)"), state: layout.side == side ? .on : .off) { _ in
                place { $0.side = side }
            }
        }
        let heights: [UIMenuElement] = TVChatLayout.Height.allCases.map { height in
            UIAction(title: session.t("tv_chat_\(height.rawValue)"), state: layout.height == height ? .on : .off) { _ in
                place { $0.height = height }
            }
        }
        var children: [UIMenuElement] = [
            // Pour cette chaîne seulement (son streamer incruste peut-être déjà le sien).
            UIAction(title: session.t("tv_chat_show"), state: shown ? .on : .off) { _ in
                Task { @MainActor in session.setChatShown(!shown, for: channel) }
            },
            UIMenu(title: session.t("tv_chat_side"), options: .displayInline, children: sides),
            UIMenu(title: session.t("tv_chat_height"), options: .displayInline, children: heights),
        ]
        // Réglages propres à cette chaîne : les garder partout, ou revenir au défaut.
        if session.hasOwnChatSettings(channel) {
            children.append(UIMenu(title: "", options: .displayInline, children: [
                UIAction(title: session.t("tv_chat_all")) { _ in
                    Task { @MainActor in session.makeDefaultChatLayout(from: channel) }
                },
                UIAction(title: session.t("tv_chat_reset")) { _ in
                    Task { @MainActor in session.resetChatSettings(for: channel) }
                },
            ]))
        }
        return UIMenu(title: session.t("tv_chat"),
                      image: UIImage(systemName: shown ? "bubble.left.and.bubble.right.fill"
                                                       : "bubble.left.and.bubble.right"),
                      children: children)
    }

    /// Libellé commun avec l'iPhone ; l'audio seul garde le texte de la TV.
    private func label(_ key: String) -> String {
        isAudioQuality(key) ? session.t("tv_audio") : qualityText(key, session.lang)
    }
}

// MARK: – Pause pub de la chaîne
/// Bandeau d'une pause pub cousue par Twitch (AdBreakWatcher), comme celui
/// du lecteur de l'iPhone (AdBreakBanner) : ce qu'est l'écran violet, et
/// dans combien de temps le direct revient. Rien hors pause ; jamais le
/// focus.
struct TVAdBreakBanner: View {
    @ObservedObject var watcher: AdBreakWatcher
    @ObservedObject var session: TVSession

    var body: some View {
        if let left = watcher.remaining {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Image(systemName: "megaphone.fill")
                    Text(session.t("ad_break_title"))
                }
                .font(.headline)
                Text(session.t("ad_break_sub").replacingOccurrences(of: "{n}", with: "\(left)"))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundColor(.white)
            .padding(.horizontal, 32).padding(.vertical, 20)
            .frame(maxWidth: 760, alignment: .leading)
            .background(Color.black.opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.tPurple.opacity(0.6), lineWidth: 2))
            .allowsHitTesting(false)
            .transition(.opacity)
            .accessibilityElement(children: .combine)
        }
    }
}
