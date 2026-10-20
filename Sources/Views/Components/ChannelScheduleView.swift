import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════
//  Planning d'une chaîne (onglet « Planning » de sa page) : ses prochains
//  lives au jour et à l'heure de l'appareil, avec leur durée, leur titre,
//  leur catégorie et les créneaux répétés chaque semaine ; ses vacances en
//  tête. L'onglet n'apparaît que si la chaîne a un planning, et le bandeau
//  d'une chaîne hors ligne en reprend le prochain live (scheduleHeadline).
// ═══════════════════════════════════════════════════════════════════════════

/// Jour d'un créneau dans la langue de l'app : « aujourd'hui », « demain »,
/// « mardi » dans la semaine, « mardi 28 oct. » au-delà.
func scheduleDay(_ date: Date, store: AppStore) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(date) { return store.t("sched_today") }
    if cal.isDateInTomorrow(date) { return store.t("sched_tomorrow") }
    let df = DateFormatter()
    df.locale = Locale(identifier: store.lang.rawValue)
    df.setLocalizedDateFormatFromTemplate(date.timeIntervalSinceNow < 6 * 86400 ? "EEEE" : "EEEE d MMM")
    return df.string(from: date)
}

/// Heure d'un créneau, en 12 h ou 24 h selon le réglage de l'heure.
func scheduleTime(_ date: Date, store: AppStore) -> String {
    let df = DateFormatter()
    df.locale = Locale(identifier: store.lang.rawValue)
    df.dateFormat = ClockFormat.pattern(twelve: store.clock12h)
    return df.string(from: date)
}

/// Ligne du bandeau d'une chaîne hors ligne : ses vacances en cours, sinon
/// « Prochain live : mardi · 20:00 ». nil sans rien de prévu.
func scheduleHeadline(_ schedule: ChannelSchedule, store: AppStore) -> (icon: String, text: String)? {
    let now = Date()
    if let v = schedule.activeVacation(at: now), v.start <= now {
        return (icon: "airplane", text: vacationText(v, store: store))
    }
    guard let next = schedule.next(at: now) else { return nil }
    let when = "\(scheduleDay(next.start, store: store)) · \(scheduleTime(next.start, store: store))"
    return (icon: "calendar", text: store.t("sched_next").replacingOccurrences(of: "{d}", with: when))
}

/// « En vacances jusqu'au 28 oct. », ou « du 20 oct. au 28 oct. » à venir.
func vacationText(_ v: ScheduleVacation, store: AppStore) -> String {
    let df = DateFormatter()
    df.locale = Locale(identifier: store.lang.rawValue)
    df.setLocalizedDateFormatFromTemplate("d MMM")
    if v.start <= Date() {
        return store.t("sched_vacation_until").replacingOccurrences(of: "{d}", with: df.string(from: v.end))
    }
    return store.t("sched_vacation_range")
        .replacingOccurrences(of: "{a}", with: df.string(from: v.start))
        .replacingOccurrences(of: "{b}", with: df.string(from: v.end))
}

// MARK: – Onglet « Planning »
struct ChannelScheduleView: View {
    let schedule: ChannelSchedule
    @EnvironmentObject private var store: AppStore

    var body: some View {
        let now = Date()
        // Vingt créneaux au plus : quatre semaines d'un planning chargé.
        let segments = Array(schedule.upcoming(at: now).prefix(20))
        VStack(alignment: .leading, spacing: TSpace.md) {
            if let v = schedule.activeVacation(at: now) {
                HStack(spacing: TSpace.sm) {
                    Image(systemName: "airplane")
                        .font(.system(size: 14, weight: .semibold))
                    Text(vacationText(v, store: store))
                        .font(.tLabel)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .foregroundColor(.tPrimary)
                .tCard(padding: TSpace.md)
                .padding(.horizontal, TSpace.lg)
            }

            if segments.isEmpty {
                TEmptyState(icon: "calendar", title: store.t("sched_none"))
            } else {
                VStack(spacing: 0) {
                    ForEach(segments) { segment in
                        ScheduleSegmentRow(segment: segment)
                        if segment.id != segments.last?.id {
                            Divider().background(Color.tBorder).padding(.leading, 68)
                        }
                    }
                }
                .background(Color.tCard)
                .cornerRadius(TRadius.card)
                .padding(.horizontal, TSpace.lg)

                // Le streamer annonce ses heures dans son fuseau : elles sont
                // converties, on le dit une fois.
                Label(store.t("sched_local_hint"), systemImage: "clock")
                    .font(.tMeta)
                    .foregroundColor(.tMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, TSpace.lg)
            }
        }
    }
}

/// Un créneau : le jour façon calendrier, puis titre, heures et durée,
/// catégorie, répétition ou annulation.
private struct ScheduleSegmentRow: View {
    let segment: ScheduleSegment
    @EnvironmentObject private var store: AppStore

    private func format(_ template: String) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: store.lang.rawValue)
        df.setLocalizedDateFormatFromTemplate(template)
        return df.string(from: segment.start)
    }

    /// Titre du créneau ; sans titre, sa catégorie, sinon « Live prévu ».
    private var title: String {
        if !segment.title.isEmpty { return segment.title }
        return segment.category.isEmpty ? store.t("sched_untitled") : segment.category
    }

    /// « Mardi · 20:00 – 23:00 · 3 h » ; sans fin connue, l'heure de début.
    private var when: String {
        let day = scheduleDay(segment.start, store: store)
        let dayText = day.prefix(1).uppercased() + String(day.dropFirst())
        var text = "\(dayText) · \(scheduleTime(segment.start, store: store))"
        guard let end = segment.end, end > segment.start else { return text }
        let minutes = Int(end.timeIntervalSince(segment.start) / 60)
        let h = minutes / 60, m = minutes % 60
        var length = "\(h) \(store.t("hour"))"
        if h == 0 {
            length = "\(m) \(store.t("min"))"
        } else if m > 0 {
            length += " " + String(format: "%02d", m)
        }
        text += " – \(scheduleTime(end, store: store)) · \(length)"
        return text
    }

    var body: some View {
        HStack(alignment: .top, spacing: TSpace.md) {
            VStack(spacing: 1) {
                Text(format("EEE").uppercased())
                    .font(.tBadge)
                    .foregroundColor(.tPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(format("d"))
                    .font(.system(size: 19, weight: .bold).monospacedDigit())
                    .foregroundColor(.tText)
            }
            .frame(width: 44, height: 48)
            .background(Color.tSurface)
            .cornerRadius(TRadius.chip)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .strikethrough(segment.canceled)
                    .font(.tCardTitle)
                    .foregroundColor(.tText)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text(when)
                    .font(.tMeta)
                    .foregroundColor(.tMuted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                // Catégorie sous le titre, si le titre n'est pas déjà elle.
                if !segment.category.isEmpty, title != segment.category {
                    HStack(spacing: 4) {
                        Image(systemName: "gamecontroller.fill").font(.system(size: 10))
                        Text(segment.category).font(.tMeta).lineLimit(1)
                    }
                    .foregroundColor(.tPurple)
                }
                if segment.recurring || segment.canceled {
                    HStack(spacing: TSpace.sm) {
                        if segment.recurring {
                            TMeta(icon: "repeat", text: store.t("sched_weekly"))
                        }
                        if segment.canceled {
                            TMeta(icon: "xmark.circle", text: store.t("sched_canceled"), tint: .tDanger)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(TSpace.md)
        .opacity(segment.canceled ? 0.6 : 1)
    }
}
