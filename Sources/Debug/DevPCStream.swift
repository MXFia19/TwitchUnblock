import Foundation
import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════
//  « Envoyer au PC » (TU Dev) : chaque requête finie part, par lots, vers le
//  petit serveur de tools/devlog lancé sur le PC (même Wi-Fi), qui la montre
//  dans une page façon onglet Réseau. L'adresse et le code qu'il affiche au
//  démarrage se règlent dans l'onglet PC de l'inspecteur. Jetons et cookies
//  partent masqués, sauf si « Envoyer aussi les secrets » est allumé (le
//  réseau local voit passer ce HTTP en clair). Ses propres envois portent
//  l'en-tête X-TU-DevLog : NetCapture ne les note pas.
// ═══════════════════════════════════════════════════════════════════════════

enum DevSecrets {
    static let headerNames: Set<String> = ["authorization", "cookie", "set-cookie", "client-integrity"]
    static let maskText = "•••• (masqué)"
}

final class DevPCStream: ObservableObject {
    static let shared = DevPCStream()
    static let marker = "X-TU-DevLog"

    private struct Settings {
        var enabled = false
        var address = ""
        var code = ""
        var secrets = false
    }

    @Published var enabled: Bool { didSet { store() } }
    /// « 192.168.1.20:8787 », comme l'affiche le serveur.
    @Published var address: String { didSet { store() } }
    @Published var code: String { didSet { store() } }
    @Published var includeSecrets: Bool { didSet { store() } }
    @Published private(set) var sent = 0
    @Published private(set) var lastError: String? = nil

    private let lock = NSLock()
    private var current = Settings()
    private let work = DispatchQueue(label: "tu.dev.pcstream")
    /// File d'attente (fil `work`) : 300 requêtes au plus, numérotées.
    private var pending: [(seq: Int, json: [String: Any])] = []
    private var nextSeq = 1
    private var inFlight = false
    private let session = URLSession(configuration: .ephemeral)

    private init() {
        let ud = UserDefaults.standard
        enabled = ud.bool(forKey: "dev_pc_enabled")
        address = ud.string(forKey: "dev_pc_address") ?? ""
        code = ud.string(forKey: "dev_pc_code") ?? ""
        includeSecrets = ud.bool(forKey: "dev_pc_secrets")
        current = Settings(enabled: enabled, address: address, code: code, secrets: includeSecrets)
    }

    private func store() {
        let ud = UserDefaults.standard
        ud.set(enabled, forKey: "dev_pc_enabled")
        ud.set(address, forKey: "dev_pc_address")
        ud.set(code, forKey: "dev_pc_code")
        ud.set(includeSecrets, forKey: "dev_pc_secrets")
        lock.lock()
        current = Settings(enabled: enabled, address: address, code: code, secrets: includeSecrets)
        lock.unlock()
        if enabled { work.async { self.flush() } }
    }

