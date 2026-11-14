import SwiftUI
import AVFoundation
import UIKit

// ═══════════════════════════════════════════════════════════════════════════
//  Inspecteur de « TU Dev », ouvert par la bulle (voir DevTools) : l'onglet
//  Réseau (requêtes de l'app, filtres, détail, cURL) et l'onglet Lecteur
//  (statistiques des AVPlayer en place). Textes en français : outil du
//  développeur seulement.
// ═══════════════════════════════════════════════════════════════════════════

struct DevInspectorView: View {
    var onClose: () -> Void
    @State private var tab = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Onglet", selection: $tab) {
                    Text("Réseau").tag(0)
                    Text("Lecteur").tag(1)
                    Text("PC").tag(2)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
                switch tab {
                case 0: DevNetworkList()
                case 1: DevPlayerPanel()
                default: DevPCPanel()
                }
            }
            .navigationTitle("TU Dev")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fermer", action: onClose)
                }
            }
        }
    }
}

// MARK: – Mise en forme

enum DevFormat {
    static func bytes(_ n: Int64) -> String {
        n <= 0 ? "0 o" : ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    static func duration(_ t: TimeInterval) -> String {
        t < 1 ? "\(Int((t * 1000).rounded())) ms" : String(format: "%.2f s", t)
    }

    /// JSON indenté (clés triées), sinon le texte tel quel. `mask` : valeurs
    /// des clés sensibles (jetons, signatures, cookies…) remplacées.
    static func pretty(_ data: Data, mask: Bool = false) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
           let out = try? JSONSerialization.data(withJSONObject: mask ? masked(obj) : obj,
                                                 options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]),
           let text = String(data: out, encoding: .utf8) {
            return text.replacingOccurrences(of: "\\/", with: "/")
        }
        return String(data: data, encoding: .utf8) ?? "\(data.count) octets (binaire)"
    }

    /// Affichage d'un long corps : les 120 000 premiers caractères (Copier
    /// donne tout).
    static func preview(_ text: String) -> String {
        text.count > 120_000 ? String(text.prefix(120_000)) + "\n… (suite coupée à l'affichage)" : text
    }

    private static let secretKeys = ["token", "signature", "secret", "password", "cookie", "authorization", "integrity"]

    /// Copie du JSON aux valeurs sensibles masquées. Jeton de lecture de
    /// Twitch (« value » + « signature ») compris.
    static func masked(_ obj: Any) -> Any {
        if let dict = obj as? [String: Any] {
            let playbackToken = dict["value"] != nil && dict["signature"] != nil
            var out: [String: Any] = [:]
            for (key, value) in dict {
                let lower = key.lowercased()
                let secret = (playbackToken && (lower == "value" || lower == "signature"))
                    || secretKeys.contains { lower.contains($0) }
                out[key] = secret && value is String ? ("•••• (masqué)" as Any) : masked(value)
            }
            return out
        }
        if let list = obj as? [Any] { return list.map { masked($0) } }
        return obj
    }
}

/// Une ligne « libellé : valeur », la valeur sélectionnable.
struct DevRow: View {
    let label: String
    let value: String
    var mono = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundColor(.secondary)
            Text(value)
                .font(mono ? .caption.monospaced() : .callout)
                .textSelection(.enabled)
        }
    }
}

// MARK: – Réseau

enum NetKind: String, CaseIterable, Identifiable {
    case all = "Tout", gql = "GQL", playlist = "Playlist", worker = "Worker", proxy = "Proxy",
         helix = "Helix", image = "Images", other = "Autre", errors = "Erreurs"
    var id: String { rawValue }

    static func of(_ e: NetEntry) -> NetKind {
        let host = (e.url.host ?? "").lowercased()
        let path = e.url.path.lowercased()
        if host == "gql.twitch.tv" { return .gql }
        if host.hasSuffix("playlist.ttvnw.net") || host.hasPrefix("usher.") || path.hasSuffix(".m3u8") { return .playlist }
        if host.hasSuffix("workers.dev") { return .worker }
        if host.hasSuffix("luminous.dev") || host.contains("perfprod") || host.contains("nadeko") { return .proxy }
        if host == "api.twitch.tv" || host == "id.twitch.tv" { return .helix }
        if (e.mime ?? "").hasPrefix("image/") || host.hasSuffix("jtvnw.net") || host.contains("7tv")
            || host.contains("betterttv") || host.contains("frankerfacez") { return .image }
        return .other
    }
}

