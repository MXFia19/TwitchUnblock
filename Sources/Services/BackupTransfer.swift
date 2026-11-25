import UIKit
import Compression

// ═══════════════════════════════════════════════════════════════════════════
//  Réglages envoyés d'une app à l'autre : TwitchUnblock ↔ TU Test (et TU
//  Dev), installées côte à côte sous des identifiants différents, donc avec
//  des données à part (demande n° 13 de joey). Un App Group les partagerait,
//  mais les outils d'installation (Feather, SideStore, AltStore…) réécrivent
//  les droits de l'app : rien de fiable. Ici, un transfert à la demande :
//
//  - Réglages → Général → Sauvegarde : « Envoyer mes réglages à TU Test »
//    (« … à TwitchUnblock » dans TU Test), seulement si l'autre app est
//    installée (canOpenURL : ses schémas sont dans LSApplicationQueriesSchemes
//    de l'Info.plist) ;
//  - le bouton ouvre l'autre app par son schéma de lien, avec toute la
//    sauvegarde (format de Backup.swift, compressée en DEFLATE puis en base64
//    « URL ») : <schéma>://import-settings?v=1&from=<schéma d'ici>&d=… ;
//  - trop longue pour une adresse, ou refusée par iOS : elle passe par le
//    presse-papiers, sous un type à part (l'autre app la voit sans lire le
//    presse-papiers), gardée 10 minutes et jamais copiée sur les autres
//    appareils ; l'adresse ne porte alors que « clip=1 », et l'autre app
//    propose aussi « Importer depuis le presse-papiers » dans ses réglages ;
//  - l'app qui reçoit demande toujours avant d'importer (Tout, Chaînes
//    seulement, Annuler), comme pour un fichier : n'importe quelle page peut
//    ouvrir un lien twitchunblock://, rien n'est repris sans un oui.
//
//  Comme dans le fichier, jamais de jetons, de sessions ni de Worker
//  personnel. Pas dans l'app Apple TV (ni presse-papiers ni réglages ici).
// ═══════════════════════════════════════════════════════════════════════════

enum BackupTransfer {
    /// Une app de la famille, par son schéma de lien.
    struct Peer: Identifiable, Equatable {
        let scheme: String
        let name: String
        var id: String { scheme }
    }

    /// Apps de la famille : schémas posés par la CI (build.yml : TU Test sur
    /// la branche de test, TU Dev sur celle de debug).
    static let apps: [Peer] = [
        Peer(scheme: "twitchunblock", name: "TwitchUnblock"),
        Peer(scheme: "twitchunblock-test", name: "TU Test"),
        Peer(scheme: "twitchunblock-dev", name: "TU Dev"),
    ]

    /// Hôte des liens d'envoi : <schéma>://import-settings?…
    static let host = "import-settings"
    /// Version du format des liens.
    private static let linkVersion = "1"
    /// Au-delà, l'adresse passerait mal d'une app à l'autre : presse-papiers.
    private static let maxURLLength = 30_000
    /// Type de la sauvegarde dans le presse-papiers.
    static let pasteboardType = "com.mxfia19.twitchunblock.backup"
    /// Le presse-papiers ne la garde que 10 minutes.
    private static let pasteboardLifetime: TimeInterval = 600
    /// Sauvegarde décompressée : moins de 2 Mo, comme Backup.read.
    private static let maxBackupBytes = 2_000_000
    /// Texte reçu : de quoi tenir 2 Mo, même incompressibles.
    private static let maxPayloadLength = 3_000_000

    /// Nom d'une app de la famille d'après son schéma ; nil sinon.
    static func name(ofScheme scheme: String?) -> String? {
        apps.first { $0.scheme == scheme }?.name
    }

    /// Les autres apps de la famille installées (pas celle-ci) : un bouton
    /// « Envoyer mes réglages à … » chacune.
    @MainActor
    static func installedTargets() -> [Peer] {
        apps.filter { app in
            guard app.scheme != kAppURLScheme, let url = URL(string: "\(app.scheme)://") else { return false }
            return UIApplication.shared.canOpenURL(url)
        }
    }

    /// Réglages laissés dans le presse-papiers par l'autre app : vu à son
    /// type, sans lire le presse-papiers (pas d'alerte d'iOS).
    @MainActor
    static var pasteboardHasBackup: Bool {
        UIPasteboard.general.contains(pasteboardTypes: [pasteboardType])
    }

