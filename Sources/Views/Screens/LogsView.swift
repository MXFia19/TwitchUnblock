import SwiftUI

struct LogsView: View {
    @ObservedObject private var appLogger = AppLogger.shared
    @State private var filter: LogLevel? = nil
    @State private var expandedIds: Set<Int> = []
    @State private var showClearAlert = false

    private var filtered: [LogEntry] {
        guard let f = filter else { return appLogger.logs }
        return appLogger.logs.filter { $0.level == f }
    }

    // Texte exporté — calculé une seule fois au moment du partage
    private var exportText: String {
        appLogger.logs
            .map { "[\($0.timestamp)] [\($0.level.rawValue.uppercased())] [\($0.category)] \($0.message)\($0.detail.map { "\n  → \($0)" } ?? "")" }
            .joined(separator: "\n")
    }

    var body: some View {
        VStack(spacing: 0) {

            // ── Filtres ─────────────────────────────────────────────
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    filterChip(label: "Tout (\(appLogger.logs.count))", active: filter == nil) {
                        filter = nil
                    }
                    ForEach(LogLevel.allCases, id: \.self) { level in
                        filterChip(label: level.rawValue, active: filter == level) {
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

                // ✅ ShareLink iOS 16+ — remplace UIActivityViewController dans .sheet
                // (UIActivityViewController présenté dans un .sheet est cassé sur iOS 16)
                ShareLink(item: exportText) {
                    Text("📤 Exporter")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.tText)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Color.tSurface)
                        .cornerRadius(8)
                }
                .disabled(appLogger.logs.isEmpty)

                Button {
                    showClearAlert = true
                } label: {
                    Text("🗑 Effacer")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.tDanger)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Color(hex: "3a1a1a"))
                        .cornerRadius(8)
                }
                .disabled(appLogger.logs.isEmpty)

                Spacer()
                Text("\(filtered.count) logs")
                    .font(.system(size: 11)).foregroundColor(.tMuted)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)

            // ── Liste ────────────────────────────────────────────────
            if filtered.isEmpty {
                VStack(spacing: 8) {
                    Text("📋").font(.system(size: 48))
                    Text(appLogger.logs.isEmpty
                         ? "Aucun log"
                         : "Aucun résultat pour ce filtre")
                        .font(.system(size: 18, weight: .bold)).foregroundColor(.tText)
                    Text("Lance une VOD ou un stream pour voir les logs")
                        .font(.system(size: 13)).foregroundColor(.tMuted)
                        .multilineTextAlignment(.center)
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
        .alert("Effacer les logs", isPresented: $showClearAlert) {
            Button("Annuler", role: .cancel) {}
            Button("Effacer", role: .destructive) { appLogger.clear() }
        } message: {
            Text("Confirmer ?")
        }
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
                Text(entry.category)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(color)
            }

            Text(entry.message)
                .font(.system(size: 12))
                .foregroundColor(.tText)
                .lineLimit(isExpanded ? nil : 2)

            if let detail = entry.detail {
                if isExpanded {
                    Text(detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.tMuted)
                        .padding(8)
                        .background(Color(hex: "111111"))
                        .cornerRadius(6)
                } else {
                    Text("▼ Détails")
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