struct DevNetworkList: View {
    @ObservedObject private var log = NetLog.shared
    @State private var kind = NetKind.all
    @State private var search = ""
    @State private var paused = NetLog.shared.paused

    var body: some View {
        let all = log.snapshot
        let shown: [NetEntry] = all.reversed().filter { e in
            let kindOK = kind == .all || (kind == .errors ? e.failed : NetKind.of(e) == kind)
            let searchOK = search.isEmpty || e.url.absoluteString.localizedCaseInsensitiveContains(search)
                || e.name.localizedCaseInsensitiveContains(search)
            return kindOK && searchOK
        }
        let received = all.reduce(Int64(0)) { $0 + $1.bytes }
        List {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(NetKind.allCases) { k in
                            Button { kind = k } label: {
                                Text(k.rawValue)
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Capsule().fill(kind == k ? Color.accentColor : Color.secondary.opacity(0.18)))
                                    .foregroundColor(kind == k ? .white : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
            } footer: {
                Text("\(shown.count) sur \(all.count) requêtes · \(DevFormat.bytes(received)) reçus\(paused ? " · capture en pause" : "")\(NetCapture.bodyCaptureActive ? "" : " · corps des réponses indisponibles sur cet iOS"). Les morceaux de vidéo qu'AVPlayer charge lui-même n'y sont pas : voir l'onglet Lecteur.")
            }
            Section {
                ForEach(shown) { e in
                    NavigationLink {
                        DevRequestDetail(id: e.id)
                    } label: {
                        DevRequestRow(entry: e)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $search, prompt: "Filtrer (adresse, nom)")
        .toolbar {
            ToolbarItemGroup(placement: .cancellationAction) {
                Button {
                    log.paused.toggle()
                    paused = log.paused
                } label: {
                    Image(systemName: paused ? "play.circle" : "pause.circle")
                }
                Button(role: .destructive) {
                    log.clear()
                } label: {
                    Image(systemName: "trash")
                }
            }
        }
    }
}

struct DevRequestRow: View {
    let entry: NetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(entry.method).font(.caption2.monospaced()).foregroundColor(.secondary)
                Text(entry.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Text(statusText).font(.caption.monospacedDigit().weight(.bold)).foregroundColor(statusColor)
            }
            HStack(spacing: 8) {
                Text(entry.url.host ?? "").lineLimit(1)
                Spacer(minLength: 4)
                Text(NetKind.of(entry).rawValue)
                Text(DevFormat.bytes(entry.bytes))
                Text(entry.duration.map(DevFormat.duration) ?? "…")
            }
            .font(.caption2.monospacedDigit())
            .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var statusText: String {
        if entry.cancelled { return "annulée" }
        if entry.error != nil { return "erreur" }
        if let s = entry.status { return "\(s)" }
        return entry.finished ? "—" : "…"
    }

    private var statusColor: Color {
        if entry.cancelled { return .orange }
        if entry.error != nil { return .red }
        guard let s = entry.status else { return .secondary }
        return s >= 400 ? .red : s >= 300 ? .orange : .green
    }
}

struct DevRequestDetail: View {
    let id: Int
    @ObservedObject private var log = NetLog.shared
    @State private var showSecrets = false

    private static let secretHeaders: Set<String> = ["authorization", "cookie", "set-cookie", "client-integrity"]

    var body: some View {
        if let e = log.snapshot.last(where: { $0.id == id }) {
            List {
                Section("Général") {
                    DevRow(label: "Adresse", value: e.url.absoluteString, mono: true)
                    if let f = e.finalURL { DevRow(label: "Adresse finale", value: f.absoluteString, mono: true) }
                    DevRow(label: "Méthode", value: e.method)
                    DevRow(label: "Statut", value: e.status.map { String($0) } ?? (e.finished ? "—" : "en cours"))
                    if let err = e.error { DevRow(label: "Erreur", value: err) }
                    DevRow(label: "Type", value: NetKind.of(e).rawValue + (e.mime.map { " · \($0)" } ?? ""))
                    DevRow(label: "Taille", value: DevFormat.bytes(e.bytes))
                    DevRow(label: "Durée", value: e.duration.map(DevFormat.duration) ?? "…")
                    DevRow(label: "Début", value: e.started.formatted(date: .omitted, time: .standard))
                }
                if let op = e.gqlOperation {
                    Section("Opération GQL") {
                        Text(op).font(.callout.monospaced()).textSelection(.enabled)
                        if let q = e.gqlQuery {
                            Text(q).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                }
                headers("En-têtes de la requête", e.requestHeaders)
                if let body = e.requestBody, !body.isEmpty {
                    Section("Corps de la requête") {
                        Text(DevFormat.pretty(body)).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                headers("En-têtes de la réponse", e.responseHeaders)
                responseSection(e)
                Section {
                    Toggle("Afficher les secrets (jetons, cookies)", isOn: $showSecrets)
                    Button("Copier l'adresse") { UIPasteboard.general.string = e.url.absoluteString }
                    Button("Copier en cURL") { UIPasteboard.general.string = curl(e) }
                } footer: {
                    Text("Les secrets restent masqués dans les copies (cURL, réponse) tant qu'ils le sont ici.")
                }
            }
            .navigationTitle(e.name)
            .navigationBarTitleDisplayMode(.inline)
        } else {
            Text("Requête effacée").foregroundColor(.secondary)
        }
    }

    /// Corps de la réponse : JSON mis en forme (secrets masqués tant que le
    /// réglage est coupé) ou texte ; sinon pourquoi il manque.
    @ViewBuilder private func responseSection(_ e: NetEntry) -> some View {
        if let body = e.responseBody, !body.isEmpty {
            let text = DevFormat.pretty(body, mask: !showSecrets)
            Section("Réponse" + (e.responseTruncated ? " (tronquée à 512 Ko)" : "")) {
                Text(DevFormat.preview(text)).font(.caption.monospaced()).textSelection(.enabled)
                Button("Copier la réponse") { UIPasteboard.general.string = text }
            }
        } else if e.finished {
            Section("Réponse") {
                Text(missingBodyReason(e)).font(.callout).foregroundColor(.secondary)
            }
        }
    }

    private func missingBodyReason(_ e: NetEntry) -> String {
        if e.bodyDropped { return "Oubliée pour tenir le budget de 48 Mo (requête ancienne)." }
        if !NetCapture.bodyCaptureActive { return "Corps des réponses indisponibles sur cette version d'iOS." }
        let mime = (e.mime ?? "").lowercased()
        if mime.hasPrefix("image/") || mime.hasPrefix("video/") || mime.hasPrefix("audio/") || mime == "application/octet-stream" {
            return "Pas gardée : image, vidéo ou son."
        }
        return e.bytes == 0 ? "Réponse vide." : "Pas de corps lu pour cette requête."
    }

    private func shown(_ name: String, _ value: String) -> String {
        Self.secretHeaders.contains(name.lowercased()) && !showSecrets ? "•••• (masqué)" : value
    }

    @ViewBuilder private func headers(_ title: String, _ h: [String: String]) -> some View {
        if !h.isEmpty {
            Section(title) {
                ForEach(h.keys.sorted(), id: \.self) { k in
                    DevRow(label: k, value: shown(k, h[k] ?? ""), mono: true)
                }
            }
        }
    }

    private func curl(_ e: NetEntry) -> String {
        var parts = ["curl -X \(e.method) '\(e.url.absoluteString)'"]
        for k in e.requestHeaders.keys.sorted() {
            parts.append("-H '\(k): \(shown(k, e.requestHeaders[k] ?? ""))'")
        }
        if let body = e.requestBody, let text = String(data: body, encoding: .utf8) {
            parts.append("--data-raw '\(text.replacingOccurrences(of: "'", with: "'\\''"))'")
        }
        return parts.joined(separator: " \\\n  ")
    }
}

// MARK: – Lecteur

struct DevPlayerPanel: View {
    /// Redessiné chaque seconde : les statistiques d'AVPlayer n'ont pas
    /// d'avis de changement.
    @State private var tick = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        // Lu ici pour que chaque seconde redessine la liste, sans la recréer
        // (la position de défilement reste).
        let _ = tick
        let players = PlayerTracker.all.filter { $0.currentItem != nil }
        List {
            Section {
                DevRow(label: "Source du direct (app)", value: UsageService.shared.adSource ?? "—")
            } footer: {
                Text("Mis à jour chaque seconde. Les morceaux de vidéo sont chargés par AVPlayer lui-même : ils ne figurent pas dans l'onglet Réseau, leur compte est ici.")
            }
            if players.isEmpty {
                Section {
                    Text("Aucun lecteur ouvert.").foregroundColor(.secondary)
                }
            }
            ForEach(Array(players.enumerated()), id: \.offset) { pair in
                DevPlayerSection(index: pair.offset, count: players.count, player: pair.element)
            }
        }
        .listStyle(.insetGrouped)
        .onReceive(timer) { _ in tick &+= 1 }
    }
}

struct DevPlayerSection: View {
    let index: Int
    let count: Int
    let player: AVPlayer

    var body: some View {
        let item = player.currentItem
        let event = item?.accessLog()?.events.last
        let failure = item?.errorLog()?.events.last
        Section(count > 1 ? "Lecteur \(index + 1)" : "Lecteur") {
            DevRow(label: "Adresse", value: address(item), mono: true)
            DevRow(label: "État", value: state)
            DevRow(label: "Image", value: size(item))
            DevRow(label: "Débit annoncé / mesuré", value: "\(mbps(event?.indicatedBitrate)) / \(mbps(event?.observedBitrate))")
            DevRow(label: "Tampon d'avance", value: buffer(item))
            DevRow(label: "Calages", value: "\(event?.numberOfStalls ?? 0)")
            DevRow(label: "Morceaux chargés", value: "\(event?.numberOfMediaRequests ?? 0) · \(DevFormat.bytes(event?.numberOfBytesTransferred ?? 0))")
            DevRow(label: "Images perdues", value: "\(event?.numberOfDroppedVideoFrames ?? 0)")
            if let type = event?.playbackType { DevRow(label: "Type", value: type) }
            if let server = event?.serverAddress { DevRow(label: "Serveur", value: server, mono: true) }
            if let uri = event?.uri { DevRow(label: "Variante", value: uri, mono: true) }
            if let ad = adBreak(item) { DevRow(label: "Pause pub", value: ad) }
            if let f = failure {
                DevRow(label: "Dernière erreur", value: "\(f.errorStatusCode) · \(f.errorDomain) · \(f.errorComment ?? "")")
            }
        }
    }

    private var state: String {
        let status: String
        switch player.timeControlStatus {
        case .playing: status = "lecture"
        case .paused: status = "pause"
        case .waitingToPlayAtSpecifiedRate:
            status = "attente" + (player.reasonForWaitingToPlay.map { " (\($0.rawValue))" } ?? "")
        @unknown default: status = "?"
        }
        return "\(status) · vitesse \(player.rate)" + (player.isMuted ? " · son coupé" : "")
    }

    private func address(_ item: AVPlayerItem?) -> String {
        guard let url = (item?.asset as? AVURLAsset)?.url else { return "—" }
        let real = LivePlaylistLoader.unwrap(url) ?? url
        return real.host.map { "\($0)\(real.path)" } ?? real.absoluteString
    }

    private func size(_ item: AVPlayerItem?) -> String {
        guard let s = item?.presentationSize, s.width > 0 else { return "—" }
        return "\(Int(s.width))×\(Int(s.height))"
    }

    private func buffer(_ item: AVPlayerItem?) -> String {
        guard let item else { return "—" }
        let now = item.currentTime()
        for value in item.loadedTimeRanges {
            let range = value.timeRangeValue
            if range.containsTime(now) {
                return String(format: "%.1f s", CMTimeGetSeconds(CMTimeSubtract(range.end, now)))
            }
        }
        return "0 s"
    }

    private func mbps(_ value: Double?) -> String {
        guard let value, value > 0 else { return "—" }
        return String(format: "%.1f Mb/s", value / 1_000_000)
    }

    private func adBreak(_ item: AVPlayerItem?) -> String? {
        guard let item, let current = AdBreakMonitor.monitor(of: item)?.playbackBreak(on: player) else { return nil }
        let left = max(0, Int(current.brk.countdownEnd.timeIntervalSince(current.clock).rounded(.up)))
        return "\(left) s restantes" + (current.brk.roll.isEmpty ? "" : " · \(current.brk.roll)")
    }
}
