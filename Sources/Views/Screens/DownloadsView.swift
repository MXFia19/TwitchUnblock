import SwiftUI
import UIKit
import UserNotifications

// ═══════════════════════════════════════════════════════════════════════════
//  Téléchargement d'une VOD (ou d'un passage) pour la regarder hors ligne :
//  la feuille de choix (menu ⋯ du lecteur) et la ligne de « Mes VODs ».
// ═══════════════════════════════════════════════════════════════════════════

/// « 1:02:03 », ou « 2:03 » sous l'heure.
func dlClock(_ seconds: Double) -> String {
    let t = max(0, Int(seconds.rounded()))
    let h = t / 3600, m = (t % 3600) / 60, s = t % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

private func dlBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

// MARK: – Choix du passage
struct VodDownloadSheet: View {
    let context: VodDownloadContext

    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var quality = ""
    @State private var vodDuration: Double = 0
    @State private var bytesPerSecond: Double? = nil
    @State private var loading = false
    @State private var failed = false
    @State private var start: Double = 0
    @State private var end: Double = 0
    @State private var restore = true
    @State private var withChat = true

    private var qualities: [String] { sortQualities(Array(context.links.keys), variants: context.variants) }

    /// La qualité préférée (ou la plus proche en dessous), comme à la
    /// lecture, mais 720p au plus et jamais l'audio seul : « Source » (le
    /// réglage par défaut) pèse 2 à 3 fois plus lourd, et un « Audio seul »
    /// choisi une fois dans le lecteur téléchargeait la VOD sans image.
    private var defaultQuality: String {
        let pref = String(min(Int(store.preferredQuality) ?? 720, 720))
        return preferredQualityKey(qualities, pref: pref, variants: context.variants)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(store.t("dl_title")).font(.tSection).foregroundColor(.tText)
                Spacer()
                TIconButton(icon: "xmark") { dismiss() }
            }
            .padding(TSpace.lg)

            Divider().background(Color.tBorder)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(context.title)
                        .font(.tCardTitle).foregroundColor(.tText)
                        .lineLimit(2)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(store.t("quality")).font(.tMeta).foregroundColor(.tMuted)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: TSpace.sm) {
                                ForEach(qualities, id: \.self) { q in
                                    TChip(title: label(q), isOn: q == quality) { quality = q }
                                }
                            }
                        }
                    }

                    if loading {
                        ProgressView().tint(.tPrimary).frame(maxWidth: .infinity)
                    } else if failed {
                        Text(store.t("dl_error")).font(.tMeta).foregroundColor(.tLive)
                    } else if vodDuration >= 20 {
                        rangeControls
                        summary
                        Toggle(isOn: $restore) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(store.t("dl_restore")).font(.tCardTitle).foregroundColor(.tText)
                                Text(store.t("dl_restore_sub"))
                                    .font(.tMeta).foregroundColor(.tMuted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .tint(.tPrimary)

                        // Une VOD supprimée retrouvée n'a plus de chat.
                        if VodDownloads.hasChat(context.vodId) {
                            Toggle(isOn: $withChat) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(store.t("dl_chat")).font(.tCardTitle).foregroundColor(.tText)
                                    Text(store.t("dl_chat_sub"))
                                        .font(.tMeta).foregroundColor(.tMuted)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .tint(.tPrimary)
                        }

                        TPrimaryButton(title: store.t("dl_download"), icon: "arrow.down.circle.fill", fullWidth: true) {
                            VodDownloads.shared.start(context, quality: quality, start: start.rounded(.down),
                                                      end: end.rounded(.up), restoreAudio: restore,
                                                      withChat: withChat)
                            // Prévenir à la fin du téléchargement.
                            Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) }
                            dismiss()
                        }
                    }

                    Text(store.t("dl_note").replacingOccurrences(of: "{tab}", with: store.t("tab_library")))
                        .font(.tMeta).foregroundColor(.tMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(TSpace.lg)
            }
        }
        .background(Color.tDark)
        .onAppear { if quality.isEmpty { quality = defaultQuality } }
        .task(id: quality) { await loadInfo() }
    }

    // MARK: Passage
    /// Au moins 10 s entre le début et la fin : déplacer l'un pousse l'autre.
    @ViewBuilder private var rangeControls: some View {
        timeRow(store.t("dl_start"), value: $start, range: 0 ... vodDuration - 10)
            .onChange(of: start) { s in if end < s + 10 { end = min(vodDuration, s + 10) } }
        timeRow(store.t("dl_end"), value: $end, range: 10 ... vodDuration)
            .onChange(of: end) { e in if start > e - 10 { start = max(0, e - 10) } }
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: TSpace.sm) {
                TChip(title: store.t("dl_all"), isOn: start == 0 && end == vodDuration) {
                    start = 0
                    end = vodDuration
                }
                TChip(title: store.t("dl_from_here"), isOn: false) {
                    start = min(context.position, max(0, vodDuration - 10))
                    end = vodDuration
                }
                TChip(title: store.t("dl_ten_min"), isOn: false) {
                    start = min(context.position, max(0, vodDuration - 10))
                    end = min(vodDuration, start + 600)
                }
            }
        }
    }

    private func timeRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: TSpace.md) {
                Text(title).font(.tMeta).foregroundColor(.tMuted)
                Spacer()
                Button("−1 min") { value.wrappedValue = max(range.lowerBound, value.wrappedValue - 60) }
                    .font(.tMeta).foregroundColor(.tPrimary)
                Text(dlClock(value.wrappedValue))
                    .font(.tCardTitle.monospacedDigit()).foregroundColor(.tText)
                Button("+1 min") { value.wrappedValue = min(range.upperBound, value.wrappedValue + 60) }
                    .font(.tMeta).foregroundColor(.tPrimary)
            }
            .buttonStyle(.plain)
            Slider(value: value, in: range).tint(.tPrimary)
        }
    }

    private var summary: some View {
        let length = max(0, end - start)
        let size = bytesPerSecond.map { dlBytes(Int64($0 * length)) } ?? "?"
        return Text(store.t("dl_summary")
                        .replacingOccurrences(of: "{d}", with: dlClock(length))
                        .replacingOccurrences(of: "{s}", with: size))
            .font(.tCardTitle).foregroundColor(.tText)
    }

    private func label(_ q: String) -> String { qualityText(q, store.lang) }

    /// Durée de la VOD (playlist de la qualité choisie) et débit estimé d'après
    /// la taille du premier segment.
    private func loadInfo() async {
        guard let link = context.links[quality], let url = URL(string: link) else { return }
        loading = true
        failed = false
        let text = await VodDownloadPlan.fetch(url)
        // Autre qualité choisie entre-temps : c'est sa propre lecture qui compte.
        guard !Task.isCancelled else { return }
        loading = false
        guard let text else { failed = true; return }
        let plan = VodDownloadPlan.make(text, base: url, from: 0, to: 0)
        guard plan.vodDuration >= 20 else { failed = true; return }
        let firstTime = vodDuration == 0
        vodDuration = plan.vodDuration
        if firstTime {
            // Par défaut : de là où l'on en est jusqu'à la fin.
            start = context.position >= 10 ? min(context.position, max(0, vodDuration - 10)) : 0
            end = vodDuration
        } else {
            end = min(max(end, start + 10), vodDuration)
        }
        bytesPerSecond = nil
        if let first = plan.segments.first, first.duration > 0 {
            var req = URLRequest(url: first.url, timeoutInterval: 8)
            req.httpMethod = "HEAD"
            if let (_, resp) = try? await URLSession.shared.data(for: req),
               let length = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length"),
               let n = Double(length) {
                bytesPerSecond = n / first.duration
            }
        }
    }
}

