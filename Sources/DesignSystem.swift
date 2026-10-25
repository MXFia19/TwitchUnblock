import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════
//  Socle visuel commun à toute l'app.
//
//  Avant, chaque écran redéfinissait ses tailles de police, ses marges et ses
//  cartes dans son coin : deux listes voisines n'avaient ni la même graisse de
//  titre ni le même rayon d'angle. Tout passe désormais par ces échelles.
//
//  Règle : un écran n'écrit plus `.font(.system(size: 13, weight: .bold))`,
//  il écrit `.font(.tCardTitle)`.
// ═══════════════════════════════════════════════════════════════════════════

// MARK: – Taille du texte d'iOS (Dynamic Type)
/// Taille du texte choisie dans iOS (Réglages → Luminosité et affichage →
/// Taille du texte, ou Accessibilité → Affichage et taille du texte),
/// appliquée aux polices de l'app.
///
/// Les tailles écrites dans l'app sont celles du réglage par défaut
/// (« Grand ») : `scaled` les fait grossir ou rétrécir comme le style de
/// texte d'iOS le plus proche, avec les paliers d'Apple. Plafond à
/// `maxSize` : au-delà, cartes et lignes ne tiennent plus.
///
/// SwiftUI ne fait pas suivre la taille du texte à `Font.system(size:)`.
/// La taille en cours est donc relevée par les racines (MainTabView,
/// `tTypeRoot()` des feuilles), au début de leur rendu, avant celui de leur
/// contenu ; quand elle change, elles refont ce contenu (comme pour un
/// changement de thème). Les commandes posées sur la vidéo et les pastilles
/// sur les miniatures gardent `Font.system(size:)`, à taille fixe.
enum TType {
    /// Plafond : « Accessibilité 2 » (le 9ᵉ cran sur 12).
    static let maxSize: DynamicTypeSize = .accessibility2
    /// Taille en cours, plafonnée.
    private(set) static var size: DynamicTypeSize = .large

    static func capped(_ s: DynamicTypeSize) -> DynamicTypeSize { min(s, maxSize) }

    /// Relevée par une racine : rend la taille plafonnée (clé de son contenu).
    @discardableResult
    static func adopt(_ s: DynamicTypeSize) -> DynamicTypeSize {
        let c = capped(s)
        if c != size { size = c }
        return c
    }

    /// Tailles d'accessibilité (les 5 derniers crans) : les mises en page
    /// serrées passent sur une colonne.
    static var isAccessibility: Bool { size.isAccessibilitySize }

    /// Points des styles de texte d'iOS, du plus petit cran (« Très petit »)
    /// au plus grand (« Accessibilité 5 »), le défaut (« Grand ») en 4ᵉ ;
    /// `upTo` : plus grande taille par défaut qui suit ce style.
    private static let curves: [(upTo: CGFloat, points: [CGFloat])] = [
        (11, [11, 11, 11, 11, 13, 15, 17, 20, 24, 29, 34, 40]),            // caption 2
        (12, [11, 11, 11, 12, 14, 16, 18, 22, 26, 32, 37, 43]),            // caption 1
        (13, [12, 12, 12, 13, 15, 17, 19, 23, 27, 33, 38, 44]),            // footnote
        (15, [12, 13, 14, 15, 17, 19, 21, 25, 30, 36, 42, 49]),            // subheadline
        (16, [13, 14, 15, 16, 18, 20, 22, 26, 32, 38, 44, 51]),            // callout
        (19, [14, 15, 16, 17, 19, 21, 23, 28, 33, 40, 47, 53]),            // body
        (21, [17, 18, 19, 20, 22, 24, 26, 31, 37, 43, 49, 55]),            // title 3
        (25, [19, 20, 21, 22, 24, 26, 28, 34, 39, 44, 50, 56]),            // title 2
        (31, [25, 26, 27, 28, 30, 32, 34, 38, 43, 48, 53, 58]),            // title 1
        (.infinity, [31, 32, 33, 34, 36, 38, 40, 44, 48, 52, 56, 60]),     // large title
    ]

