import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════
//  Disposition des onglets : l'en-tête, l'écran de l'onglet, et la barre
//  d'onglets — en bas sur iPhone, en colonne à gauche quand la fenêtre est
//  large (écran intérieur de l'iPhone Duo en paysage, iPad), pour laisser
//  toute la hauteur au contenu.
//
//  Structure à part, en-tête et écran effacés (AnyView) : le type de
//  MainTabView reste peu profond (iOS 18 plante au décodage d'un type de
//  vue trop imbriqué, voir SettingsView.sectionPage).
// ═══════════════════════════════════════════════════════════════════════════

struct TabScaffold: View {
    @Binding var activeTab: MainTabView.TabName
    /// Colonne d'onglets à gauche : tenue par MainTabView, qui place la
    /// mini-barre en conséquence ; mise à jour ici d'après la taille de la
    /// fenêtre (rotation, pliage, Split View).
    @Binding var sideTabs: Bool
    /// Marge haute de la fenêtre (MainTabView), comme l'en-tête.
    let safeTop: CGFloat
    let header: AnyView
    let content: AnyView

    @EnvironmentObject private var store: AppStore

    var body: some View {
        let glass = store.liquidGlass && Theme.glassSupported
        HStack(spacing: 0) {
            if sideTabs {
                SideTabRail(activeTab: $activeTab, safeTop: safeTop)
            }

            VStack(spacing: 0) {
                header
                    .zIndex(10)

                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Grilles de cartes : colonnes d'après la largeur de l'onglet.
                    .tMeasuresContentWidth()
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        bottomInset(glass: glass)
                    }

                if !sideTabs && !glass {
                    CustomTabBar(activeTab: $activeTab)
                }
            }
        }
        // Taille de la fenêtre, marges des côtés déduites : barre en bas ou
        // colonne à gauche.
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { update(geo.size, appearing: true) }
                .onChange(of: geo.size) { update($0) }
        })
        // Haut et bas : l'en-tête, la barre et la colonne posent eux-mêmes
        // leurs marges (encoche, indicateur d'accueil). Gauche et droite :
        // celles d'iOS, sinon la colonne d'état de l'iPhone Duo (écran
        // extérieur, écran intérieur en paysage) recouvrait l'avatar et les
        // cartes. Les fonds (barre, colonne, en-tête) vont jusqu'au bord.
        .ignoresSafeArea(edges: .vertical)
    }

    /// Bas de l'écran de l'onglet. Verre liquide (iOS 26) : la barre
    /// d'onglets flotte sur le contenu, qui défile dessous et transparaît à
    /// travers. Colonne à gauche : rien en bas, sauf l'indicateur d'accueil,
    /// au-dessus duquel s'arrêtent les listes.
    @ViewBuilder private func bottomInset(glass: Bool) -> some View {
        if sideTabs {
            Color.clear.frame(height: UIApplication.safeAreaBottom)
        } else if glass {
            CustomTabBar(activeTab: $activeTab, floating: true)
        }
    }

    /// Barre en bas ou colonne, d'après la taille mesurée. Le journal note
    /// chaque bascule, et l'affichage au-delà d'un iPhone (plus de 500 pt) :
    /// tailles et marges de l'iPhone Duo et de l'iPad, de quoi régler ces
    /// écrans d'après les journaux joints aux retours.
    private func update(_ size: CGSize, appearing: Bool = false) {
        let side = SideTabRail.fits(size)
        guard side != sideTabs || (appearing && size.width > 500) else { return }
        if side != sideTabs { sideTabs = side }
        logger.info("APP", side ? "Onglets en colonne à gauche" : "Onglets en bas",
                    "\(Int(size.width))×\(Int(size.height)) pt · marges \(Self.windowInsets)")
    }

    /// Marges de sécurité de la fenêtre (gauche/droite/haut/bas), pour le
    /// journal : celles de l'iPhone Duo ne sont connues que par lui.
    private static var windowInsets: String {
        let i = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first(where: { $0.isKeyWindow })?.safeAreaInsets ?? .zero
        return "\(Int(i.left))/\(Int(i.right))/\(Int(i.top))/\(Int(i.bottom))"
    }
}

// MARK: – Colonne d'onglets
/// Barre d'onglets posée à gauche quand la fenêtre est large : la hauteur
/// reste au contenu. Mêmes onglets, même ordre et mêmes réglages que la
/// barre du bas (Réglages → Personnaliser), tous pendant la visite guidée.
/// Ses onglets restent dans la zone sûre (après la marge de sécurité de
/// gauche) ; son fond va jusqu'au bord.
struct SideTabRail: View {
    @Binding var activeTab: MainTabView.TabName
    /// Marge haute de la fenêtre (barre d'état), comme l'en-tête.
    let safeTop: CGFloat
    @EnvironmentObject private var store: AppStore
    /// Visite guidée en cours : tous les onglets, même masqués.
    @AppStorage("onboarding_done") private var onboardingDone = false

    /// Largeur de la colonne (marge de sécurité non comprise) : la
    /// mini-barre se décale d'autant (MainTabView).
    static let width: CGFloat = 84

    /// Fenêtre assez large pour la colonne, marges des côtés déduites :
    /// 700 pt et plus (écran intérieur de l'iPhone Duo en paysage, iPad ;
    /// pas l'écran intérieur en portrait, ~670 pt). Un iPhone couché (moins
    /// de 500 pt de haut) garde la barre du bas.
    static func fits(_ size: CGSize) -> Bool {
        size.width >= 700 && size.height >= 500
    }

    /// Même règle d'après la fenêtre d'UIKit, avant la première mesure
    /// (TabScaffold) : l'iPad ne montre pas la barre du bas un instant au
    /// lancement. Pas de fenêtre encore : barre du bas.
    static var windowFits: Bool {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows ?? []
        guard let window = windows.first(where: { $0.isKeyWindow }) ?? windows.first else { return false }
        let insets = window.safeAreaInsets
        return fits(CGSize(width: window.bounds.width - insets.left - insets.right,
                           height: window.bounds.height))
    }

    var body: some View {
        if store.liquidGlass && Theme.glassSupported {
            // Verre liquide : une pastille flottante, comme la barre du bas.
            tabs
                .padding(.vertical, 8)
                .padding(.horizontal, 6)
                .tGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous), fallback: .tCard)
                .padding(.horizontal, 8)
                .padding(.top, safeTop + 8)
                .frame(width: Self.width)
                .frame(maxHeight: .infinity, alignment: .top)
        } else {
            tabs
                .padding(.horizontal, 6)
                .padding(.top, safeTop + 8)
                .frame(width: Self.width)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(.ultraThinMaterial)
                .overlay(alignment: .trailing) {
                    Color.tBorder.frame(width: 0.5)
                }
        }
    }

    private var tabs: some View {
        VStack(spacing: 6) {
            ForEach(MainTabView.TabName.visible(store, all: !onboardingDone), id: \.self) { tab in
                item(tab)
            }
        }
    }

    private func item(_ tab: MainTabView.TabName) -> some View {
        let isActive = activeTab == tab
        return Button {
            CustomTabBar.select(tab, in: $activeTab)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: isActive ? tab.iconFilled : tab.icon)
                    .font(.system(size: 19, weight: isActive ? .semibold : .regular))
                    .frame(height: 24)
                Text(tab.label(store))
                    .font(.system(size: 11, weight: isActive ? .semibold : .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .foregroundColor(isActive ? .tPrimary : .tMuted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isActive ? Color.tPrimary.opacity(0.14) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.label(store))
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
        .tourAnchor(tab.tourTarget)
    }
}
