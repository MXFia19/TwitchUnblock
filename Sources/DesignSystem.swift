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

// MARK: – Typographie
extension Font {
    /// Grand titre d'écran (en-tête de page).
    static let tScreenTitle = Font.system(size: 26, weight: .bold)
    /// Titre de section dans une page.
    static let tSection     = Font.system(size: 17, weight: .bold)
    /// Titre d'une carte / d'une ligne de liste.
    static let tCardTitle   = Font.system(size: 14, weight: .semibold)
    /// Texte courant.
    static let tBody        = Font.system(size: 14)
    /// Libellé de bouton ou de champ.
    static let tLabel       = Font.system(size: 13, weight: .semibold)
    /// Métadonnée secondaire (durée, vues, date…).
    static let tMeta        = Font.system(size: 12, weight: .medium)
    /// Pastille, badge, compteur.
    static let tBadge       = Font.system(size: 11, weight: .bold)
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
                .font(.system(size: 14, weight: .semibold))
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
                    Image(systemName: icon).font(.system(size: 13, weight: .bold))
                }
                Text(title).font(.tLabel)
            }
            .foregroundColor(.white)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.horizontal, fullWidth ? 0 : TSpace.lg)
            .frame(height: 44)
            .background(Color.tPrimary)
            .cornerRadius(TRadius.control)
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
                    Image(systemName: icon).font(.system(size: 13, weight: .bold))
                }
                Text(title).font(.tLabel)
            }
            .foregroundColor(tint)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.horizontal, fullWidth ? 0 : TSpace.lg)
            .frame(height: 44)
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
                .background(Color.tSurface)
                .clipShape(Circle())
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
                    Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                }
                Text(title).font(.tLabel).lineLimit(1)
            }
            .foregroundColor(isOn ? .white : .tMuted)
            .padding(.horizontal, TSpace.md)
            .frame(height: 32)
            .background(isOn ? Color.tPrimary : Color.tSurface)
            .cornerRadius(TRadius.chip)
        }
        .buttonStyle(.plain)
    }
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

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: TSpace.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(focused ? .tPrimary : .tMuted)

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
                        .font(.system(size: 15))
                        .foregroundColor(.tMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, TSpace.md)
        .frame(height: 44)
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

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 10))
            Text(text).font(.tMeta)
        }
        .foregroundColor(tint)
        .fixedSize()
    }
}

// MARK: – Bouton de pagination
struct TLoadMoreButton: View {
    let busy: Bool
    let action: () -> Void
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Button(action: action) {
            Group {
                if busy {
                    ProgressView().tint(.tPrimary)
                } else {
                    Text(store.t("load_more")).font(.tLabel).foregroundColor(.tPrimary)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(Color.tPrimary.opacity(0.12))
            .cornerRadius(TRadius.control)
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .padding(.horizontal, TSpace.lg)
        .padding(.top, TSpace.md)
    }
}
