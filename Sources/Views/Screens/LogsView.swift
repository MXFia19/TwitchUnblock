import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers

struct LogsView: View {
    @ObservedObject private var appLogger = AppLogger.shared
    @State private var filter: LogLevel? = nil
    @State private var expandedIds: Set<Int> = []
    @State private var showClearAlert = false
    /// Langue de l'app : le journal, écrit en français, s'affiche traduit
    /// (LogTranslator) ; l'export suit la même langue.
    @AppStorage("lang") private var langRaw = "en"

    private var lang: Lang { Lang(rawValue: langRaw) ?? .en }
    private func t(_ key: String) -> String { translate(key, lang) }
    private func tr(_ text: String) -> String { LogTranslator.translate(text, lang) }

    private var filtered: [LogEntry] {
        guard let f = filter else { return appLogger.logs }
        return appLogger.logs.filter { $0.level == f }
    }

    // Journal exporté : ici, son en-tête seulement (version, système,
    // appareil et nombre de lignes par niveau, pour situer un rapport et
    // repérer ses erreurs d'un coup d'œil) ; les lignes ne sont traduites
    // qu'au moment du partage (LogsExport).
    private var export: LogsExport {
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        let counts = LogLevel.allCases.map { "\($0.rawValue) \(appLogger.count($0))" }.joined(separator: " · ")
        let header = "TwitchUnblock \(version) · \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
            + " · \(Self.deviceModel) · \(lang.rawValue)\n\(counts)\n\n"
        return LogsExport(header: header, entries: appLogger.logs, lang: lang)
    }

    /// Modèle exact de l'appareil (« iPhone15,2 »).
    private static var deviceModel: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// « TwitchUnblock-logs-2026-10-16-0215.txt »
    private var exportFileName: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmm"
        return "TwitchUnblock-logs-\(f.string(from: Date())).txt"
    }

    var body: some View {
        VStack(spacing: 0) {

            // ── Filtres ─────────────────────────────────────────────
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    filterChip(label: t("logs_all").replacingOccurrences(of: "{n}", with: "\(appLogger.logs.count)"),
                               active: filter == nil) {
                        filter = nil
                    }
                    // Nombre de lignes de chaque niveau : les erreurs se voient
                    // sans parcourir le journal.
                    ForEach(LogLevel.allCases, id: \.self) { level in
                        let n = appLogger.count(level)
                        filterChip(label: n > 0 ? "\(t("log_level_\(level.rawValue)")) \(n)" : t("log_level_\(level.rawValue)"),
                                   active: filter == level) {
                            filter = (filter == level) ? nil : level
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 12)
            }
            .background(Color.tCard)
            .overlay(Divider().background(Color.tBorder), alignment: .bottom)

            // ── Actions ─────────────────────────────────────────────
            HStack(spacing: 8) {
                let export = self.export

                // ✅ ShareLink iOS 16+ — remplace UIActivityViewController dans .sheet
                // (UIActivityViewController présenté dans un .sheet est cassé sur iOS 16)
                ShareLink(item: export, preview: SharePreview(t("logs_title"))) {
                    actionLabel(t("logs_share"))
                }
                .disabled(appLogger.logs.isEmpty)

                // Fichier .txt : Enregistrer dans Fichiers, AirDrop, Mail…
                // (écrit seulement quand on choisit où l'envoyer).
                ShareLink(item: LogsFile(export: export, name: exportFileName),
                          preview: SharePreview(exportFileName)) {
                    actionLabel(t("logs_file"))
                }
                .disabled(appLogger.logs.isEmpty)

                Button {
                    showClearAlert = true
                } label: {
                    Text(t("logs_clear"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.tDanger)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Color(hex: "3a1a1a"))
                        .cornerRadius(8)
                }
                .disabled(appLogger.logs.isEmpty)

                Spacer()
                Text(translatePlural("logs_count", filtered.count, lang).replacingOccurrences(of: "{n}", with: "\(filtered.count)"))
                    .font(.system(size: 11)).foregroundColor(.tMuted)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)

            // ── Liste ────────────────────────────────────────────────
            if filtered.isEmpty {
                VStack(spacing: 8) {
                    Text("📋").font(.system(size: 48))
                    Text(appLogger.logs.isEmpty ? t("logs_empty") : t("logs_no_match"))
                        .font(.system(size: 18, weight: .bold)).foregroundColor(.tText)
                    // Le conseil seulement quand le journal est vide (pas quand un filtre ne trouve rien).
                    if appLogger.logs.isEmpty {
                        Text(t("logs_empty_hint"))
                            .font(.system(size: 13)).foregroundColor(.tMuted)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(40)
            } else {
                List(filtered) { entry in
                    logRow(entry)
                        .listRowBackground(Color.tDark)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                }
                .listStyle(.plain)
                .background(Color.tDark)
            }
        }
        .background(Color.tDark)
        .alert(t("logs_clear_title"), isPresented: $showClearAlert) {
            Button(t("cancel"), role: .cancel) {}
            Button(t("logs_clear_btn"), role: .destructive) { appLogger.clear() }
        } message: {
            Text(t("logs_clear_confirm"))
        }
    }

    private func actionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.tText)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Color.tSurface)
            .cornerRadius(8)
    }

    // MARK: – Log row
    @ViewBuilder
    private func logRow(_ entry: LogEntry) -> some View {
        let color      = Color(hex: entry.level.color)
        let isExpanded = expandedIds.contains(entry.id)

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(entry.level.icon)
                    .font(.system(size: 12, weight: .black))
                    .foregroundColor(color)
                    .frame(width: 14)
                Text(entry.timestamp)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.tMuted)
                // Catégorie traduite elle aussi (« LECTEUR » → « PLAYER »).
                Text(LogTranslator.category(entry.category, lang))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(color)
                // Même ligne arrivée plusieurs fois de suite.
                if entry.repeats > 1 {
                    Text("×\(entry.repeats)")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundColor(color)
                        .padding(.horizontal, 5)
                        .background(color.opacity(0.15))
                        .clipShape(Capsule())
                }
            }

            Text(tr(entry.message))
                .font(.system(size: 12))
                .foregroundColor(.tText)
                .lineLimit(isExpanded ? nil : 2)

            if let detail = entry.detail {
                if isExpanded {
                    Text(tr(detail))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.tMuted)
                        .padding(8)
                        .background(Color(hex: "111111"))
                        .cornerRadius(6)
                } else {
                    Text(t("logs_details"))
                        .font(.system(size: 10))
                        .foregroundColor(.tPrimary)
                }
            }
        }
        .padding(10)
        .background(Color.tCard)
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.tBorder, lineWidth: 1))
        .overlay(Rectangle().fill(color).frame(width: 3), alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture {
            guard entry.detail != nil else { return }
            if expandedIds.contains(entry.id) { expandedIds.remove(entry.id) }
            else { expandedIds.insert(entry.id) }
        }
    }

    // MARK: – Filter chip
    @ViewBuilder
    private func filterChip(label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(active ? .white : .tMuted)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(active ? Color.tPrimary : Color.tSurface)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(active ? Color.tPrimary : Color.tBorder, lineWidth: 1)
                )
        }
    }
}

