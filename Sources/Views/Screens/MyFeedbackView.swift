import SwiftUI
import PhotosUI

// ═══════════════════════════════════════════════════════════════════════════
//  « Mes signalements » : les retours envoyés depuis l'app, leur état, et la
//  discussion avec le développeur (réponses, captures). Voir FeedbackStore.
// ═══════════════════════════════════════════════════════════════════════════

// MARK: – Captures jointes
/// Choix de 3 captures au plus, en vignettes retirables.
struct FeedbackPhotoPicker: View {
    @Binding var images: [UIImage]
    @EnvironmentObject private var store: AppStore
    @State private var items: [PhotosPickerItem] = []

    var body: some View {
        VStack(alignment: .leading, spacing: TSpace.sm) {
            if !images.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: TSpace.sm) {
                        ForEach(Array(images.enumerated()), id: \.offset) { i, img in
                            Image(uiImage: img)
                                .resizable().scaledToFill()
                                .frame(width: 72, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(alignment: .topTrailing) {
                                    Button {
                                        images.remove(at: i)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 18))
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, .black.opacity(0.65))
                                    }
                                    .buttonStyle(.plain)
                                    .padding(3)
                                }
                        }
                    }
                }
            }
            if images.count < 3 {
                PhotosPicker(selection: $items, maxSelectionCount: 3 - images.count, matching: .images) {
                    Label(store.t("fb_add_photos"), systemImage: "photo.on.rectangle.angled")
                        .font(.tLabel).foregroundColor(.tPrimary)
                        .padding(.horizontal, TSpace.md).frame(height: 34)
                        .background(Color.tPrimary.opacity(0.12))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .onChange(of: items) { picked in
            guard !picked.isEmpty else { return }
            Task {
                for item in picked {
                    guard images.count < 3,
                          let data = try? await item.loadTransferable(type: Data.self),
                          let img = UIImage(data: data) else { continue }
                    images.append(img)
                }
                items = []
            }
        }
    }
}

// MARK: – Liste
struct MyFeedbackList: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var inbox = FeedbackStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            LazyVStack(spacing: TSpace.sm) {
                if inbox.reports.isEmpty {
                    TEmptyState(icon: "tray", title: store.t("fb_mine"), message: store.t("fb_mine_empty"))
                }
                ForEach(inbox.reports.sorted { $0.updatedAt > $1.updatedAt }) { r in
                    NavigationLink {
                        FeedbackThreadView(id: r.id)
                    } label: {
                        row(r)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(TSpace.lg)
        }
        .background(Color.tDark.ignoresSafeArea())
        .navigationTitle(store.t("fb_mine"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(store.t("close")) { dismiss() }
            }
        }
        // Liste à jour toute seule : état et réponses arrivent sans tirer
        // pour rafraîchir. Arrêté dès que la liste n'est plus affichée.
        .task {
            while !Task.isCancelled {
                await inbox.refresh(force: true)
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
        .refreshable { await inbox.refresh(force: true) }
    }

    @ViewBuilder
    private func row(_ r: MyFeedback) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: TSpace.sm) {
                FeedbackKindTag(kind: r.kind)
                FeedbackStatusPill(status: r.status)
                if r.unread {
                    Circle().fill(Color.tLive).frame(width: 8, height: 8)
                }
                Spacer(minLength: 0)
                Text(r.updatedAtDate.formatted(date: .abbreviated, time: .shortened))
                    .font(.tMeta).foregroundColor(.tMuted)
            }
            Text(r.text)
                .font(.tBody).foregroundColor(.tText)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(TSpace.md)
        .background(Color.tCard)
        .cornerRadius(TRadius.control)
        .overlay(RoundedRectangle(cornerRadius: TRadius.control)
            .stroke(r.unread ? Color.tPrimary.opacity(0.6) : Color.tBorder.opacity(0.6), lineWidth: 1))
    }
}

private extension MyFeedback {
    var updatedAtDate: Date { Date(timeIntervalSince1970: updatedAt / 1000) }
}

struct FeedbackKindTag: View {
    let kind: String
    @EnvironmentObject private var store: AppStore
    var body: some View {
        let tint: Color = kind == "bug" ? .tDanger : (kind == "idea" ? .tPurple : .tMuted)
        Text(store.t("fb_\(kind)"))
            .font(.tBadge).foregroundColor(tint)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(tint.opacity(0.15))
            .cornerRadius(6)
    }
}

