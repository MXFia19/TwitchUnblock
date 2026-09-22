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
    var onRewind:      () -> Void = {}
    var onBackToLive:  () -> Void = {}
    var onSleepTimer:  () -> Void = {}
    var onSettings:    () -> Void = {}

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

                    row(icon: "moon.zzz.fill", title: store.t("sleep_timer"),
                        action: onSleepTimer)
                    divider
                    row(icon: "gearshape.fill", title: store.t("settings"),
                        action: onSettings)
                }
                .padding(.vertical, TSpace.sm)
            }
        }
        .background(Color.tDark)
    }

    private func label(_ q: String) -> String {
        q.replacingOccurrences(of: "chunked", with: "Source")
         .replacingOccurrences(of: "source",  with: "Source")
    }

    private var divider: some View {
        Divider().background(Color.tBorder).padding(.leading, 56)
    }

    @ViewBuilder
    private func row(icon: String, title: String, detail: String? = nil,
                     tint: Color = .tPrimary, action: (() -> Void)? = nil) -> some View {
        let content = HStack(spacing: TSpace.md) {
            Image(systemName: icon)
                .font(.system(size: 15)).foregroundColor(tint).frame(width: 24)
            Text(title).font(.tCardTitle).foregroundColor(.tText)
            Spacer()
            if let detail {
                Text(detail).font(.tMeta).foregroundColor(.tMuted)
            }
            if action != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(.tMuted)
            }
        }
        .padding(.horizontal, TSpace.lg)
        .padding(.vertical, TSpace.md)
        .contentShape(Rectangle())

        if let action {
            Button(action: action) { content }.buttonStyle(.plain)
        } else {
            content
        }
    }
}
