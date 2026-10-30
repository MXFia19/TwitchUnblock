import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════
//  « Aller à une heure » d'une archive de direct : l'heure réelle de la
//  diffusion (22 h 15), changée en position dans la VOD. Menu ⋯ du lecteur
//  immersif ; le saut passe par .tuSeekTo.
// ═══════════════════════════════════════════════════════════════════════════

struct VodClockSheet: View {
    /// Début de la diffusion.
    let start: Date
    /// Durée de la VOD et position lue, en secondes.
    let duration: Double
    let position: Double
    let onGo: (Double) -> Void

    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var target = Date()

    private var end: Date { start.addingTimeInterval(max(duration, 1)) }
    /// Diffusion passée minuit : le jour se choisit aussi.
    private var spansDays: Bool { !Calendar.current.isDate(start, inSameDayAs: end) }

    var body: some View {
        VStack(spacing: TSpace.md) {
            HStack {
                Text(store.t("vod_goto_time")).font(.tSection).foregroundColor(.tText)
                Spacer()
                TIconButton(icon: "xmark") { dismiss() }
            }
            Text(store.t("vod_goto_time_sub")
                    .replacingOccurrences(of: "{a}", with: clock(start))
                    .replacingOccurrences(of: "{b}", with: clock(end)))
                .font(.tMeta).foregroundColor(.tMuted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            DatePicker("", selection: $target, in: start...end,
                       displayedComponents: spansDays ? [.date, .hourAndMinute] : [.hourAndMinute])
                .datePickerStyle(.wheel)
                .labelsHidden()
            Button {
                onGo(min(max(0, target.timeIntervalSince(start)), duration))
                dismiss()
            } label: {
                Text(store.t("vod_goto_btn"))
                    .font(.tLabel).foregroundColor(.white)
                    .frame(maxWidth: .infinity).frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: TRadius.card, style: .continuous)
                        .fill(Color.tPrimary))
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
        }
        .padding(TSpace.lg)
        .background(Color.tDark)
        .onAppear { target = min(end, start.addingTimeInterval(max(0, position))) }
    }

    private func clock(_ d: Date) -> String {
        spansDays ? d.formatted(date: .abbreviated, time: .shortened)
                  : d.formatted(date: .omitted, time: .shortened)
    }
}