    // MARK: Envoi

    /// Envoie toute la sauvegarde à `app` : dans le lien s'il reste court,
    /// sinon par le presse-papiers. `done(false)` : l'autre app ne s'est pas
    /// ouverte.
    @MainActor
    static func send(to app: Peer, store: AppStore, done: @escaping @MainActor (Bool) -> Void) {
        guard let payload = encode(Backup.export(store: store, compact: true)) else {
            logger.warn("SAUVEGARDE", "Envoi des réglages impossible", "compression")
            done(false)
            return
        }
        let base = "\(app.scheme)://\(host)?v=\(linkVersion)&from=\(kAppURLScheme)"
        Task { @MainActor in
            if base.count + payload.count + 3 <= Self.maxURLLength,
               let url = URL(string: base + "&d=" + payload),
               await UIApplication.shared.open(url) {
                logger.info("SAUVEGARDE", "Réglages envoyés à une autre app", "\(app.name) · dans le lien")
                done(true)
                return
            }
            // Trop long pour un lien, ou refusé par iOS : presse-papiers.
            UIPasteboard.general.setItems([[Self.pasteboardType: Data(payload.utf8)]],
                                          options: [.localOnly: true,
                                                    .expirationDate: Date().addingTimeInterval(Self.pasteboardLifetime)])
            guard let url = URL(string: base + "&clip=1"), await UIApplication.shared.open(url) else {
                logger.warn("SAUVEGARDE", "L'autre app ne s'ouvre pas", app.name)
                done(false)
                return
            }
            logger.info("SAUVEGARDE", "Réglages envoyés à une autre app", "\(app.name) · par le presse-papiers")
            done(true)
        }
    }

    // MARK: Réception

