import SwiftUI

/// Réglage rapide du minuteur de veille, depuis le lecteur.
/// (Le même minuteur est aussi réglable depuis les Réglages.)
struct SleepTimerSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var timer = SleepTimerService.shared

    private let columns = [GridItem(.adaptive(minimum: 90), spacing: 10)]

    var body: some View {
        VStack(spacing: 0) {

            // ── En-tête ─────────────────────────────────────────────
            HStack(spacing: 8) {
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 15)).foregroundColor(.tPurple)
                Text(store.t("sleep_timer"))
                    .font(.system(size: 16, weight: .bold)).foregroundColor(.tText)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .bold))
                        .foregroundColor(.tMuted).frame(width: 30, height: 30)
                        .background(Color.tSurface).clipShape(Circle())
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(Color.tCard)
            Divider().background(Color.tBorder)

            VStack(spacing: 16) {
                if timer.isActive {
                    VStack(spacing: 4) {
                        Text(store.t("sleep_remaining"))
                            .font(.system(size: 12)).foregroundColor(.tMuted)
                        Text(timer.label)
                            .font(.system(size: 40, weight: .heavy).monospacedDigit())
                            .foregroundColor(.tPurple)
                    }
                    .padding(.top, 8)
                } else {
                    Text(store.t("sleep_timer_sub"))
                        .font(.system(size: 13)).foregroundColor(.tMuted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 12)
                }

                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(SleepTimerService.presets, id: \.self) { m in
                        Button { timer.start(minutes: m) } label: {
                            Text(presetLabel(m))
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.tText)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.tSurface)
                                .cornerRadius(10)
                                .overlay(RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.tBorder, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }

                if timer.isActive {
                    HStack(spacing: 10) {
                        Button { timer.add(minutes: 15) } label: {
                            Text(store.t("sleep_add"))
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.tPrimary)
                                .frame(maxWidth: .infinity).padding(.vertical, 12)
                                .background(Color.tPrimary.opacity(0.15))
                                .cornerRadius(10)
                                .overlay(RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.tPrimary, lineWidth: 1))
                        }
                        Button {
                            timer.cancel()
                            dismiss()
                        } label: {
                            Text(store.t("sleep_cancel"))
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.tDanger)
                                .frame(maxWidth: .infinity).padding(.vertical, 12)
                                .background(Color.tDanger.opacity(0.15))
                                .cornerRadius(10)
                                .overlay(RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.tDanger, lineWidth: 1))
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(16)
        }
        .background(Color.tDark)
    }

    private func presetLabel(_ minutes: Int) -> String {
        switch minutes {
        case 60:  return store.t("sleep_hour")
        case 120: return store.t("sleep_2hours")
        default:  return "\(minutes) \(store.t("sleep_minutes"))"
        }
    }
}