/// Journal à partager en texte. Ses lignes ne sont traduites et assemblées
/// qu'au moment de l'envoi : calculé dans `body`, le texte refaisait ses
/// 1 000 lignes deux fois à chaque rendu, et le journal se redessine à
/// chaque nouvelle ligne (lecture en cours).
struct LogsExport: Transferable {
    let header: String
    let entries: [LogEntry]
    let lang: Lang

    /// Sur le fil principal : LogTranslator garde ses traductions dans un
    /// cache sans verrou, que l'écran du journal remplit au même moment.
    @MainActor var text: String {
        header + entries
            .map { e in
                let times = e.repeats > 1 ? " (×\(e.repeats))" : ""
                return "[\(e.timestamp)] [\(e.level.rawValue.uppercased())] [\(LogTranslator.category(e.category, lang))] \(LogTranslator.translate(e.message, lang))\(times)"
                    + (e.detail.map { "\n  → \(LogTranslator.translate($0, lang))" } ?? "")
            }
            .joined(separator: "\n")
    }

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .utf8PlainText) { item in
            let text = await item.text
            return Data(text.utf8)
        }
    }
}

/// Journal en fichier texte (.txt) : Enregistrer dans Fichiers, AirDrop,
/// Mail… Le fichier n'est écrit qu'au moment de l'envoi.
struct LogsFile: Transferable {
    let export: LogsExport
    let name: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { file in
            let text = await file.export.text
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(file.name)
            try text.write(to: url, atomically: true, encoding: .utf8)
            return SentTransferredFile(url)
        }
    }
}