    private var settings: Settings {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    /// Requête finie (NetCapture.finish, n'importe quel fil).
    func enqueue(_ entry: NetEntry) {
        let s = settings
        guard s.enabled else { return }
        work.async {
            self.pending.append((seq: self.nextSeq, json: Self.json(entry, secrets: s.secrets)))
            self.nextSeq += 1
            if self.pending.count > 300 { self.pending.removeFirst(self.pending.count - 300) }
            self.flush()
        }
    }

    /// Un lot de 50 au plus ; le suivant après la réponse, ou 3 s après un échec.
    private func flush() {
        let s = settings
        guard s.enabled, !inFlight, !pending.isEmpty, let base = request(s) else { return }
        let batch = Array(pending.prefix(50))
        guard let body = try? JSONSerialization.data(withJSONObject: ["entries": batch.map { $0.json }]) else {
            pending.removeFirst(batch.count)
            return
        }
        let last = batch[batch.count - 1].seq
        var req = base
        req.httpBody = body
        inFlight = true
        session.dataTask(with: req) { [weak self] _, response, error in
            guard let self else { return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            self.work.async {
                self.inFlight = false
                if status == 200 {
                    self.pending.removeAll { $0.seq <= last }
                    DispatchQueue.main.async {
                        self.sent += batch.count
                        self.lastError = nil
                    }
                    self.flush()
                } else {
                    let message = status == 403 ? "code refusé par le serveur"
                        : error?.localizedDescription ?? "réponse \(status)"
                    DispatchQueue.main.async { self.lastError = message }
                    self.work.asyncAfter(deadline: .now() + 3) { self.flush() }
                }
            }
        }.resume()
    }

    private func request(_ s: Settings) -> URLRequest? {
        let host = s.address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !s.code.isEmpty,
              let url = URL(string: host.lowercased().hasPrefix("http") ? "\(host)/log" : "http://\(host)/log") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 5)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(s.code.trimmingCharacters(in: .whitespaces), forHTTPHeaderField: "X-TU-Code")
        req.setValue("1", forHTTPHeaderField: Self.marker)
        return req
    }

    // MARK: Requête en JSON

    static func json(_ e: NetEntry, secrets: Bool) -> [String: Any] {
        func headers(_ h: [String: String]) -> [String: String] {
            guard !secrets else { return h }
            var out = h
            for k in h.keys where DevSecrets.headerNames.contains(k.lowercased()) { out[k] = DevSecrets.maskText }
            return out
        }
        func body(_ data: Data?) -> [String: Any]? {
            guard let data, !data.isEmpty else { return nil }
            guard let text = String(data: data, encoding: .utf8) else { return ["base64": data.base64EncodedString()] }
            if !secrets, let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
               let masked = try? JSONSerialization.data(withJSONObject: DevFormat.masked(obj), options: [.fragmentsAllowed]),
               let maskedText = String(data: masked, encoding: .utf8) {
                return ["text": maskedText]
            }
            return ["text": text]
        }
        var o: [String: Any] = [
            "id": e.id,
            "started": e.started.timeIntervalSince1970 * 1000,
            "method": e.method,
            "url": e.url.absoluteString,
            "name": e.name,
            "kind": NetKind.of(e).rawValue,
            "requestHeaders": headers(e.requestHeaders),
            "responseHeaders": headers(e.responseHeaders),
            "bytes": e.bytes,
            "truncated": e.responseTruncated,
        ]
        if let f = e.finalURL { o["finalURL"] = f.absoluteString }
        if let s = e.status { o["status"] = s }
        if let m = e.mime { o["mime"] = m }
        if let d = e.duration { o["duration"] = d * 1000 }
        if let err = e.error { o["error"] = err }
        if let op = e.gqlOperation { o["gql"] = op }
        if let b = body(e.requestBody) { o["requestBody"] = b }
        if let b = body(e.responseBody) { o["responseBody"] = b }
        return o
    }
}

// MARK: – Onglet PC de l'inspecteur

struct DevPCPanel: View {
    @ObservedObject private var stream = DevPCStream.shared

    var body: some View {
        List {
            Section {
                Toggle("Envoyer au PC", isOn: $stream.enabled)
                TextField("Adresse (ex. 192.168.1.20:8787)", text: $stream.address)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Code", text: $stream.code)
                    .keyboardType(.numberPad)
                Toggle("Envoyer aussi les secrets (jetons, cookies)", isOn: $stream.includeSecrets)
            } footer: {
                Text("Les requêtes finies partent par lots vers le serveur, avec leurs réponses. Les secrets sont masqués d'office : ce HTTP passe en clair sur le Wi-Fi.")
            }
            Section("État") {
                DevRow(label: "Requêtes envoyées", value: "\(stream.sent)")
                if let error = stream.lastError {
                    DevRow(label: "Dernière erreur", value: error)
                }
            }
            Section("Sur le PC") {
                Text("1. Dans le dossier de la branche dev-17d298 : node tools/devlog/server.mjs")
                Text("2. Autorise Node dans le pare-feu de Windows (réseaux privés).")
                Text("3. Tape ici l'adresse et le code qu'il affiche, puis ouvre http://localhost:8787 sur le PC.")
                Text("iPhone et PC sur le même Wi-Fi. La première fois, iOS demande l'accès au réseau local : accepte.")
                    .foregroundColor(.secondary)
            }
            .font(.callout)
        }
        .listStyle(.insetGrouped)
    }
}
