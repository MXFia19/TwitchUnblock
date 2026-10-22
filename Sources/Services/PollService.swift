import Foundation
import SwiftUI

// MARK: – Sondages du développeur
//
// Comme les annonces : lancé depuis /stats ou avec /poll sur Discord, gardé
// par le Worker. Vote anonyme par appareil (même identifiant que les
// réactions), modifiable jusqu'à la fin ; résultats montrés après avoir
// voté, et à tous une fois fini (24 h). Relu à l'ouverture et au retour au
// premier plan (au plus toutes les 5 min), affiché sous l'annonce.
@MainActor
final class PollService: ObservableObject {
    static let shared = PollService()

    struct Poll: Equatable, Identifiable {
        let id: String
        let question: String
        let options: [String]
        let multi: Bool
        let until: Date
        let ended: Bool
    }
    struct Results: Equatable {
        let counts: [Int]
        let voters: Int
    }

    @Published private(set) var poll: Poll? = nil
    /// Choix de cet appareil (vide : pas encore voté).
    @Published private(set) var mine: [Int] = []
    /// Montrés après le vote, ou à tous une fois fini.
    @Published private(set) var results: Results? = nil
    @Published private(set) var sending = false
    /// Clé du message après un échec (vote non envoyé, sondage fini).
    @Published private(set) var notice: String? = nil

    private let dismissedKey = "poll_dismissed"
    private var lastFetch: Date? = nil

    func refresh(force: Bool = false) async {
        if !force, let lastFetch, Date().timeIntervalSince(lastFetch) < 5 * 60 { return }
        let r = await post("/api/poll", ["device": UsageService.shared.installId])
        guard r.status == 200, let json = r.json else { return }
        lastFetch = Date()
        apply(json)
    }

    /// Un seul choix : celui touché ; plusieurs : ceux cochés.
    func vote(_ choices: [Int]) async {
        guard let p = poll, !sending else { return }
        sending = true
        notice = nil
        defer { sending = false }
        let r = await post("/api/poll/vote", ["device": UsageService.shared.installId,
                                              "pollId": p.id, "choices": choices])
        if r.status == 410 {
            // Fini entre-temps : résultats finaux relus.
            notice = "poll_closed"
            await refresh(force: true)
        } else if r.status == 200, let json = r.json {
            apply(json)
        } else {
            notice = "poll_failed"
        }
    }

    /// ✕ : ce sondage ne revient plus (un nouveau, si).
    func dismiss() {
        guard let p = poll else { return }
        var ids = UserDefaults.standard.stringArray(forKey: dismissedKey) ?? []
        ids.append(p.id)
        UserDefaults.standard.set(Array(ids.suffix(20)), forKey: dismissedKey)
        withAnimation { poll = nil }
    }

    private func apply(_ json: [String: Any]) {
        guard let p = json["poll"] as? [String: Any], let id = p["id"] as? String,
              let untilMs = p["until"] as? Double,
              !(UserDefaults.standard.stringArray(forKey: dismissedKey) ?? []).contains(id) else {
            poll = nil; mine = []; results = nil
            return
        }
        if poll?.id != id { notice = nil }
        poll = Poll(id: id,
                    question: p["question"] as? String ?? "",
                    options: p["options"] as? [String] ?? [],
                    multi: p["multi"] as? Bool ?? false,
                    until: Date(timeIntervalSince1970: untilMs / 1000),
                    ended: p["ended"] as? Bool ?? false)
        mine = json["mine"] as? [Int] ?? []
        results = (json["results"] as? [String: Any]).map {
            Results(counts: $0["counts"] as? [Int] ?? [], voters: $0["voters"] as? Int ?? 0)
        }
    }

