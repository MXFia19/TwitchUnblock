import SwiftUI

// MARK: – Synchro du chat avec la vidéo
//
// Les messages de l'IRC arrivent presque en temps réel, l'image du direct avec
// plusieurs secondes de retard : sans rien faire, le chat commente ce qu'on
// n'a pas encore vu. ChatService retient donc chaque message reçu jusqu'à son
// heure d'arrivée + le retard du chat.
//
// Mesure retenue : `onBehind` du lecteur (LiveSyncEstimator), notre retard sur
// le direct tel que le voient les autres spectateurs — ceux qui écrivent. Pas
// la latence affichée (`onLatency`, heure − horodatage du segment lu) : elle
// compte aussi le délai de publication de Twitch et celui que certaines
// chaînes ajoutent à leur diffusion, que tous les spectateurs subissent — le
// chat arrivait alors 10 s trop tard, ou plus. La mesure grandit d'elle-même
// quand la lecture cale ou recule, et baisse au retour vers le bord
// (« Direct », glissé de la barre, rattrapage du lecteur).
//
// Retard du chat = retard du lecteur − `reactionMargin` (+ la retouche des
// réglages), entre 0 et `maxDelay`. Aucun retard sans mesure : VOD (leur chat
// suit déjà la position), rembobinage par l'enregistrement (DVR), multi-live,
// chat seul. Tenu à jour par MainTabView, pour le lecteur principal seulement.
@MainActor
final class ChatSync: ObservableObject {
    static let shared = ChatSync()

    /// Temps de réaction moyen des autres spectateurs (s) : ils écrivent un
    /// instant après avoir vu l'image. Retiré du retard du lecteur, pour que
    /// leurs réactions tombent avec elle plutôt qu'après.
    static let reactionMargin: Double = 2
    /// Retard du chat maximal (s).
    static let maxDelay: Double = 60
    /// Mesures attendues toutes les 0,5 s (lecteur immersif) ou 1 s (natif).
    /// Sans nouvelle depuis ce délai, l'image est figée (calage, autre
    /// qualité qui charge) : son retard grandit avec l'heure…
    static let staleAfter: Double = 1.5
    /// … pendant ce temps au plus (s). Au-delà, ce n'est plus un calage
    /// (pause, lecture en échec) : retard inconnu, donc plus de retard.
    static let maxHold: Double = 15

    /// Dernière mesure (s) et son heure ; nil : pas de direct à suivre.
    private var measured: Double?
    private var measuredAt = Date.distantPast
    /// Mesure arrondie à la seconde, pour la pastille du chat : seule valeur
    /// publiée, la pastille ne se redessine qu'au changement de seconde.
    @Published private(set) var shownSeconds: Int?
    /// Dernière mesure écrite au journal.
    private var lastLogged: Double?

    private init() {}

    /// Mesure du lecteur principal, à chaque tick d'un direct. nil : pas de
    /// mesure à ce tick (bornes du direct pas encore connues) — la dernière
    /// vieillit alors comme pendant un calage.
    func update(_ behind: Double?) {
        guard let behind, behind.isFinite else { return }
        // Bornée : au-delà d'une heure, la mesure n'a plus de sens (horodatage
        // aberrant) et l'arrondi en entier doit rester possible.
        let value = min(max(0, behind), 3600)
        measured = value
        measuredAt = Date()
        let seconds = Int(value.rounded())
        if seconds != shownSeconds { shownSeconds = seconds }
        // Journal : les vrais changements seulement (calage, retour au
        // direct), pas le bruit de la mesure.
        if lastLogged.map({ abs($0 - value) >= 3 }) ?? true {
            lastLogged = value
            logger.debug("CHAT", "Synchro du chat", String(format: "%.0f s de retard", value))
        }
    }

    /// Plus de direct à suivre : VOD, enregistrement, chat seul, lecteur fermé.
    func reset() {
        guard measured != nil || shownSeconds != nil else { return }
        measured = nil
        shownSeconds = nil
        lastLogged = nil
    }

    /// Retard de l'image à l'instant `now` ; nil s'il est inconnu.
    func playerDelay(at now: Date) -> Double? {
        guard let measured else { return nil }
        let frozen = now.timeIntervalSince(measuredAt) - Self.staleAfter
        if frozen <= 0 { return measured }
        return frozen > Self.maxHold ? nil : measured + frozen
    }

    /// Retard du chat pour un retard de l'image (s) et la retouche des réglages.
    static func chatDelay(player: Double, nudge: Double) -> Double {
        min(maxDelay, max(0, player - reactionMargin + nudge))
    }
}

/// Pastille de la barre du chat quand un retard s'applique (« ⏱ −6 s »). Un
/// toucher coupe la synchro (chat en temps réel : la pastille reste, barrée)
/// ou la rallume ; un appui long retouche le retard d'une seconde.
struct ChatSyncBadge: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var sync = ChatSync.shared

    /// Retard du chat à afficher (s) ; nil : pas de pastille (rien à suivre,
    /// ou moins d'une seconde).
    private var seconds: Int? {
        guard let player = sync.shownSeconds else { return nil }
        let delay = Int(ChatSync.chatDelay(player: Double(player), nudge: store.chatSyncNudge).rounded())
        return delay >= 1 ? delay : nil
    }

    var body: some View {
        if let seconds {
            Button {
                store.chatSync.toggle()
                logger.settingChanged("Chat synchronisé avec la vidéo", value: store.chatSync ? "activé" : "désactivé")
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "timer").font(.system(size: 9, weight: .semibold))
                    Text(verbatim: "−\(seconds) s")
                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                        .strikethrough(!store.chatSync)
                }
                .foregroundColor(store.chatSync ? .tOutplayer : .tMuted)
                .fixedSize()
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background((store.chatSync ? Color.tOutplayer : Color.tMuted).opacity(0.15)).cornerRadius(6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(store.t(store.chatSync ? "chat_sync_on" : "chat_sync_off")
                .replacingOccurrences(of: "{s}", with: "\(seconds)"))
            .contextMenu {
                Section(store.t("chat_sync_hint")) {
                    Button { nudge(1) } label: {
                        Label(store.t("chat_sync_later"), systemImage: "plus.circle")
                    }
                    Button { nudge(-1) } label: {
                        Label(store.t("chat_sync_earlier"), systemImage: "minus.circle")
                    }
                    if store.chatSyncNudge != 0 {
                        Button { nudge(0) } label: {
                            Label(store.t("chat_sync_reset"), systemImage: "arrow.counterclockwise")
                        }
                    }
                }
            }
        }
    }

    /// Retouche du retard : ±1 s, ou 0 pour revenir à la mesure seule.
    private func nudge(_ step: Double) {
        let v = step == 0 ? 0 : min(20, max(-20, store.chatSyncNudge + step))
        store.chatSyncNudge = v
        logger.settingChanged("Retouche de la synchro du chat", value: String(format: "%+.0f s", v))
    }
}
