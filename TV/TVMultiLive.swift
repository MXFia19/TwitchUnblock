import SwiftUI
import AVFoundation

// ═══════════════════════════════════════════════════════════════════════════
//  Multi-live sur Apple TV (demande de Slowie, 06/11) : jusqu'à 4 directs
//  côte à côte. Bouton central maintenu sur la carte d'un direct → « Ajouter
//  au multi-live » ; le bandeau « Multi-live (n/4) » en haut des listes
//  l'ouvre. Même cœur que l'iPhone (MultiLive.swift : liste gardée, qualité
//  selon le nombre de tuiles, pauses pub, relances, retour du réseau).
//  Le son suit la tuile qui a le focus ; Sélection l'agrandit (encore une
//  fois, ou Menu : retour à la mosaïque) ; Menu ferme le multi-live.
// ═══════════════════════════════════════════════════════════════════════════

/// Ouverture du multi-live depuis n'importe quel onglet (TVRootView le présente).
@MainActor
final class TVMultiRoute: ObservableObject {
    static let shared = TVMultiRoute()
    @Published var open = false

    /// Après la fermeture d'un menu contextuel : présenté pendant qu'il se
    /// referme, l'écran risquerait de ne pas s'afficher (comme le lecteur).
    func openSoon() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            open = true
        }
    }
}

/// Bandeau au-dessus des listes de directs, dès qu'une chaîne est choisie :
/// ouvrir le multi-live, ou vider la liste.
struct TVMultiLiveBar: View {
    @EnvironmentObject private var session: TVSession
    @ObservedObject private var multi = MultiLive.shared

    var body: some View {
        if !multi.entries.isEmpty {
            HStack(spacing: 32) {
                Button {
                    TVMultiRoute.shared.open = true
                } label: {
                    Label("\(session.t("multi_title")) (\(multi.entries.count)/\(MultiLive.max))",
                          systemImage: "rectangle.split.2x2")
                }
                Text(multi.entries.map(\.displayName).joined(separator: " · "))
                    .font(.callout).foregroundColor(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                Button(session.t("tv_multi_clear")) { multi.clear() }
            }
            .padding(.horizontal, 64)
            .padding(.top, 24)
            .focusSection()
        }
    }
}

/// Entrées du menu d'une carte de direct (bouton central maintenu).
struct TVMultiLiveMenuItems: View {
    let login: String
    let name: String
    @EnvironmentObject private var session: TVSession
    @ObservedObject private var multi = MultiLive.shared

    var body: some View {
        if multi.contains(login) {
            Button {
                multi.remove(login)
            } label: {
                Label(session.t("multi_remove"), systemImage: "minus.rectangle")
            }
        } else if multi.isFull {
            Button {} label: {
                Label(session.t("multi_full"), systemImage: "rectangle.split.2x2")
            }
            .disabled(true)
        } else {
            Button {
                multi.add(login, name: name)
            } label: {
                Label(session.t("multi_add"), systemImage: "plus.rectangle.on.rectangle")
            }
        }
        // Déjà au moins une autre chaîne : l'ouvrir d'ici, avec celle-ci.
        if !multi.entries.isEmpty, !(multi.entries.count == 1 && multi.contains(login)) {
            Button {
                if !multi.contains(login) { multi.add(login, name: name) }
                TVMultiRoute.shared.openSoon()
            } label: {
                Label(session.t("multi_watch") + " · " + session.t("multi_title"), systemImage: "play.rectangle")
            }
        }
    }
}

/// Repère sur la carte d'un direct choisi pour le multi-live.
struct TVMultiLiveMark: View {
    let login: String
    @ObservedObject private var multi = MultiLive.shared

    var body: some View {
        if multi.contains(login) {
            Image(systemName: "rectangle.split.2x2.fill")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.tPurple)
                .cornerRadius(4)
        }
    }
}

// MARK: – Écran

struct TVMultiLiveScreen: View {
    @EnvironmentObject private var session: TVSession
    @ObservedObject private var multi = MultiLive.shared
    @StateObject private var model = MultiLiveSession()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var focused: String?
    /// Tuile agrandie (Sélection) ; nil : la mosaïque. Les autres continuent,
    /// sans le son, hors de l'écran.
    @State private var zoomed: String?
    @State private var showHint = true

    /// Directs seulement : l'Apple TV n'ajoute pas de VOD (une VOD ajoutée sur
    /// une autre version garderait sinon une tuile sans commandes).
    private var entries: [MultiLiveEntry] { multi.entries.filter { !$0.isVod } }

    private var shown: [MultiLiveEntry] {
        if let zoomed, let entry = entries.first(where: { $0.id == zoomed }) { return [entry] }
        return entries
    }

    var body: some View {
        GeometryReader { geo in
            let list = shown
            let frames = Self.frames(count: list.count, in: geo.size)
            ZStack {
                Color.black
                ForEach(Array(list.enumerated()), id: \.element.id) { index, entry in
                    if let tile = model.tiles[entry.id], index < frames.count {
                        tileButton(entry, tile)
                            .frame(width: frames[index].width, height: frames[index].height)
                            .position(x: frames[index].midX, y: frames[index].midY)
                    }
                }
                if showHint {
                    Text(session.t("tv_multi_hint"))
                        .font(.callout)
                        .padding(.horizontal, 28).padding(.vertical, 14)
                        .background(.ultraThinMaterial, in: Capsule())
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 48)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
        }
        .ignoresSafeArea()
        .defaultFocus($focused, entries.first?.id)
        .onAppear { model.sync(entries) }
        .onDisappear { model.stopAll() }
        .onChange(of: multi.entries) { _ in
            let now = entries
            if now.isEmpty { dismiss(); return }
            if let zoomed, !now.contains(where: { $0.id == zoomed }) { self.zoomed = nil }
            model.sync(now)
        }
        // Le son suit la tuile qui a le focus (une seule l'a).
        .onChange(of: focused) { id in if let id { model.select(id) } }
        .onChange(of: scenePhase) { model.sceneChanged($0) }
        .onReceive(NotificationCenter.default.publisher(for: .tuNetworkRestored)) { _ in model.networkRestored() }
        .onExitCommand {
            if let zoomed {
                self.zoomed = nil
                focused = zoomed
            } else {
                dismiss()
            }
        }
        .task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            withAnimation { showHint = false }
        }
    }

