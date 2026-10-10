import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════
//  Thèmes : couleur d'accent, fond, et verre liquide (iOS 26).
//
//  Les couleurs de l'app (`Color.tPrimary`, `.tDark`, `.tCard`…) lisent la
//  palette en cours à chaque affichage. Les réglages la remplacent ; les vues
//  se redessinent parce qu'elles observent l'AppStore, et MainTabView
//  reconstruit les onglets (`AppStore.themeID`) pour ne rien laisser en
//  retard.
// ═══════════════════════════════════════════════════════════════════════════

/// Couleur d'accent : boutons, onglet actif, liens.
enum AccentTheme: String, CaseIterable, Identifiable {
    case twitch, blue, green, pink, orange, red, teal
    var id: String { rawValue }
    /// Couleur principale, et sa version claire (textes mis en avant).
    var hex: (primary: String, light: String) {
        switch self {
        case .twitch: return ("9146ff", "bf94ff")
        case .blue:   return ("2f7cf6", "8ab8ff")
        case .green:  return ("10b981", "6ee7b7")
        case .pink:   return ("ec4899", "f9a8d4")
        case .orange: return ("f97316", "fdba74")
        case .red:    return ("e5484d", "ff9c9f")
        case .teal:   return ("06b6d4", "67e8f9")
        }
    }
    var color: Color { Color(hex: hex.primary) }
    var labelKey: String { "accent_\(rawValue)" }
}

/// Fond de l'app : sombre façon Twitch, noir complet (écrans OLED : les
/// pixels éteints ne consomment rien), ou ardoise.
enum BackgroundTheme: String, CaseIterable, Identifiable {
    case dark, oled, slate
    var id: String { rawValue }
    var hex: (dark: String, card: String, surface: String, border: String) {
        switch self {
        case .dark:  return ("0e0e10", "18181b", "26262c", "3a3a40")
        case .oled:  return ("000000", "0e0e10", "1c1c1f", "2e2e33")
        case .slate: return ("0f141c", "171e29", "232c3a", "35404f")
        }
    }
    var labelKey: String { "bg_\(rawValue)" }
}

struct Palette {
    let primary, light, dark, card, surface, border: Color

    init(accent: AccentTheme, background: BackgroundTheme) {
        primary = Color(hex: accent.hex.primary)
        light   = Color(hex: accent.hex.light)
        dark    = Color(hex: background.hex.dark)
        card    = Color(hex: background.hex.card)
        surface = Color(hex: background.hex.surface)
        border  = Color(hex: background.hex.border)
    }
}

/// Thème en cours, lu au lancement puis tenu à jour par l'AppStore.
enum Theme {
    static let accentKey = "cfg_accent"
    static let backgroundKey = "cfg_background"
    static let glassKey = "cfg_liquid_glass"

    static var storedAccent: AccentTheme {
        AccentTheme(rawValue: UserDefaults.standard.string(forKey: accentKey) ?? "") ?? .twitch
    }
    static var storedBackground: BackgroundTheme {
        BackgroundTheme(rawValue: UserDefaults.standard.string(forKey: backgroundKey) ?? "") ?? .dark
    }

    static var palette = Palette(accent: storedAccent, background: storedBackground)
    static var liquidGlass = UserDefaults.standard.bool(forKey: glassKey)

    /// Le verre liquide n'existe qu'à partir d'iOS 26.
    static var glassSupported: Bool {
        if #available(iOS 26, *) { return true }
        return false
    }
    /// Verre liquide à dessiner : option cochée, sur un système qui le connaît.
    static var useGlass: Bool { liquidGlass && glassSupported }
}

// MARK: – Verre liquide
/// Verre purement visuel, pas « interactif » : la réaction du verre interactif
/// au toucher ignore le test de touche des vues — elle s'allumait même quand
/// l'appui n'atteignait pas le bouton, qui ne faisait alors rien.
@available(iOS 26, *)
private func tuGlass(tint: Color?, clear: Bool) -> Glass {
    var g: Glass = clear ? .clear : .regular
    if let tint { g = g.tint(tint) }
    return g
}

extension View {
    /// Fond « verre liquide » (iOS 26) quand l'option est active ; sinon le
    /// fond plein d'avant, découpé à la même forme.
    /// - Parameter clear: verre plus transparent, pour les boutons posés sur
    ///   la vidéo.
    @ViewBuilder
    func tGlass<S: Shape>(in shape: S, fallback: Color, tint: Color? = nil,
                          clear: Bool = false) -> some View {
        if #available(iOS 26, *) {
            if Theme.useGlass {
                // `contentShape` : le verre, lui, ne reçoit pas les touchers.
                // Sans elle, seul le symbole d'un bouton répondait ; un appui
                // à côté traversait jusqu'au voile du lecteur, qui masquait
                // les commandes — boutons et retour à l'accueil inutilisables
                // pendant un live. Un fond plein, lui, comptait déjà.
                self.glassEffect(tuGlass(tint: tint, clear: clear), in: shape)
                    .contentShape(shape)
            } else {
                self.background(fallback).clipShape(shape)
            }
        } else {
            self.background(fallback).clipShape(shape)
        }
    }
}