    private func post(_ path: String, _ body: [String: Any]) async -> (json: [String: Any]?, status: Int) {
        guard let url = URL(string: "\(APIConfig.base)\(path)") else { return (nil, 0) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return (nil, 0) }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

/// Carte du sondage, sous l'annonce, dans le même style.
struct DevPollCard: View {
    let poll: PollService.Poll
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var service = PollService.shared
    /// Plusieurs choix : cochés, pas encore envoyés.
    @State private var picks: Set<Int>? = nil
    /// « Changer mon vote » : choix rouverts.
    @State private var editing = false

    private var ended: Bool { poll.ended || poll.until <= Date() }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [Color.tPrimary, Color.tPurple],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 38, height: 38)
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(poll.question)
                    .font(.tCardTitle).foregroundColor(.tText)
                    .fixedSize(horizontal: false, vertical: true)
                if let r = service.results, ended || (!service.mine.isEmpty && !editing) {
                    resultsView(r)
                } else {
                    choicesView
                }
                if let n = service.notice {
                    Text(store.t(n)).font(.tMeta).foregroundColor(.tLive)
                }
            }
            Spacer(minLength: 0)
            Button { service.dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.tMuted)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(Color.tPrimary.opacity(0.10))
        .background(Color.tCard)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(Color.tPrimary.opacity(0.45), lineWidth: 1))
        .transition(.opacity.combined(with: .move(edge: .top)))
        // Sondage suivant : on repart de zéro.
        .onChange(of: poll.id) { _ in
            picks = nil
            editing = false
        }
    }

    private var choicesView: some View {
        let chosen = picks ?? Set(service.mine)
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(poll.options.enumerated()), id: \.offset) { i, option in
                let on = chosen.contains(i)
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    if poll.multi {
                        var next = chosen
                        if on { next.remove(i) } else { next.insert(i) }
                        picks = next
                    } else {
                        Task { await send([i]) }
                    }
                } label: {
                    HStack(spacing: 8) {
                        if poll.multi {
                            Image(systemName: on ? "checkmark.square.fill" : "square")
                                .font(.tSystem(size: 16))
                                .foregroundColor(on ? .tPrimary : .tMuted)
                        }
                        Text(option)
                            .font(.tSystem(size: 14)).foregroundColor(.tText)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(minHeight: 38)
                    .background(on ? Color.tPrimary.opacity(0.22) : Color.tSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(on ? Color.tPrimary : Color.tBorder, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(service.sending)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            Text("\(store.t(poll.multi ? "poll_multi_hint" : "poll_single_hint")) · \(untilText)")
                .font(.tMeta).foregroundColor(.tMuted)
            if poll.multi {
                Button { Task { await send(chosen.sorted()) } } label: {
                    Text(store.t("poll_vote"))
                        .font(.tSystem(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(Color.tPrimary)
                        .clipShape(Capsule())
                        .opacity(chosen.isEmpty || service.sending ? 0.5 : 1)
                }
                .buttonStyle(.plain)
                .disabled(chosen.isEmpty || service.sending)
            }
        }
    }

    private func resultsView(_ r: PollService.Results) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(poll.options.enumerated()), id: \.offset) { i, option in
                let count = i < r.counts.count ? r.counts[i] : 0
                let share = r.voters > 0 ? Double(count) / Double(r.voters) : 0
                let chosen = service.mine.contains(i)
                HStack(spacing: 6) {
                    if chosen {
                        Image(systemName: "checkmark")
                            .font(.tSystem(size: 11, weight: .bold)).foregroundColor(.tPrimary)
                    }
                    Text(option)
                        .font(.tSystem(size: 14)).foregroundColor(.tText)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 6)
                    Text("\(Int((share * 100).rounded()))%")
                        .font(.tSystem(size: 13, weight: .bold).monospacedDigit()).foregroundColor(.tText)
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .frame(minHeight: 34)
                .background(alignment: .leading) {
                    GeometryReader { geo in
                        Rectangle()
                            .fill(Color.tPrimary.opacity(chosen ? 0.34 : 0.18))
                            .frame(width: geo.size.width * share)
                    }
                }
                .background(Color.tSurface)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            HStack(spacing: 4) {
                Text("\(store.t(r.voters == 1 ? "poll_voter" : "poll_voters").replacingOccurrences(of: "{n}", with: "\(r.voters)")) · \(ended ? store.t("poll_ended") : untilText)")
                    .font(.tMeta).foregroundColor(.tMuted)
                if !ended {
                    Button(store.t("poll_change")) {
                        editing = true
                        picks = nil
                    }
                    .font(.tMeta.weight(.semibold))
                    .foregroundColor(.tPrimary)
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// « fin dans 3 h », dans la langue de l'app.
    private var untilText: String {
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 1
        f.allowedUnits = [.day, .hour, .minute]
        var cal = Calendar.current
        cal.locale = Locale(identifier: store.lang.rawValue)
        f.calendar = cal
        let left = f.string(from: max(60, poll.until.timeIntervalSinceNow)) ?? ""
        return store.t("poll_until").replacingOccurrences(of: "{time}", with: left)
    }

    private func send(_ choices: [Int]) async {
        await service.vote(choices)
        if service.notice == nil {
            picks = nil
            editing = false
        }
    }
}