    private func tileButton(_ entry: MultiLiveEntry, _ tile: MultiTileModel) -> some View {
        Button {
            switch tile.phase {
            case .failed, .offline: tile.retry()
            default: zoomed = zoomed == entry.id ? nil : entry.id
            }
            focused = entry.id
        } label: {
            TVMultiTileView(model: tile, adBreaks: tile.adBreaks, name: entry.displayName,
                            audible: model.audible == entry.id)
        }
        .buttonStyle(TVMultiTileStyle())
        .focused($focused, equals: entry.id)
        .contextMenu {
            Button(role: .destructive) {
                multi.remove(id: entry.id)
            } label: {
                Label(session.t("multi_remove"), systemImage: "minus.rectangle")
            }
        }
    }

    /// Cadres des tuiles, en 16:9 : une seule en grand ; deux côte à côte ;
    /// trois, la première en grand à gauche et deux l'une sur l'autre à
    /// droite (comme l'iPhone) ; quatre en 2 × 2.
    static func frames(count: Int, in size: CGSize) -> [CGRect] {
        let w = size.width, h = size.height, gap: CGFloat = 12
        func fit(_ r: CGRect) -> CGRect {
            let scale = max(0, min(r.width / 16, r.height / 9))
            let fw = 16 * scale, fh = 9 * scale
            return CGRect(x: r.midX - fw / 2, y: r.midY - fh / 2, width: fw, height: fh)
        }
        switch count {
        case ...1:
            return [fit(CGRect(x: 0, y: 0, width: w, height: h))]
        case 2:
            let half = (w - gap) / 2
            return [fit(CGRect(x: 0, y: 0, width: half, height: h)),
                    fit(CGRect(x: half + gap, y: 0, width: half, height: h))]
        case 3:
            let bigW = (w - gap) * 2 / 3, smallW = w - gap - bigW
            let big = fit(CGRect(x: 0, y: 0, width: bigW, height: h))
            let smallH = (big.height - gap) / 2
            return [big,
                    fit(CGRect(x: bigW + gap, y: big.minY, width: smallW, height: smallH)),
                    fit(CGRect(x: bigW + gap, y: big.minY + smallH + gap, width: smallW, height: smallH))]
        default:
            let cw = (w - gap) / 2, ch = (h - gap) / 2
            return [fit(CGRect(x: 0, y: 0, width: cw, height: ch)),
                    fit(CGRect(x: cw + gap, y: 0, width: cw, height: ch)),
                    fit(CGRect(x: 0, y: ch + gap, width: cw, height: ch)),
                    fit(CGRect(x: cw + gap, y: ch + gap, width: cw, height: ch))]
        }
    }
}

/// Tuile : l'image, un cadre blanc quand elle a le focus, son nom, le son, la
/// pause pub et l'état (chargement, hors ligne, échec).
struct TVMultiTileView: View {
    @ObservedObject var model: MultiTileModel
    @ObservedObject var adBreaks: AdBreakWatcher
    let name: String
    let audible: Bool
    @EnvironmentObject private var session: TVSession
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        ZStack {
            Color.black
            TVPlayerLayerView(player: model.player)
            state
            VStack {
                HStack {
                    if let left = adBreaks.remaining {
                        Text(session.t("ad_break_short").replacingOccurrences(of: "{n}", with: "\(left)"))
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Color.black.opacity(0.7))
                            .cornerRadius(8)
                    }
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    Image(systemName: audible ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    Text(name).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(.callout.weight(.semibold))
                .shadow(color: .black.opacity(0.8), radius: 4)
            }
            .foregroundColor(.white)
            .padding(16)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
                    .stroke(isFocused ? Color.white : Color.clear, lineWidth: 6))
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }

    @ViewBuilder private var state: some View {
        switch model.phase {
        case .loading:
            ProgressView()
        case .playing:
            if model.buffering { ProgressView() }
        case .offline:
            message(session.t("multi_offline"))
        case .failed:
            message(session.t("multi_failed") + "\n" + session.t("multi_retry"))
        case .ended:
            message(session.t("multi_offline"))
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .multilineTextAlignment(.center)
            .foregroundColor(.white)
            .padding(24)
    }
}

/// Bouton de tuile sans le soulèvement des cartes : le cadre de la tuile
/// montre le focus.
struct TVMultiTileStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// Image d'un AVPlayer, sans commandes ni interaction (la tuile est le bouton).
final class TVPlayerLayerHost: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct TVPlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> TVPlayerLayerHost {
        let v = TVPlayerLayerHost()
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        v.playerLayer.videoGravity = .resizeAspect
        v.playerLayer.player = player
        return v
    }

    func updateUIView(_ uiView: TVPlayerLayerHost, context: Context) {
        if uiView.playerLayer.player !== player { uiView.playerLayer.player = player }
    }
}