    /// Crans dans l'ordre, du plus petit au plus grand.
    private static let order: [DynamicTypeSize] = DynamicTypeSize.allCases

    /// `base` points au réglage par défaut, à la taille du texte en cours.
    static func scaled(_ base: CGFloat) -> CGFloat {
        guard size != .large, base > 0,
              let i = order.firstIndex(of: size), let d = order.firstIndex(of: .large),
              let curve = curves.first(where: { base <= $0.upTo })?.points,
              curve.indices.contains(i), curve.indices.contains(d) else { return base }
        return base * curve[i] / curve[d]
    }

    /// Facteur de la taille en cours pour un texte de `base` points : de quoi
    /// agrandir une hauteur réservée à du texte.
    static func ratio(_ base: CGFloat) -> CGFloat { scaled(base) / base }

    /// Grille de cartes : deux colonnes sur iPhone, une seule aux tailles
    /// d'accessibilité (titres et pseudos y seraient coupés au bout de
    /// quelques lettres) ; davantage quand la largeur en tient plus (TGrid).
    /// `width` : largeur du contenu (`tContentWidth`), 0 si inconnue.
    static func cardColumns(width: CGFloat) -> [GridItem] {
        TGrid.columns(width: width,
                      minWidth: isAccessibility ? 2 * TGrid.cardMinWidth : TGrid.cardMinWidth,
                      base: isAccessibility ? 1 : 2,
                      alignment: .top)
    }
}

// MARK: – Grilles
/// Colonnes des grilles de cartes d'après la largeur du contenu
/// (`tContentWidth`) : celles d'un iPhone (`base`) jusqu'à ~440 pt, puis
/// autant que la largeur en tient. Sur l'écran intérieur de l'iPhone Duo ou
/// sur iPad, les cartes gardent à peu près leur taille d'iPhone au lieu de
/// grossir (deux colonnes de tuiles géantes).
enum TGrid {
    /// Largeur minimale d'une carte (aperçu 16:9, jaquette 3:4) : 2 par
    /// ligne sur tout iPhone, 3 sur l'écran intérieur de l'iPhone Duo en
    /// portrait (~670 pt), 4 en paysage.
    static let cardMinWidth: CGFloat = 165
    /// Jaquettes compactes des catégories suivies : 3 par ligne sur iPhone.
    static let compactMinWidth: CGFloat = 115
    /// Espace entre deux colonnes : celui d'un GridItem sans `spacing`.
    static let columnSpacing: CGFloat = 8

    /// Colonnes pour `width` points de contenu, marges de la page
    /// (TSpace.lg de chaque côté) comprises : au moins `base`, au plus
    /// `limit` (au-delà, les cartes grandissent). Largeur inconnue : `base`.
    static func count(width: CGFloat, minWidth: CGFloat, base: Int, limit: Int = 5) -> Int {
        let usable = width - 2 * TSpace.lg
        guard usable > 0, usable.isFinite, minWidth > 0 else { return base }
        let fit = Int((usable + columnSpacing) / (minWidth + columnSpacing))
        return min(max(base, fit), max(base, limit))
    }

    /// Autant de colonnes souples, toutes pareilles (`spacing` et
    /// `alignment` : ceux de la grille, nil pour ceux d'iOS).
    static func columns(width: CGFloat, minWidth: CGFloat, base: Int, limit: Int = 5,
                        spacing: CGFloat? = nil, alignment: Alignment? = nil) -> [GridItem] {
        let n = count(width: width, minWidth: minWidth, base: base, limit: limit)
        return Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: alignment), count: n)
    }
}

// MARK: – Largeur du contenu
private struct TContentWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// Largeur offerte au contenu d'un onglet ou d'une feuille, marges de
    /// sécurité et colonne d'onglets déduites (0 : pas encore mesurée).
    /// Les grilles en tirent leur nombre de colonnes (TGrid).
    var tContentWidth: CGFloat {
        get { self[TContentWidthKey.self] }
        set { self[TContentWidthKey.self] = newValue }
    }
}

