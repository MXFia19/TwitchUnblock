import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════
//  « Gérer les retours » : la boîte de réception du propriétaire, comme le
//  panneau de /stats. Liste filtrable, discussion, réponse avec photos,
//  changement d'état, suppression, état du webhook Discord. Voir
//  AdminFeedbackService.
// ═══════════════════════════════════════════════════════════════════════════

private let feedbackStatuses = ["new", "accepted", "progress", "done", "refused"]

// MARK: – Liste
struct AdminFeedbackList: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var admin = AdminFeedbackService.shared
    @Environment(\.dismiss) private var dismiss
    /// "" = tous, "await" = à répondre, sinon un état.
    @State private var filter = ""
    @State private var testing = false
    @State private var testResult: Bool? = nil

    private var shown: [AdminFeedbackItem] {
        admin.items
            .filter { filter.isEmpty || (filter == "await" ? $0.awaiting : $0.status == filter) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: TSpace.sm) {
                webhookLine
                filters
                if shown.isEmpty {
                    TEmptyState(icon: "tray", title: store.t("adm_empty"))
                }
                ForEach(shown) { f in
                    NavigationLink {
                        AdminFeedbackThread(key: f.key)
                    } label: {
                        row(f)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(TSpace.lg)
        }
        .background(Color.tDark.ignoresSafeArea())
        .navigationTitle(store.t("adm_feedback"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(store.t("close")) { dismiss() }
            }
        }
        // Retours et réponses arrivent tout seuls, tant que la liste est là.
        .task {
            while !Task.isCancelled {
                await admin.load()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
        .refreshable { await admin.load() }
    }

    // ── État du webhook Discord ───────────────────────────────────────
    @ViewBuilder private var webhookLine: some View {
        if let w = admin.webhook {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: hookOK(w) ? "checkmark.circle.fill" : (hookBad(w) ? "xmark.octagon.fill" : "minus.circle"))
                        .foregroundColor(hookOK(w) ? .tSuccess : (hookBad(w) ? .tDanger : .tMuted))
                    Text(hookText(w))
                        .font(.tMeta).foregroundColor(.tMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    Task {
                        testing = true
                        testResult = await admin.testWebhook()
                        testing = false
                    }
                } label: {
                    HStack(spacing: 6) {
                        if testing { ProgressView().scaleEffect(0.7) }
                        Text(store.t("adm_hook_test")).font(.tLabel)
                    }
                    .foregroundColor(.tPrimary)
                }
                .buttonStyle(.plain)
                .disabled(testing)
                if testResult == true {
                    Text(store.t("adm_hook_test_ok")).font(.tMeta).foregroundColor(.tSuccess)
                }
            }
            .padding(TSpace.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.tCard)
            .cornerRadius(TRadius.control)
        }
    }

    private func hookOK(_ w: WebhookState) -> Bool { w.configured && w.last?.ok == true }
    private func hookBad(_ w: WebhookState) -> Bool {
        !w.configured || (w.last != nil && w.last?.ok == false && w.last?.detail != "missing")
    }

    private func hookText(_ w: WebhookState) -> String {
        guard w.configured else { return store.t("adm_hook_missing") }
        guard let last = w.last, last.detail != "missing" else { return store.t("adm_hook_never") }
        let when = last.at.map { Date(timeIntervalSince1970: $0 / 1000).formatted(date: .abbreviated, time: .shortened) } ?? ""
        if last.ok == true { return store.t("adm_hook_ok").replacingOccurrences(of: "{d}", with: when) }
        let why = "HTTP \(last.status ?? 0)" + ((last.detail ?? "").isEmpty ? "" : " · \(last.detail ?? "")")
        return store.t("adm_hook_fail").replacingOccurrences(of: "{d}", with: when).replacingOccurrences(of: "{e}", with: why)
    }

    // ── Filtres ────────────────────────────────────────────────────────
    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: TSpace.sm) {
                TChip(title: store.t("adm_all"), isOn: filter.isEmpty) { filter = "" }
                TChip(title: store.t("adm_await") + (admin.awaitingCount > 0 ? " (\(admin.awaitingCount))" : ""),
                      isOn: filter == "await") { filter = "await" }
                ForEach(feedbackStatuses, id: \.self) { s in
                    TChip(title: store.t("fb_status_\(s)"), isOn: filter == s) { filter = s }
                }
            }
        }
    }

    // ── Ligne d'un retour ─────────────────────────────────────────────
    @ViewBuilder
    private func row(_ f: AdminFeedbackItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: TSpace.sm) {
                FeedbackKindTag(kind: f.kind)
                FeedbackStatusPill(status: f.status)
                if f.awaiting {
                    Circle().fill(Color.tWarning).frame(width: 8, height: 8)
                        .accessibilityLabel(store.t("adm_awaiting"))
                }
                Spacer(minLength: 0)
                Text(f.updatedDate.formatted(date: .abbreviated, time: .shortened))
                    .font(.tMeta).foregroundColor(.tMuted)
            }
            Text(f.message)
                .font(.tBody).foregroundColor(.tText)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) {
                Text("\(f.platform == "ios" ? "iOS" : "Web") · \(f.version)")
                if f.count > 1 { Label("\(f.count)", systemImage: "bubble.left.and.bubble.right") }
                if f.photos > 0 { Label("\(f.photos)", systemImage: "photo") }
                if let c = f.contact, !c.isEmpty { Text(c).lineLimit(1) }
            }
            .font(.tMeta).foregroundColor(.tMuted)
        }
        .padding(TSpace.md)
        .background(Color.tCard)
        .cornerRadius(TRadius.control)
        .overlay(RoundedRectangle(cornerRadius: TRadius.control)
            .stroke(f.awaiting ? Color.tWarning.opacity(0.6) : Color.tBorder.opacity(0.6), lineWidth: 1))
    }
}