    /// Lien <schéma>://import-settings reçu (onOpenURL) : demande avant
    /// d'importer.
    @MainActor
    static func receive(_ url: URL, store: AppStore) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ key: String) -> String? { items.first { $0.name == key }?.value }
        // App qui envoie : celle du schéma donné, sinon celle de la sauvegarde.
        let senderScheme = value("from")
        let sender = name(ofScheme: senderScheme)
        if value("clip") == "1" {
            logger.info("SAUVEGARDE", "Réglages reçus d'une autre app", "\(sender ?? "?") · par le presse-papiers")
            ask(nil, from: sender, store: store)
            return
        }
        guard let payload = value("d"), let data = decode(payload), let file = try? Backup.read(data) else {
            logger.warn("SAUVEGARDE", "Réglages reçus illisibles", nil)
            inform(store.t("transfer_bad"), title: store.t("backup"))
            return
        }
        let shown = sender ?? file.app
        logger.info("SAUVEGARDE", "Réglages reçus d'une autre app", shown ?? "?")
        ask(file, from: shown, store: store)
    }

    /// Réglages du presse-papiers (laissés par l'autre app) ; nil s'il n'y en
    /// a pas, s'ils sont illisibles ou si le collage est refusé. Lus, ils en
    /// sont retirés.
    @MainActor
    static func readPasteboard() -> Backup.File? {
        let board = UIPasteboard.general
        guard board.contains(pasteboardTypes: [pasteboardType]),
              let raw = board.data(forPasteboardType: pasteboardType),
              let text = String(data: raw, encoding: .utf8),
              let data = decode(text),
              let file = try? Backup.read(data) else { return nil }
        board.items = []
        return file
    }

    /// « Importer les réglages de TU Test ? » : Tout, Chaînes seulement ou
    /// Annuler, comme pour un fichier. `file` nil : la sauvegarde attend dans
    /// le presse-papiers, lue après le choix (iOS demande alors la permission
    /// de coller).
    @MainActor
    private static func ask(_ file: Backup.File?, from: String?, store: AppStore) {
        let title = from.map { store.t("transfer_ask_title").replacingOccurrences(of: "{app}", with: $0) }
            ?? store.t("import_choice_title")
        let choice = store.t("import_choice_msg")
        let message = file == nil ? store.t("transfer_clip_msg") + "\n\n" + choice : choice
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        let scopes: [(String, Backup.Scope)] = [("import_all", .all), ("import_channels_only", .channelsOnly)]
        for (key, scope) in scopes {
            alert.addAction(UIAlertAction(title: store.t(key), style: .default) { _ in
                Task { @MainActor in Self.importNow(file, scope: scope, store: store) }
            })
        }
        alert.addAction(UIAlertAction(title: store.t("cancel"), style: .cancel) { _ in
            Task { @MainActor in logger.info("SAUVEGARDE", "Réglages reçus : import annulé", nil) }
        })
        present(alert)
    }

    /// Import choisi : le presse-papiers lu s'il le faut, la sauvegarde
    /// appliquée, puis ce qui a été repris.
    @MainActor
    private static func importNow(_ file: Backup.File?, scope: Backup.Scope, store: AppStore) {
        var picked = file
        if picked == nil { picked = readPasteboard() }
        guard let file = picked else {
            logger.warn("SAUVEGARDE", "Pas de réglages dans le presse-papiers", nil)
            inform(store.t("transfer_clip_none"), title: store.t("backup"))
            return
        }
        let summary = Backup.apply(file, scope: scope, store: store)
        // Notifications de live de la sauvegarde : l'autorisation d'iOS est
        // demandée ici, comme pour l'import d'un fichier.
        if let on = summary.liveNotifications, on != LiveNotifier.isEnabled {
            if on {
                Task { _ = await LiveNotifier.enable() }
            } else {
                LiveNotifier.disable()
            }
        }
        if scope == .all {
            logger.info("SAUVEGARDE", "Import : \(summary.follows) chaîne(s) ajoutée(s)",
                        "tout · \(summary.settings) réglage(s) repris, \(summary.settingsIgnored) ignoré(s), \(summary.continueWatching) vidéo(s) à reprendre")
        } else {
            logger.info("SAUVEGARDE", "Import : \(summary.follows) chaîne(s) ajoutée(s)", "chaînes seulement")
        }
        // Dans la langue que l'import a peut-être changée.
        inform(Backup.summaryText(summary, scope: scope, store: store), title: store.t("import_sum_title"))
    }

    /// Alerte d'information, un instant après : celle du choix se ferme encore.
    @MainActor
    private static func inform(_ message: String, title: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            Self.present(alert)
        }
    }

    /// Par-dessus tout ce qui est ouvert, feuilles comprises. Ouverte par le
    /// lien, l'app peut ne pas avoir encore de fenêtre : réessayé un moment.
    @MainActor
    private static func present(_ alert: UIAlertController, attempt: Int = 0) {
        guard var top = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first?.rootViewController else {
            guard attempt < 20 else {
                logger.warn("SAUVEGARDE", "Pas de fenêtre pour les réglages reçus", nil)
                return
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                Self.present(alert, attempt: attempt + 1)
            }
            return
        }
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        top.present(alert, animated: true)
    }

    // MARK: Format

    /// Sauvegarde → texte du lien : compressée (DEFLATE), en base64 « URL »
    /// (« - » et « _ », sans « = ») : rien à échapper dans une adresse.
    static func encode(_ data: Data) -> String? {
        guard let packed = deflated(data) else { return nil }
        return packed.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Texte du lien → sauvegarde ; nil s'il est illisible, ou trop gros une
    /// fois décompressé.
    static func decode(_ text: String) -> Data? {
        guard !text.isEmpty, text.utf8.count <= maxPayloadLength else { return nil }
        var b64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let rest = b64.utf8.count % 4
        if rest > 0 { b64 += String(repeating: "=", count: 4 - rest) }
        guard let packed = Data(base64Encoded: b64) else { return nil }
        return inflated(packed)
    }

    /// DEFLATE brut (Compression, COMPRESSION_ZLIB) ; nil en cas d'échec.
    private static func deflated(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        // Au pire, des données incompressibles grossissent un peu.
        let capacity = data.count + data.count / 8 + 1024
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                guard let d = dst.bindMemory(to: UInt8.self).baseAddress,
                      let s = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(d, capacity, s, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        out.count = written
        return out
    }

    /// Inverse de `deflated`, borné : une case de plus que la taille permise,
    /// remplie, veut dire trop gros (une « bombe » de compression ne remplit
    /// pas la mémoire).
    private static func inflated(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let capacity = maxBackupBytes + 1
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                guard let d = dst.bindMemory(to: UInt8.self).baseAddress,
                      let s = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(d, capacity, s, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0, written < capacity else { return nil }
        out.count = written
        return out
    }
}