/// Mesure la largeur de la vue et la donne à son contenu (tContentWidth).
/// `active` faux : largeur donnée pour inconnue (0), les grilles gardent
/// leurs colonnes d'iPhone (TGrid).
private struct TContentWidthReader: ViewModifier {
    let active: Bool
    @State private var width: CGFloat = 0

    init(active: Bool) { self.active = active }

    func body(content: Content) -> some View {
        content
            .environment(\.tContentWidth, active ? width : 0)
            .background(GeometryReader { geo in
                Color.clear
                    .onAppear { width = geo.size.width }
                    .onChange(of: geo.size.width) { width = $0 }
            })
    }
}

extension View {
    /// À poser sur la racine d'un onglet ou d'une feuille qui montre des
    /// grilles de cartes : leur nombre de colonnes suit sa largeur
    /// (rotation, pliage, Split View de l'iPad). `active` faux : colonnes
    /// d'iPhone, la mesure continue (TabScaffold, iPhone couché).
    func tMeasuresContentWidth(_ active: Bool = true) -> some View {
        modifier(TContentWidthReader(active: active))
    }
}

/// Racine d'une feuille : la taille du texte d'iOS (plafonnée) devient celle
/// des polices de l'app, et le contenu est refait quand elle change.
private struct TTypeRoot: ViewModifier {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        content
            .id(TType.adopt(dynamicTypeSize))
            .dynamicTypeSize(...TType.maxSize)
    }
}

extension View {
    /// À poser sur le contenu d'une feuille (voir TType).
    func tTypeRoot() -> some View { modifier(TTypeRoot()) }
}

// MARK: – Typographie
// Tailles du réglage par défaut d'iOS, qui suivent la taille du texte
// choisie (TType). Calculées à chaque rendu.
extension Font {
    /// Grand titre d'écran (en-tête de page).
    static var tScreenTitle: Font { .system(size: TType.scaled(26), weight: .bold) }
    /// Titre de section dans une page.
    static var tSection: Font     { .system(size: TType.scaled(17), weight: .bold) }
    /// Titre d'une carte / d'une ligne de liste.
    static var tCardTitle: Font   { .system(size: TType.scaled(14), weight: .semibold) }
    /// Texte courant.
    static var tBody: Font        { .system(size: TType.scaled(14)) }
    /// Libellé de bouton ou de champ.
    static var tLabel: Font       { .system(size: TType.scaled(13), weight: .semibold) }
    /// Métadonnée secondaire (durée, vues, date…).
    static var tMeta: Font        { .system(size: TType.scaled(12), weight: .medium) }
    /// Pastille, badge, compteur.
    static var tBadge: Font       { .system(size: TType.scaled(11), weight: .bold) }

    /// `Font.system(size:)` qui suit la taille du texte d'iOS : `size` est la
    /// taille au réglage par défaut.
    static func tSystem(size: CGFloat, weight: Font.Weight = .regular,
                        design: Font.Design = .default) -> Font {
        .system(size: TType.scaled(size), weight: weight, design: design)
    }
}

// MARK: – Espacements
enum TSpace {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    /// Marge latérale de référence : toutes les pages s'alignent dessus.
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
}

// MARK: – Rayons
enum TRadius {
    static let card: CGFloat    = 14
    static let control: CGFloat = 10
    static let chip: CGFloat    = 8
}

// MARK: – Surface de carte
extension View {
    /// Fond de carte standard (listes, réglages, encarts).
    func tCard(padding: CGFloat = TSpace.lg) -> some View {
        self.padding(padding)
            .background(Color.tCard)
            .cornerRadius(TRadius.card)
            .overlay(RoundedRectangle(cornerRadius: TRadius.card)
                .stroke(Color.tBorder.opacity(0.6), lineWidth: 1))
    }

