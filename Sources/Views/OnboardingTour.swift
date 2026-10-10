import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════
//  Visite guidée du premier lancement, revue depuis Réglages → À propos
//  (« Revoir le tutoriel »).
//
//  Plutôt que des pages d'explication détachées de l'app, la visite se pose
//  sur les vrais écrans : un voile sombre percé autour de l'élément montré,
//  et une bulle qui l'explique. Elle change d'onglet d'elle-même et, aux
//  étapes « touche ici », c'est le vrai bouton, sous le voile, qui fait
//  avancer.
//
//  Chaque élément montré se signale avec `.tourAnchor(_:)` ; MainTabView
//  relève leurs positions et les passe à la visite.
// ═══════════════════════════════════════════════════════════════════════════

/// Éléments de l'interface que la visite sait montrer.
enum TourTarget: Hashable {
    case homeTabs, tabSearch, searchField, tabLibrary, settings
}

/// Position des éléments signalés, remontée jusqu'à MainTabView.
struct TourAnchorKey: PreferenceKey {
    static let defaultValue: [TourTarget: Anchor<CGRect>] = [:]
    static func reduce(value: inout [TourTarget: Anchor<CGRect>],
                       nextValue: () -> [TourTarget: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Signale cette vue à la visite guidée (nil : rien à signaler).
    func tourAnchor(_ target: TourTarget?) -> some View {
        anchorPreference(key: TourAnchorKey.self, value: .bounds) { anchor in
            guard let target else { return [:] }
            return [target: anchor]
        }
    }
}

/// Voile plein écran percé d'un rectangle arrondi (règle pair-impair).
private struct SpotlightShape: Shape {
    var hole: CGRect
    var radius: CGFloat = 14

    // Le trou glisse d'un élément à l'autre au lieu de sauter.
    var animatableData: CGRect.AnimatableData {
        get { hole.animatableData }
        set { hole.animatableData = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path(rect)
        if hole.width > 0, hole.height > 0 {
            p.addRoundedRect(in: hole, cornerSize: CGSize(width: radius, height: radius), style: .continuous)
        }
        return p
    }
}

struct OnboardingTour: View {
    /// Position de chaque élément signalé, en plein écran.
    let rects: [TourTarget: CGRect]
    let size: CGSize
    @Binding var activeTab: MainTabView.TabName
    let onFinish: () -> Void

    @EnvironmentObject private var store: AppStore
    @State private var step = 0
    /// Cible pas encore dessinée (l'onglet vient de changer) : on patiente un
    /// instant, puis la bulle se met au centre si elle manque toujours
    /// (accueil resté sur « Catégories », par exemple).
    @State private var waited = false

    private struct Step {
        var target: TourTarget? = nil
        /// Onglet affiché sous le voile pendant l'étape.
        var tab: MainTabView.TabName
        let icon: String
        let titleKey: String
        var textKey = ""
        /// Franchie en touchant le vrai bouton, sous le voile.
        var tapToContinue = false
    }

    private struct Tip: Identifiable {
        let icon: String
        let key: String
        var id: String { key }
    }

    private let steps: [Step] = [
        Step(tab: .home, icon: "play.tv.fill", titleKey: "ob_welcome_title", textKey: "ob_welcome_text"),
        Step(target: .homeTabs, tab: .home, icon: "dot.radiowaves.left.and.right",
             titleKey: "ob_home_title", textKey: "ob_home_text"),
        Step(target: .tabSearch, tab: .home, icon: "magnifyingglass",
             titleKey: "ob_searchtab_title", textKey: "ob_searchtab_text", tapToContinue: true),
        Step(target: .searchField, tab: .search, icon: "text.magnifyingglass",
             titleKey: "ob_search_title", textKey: "ob_search_text"),
        Step(target: .tabLibrary, tab: .search, icon: "clock.arrow.circlepath",
             titleKey: "ob_library_title", textKey: "ob_library_text", tapToContinue: true),
        Step(target: .settings, tab: .library, icon: "gearshape.fill",
             titleKey: "ob_settings_title", textKey: "ob_settings_text"),
        Step(tab: .home, icon: "play.rectangle.fill", titleKey: "ob_player_title"),
    ]

    /// Dernière étape : ce que réserve le lecteur.
    private let tips: [Tip] = [
        Tip(icon: "plus.magnifyingglass", key: "ob_tip_zoom"),
        Tip(icon: "slider.horizontal.3", key: "ob_tip_seek"),
        Tip(icon: "lock.fill", key: "ob_tip_lock"),
        Tip(icon: "pip", key: "ob_tip_more"),
    ]

    private var current: Step { steps[step] }
    private var isLast: Bool { step == steps.count - 1 }

    /// Trou du voile autour de la cible, si elle est à l'écran.
    private var hole: CGRect? {
        guard let target = current.target, let r = rects[target],
              r.width > 0, r.height > 0, r.maxY > 0, r.minY < size.height else { return nil }
        return r.insetBy(dx: -8, dy: -6)
    }

    /// Sans cible : un trou nul au centre, d'où grandira le suivant.
    private var noHole: CGRect {
        CGRect(x: size.width / 2, y: size.height / 2, width: 0, height: 0)
    }

    var body: some View {
        let hole = self.hole
        ZStack {
            SpotlightShape(hole: hole ?? noHole)
                .fill(Color.black.opacity(0.74), style: FillStyle(eoFill: true))
                // Aux étapes « touche ici », le doigt traverse le trou jusqu'au
                // vrai bouton ; ailleurs, le voile entier arrête les touchers.
                .contentShape(SpotlightShape(hole: current.tapToContinue ? (hole ?? noHole) : noHole),
                              eoFill: true)

            if let hole {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.tPrimary, lineWidth: 2)
                    .frame(width: hole.width, height: hole.height)
                    .position(x: hole.midX, y: hole.midY)
                    .allowsHitTesting(false)
                if current.tapToContinue {
                    pulseRing(hole.size)
                        .position(x: hole.midX, y: hole.midY)
                        .allowsHitTesting(false)
                }
                placed(around: hole) { bubble }
            } else if current.target == nil {
                centered { card }
            } else if waited {
                centered { bubble }
            }
        }
        .frame(width: size.width, height: size.height)
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: hole)
        .onAppear { go(0) }
        // Étape « touche ici » : le vrai bouton a changé d'onglet → suite.
        .onChange(of: activeTab) { tab in
            guard current.tapToContinue, step + 1 < steps.count, steps[step + 1].tab == tab else { return }
            go(step + 1)
        }
    }

    // MARK: – Placement
    /// Bulle sous la cible si celle-ci est en haut de l'écran, au-dessus sinon.
    @ViewBuilder
    private func placed<Content: View>(around hole: CGRect, @ViewBuilder content: () -> Content) -> some View {
        let below = hole.midY < size.height * 0.5
        VStack(spacing: 0) {
            if below {
                Color.clear.frame(height: hole.maxY + 12)
                content()
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
                content()
                Color.clear.frame(height: max(0, size.height - hole.minY + 12))
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            content()
            Spacer(minLength: 0)
        }
        .frame(width: size.width, height: size.height)
    }

    /// Onde autour du bouton à toucher. Pilotée par l'horloge plutôt que par
    /// une animation répétée, qui se figeait quand la cible se déplaçait.
    private func pulseRing(_ ring: CGSize) -> some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.3) / 1.3
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.tPrimary, lineWidth: 3)
                .frame(width: ring.width, height: ring.height)
                .scaleEffect(1 + 0.25 * t)
                .opacity(0.9 * (1 - t))
        }
    }

    // MARK: – Bulle d'une étape
    private var bubble: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                iconBadge(current.icon, diameter: 32)
                Text(store.t(current.titleKey))
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.tText)
                    .lineLimit(2)
                Spacer(minLength: 0)
                Text("\(step)/\(steps.count - 2)")
                    .font(.tMeta.monospacedDigit())
                    .foregroundColor(.tMuted)
            }
            Text(store.t(current.textKey))
                .font(.system(size: 14))
                .foregroundColor(.tText.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            if current.tapToContinue {
                Label(store.t("ob_tap_here"), systemImage: "hand.tap.fill")
                    .font(.tLabel)
                    .foregroundColor(.tPrimary)
            }
            HStack(spacing: 8) {
                Button(store.t("ob_skip")) { finish() }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.tMuted)
                Spacer(minLength: 0)
                Button { go(step - 1) } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.tText)
                        .frame(width: 38, height: 38)
                        .background(Color.tSurface)
                        .clipShape(Circle())
                }
                .accessibilityLabel(store.t("ob_back"))
                // Aux étapes « touche ici », « Suivant » fait ce qu'aurait fait
                // le bouton : l'étape suivante ouvre son onglet.
                Button { go(step + 1) } label: {
                    Text(store.t("ob_next"))
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 18)
                        .frame(height: 38)
                        .background(Color.tPrimary)
                        .clipShape(Capsule())
                }
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(maxWidth: 440, alignment: .leading)
        .background(Color.tCard)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .stroke(Color.tPrimary.opacity(0.35), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
        .padding(.horizontal, 16)
    }

    // MARK: – Cartes centrées (accueil, astuces du lecteur)
    private var card: some View {
        VStack(spacing: 16) {
            iconBadge(current.icon, diameter: 72)
                .shadow(color: Color.tPrimary.opacity(0.45), radius: 20, y: 6)
            Text(store.t(current.titleKey))
                .font(.system(size: 22, weight: .heavy))
                .foregroundColor(.tText)
                .multilineTextAlignment(.center)
            if isLast {
                tipsList
                primaryButton(store.t("ob_start")) { finish() }
            } else {
                Text(store.t(current.textKey))
                    .font(.system(size: 15))
                    .foregroundColor(.tMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                languagePicker
                primaryButton(store.t("ob_tour")) { go(step + 1) }
                Button(store.t("ob_skip")) { finish() }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.tMuted)
                    .buttonStyle(.plain)
            }
        }
        .padding(22)
        .frame(maxWidth: 400)
        .background(Color.tCard)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
            .stroke(Color.tPrimary.opacity(0.25), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
        .padding(.horizontal, 20)
    }

    /// La langue d'abord : toute la visite la suit aussitôt.
    private var languagePicker: some View {
        VStack(spacing: 6) {
            languageButtons
            // Traduction faite avec l'IA : dit dès le choix de la langue.
            if store.lang.machineTranslated {
                Text(store.t("lang_ai_note"))
                    .font(.tMeta).foregroundColor(.tMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var languageButtons: some View {
        HStack(spacing: 8) {
            ForEach(Lang.allCases) { l in
                let on = store.lang == l
                Button {
                    logger.settingChanged("Langue", value: l.rawValue)
                    store.lang = l
                } label: {
                    HStack(spacing: 5) {
                        Text(l.flag)
                        Text(l.label)
                            .font(.tLabel)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .foregroundColor(on ? .white : .tText)
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                    .background(on ? Color.tPrimary : Color.tSurface)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var tipsList: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(tips) { tip in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: tip.icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.tPrimary)
                        .frame(width: 22)
                    Text(store.t(tip.key))
                        .font(.system(size: 14))
                        .foregroundColor(.tText)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(14)
        .background(Color.tSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(Color.tPrimary)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func iconBadge(_ name: String, diameter: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [Color.tPrimary, Color.tPurple],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: name)
                .font(.system(size: diameter * 0.42, weight: .bold))
                .foregroundColor(.white)
        }
        .frame(width: diameter, height: diameter)
    }

    // MARK: – Navigation
    private func go(_ index: Int) {
        guard index >= 0 else { return }
        guard index < steps.count else { return finish() }
        waited = false
        withAnimation(.easeInOut(duration: 0.25)) {
            step = index
            if activeTab != steps[index].tab { activeTab = steps[index].tab }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            if step == index { waited = true }
        }
    }

    /// Fin ou « Passer » : retour à l'accueil, d'où l'on était parti.
    private func finish() {
        if activeTab != .home { activeTab = .home }
        onFinish()
    }
}
