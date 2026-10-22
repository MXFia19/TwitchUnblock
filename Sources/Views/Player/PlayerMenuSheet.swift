import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════
//  Menu « ⋯ » du lecteur immersif : ce que la barre en surimpression ne peut
//  pas porter sans encombrer l'image.
// ═══════════════════════════════════════════════════════════════════════════

struct PlayerMenuSheet: View {
    let qualities: [String]
    let selected: String
    let canRewind: Bool
    /// On regarde déjà le DVR d'un direct : proposer le retour au direct.
    let isDvr: Bool

    var onSelectQuality: (String) -> Void = { _ in }
    /// Vitesse de lecture en cours ; nil masque la section (direct).
    var speed: Double? = nil
    var onSelectSpeed: (Double) -> Void = { _ in }
    var onRewind:      () -> Void = {}
    var onBackToLive:  () -> Void = {}
    var onSleepTimer:  () -> Void = {}
    var onSettings:    () -> Void = {}
    /// Signaler un problème : le formulaire, avec ce qui se lit.
    var onFeedback:    () -> Void = {}
    /// Direct : source qui sert le flux (« as », « al »…) ; nil hors direct.
    var liveSource: String? = nil
    /// Changer de source : le direct est relancé par elle.
    var onSelectSource: ((String) -> Void)? = nil
    /// VOD : télécharger un passage pour le regarder hors ligne.
    var onDownload: (() -> Void)? = nil
    /// Direct ou VOD (pas le rembobinage) : l'ajouter au multi-live (ou
    /// l'en retirer). Mêmes libellés pour les deux.
    var onMultiLive: (() -> Void)? = nil
    var multiLiveOn = false
    var multiLiveFull = false
    /// Partager ce qui se lit : la VOD (ou le rembobinage) à la position en
    /// cours, la chaîne d'un direct, le lien d'un clip. nil : rien à partager
    /// (VOD retrouvée, téléchargement).
    var shareURL: URL? = nil
    /// Position partagée d'une VOD (« 1:02:03 »), à droite de la ligne.
    var shareDetail: String? = nil
    /// Direct (pas son rembobinage) : en créer un clip.
    var onCreateClip: (() -> Void)? = nil

    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(store.t("player_section")).font(.tSection).foregroundColor(.tText)
                Spacer()
                TIconButton(icon: "xmark") { dismiss() }
            }
            .padding(TSpace.lg)

            Divider().background(Color.tBorder)

            ScrollView {
                VStack(spacing: 0) {

                    // Qualité : le lecteur immersif n'a pas de sélecteur à l'écran,
                    // c'est ici qu'on change de piste.
                    if !qualities.isEmpty {
                        HStack(spacing: TSpace.md) {
                            Image(systemName: "film")
                                .font(.system(size: 15)).foregroundColor(.tPrimary)
                                .frame(width: 24)
                            Text(store.t("quality")).font(.tCardTitle).foregroundColor(.tText)
                            Spacer()
                        }
                        .padding(.horizontal, TSpace.lg)
                        .padding(.top, TSpace.md)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: TSpace.sm) {
                                ForEach(qualities, id: \.self) { q in
                                    TChip(title: label(q), isOn: q == selected) {
                                        onSelectQuality(q)
                                    }
                                }
                            }
                            .padding(.horizontal, TSpace.lg)
                        }
                        .padding(.vertical, TSpace.sm)

                        divider
                    }

                    // Vitesse : VODs et clips. Un direct reste à 1×.
                    if let speed {
                        HStack(spacing: TSpace.md) {
                            Image(systemName: "speedometer")
                                .font(.system(size: 15)).foregroundColor(.tPrimary)
                                .frame(width: 24)
                            Text(store.t("speed")).font(.tCardTitle).foregroundColor(.tText)
                            Spacer()
                        }
                        .padding(.horizontal, TSpace.lg)
                        .padding(.top, TSpace.md)

                        ScrollViewReader { proxy in
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: TSpace.sm) {
                                    ForEach(VodSpeed.all, id: \.self) { s in
                                        TChip(title: s == 1 ? store.t("speed_normal") : VodSpeed.label(s, store.lang),
                                              isOn: abs(s - speed) < 0.01) {
                                            onSelectSpeed(s)
                                        }
                                        .id(s)
                                    }
                                    // Au-delà de 2× : expérimental (éprouvette),
                                    // séparé des crans garantis par un trait.
                                    Rectangle().fill(Color.tBorder).frame(width: 1, height: 20)
                                    ForEach(VodSpeed.experimental, id: \.self) { s in
                                        TChip(title: VodSpeed.label(s, store.lang), icon: "testtube.2",
                                              isOn: abs(s - speed) < 0.01) {
                                            onSelectSpeed(s)
                                        }
                                        .id(s)
                                        .accessibilityLabel(VodSpeed.label(s, store.lang) + ", " + store.t("speed_experimental"))
                                    }
                                }
                                .padding(.horizontal, TSpace.lg)
                            }
                            // Les crans lents sont à gauche : la vitesse en
                            // cours (souvent « Normale ») reste en vue.
                            .onAppear { proxy.scrollTo(VodSpeed.nearest(speed), anchor: .center) }
                        }
                        .padding(.top, TSpace.sm)

                        Text(store.t("speed_experimental_note"))
                            .font(.tMeta).foregroundColor(.tMuted)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, TSpace.lg)
                            .padding(.top, TSpace.xs)
                            .padding(.bottom, TSpace.sm)

                        divider
                    }

                    // Source du direct : le proxy qui sert le flux, et de quoi
                    // en changer (le direct repart aussitôt).
                    if let onSelectSource, let used = liveSource {
                        HStack(spacing: TSpace.md) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 15)).foregroundColor(.tPrimary)
                                .frame(width: 24)
                            Text(store.t("live_source")).font(.tCardTitle).foregroundColor(.tText)
                            Spacer()
                            Text(store.t("src_\(used)")).font(.tMeta).foregroundColor(.tMuted)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, TSpace.lg)
                        .padding(.top, TSpace.md)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: TSpace.sm) {
                                // Dans l'ordre des réglages ; en choisir une la met en tête.
                                // Cochée : celle qui sert le flux (la première de
                                // l'ordre a pu ne pas répondre). Lecture par le
                                // compte ou par le Worker : aucune, l'en-tête la
                                // nomme ; en choisir une quitte le compte pour
                                // cette chaîne.
                                ForEach(store.liveSourceOrder, id: \.self) { id in
                                    TChip(title: store.t("src_\(id)"), isOn: id == used) {
                                        onSelectSource(id)
                                    }
                                }
                            }
                            .padding(.horizontal, TSpace.lg)
                        }
                        .padding(.vertical, TSpace.sm)

                        divider
                    }

                    if isDvr {
                        row(icon: "dot.radiowaves.left.and.right",
                            title: store.t("back_to_live"),
                            tint: .tLive, action: onBackToLive)
                        divider
                    } else if canRewind {
                        row(icon: "gobackward", title: store.t("rewind"),
                            detail: store.t("rewind_sub"), action: onRewind)
                        divider
                    }

                    if let onDownload {
                        row(icon: "arrow.down.circle", title: store.t("dl_download"),
                            detail: store.t("dl_download_sub"), action: onDownload)
                        divider
                    }

                    if let onMultiLive {
                        row(icon: multiLiveOn ? "minus.square" : "square.grid.2x2",
                            title: store.t(multiLiveOn ? "multi_remove" : "multi_add"),
                            detail: store.t(multiLiveFull && !multiLiveOn ? "multi_full" : "multi_add_sub"),
                            action: onMultiLive)
                        divider
                    }

                    // Feuille de partage d'iOS, par-dessus ce menu.
                    if let shareURL {
                        ShareLink(item: shareURL) {
                            rowLabel(icon: "square.and.arrow.up", title: store.t("share"),
                                     detail: shareDetail, tint: .tPrimary, chevron: true)
                        }
                        .buttonStyle(.plain)
                        divider
                    }

                    if let onCreateClip {
                        row(icon: "scissors", title: store.t("clip_create"), action: onCreateClip)
                        divider
                    }

                    row(icon: "moon.zzz.fill", title: store.t("sleep_timer"),
                        action: onSleepTimer)
                    divider
                    row(icon: "gearshape.fill", title: store.t("settings"),
                        action: onSettings)
                    divider
                    row(icon: "ladybug.fill", title: store.t("report_problem"),
                        tint: .tLive, action: onFeedback)
                }
                .padding(.vertical, TSpace.sm)
            }
        }
        .background(Color.tDark)
    }

    private func label(_ q: String) -> String { qualityText(q, store.lang) }

    private var divider: some View {
        Divider().background(Color.tBorder).padding(.leading, 56)
    }

    @ViewBuilder
    private func row(icon: String, title: String, detail: String? = nil,
                     tint: Color = .tPrimary, action: (() -> Void)? = nil) -> some View {
        let content = rowLabel(icon: icon, title: title, detail: detail, tint: tint,
                               chevron: action != nil)
        if let action {
            Button(action: action) { content }.buttonStyle(.plain)
        } else {
            content
        }
    }

    /// Contenu d'une ligne (aussi celui du lien de partage).
    private func rowLabel(icon: String, title: String, detail: String?,
                          tint: Color, chevron: Bool) -> some View {
        HStack(spacing: TSpace.md) {
            Image(systemName: icon)
                .font(.system(size: 15)).foregroundColor(tint).frame(width: 24)
            Text(title).font(.tCardTitle).foregroundColor(.tText)
            Spacer()
            if let detail {
                Text(detail).font(.tMeta).foregroundColor(.tMuted)
            }
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(.tMuted)
            }
        }
        .padding(.horizontal, TSpace.lg)
        .padding(.vertical, TSpace.md)
        .contentShape(Rectangle())
    }
}