    /// Fond de contrôle (champ de saisie, tuile cliquable).
    func tControlSurface(focused: Bool = false) -> some View {
        self.background(Color.tSurface)
            .cornerRadius(TRadius.control)
            .overlay(RoundedRectangle(cornerRadius: TRadius.control)
                .stroke(focused ? Color.tPrimary : Color.tBorder, lineWidth: 1))
    }
}

// MARK: – Titre de section
/// Titre d'une section de page, avec action optionnelle à droite.
struct TSectionHeader<Trailing: View>: View {
    let icon: String
    let title: String
    @ViewBuilder var trailing: Trailing

    init(_ title: String, icon: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.icon = icon
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: TSpace.sm) {
            Image(systemName: icon)
                .font(.tSystem(size: 14, weight: .semibold))
                .foregroundColor(.tPrimary)
            Text(title)
                .font(.tSection)
                .foregroundColor(.tText)
            Spacer(minLength: TSpace.sm)
            trailing
        }
        .padding(.horizontal, TSpace.lg)
    }
}

/// Variante sans action à droite. Init séparé plutôt qu'une valeur par défaut :
/// le type générique n'aurait rien pour être déduit à l'appel.
extension TSectionHeader where Trailing == EmptyView {
    init(_ title: String, icon: String) {
        self.init(title, icon: icon) { EmptyView() }
    }
}

// MARK: – Boutons
/// Bouton plein, action principale.
struct TPrimaryButton: View {
    let title: String
    var icon: String? = nil
    var fullWidth = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: TSpace.sm) {
                if let icon {
                    Image(systemName: icon).font(.tSystem(size: 13, weight: .bold))
                }
                Text(title).font(.tLabel).multilineTextAlignment(.center)
            }
            .foregroundColor(.white)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.horizontal, fullWidth ? 0 : TSpace.lg)
            // Hauteur minimale : avec un grand texte (réglage d'iOS), le
            // libellé passe sur deux lignes au lieu de déborder.
            .padding(.vertical, TSpace.xs)
            .frame(minHeight: 44)
            .tGlass(in: RoundedRectangle(cornerRadius: TRadius.control, style: .continuous),
                    fallback: .tPrimary, tint: .tPrimary)
        }
        .buttonStyle(.plain)
    }
}

/// Bouton contour, action secondaire.
struct TSecondaryButton: View {
    let title: String
    var icon: String? = nil
    var tint: Color = .tPrimary
    var fullWidth = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: TSpace.sm) {
                if let icon {
                    Image(systemName: icon).font(.tSystem(size: 13, weight: .bold))
                }
                Text(title).font(.tLabel).multilineTextAlignment(.center)
            }
            .foregroundColor(tint)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.horizontal, fullWidth ? 0 : TSpace.lg)
            .padding(.vertical, TSpace.xs)
            .frame(minHeight: 44)
            .background(tint.opacity(0.15))
            .cornerRadius(TRadius.control)
            .overlay(RoundedRectangle(cornerRadius: TRadius.control)
                .stroke(tint.opacity(0.8), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// Bouton icône rond (fermer, corbeille, réglage…).
struct TIconButton: View {
    let icon: String
    var tint: Color = .tMuted
    var size: CGFloat = 34
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: size, height: size)
                .tGlass(in: Circle(), fallback: .tSurface)
        }
        .buttonStyle(.plain)
    }
}

// MARK: – Pastille sélectionnable
struct TChip: View {
    let title: String
    var icon: String? = nil
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: TSpace.xs) {
                if let icon {
                    Image(systemName: icon).font(.tSystem(size: 11, weight: .semibold))
                }
                Text(title).font(.tLabel).lineLimit(1)
            }
            .foregroundColor(isOn ? .white : .tMuted)
            .padding(.horizontal, TSpace.md)
            .padding(.vertical, TSpace.xs)
            .frame(minHeight: 32)
            .background(isOn ? Color.tPrimary : Color.tSurface)
            .cornerRadius(TRadius.chip)
        }
        .buttonStyle(.plain)
    }
}