// MARK: – Ligne de « Mes VODs »
struct DownloadRow: View {
    let item: VodDownload
    let onPlay: (VodDownload) -> Void

    @EnvironmentObject private var store: AppStore
    @ObservedObject private var downloads = VodDownloads.shared
    @State private var confirmDelete = false
    @State private var exporting = false

    private var detail: String {
        var parts = ["\(dlClock(item.start)) → \(dlClock(item.end))", dlBytes(item.bytes)]
        switch item.state {
        case .paused: parts.append(store.t("dl_paused"))
        case .failed: parts.append(failure)
        case .downloading:
            if item.total == 0 {
                parts.append(store.t("dl_preparing"))
            } else {
                parts.append("\(Int(item.progress * 100)) %")
                parts.append("\(item.done)/\(item.total)")
            }
        case .done:
            if item.restored > 0 { parts.append(store.t("dl_restored").replacingOccurrences(of: "{d}", with: dlClock(item.restored))) }
            if item.muted > 0 { parts.append(store.t("dl_muted").replacingOccurrences(of: "{d}", with: dlClock(item.muted))) }
        }
        if item.withChat == true {
            parts.append(item.chatCount.map { store.tn("dl_chat_count", $0).replacingOccurrences(of: "{n}", with: "\($0)") }
                         ?? store.t("dl_chat_pending"))
        }
        return parts.joined(separator: " · ")
    }

