import SwiftUI
import UIKit

// ═══════════════════════════════════════════════════════════════════════════
//  Retour (bug, idée, autre) envoyé au Worker, qui le range (base D1) et le
//  transmet sur Discord. Ce qui part est affiché avant l'envoi : le message,
//  le contact s'il est rempli, le modèle d'iPhone, la version d'iOS et de
//  l'app, la langue. Ni compte Twitch ni identifiant d'installation.
// ═══════════════════════════════════════════════════════════════════════════

struct FeedbackSheet: View {
    enum Kind: String, CaseIterable, Identifiable {
        case bug, idea, other
        var id: String { rawValue }
        var label: String { "fb_\(rawValue)" }
        var placeholder: String { "fb_ph_\(rawValue)" }
    }

    /// Ce qui se lisait (« live xqc », « vod xqc 2893568220 ») quand le
    /// formulaire a été ouvert depuis le lecteur.
    let context: String?

    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var kind: Kind
    @State private var message = ""
    @State private var contact = ""
    @State private var sending = false
    @State private var failure: String? = nil
    @State private var sent = false
    @FocusState private var messageFocused: Bool

    init(initialKind: Kind = .bug, context: String? = nil) {
        self.context = context
        _kind = State(initialValue: initialKind)
    }

    private var trimmed: String { message.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Infos techniques jointes : de quoi reproduire un bug, rien de plus.
    private var info: [String: String] {
        var sys = utsname()
        uname(&sys)
        var machine = sys.machine
        let model = withUnsafeBytes(of: &machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        var out: [String: String] = [
            "device": model,
            "ios": UIDevice.current.systemVersion,
            "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?",
            "lang": store.lang.rawValue,
        ]
        if let context, !context.isEmpty { out["watching"] = context }
        return out
    }

    private var infoSummary: String {
        let i = info
        let base = "\(i["device"] ?? "?") · iOS \(i["ios"] ?? "?") · \(UsageService.shared.appVersion) (\(i["build"] ?? "?")) · \(i["lang"] ?? "")"
        if let watching = i["watching"] { return base + " · " + watching }
        return base
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(store.t("feedback"))
                    .font(.tSection).foregroundColor(.tText)
                    .lineLimit(2)
                Spacer(minLength: TSpace.sm)
                TIconButton(icon: "xmark") { dismiss() }
            }
            .padding(TSpace.lg)

            ScrollView {
                VStack(alignment: .leading, spacing: TSpace.md) {
                    Picker("", selection: $kind) {
                        ForEach(Kind.allCases) { k in Text(store.t(k.label)).tag(k) }
                    }
                    .pickerStyle(.segmented)

                    ZStack(alignment: .topLeading) {
                        if message.isEmpty {
                            Text(store.t(kind.placeholder))
                                .font(.tBody).foregroundColor(.tMuted)
                                .padding(.horizontal, 13).padding(.vertical, 12)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $message)
                            .font(.tBody).foregroundColor(.tText)
                            .scrollContentBackground(.hidden)
                            .focused($messageFocused)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .onChange(of: message) { v in
                                if v.count > 2000 { message = String(v.prefix(2000)) }
                            }
                    }
                    .frame(minHeight: 150)
                    .background(Color.tSurface)
                    .cornerRadius(TRadius.control)

                    TextField(store.t("fb_contact_ph"), text: $contact)
                        .font(.tBody).foregroundColor(.tText)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .padding(.horizontal, TSpace.md)
                        .frame(height: 44)
                        .background(Color.tSurface)
                        .cornerRadius(TRadius.control)
                        .onChange(of: contact) { v in
                            if v.count > 100 { contact = String(v.prefix(100)) }
                        }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.t("fb_info")).font(.tMeta).foregroundColor(.tMuted)
                        Text(infoSummary).font(.tMeta).foregroundColor(.tText.opacity(0.75))
                    }

                    if let failure {
                        Text(failure).font(.tMeta).foregroundColor(.tDanger)
                    }

                    if sent {
                        Label(store.t("fb_thanks"), systemImage: "checkmark.circle.fill")
                            .font(.tLabel).foregroundColor(.tSuccess)
                    } else {
                        Button { Task { await send() } } label: {
                            HStack(spacing: TSpace.sm) {
                                if sending {
                                    ProgressView().tint(.white)
                                } else {
                                    Image(systemName: "paperplane.fill").font(.system(size: 13, weight: .bold))
                                    Text(store.t("fb_send")).font(.tLabel)
                                }
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(trimmed.count >= 5 ? Color.tPrimary : Color.tMuted.opacity(0.5))
                            .cornerRadius(TRadius.control)
                        }
                        .buttonStyle(.plain)
                        .disabled(sending || trimmed.count < 5)
                    }
                }
                .padding(.horizontal, TSpace.lg)
                .padding(.bottom, TSpace.xl)
            }
        }
        .background(Color.tDark.ignoresSafeArea())
        .onAppear { messageFocused = true }
    }

    private func send() async {
        guard trimmed.count >= 5, let url = URL(string: "\(kAPIURL)/api/feedback") else { return }
        sending = true
        failure = nil
        defer { sending = false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "kind": kind.rawValue,
            "message": trimmed,
            "contact": contact.trimmingCharacters(in: .whitespacesAndNewlines),
            "platform": "ios",
            "version": UsageService.shared.appVersion,
            "info": info,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                failure = store.t(code == 429 ? "fb_too_many" : "fb_failed")
                logger.warn("FEEDBACK", "Retour refusé", "HTTP \(code)")
                return
            }
            logger.success("FEEDBACK", "Retour envoyé", kind.rawValue)
            withAnimation { sent = true }
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            dismiss()
        } catch {
            failure = store.t("fb_failed")
            logger.warn("FEEDBACK", "Envoi impossible", error.localizedDescription)
        }
    }
}