// MARK: – Contenu refait seulement quand sa clé change
/// À poser avec `.equatable()` : `content` n'est reconstruit que si `key`
/// change. iOS refait un menu ouvert (`Menu`, `Picker` en menu) à chaque
/// rendu de la vue qui le contient ; pendant une lecture, les écrans se
/// redessinent sans arrêt (position d'une VOD, durée du direct…), et une
/// longue liste comme les 34 langues du top remontait en haut à chaque fois :
/// impossible de la faire défiler. `key` réunit tout ce que le contenu
/// affiche (choix en cours, langue de l'interface, thème : `store.themeID`,
/// ses couleurs sont lues au rendu).
struct KeyedView<Content: View>: View, Equatable {
    let key: String
    let content: () -> Content

    init(key: String, @ViewBuilder content: @escaping () -> Content) {
        self.key = key
        self.content = content
    }

    var body: some View { content() }

    nonisolated static func == (lhs: KeyedView, rhs: KeyedView) -> Bool { lhs.key == rhs.key }
}

// MARK: – Sous-onglets (Streams / Catégories…)
struct TSegmented<Item: Hashable>: View {
    let items: [Item]
    @Binding var selection: Item
    let label: (Item) -> String

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.self) { item in
                let isOn = selection == item
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { selection = item }
                } label: {
                    VStack(spacing: 7) {
                        Text(label(item))
                            .font(.tCardTitle)
                            .foregroundColor(isOn ? .tText : .tMuted)
                            // Cinq onglets sur un iPhone étroit : un libellé
                            // un peu réduit plutôt que coupé sur deux lignes.
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        Rectangle()
                            .fill(isOn ? Color.tPrimary : .clear)
                            .frame(height: 2)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, TSpace.sm)
        .background(Color.tDark)
        .overlay(Divider().background(Color.tBorder), alignment: .bottom)
    }
}

// MARK: – Champ de recherche
struct TSearchField: View {
    @Binding var text: String
    let placeholder: String
    var submitLabel: SubmitLabel = .search
    var onSubmit: () -> Void = {}
    /// Recherche en cours : un indicateur à la place de la loupe.
    var busy = false

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: TSpace.sm) {
            if busy {
                ProgressView()
                    .tint(.tPrimary)
                    .scaleEffect(0.75)
                    .frame(width: 15, height: 15)
            } else {
                Image(systemName: "magnifyingglass")
                    .font(.tSystem(size: 14, weight: .semibold))
                    .foregroundColor(focused ? .tPrimary : .tMuted)
            }

            TextField(placeholder, text: $text)
                .font(.tBody)
                .foregroundColor(.tText)
                .focused($focused)
                .autocorrectionDisabled()
                .autocapitalization(.none)
                .submitLabel(submitLabel)
                .onSubmit(onSubmit)

            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.tSystem(size: 15))
                        .foregroundColor(.tMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, TSpace.md)
        .padding(.vertical, TSpace.xs)
        .frame(minHeight: 44)
        .tControlSurface(focused: focused)
    }
}

// MARK: – État vide
/// Message d'écran vide : dit ce qui manque ET quoi faire ensuite.
struct TEmptyState: View {
    let icon: String
    let title: String
    var message: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: TSpace.md) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .light))
                .foregroundColor(.tPrimary.opacity(0.7))
            Text(title)
                .font(.tCardTitle)
                .foregroundColor(.tText)
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(.tMeta)
                    .foregroundColor(.tMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let actionTitle, let action {
                TPrimaryButton(title: actionTitle, action: action)
                    .padding(.top, TSpace.xs)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, TSpace.xl)
        .padding(.vertical, TSpace.xl)
    }
}

// MARK: – Chargement
struct TLoader: View {
    var body: some View {
        ProgressView()
            .tint(.tPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, TSpace.xl)
    }
}

// MARK: – Badge de direct
struct TLiveBadge: View {
    var compact = false
    @EnvironmentObject private var store: AppStore