    /// Pourquoi il s'est arrêté, quand on le sait.
    private var failure: String {
        let reason = item.reason ?? ""
        switch reason {
        case VodDownloadFailure.network: return store.t("dl_failed_network")
        case VodDownloadFailure.space: return store.t("dl_failed_space")
        case VodDownloadFailure.playlist: return store.t("dl_failed_playlist")
        default:
            guard reason.hasPrefix("http:") else { return store.t("dl_failed") }
            return store.t("dl_failed_refused")
                .replacingOccurrences(of: "{c}", with: "HTTP " + String(reason.dropFirst(5)))
        }
    }

    /// Un seul fichier, proposé à la feuille de partage (Fichiers, AirDrop,
    /// VLC…), effacé une fois partagé.
    private func export() {
        exporting = true
        Task { @MainActor in
            let url = await downloads.export(item)
            exporting = false
            guard let url else { return }
            ShareSheet.present(url) { try? FileManager.default.removeItem(at: url) }
        }
    }

    var body: some View {
        HStack(spacing: TSpace.md) {
            HStack(spacing: TSpace.md) {
                ZStack {
                    AsyncImage(url: URL(string: item.thumbnail)) { img in
                        img.resizable().aspectRatio(16/9, contentMode: .fill)
                    } placeholder: {
                        Rectangle().fill(Color.tSurface)
                            .overlay(Image(systemName: "arrow.down.circle")
                                .font(.system(size: 16)).foregroundColor(.tMuted))
                    }
                    if item.state == .done {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 26)).foregroundColor(.white.opacity(0.9))
                            .shadow(radius: 3)
                    }
                }
                .frame(width: 116, height: 65)
                .clipped()
                .cornerRadius(TRadius.chip)

                VStack(alignment: .leading, spacing: TSpace.xs) {
                    Text(item.title)
                        .font(.tCardTitle).foregroundColor(.tText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text([item.streamer, item.quality.isEmpty ? "" : qualityText(item.quality, store.lang)]
                            .filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.tMeta).foregroundColor(.tPurple).lineLimit(1)
                    Text(detail)
                        .font(.tMeta).foregroundColor(item.state == .failed ? .tDanger : .tMuted).lineLimit(3)
                    if item.state != .done {
                        ProgressView(value: item.progress).tint(.tPrimary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
            .onTapGesture { if item.state == .done { onPlay(item) } }

            switch item.state {
            case .downloading:
                TIconButton(icon: "pause.fill") { downloads.pause(item.id) }
            case .paused, .failed:
                TIconButton(icon: "arrow.clockwise") { downloads.resume(item.id) }
            case .done:
                if exporting {
                    ProgressView().tint(.tPrimary).frame(width: 34, height: 34)
                } else {
                    TIconButton(icon: "square.and.arrow.up") { export() }
                }
            }
            TIconButton(icon: "trash", tint: .tDanger) { confirmDelete = true }
        }
        .padding(.horizontal, TSpace.lg)
        .alert(store.t("dl_delete_confirm"), isPresented: $confirmDelete) {
            Button(store.t("cancel"), role: .cancel) {}
            Button(store.t("erase"), role: .destructive) { downloads.delete(item.id) }
        }
    }
}

// MARK: – Partage
/// Feuille de partage d'iOS pour un fichier (Enregistrer dans Fichiers,
/// AirDrop, ouvrir dans VLC…).
enum ShareSheet {
    @MainActor
    static func present(_ url: URL, completion: @escaping () -> Void) {
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.completionWithItemsHandler = { _, _, _, _ in completion() }
        guard let root = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first?.rootViewController else {
            completion()
            return
        }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        // iPad : la feuille s'ouvre au centre, sans flèche.
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        top.present(sheet, animated: true)
    }
}