struct FeedbackStatusPill: View {
    let status: String
    @EnvironmentObject private var store: AppStore
    var body: some View {
        let tint: Color = {
            switch status {
            case "accepted": return .tOutplayer
            case "progress": return .tWarning
            case "done":     return .tSuccess
            case "refused":  return .tDanger
            default:         return .tMuted
            }
        }()
        Text(store.t("fb_status_\(status)"))
            .font(.tBadge).foregroundColor(tint)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(tint.opacity(0.15))
            .clipShape(Capsule())
    }
}

// MARK: – Discussion
struct FeedbackThreadView: View {
    let id: String
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var inbox = FeedbackStore.shared
    @State private var reply = ""
    @State private var images: [UIImage] = []
    @State private var sending = false
    @State private var failed = false
    @State private var zoomed: URL? = nil

    private var report: MyFeedback? { inbox.reports.first { $0.id == id } }

    var body: some View {
        VStack(spacing: 0) {
            if let r = report {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: TSpace.sm) {
                            ForEach(Array(r.messages.enumerated()), id: \.offset) { i, m in
                                message(m, in: r).id(i)
                            }
                        }
                        .padding(TSpace.lg)
                    }
                    .onAppear { proxy.scrollTo(r.messages.count - 1, anchor: .bottom) }
                    .onChange(of: r.messages.count) { n in
                        withAnimation { proxy.scrollTo(n - 1, anchor: .bottom) }
                    }
                }
                composer
            } else {
                TEmptyState(icon: "tray", title: store.t("fb_gone"))
                    .frame(maxHeight: .infinity)
            }
        }
        .background(Color.tDark.ignoresSafeArea())
        .toolbar {
            ToolbarItem(placement: .principal) {
                if let r = report {
                    HStack(spacing: TSpace.sm) {
                        FeedbackKindTag(kind: r.kind)
                        FeedbackStatusPill(status: r.status)
                    }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        // Discussion ouverte : relue toutes les 20 s, la réponse apparaît
        // sans rien toucher. La tâche s'arrête quand on quitte l'écran.
        .task {
            inbox.markSeen(id)
            while !Task.isCancelled {
                await inbox.refresh(force: true)
                inbox.markSeen(id)
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
        }
        .sheet(item: Binding(get: { zoomed.map(ZoomedPhoto.init) }, set: { zoomed = $0?.url })) { z in
            ZoomedPhotoView(url: z.url)
        }
    }

    @ViewBuilder
    private func message(_ m: FeedbackMessage, in r: MyFeedback) -> some View {
        if let s = m.s {
            Text(store.t("fb_status_line").replacingOccurrences(of: "{s}", with: store.t("fb_status_\(s)"))
                 + " · " + m.date.formatted(date: .abbreviated, time: .shortened))
                .font(.tMeta).foregroundColor(.tMuted)
                .frame(maxWidth: .infinity)
        } else {
            let mine = !m.fromTeam
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
                            ForEach(ph, id: \.self) { n in
                                if let url = inbox.photoURL(r, n) {
                                    Button { zoomed = url } label: {
                                        AsyncImage(url: url) { img in
                                            img.resizable().scaledToFill()
                                        } placeholder: {
                                            Color.tSurface.overlay(ProgressView().tint(.tMuted))
                                        }
                                        .frame(width: 96, height: 96)
                                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    Text((mine ? store.t("fb_you") : store.t("fb_team")) + " · "
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

    private var composer: some View {
        VStack(alignment: .leading, spacing: TSpace.sm) {
            if failed {
                Text(store.t("fb_reply_failed")).font(.tMeta).foregroundColor(.tDanger)
            }
            FeedbackPhotoPicker(images: $images)
            HStack(alignment: .bottom, spacing: TSpace.sm) {
                TextField(store.t("fb_reply_ph"), text: $reply, axis: .vertical)
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
        let ok = await inbox.reply(id, message: reply.trimmingCharacters(in: .whitespacesAndNewlines),
                                   photos: photos)
        if ok {
            reply = ""
            images = []
            logger.success("FEEDBACK", "Réponse envoyée", nil)
        } else {
            failed = true
        }
    }
}

// MARK: – Photo en grand
private struct ZoomedPhoto: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

private struct ZoomedPhotoView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            AsyncImage(url: url) { img in
                img.resizable().scaledToFit()
            } placeholder: {
                ProgressView().tint(.white)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            TIconButton(icon: "xmark") { dismiss() }
                .padding(TSpace.lg)
        }
    }
}