    var body: some View {
        HStack(spacing: TSpace.xs) {
            Circle().fill(Color.white).frame(width: 5, height: 5)
            Text(store.t("live_on"))
                .font(.system(size: compact ? 9 : 11, weight: .bold))
        }
        .foregroundColor(.white)
        .padding(.horizontal, compact ? 5 : 7)
        .padding(.vertical, compact ? 2 : 3)
        .background(Color.tLive)
        .cornerRadius(4)
        .fixedSize()
    }
}

// MARK: – Métadonnée avec icône (spectateurs, durée…)
struct TMeta: View {
    let icon: String
    let text: String
    var tint: Color = .tMuted
    /// Posée sur une image (spectateurs sur une miniature) : taille fixe,
    /// sinon un grand texte (réglage d'iOS) couvrirait l'image.
    var onImage = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(onImage ? Font.system(size: 10) : Font.tSystem(size: 10))
            Text(text).font(onImage ? Font.system(size: 12, weight: .medium) : Font.tMeta)
        }
        .foregroundColor(tint)
        .fixedSize()
    }
}

// MARK: – Bouton de pagination
struct TLoadMoreButton: View {
    let busy: Bool
    /// Clé de traduction du libellé (« Charger plus » par défaut).
    var titleKey = "load_more"
    let action: () -> Void
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Button(action: action) {
            Group {
                if busy {
                    ProgressView().tint(.tPrimary)
                } else {
                    Text(store.t(titleKey)).font(.tLabel).foregroundColor(.tPrimary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, TSpace.xs)
            .frame(minHeight: 44)
            .background(Color.tPrimary.opacity(0.12))
            .cornerRadius(TRadius.control)
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .padding(.horizontal, TSpace.lg)
        .padding(.top, TSpace.md)
    }
}

/// À la place de TLoadMoreButton quand Twitch refuse la suite d'une liste :
/// une ligne discrète qui dit pourquoi (`key` : clé de traduction).
struct TListEndNote: View {
    let key: String
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Text(store.t(key))
            .font(.tMeta).foregroundColor(.tMuted)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, TSpace.lg)
            .padding(.top, TSpace.sm)
    }
}

// MARK: – Carte de dialogue (style de l'app)
/// Remplace l'alerte système grise : carte sombre, icône dans un rond violet,
/// bouton principal plein et bouton secondaire discret. Un appui en dehors
/// vaut « Plus tard ».
struct TPromptCard: View {
    let icon: String
    let title: String
    let message: String
    var detail: String? = nil
    let primary: String
    var secondary: String? = nil
    let onPrimary: () -> Void
    var onSecondary: () -> Void = {}
    /// Troisième choix, plus discret (ex. « Ne plus afficher »).
    var tertiary: String? = nil
    var onTertiary: () -> Void = {}
    /// Liste à puces groupée (ex. nouveautés par version), défilable.
    var sections: [PromptSection] = []

    struct PromptSection: Identifiable {
        let title: String
        let items: [String]
        /// Identifiant propre (numéro de build) : deux builds de même version
        /// avaient le même titre, donc le même identifiant.
        var key: String? = nil
        var id: String { key ?? title }
    }

    /// Paysage sur iPhone : sans l'icône et avec une liste plus courte, la
    /// carte tient à l'écran (« Ouvrir » et « Plus tard » en sortaient).
    @Environment(\.verticalSizeClass) private var verticalSize

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .onTapGesture { onSecondary() }

