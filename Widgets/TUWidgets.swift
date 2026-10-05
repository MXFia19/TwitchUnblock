import ActivityKit
import SwiftUI
import WidgetKit

// ═══════════════════════════════════════════════════════════════════════════
//  Extension TwitchUnblockWidgets : la Live Activity du lecteur, sur l'écran
//  verrouillé et dans la Dynamic Island. En plus de la fiche « à l'écoute »
//  d'iOS : badge EN DIRECT, spectateurs, durée du live, progression d'une VOD.
//
//  Une extension ne charge pas d'image distante et n'a pas le code de l'app :
//  tout ce qu'elle affiche arrive dans PlayerActivityAttributes (dossier
//  Shared), déjà mis en forme, et les couleurs sont redéfinies ici.
// ═══════════════════════════════════════════════════════════════════════════

@main
struct TUWidgetBundle: WidgetBundle {
    var body: some Widget {
        PlayerLiveActivity()
    }
}

/// Violet de l'app et rouge du direct.
private let purple  = Color(red: 0.57, green: 0.27, blue: 1)
private let liveRed = Color(red: 0.92, green: 0.10, blue: 0.20)

struct PlayerLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PlayerActivityAttributes.self) { context in
            LockScreenView(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.82))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let a = context.attributes
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Badge(attributes: a)
                        Text(a.channel).font(.headline).lineLimit(1)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TrailingInfo(attributes: a, state: s)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        if !s.title.isEmpty {
                            Text(s.title).font(.subheadline).lineLimit(2)
                        }
                        Footer(attributes: a, state: s)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                if a.isLive {
                    Circle().fill(liveRed).frame(width: 8, height: 8)
                } else {
                    Image(systemName: s.isPlaying ? "play.fill" : "pause.fill")
                        .foregroundColor(purple)
                }
            } compactTrailing: {
                if a.isLive {
                    Text(s.viewers.isEmpty ? "LIVE" : s.viewers)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                } else {
                    ElapsedText(state: s)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .frame(maxWidth: 56)
                }
            } minimal: {
                if a.isLive {
                    Circle().fill(liveRed).frame(width: 8, height: 8)
                } else {
                    Image(systemName: "play.tv.fill").foregroundColor(purple)
                }
            }
        }
    }
}

// MARK: – Écran verrouillé
private struct LockScreenView: View {
    let attributes: PlayerActivityAttributes
    let state: PlayerActivityAttributes.ContentState

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "play.tv.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .background(purple)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Badge(attributes: attributes)
                    Text(attributes.channel).font(.headline).lineLimit(1)
                    Spacer(minLength: 4)
                    TrailingInfo(attributes: attributes, state: state)
                }
                if !state.title.isEmpty {
                    Text(state.title).font(.subheadline).lineLimit(2)
                }
                Footer(attributes: attributes, state: state)
            }
        }
        .foregroundColor(.white)
        .padding(14)
    }
}

// MARK: – Briques
/// « EN DIRECT » en rouge, ou « VOD » en violet.
private struct Badge: View {
    let attributes: PlayerActivityAttributes

    var body: some View {
        Text(attributes.isLive ? attributes.liveLabel.uppercased() : "VOD")
            .font(.system(size: 10, weight: .heavy))
            .foregroundColor(.white)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(attributes.isLive ? liveRed : purple)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

/// À droite du nom : les spectateurs d'un direct, sinon l'état de la lecture.
private struct TrailingInfo: View {
    let attributes: PlayerActivityAttributes
    let state: PlayerActivityAttributes.ContentState

    var body: some View {
        if attributes.isLive, !state.viewers.isEmpty {
            Label(state.viewers, systemImage: "eye.fill")
                .font(.caption.monospacedDigit())
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)
        } else if !state.isPlaying {
            Image(systemName: "pause.fill")
                .font(.caption)
                .foregroundColor(.white.opacity(0.85))
        }
    }
}

/// Direct : catégorie et durée du live (qui défile seule). VOD : barre de
/// progression et temps écoulé / durée.
private struct Footer: View {
    let attributes: PlayerActivityAttributes
    let state: PlayerActivityAttributes.ContentState

    var body: some View {
        if attributes.isLive {
            HStack(spacing: 5) {
                if !state.game.isEmpty {
                    Image(systemName: "gamecontroller.fill").font(.caption2)
                    Text(state.game).lineLimit(1)
                }
                Spacer(minLength: 4)
                if let start = state.startedAt {
                    Text(start, style: .timer)
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 90, alignment: .trailing)
                }
            }
            .font(.caption)
            .foregroundColor(.white.opacity(0.75))
        } else if state.duration > 0 {
            VStack(spacing: 4) {
                ProgressBar(state: state)
                HStack {
                    ElapsedText(state: state)
                    Spacer(minLength: 4)
                    Text(clock(state.duration))
                }
                .font(.caption.monospacedDigit())
                .foregroundColor(.white.opacity(0.75))
            }
        }
    }
}

/// Barre d'une VOD : elle avance seule pendant la lecture (bornes en dates),
/// et reste figée en pause.
private struct ProgressBar: View {
    let state: PlayerActivityAttributes.ContentState

    var body: some View {
        if state.isPlaying, let start = state.startedAt {
            ProgressView(timerInterval: start...start.addingTimeInterval(max(state.duration, 1)),
                         countsDown: false) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .tint(purple)
        } else {
            ProgressView(value: min(max(state.position, 0), max(state.duration, 1)),
                         total: max(state.duration, 1))
                .tint(purple)
        }
    }
}

/// Temps écoulé d'une VOD : compteur qui tourne seul pendant la lecture.
private struct ElapsedText: View {
    let state: PlayerActivityAttributes.ContentState

    var body: some View {
        if state.isPlaying, let start = state.startedAt, state.duration > 0 {
            Text(timerInterval: start...start.addingTimeInterval(state.duration), countsDown: false)
        } else {
            Text(clock(state.position))
        }
    }
}

private func clock(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let t = Int(seconds), h = t / 3600, m = (t % 3600) / 60, s = t % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}