// MARK: – Discussion
struct AdminFeedbackThread: View {
    let key: String
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var admin = AdminFeedbackService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var reply = ""
    @State private var images: [UIImage] = []
    @State private var sending = false
    @State private var failed = false
    @State private var confirmDelete = false

    private var item: AdminFeedbackItem? { admin.items.first { $0.key == key } }
    private var thread: [FeedbackMessage] {
        admin.threads[key] ?? item.map { [FeedbackMessage(f: "u", m: $0.message, at: $0.at)] } ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: TSpace.sm) {
                        if let item { header(item) }
                        ForEach(Array(thread.enumerated()), id: \.offset) { i, m in
                            message(m).id(i)
                        }
                        if let item { statusPicker(item) }
                    }
                    .padding(TSpace.lg)
                }
                .onChange(of: thread.count) { n in
                    withAnimation { proxy.scrollTo(n - 1, anchor: .bottom) }
                }
            }
            composer
        }
        .background(Color.tDark.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                if let item {
                    HStack(spacing: TSpace.sm) {
                        FeedbackKindTag(kind: item.kind)
                        FeedbackStatusPill(status: item.status)
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive) { confirmDelete = true } label: {
                    Image(systemName: "trash")
                }
                .tint(.tDanger)
            }
        }
        .confirmationDialog(store.t("adm_delete_confirm"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(store.t("adm_delete"), role: .destructive) {
                Task { if await admin.delete(key) { dismiss() } else { failed = true } }
            }
            Button(store.t("cancel"), role: .cancel) {}
        }
        // Discussion relue toutes les 20 s, tant qu'elle est affichée.
        .task {
            while !Task.isCancelled {
                await admin.loadThread(key)
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
        }
    }

    // ── En-tête : d'où vient le retour ────────────────────────────────
    @ViewBuilder
    private func header(_ f: AdminFeedbackItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(f.platform == "ios" ? "App iOS" : "Site") · \(f.version) · \(f.date.formatted(date: .abbreviated, time: .shortened))")
                .font(.tMeta).foregroundColor(.tMuted)
            if let c = f.contact, !c.isEmpty {
                Text("\(store.t("adm_contact")) : \(c)")
                    .font(.tLabel).foregroundColor(.tText)
                    .textSelection(.enabled)
            }
            if let info = f.readableInfo {
                DisclosureGroup(store.t("adm_info")) {
                    Text(info)
                        .font(.system(size: 12).monospaced())
                        .foregroundColor(.tMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .font(.tMeta)
                .tint(.tMuted)
            }
        }
        .padding(TSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.tCard)
        .cornerRadius(TRadius.control)
    }

    // ── Messages ──────────────────────────────────────────────────────
    @ViewBuilder
    private func message(_ m: FeedbackMessage) -> some View {
        if let s = m.s {
            Text(store.t("fb_status_line").replacingOccurrences(of: "{s}", with: store.t("fb_status_\(s)"))
                 + " · " + m.date.formatted(date: .abbreviated, time: .shortened))
                .font(.tMeta).foregroundColor(.tMuted)
                .frame(maxWidth: .infinity)
        } else {
            // Ici, « toi » c'est le développeur : ses messages à droite.
            let mine = m.fromTeam
            HStack {
                if mine { Spacer(minLength: 40) }
                VStack(alignment: .leading, spacing: 6) {
                    if let text = m.m, !text.isEmpty {
                        Text(text).font(.tBody).foregroundColor(.tText)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    if let ph = m.ph, !ph.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(ph, id: \.self) { n in AdminPhoto(key: key, n: n) }
                        }
                    }
                    Text((mine ? store.t("fb_you") : store.t("adm_them")) + " · "
                         + m.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 11)).foregroundColor(.tMuted)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(mine ? Color.tPrimary.opacity(0.22) : Color.tCard)
                .cornerRadius(14)
                if !mine { Spacer(minLength: 40) }
            }
        }
    }

    // ── États ─────────────────────────────────────────────────────────
    private func statusPicker(_ f: AdminFeedbackItem) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: TSpace.sm) {
                ForEach(feedbackStatuses, id: \.self) { s in
                    TChip(title: store.t("fb_status_\(s)"), isOn: f.status == s) {
                        guard f.status != s else { return }
                        Task { if !(await admin.setStatus(key, s)) { failed = true } }
                    }
                }
            }
        }
        .padding(.top, TSpace.sm)
    }

    // ── Réponse ───────────────────────────────────────────────────────
    private var composer: some View {
        VStack(alignment: .leading, spacing: TSpace.sm) {
            if failed {
                Text(store.t("adm_failed")).font(.tMeta).foregroundColor(.tDanger)
            }
            FeedbackPhotoPicker(images: $images)
            HStack(alignment: .bottom, spacing: TSpace.sm) {
                TextField(store.t("adm_reply_ph"), text: $reply, axis: .vertical)
                    .lineLimit(1...5)
                    .font(.tBody).foregroundColor(.tText)
                    .padding(.horizontal, TSpace.md).padding(.vertical, 10)
                    .background(Color.tSurface)
                    .cornerRadius(TRadius.control)
                    .onChange(of: reply) { v in if v.count > 2000 { reply = String(v.prefix(2000)) } }
                Button { Task { await send() } } label: {
                    Group {
                        if sending { ProgressView().tint(.white) }
                        else { Image(systemName: "paperplane.fill").font(.system(size: 15, weight: .bold)) }
                    }
                    .foregroundColor(.white)
                    .frame(width: 42, height: 42)
                    .background(canSend ? Color.tPrimary : Color.tMuted.opacity(0.5))
                    .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel(store.t("fb_reply_send"))
            }
        }
        .padding(TSpace.md)
        .background(Color.tCard.ignoresSafeArea(edges: .bottom))
    }

    private var canSend: Bool {
        !sending && (!reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty)
    }

    private func send() async {
        sending = true
        failed = false
        defer { sending = false }
        let photos = images.compactMap { $0.feedbackJPEG() }
        if await admin.reply(key, message: reply.trimmingCharacters(in: .whitespacesAndNewlines), photos: photos) {
            reply = ""
            images = []
            logger.success("ADMIN", "Réponse envoyée", nil)
        } else {
            failed = true
        }
    }
}

/// Photo d'une discussion, chargée avec le jeton admin.
private struct AdminPhoto: View {
    let key: String
    let n: Int
    @ObservedObject private var admin = AdminFeedbackService.shared
    @State private var image: UIImage? = nil
    @State private var zoom = false

    var body: some View {
        Button { if image != nil { zoom = true } } label: {
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Color.tSurface.overlay(ProgressView().tint(.tMuted))
                }
            }
            .frame(width: 96, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .task { image = await admin.photo(key, n) }
        .fullScreenCover(isPresented: $zoom) {
            ZStack(alignment: .topTrailing) {
                Color.black.ignoresSafeArea()
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                TIconButton(icon: "xmark") { zoom = false }
                    .padding(TSpace.lg)
            }
        }
    }
}