            VStack(spacing: verticalSize == .compact ? 10 : 14) {
                if verticalSize != .compact {
                    ZStack {
                        Circle()
                            .fill(LinearGradient(colors: [Color.tPrimary, Color.tPurple],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 56, height: 56)
                        Image(systemName: icon)
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .padding(.top, 4)
                }

                Text(title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.tText)
                    .multilineTextAlignment(.center)

                if let detail {
                    Text(detail)
                        .font(.system(size: 13, weight: .bold).monospacedDigit())
                        .foregroundColor(.tPrimary)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Color.tPrimary.opacity(0.15))
                        .clipShape(Capsule())
                }

                Text(message)
                    .font(.system(size: 14))
                    .foregroundColor(.tMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if !sections.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(sections) { section in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(section.title)
                                        .font(.system(size: 12, weight: .bold).monospacedDigit())
                                        .foregroundColor(.tPrimary)
                                    ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                                            Text("•").foregroundColor(.tPrimary)
                                            Text(item)
                                                .foregroundColor(.tText)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                        .font(.system(size: 13))
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                    }
                    .frame(maxHeight: verticalSize == .compact ? 80 : 220)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(Color.tSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                VStack(spacing: 6) {
                    Button(action: onPrimary) {
                        Text(primary)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(Color.tPrimary)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    if let secondary {
                        Button(action: onSecondary) {
                            Text(secondary)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.tMuted)
                                .frame(maxWidth: .infinity)
                                .frame(height: 40)
                        }
                        .buttonStyle(.plain)
                    }
                    if let tertiary {
                        Button(action: onTertiary) {
                            Text(tertiary)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.tMuted.opacity(0.75))
                                .frame(maxWidth: .infinity)
                                .frame(height: 30)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 4)
            }
            .padding(22)
            .frame(maxWidth: 340)
            .background(Color.tCard)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.tPrimary.opacity(0.25), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
            .padding(.horizontal, 28)
            .transition(.scale(scale: 0.92).combined(with: .opacity))
        }
    }
}

// MARK: – Retour en glissant depuis le bord gauche
/// Nos navigations maison (pages des Réglages, catégorie ouverte, chaîne
/// ouverte depuis une recherche) ne passent pas par un UINavigationController :
/// pas de glissé d'iOS depuis le bord gauche, il fallait toucher Retour. Ce
/// geste le rend. Il ne part qu'à moins de 24 pt du bord gauche de la vue,
/// vers la droite et plus à l'horizontale qu'à la verticale ; simultané, il
/// laisse défiler les listes, et les gestes du lecteur, de Découvrir ou des
/// feuilles, posés sur d'autres vues, ne le reçoivent pas.
private struct EdgeSwipeBack: ViewModifier {
    let enabled: Bool
    /// La vue suit le doigt (une page posée sur ce qu'elle découvre).
    let follows: Bool
    let onBack: () -> Void

    struct Drag: Equatable {
        var dx: CGFloat = 0
        /// Sens décidé au premier mouvement : un défilement vertical ne
        /// devient pas un retour en cours de route.
        var decided = false
        var back = false
    }
    /// Remis à zéro, en douceur, quand le doigt se lève ou que le geste est
    /// interrompu (la vue revient en place).
    @GestureState(resetTransaction: Transaction(animation: .easeOut(duration: 0.2)))
    private var drag = Drag()

    func body(content: Content) -> some View {
        content
            .offset(x: follows ? drag.dx : 0)
            .simultaneousGesture(
                DragGesture(minimumDistance: 12)
                    .updating($drag) { value, state, _ in
                        if !state.decided {
                            state.decided = true
                            state.back = isEdgeBackSwipe(value)
                        }
                        if state.back { state.dx = max(0, value.translation.width) }
                    }
                    .onEnded { value in
                        // Assez loin, ou lancé : retour ; sinon la vue revient.
                        guard isEdgeBackSwipe(value),
                              value.translation.width > 100 || value.predictedEndTranslation.width > 240
                        else { return }
                        onBack()
                    },
                including: enabled ? GestureMask.all : GestureMask.subviews)
    }
}

/// Parti du bord gauche de la vue, vers la droite, plus à l'horizontale qu'à
/// la verticale.
private func isEdgeBackSwipe(_ value: DragGesture.Value) -> Bool {
    value.startLocation.x <= 24 && value.translation.width > abs(value.translation.height)
}

extension View {
    /// Retour par un glissé depuis le bord gauche (voir EdgeSwipeBack).
    /// `follows` : la vue suit le doigt ; `enabled` faux : pas de geste.
    func edgeSwipeBack(enabled: Bool = true, follows: Bool = true,
                       onBack: @escaping () -> Void) -> some View {
        modifier(EdgeSwipeBack(enabled: enabled, follows: follows, onBack: onBack))
    }
}
