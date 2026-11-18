import SwiftUI

/// « Mon proxy » (Réglages → Lecteur, sous Ma source) : un proxy HTTP à soi
/// pour le jeton et les playlists du direct (LiveProxy, source « proxy »).
/// Gardé en quittant les champs ou avec « OK » du clavier ; « Tester le
/// proxy » dit s'il marche, et le dernier résultat (direct ou test :
/// injoignable, identifiants refusés…) s'affiche dessous.
struct LiveProxyRow: View {
    @EnvironmentObject private var store: AppStore
    @State private var address = ""
    @State private var user = ""
    @State private var password = ""
    @State private var refused = false
    @State private var testing = false
    @State private var status: LiveProxy.Status? = nil
    @FocusState private var focused: Field?

    private enum Field: Hashable { case address, user, password }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(store.t("src_proxy")).font(.tCardTitle).foregroundColor(.tText)
            Text(store.t("src_proxy_sub"))
                .font(.tMeta).foregroundColor(.tMuted)
                .fixedSize(horizontal: false, vertical: true)
            TextField("proxy.example.com:8080", text: $address)
                .font(.tBody).foregroundColor(.tText)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.done)
                .focused($focused, equals: .address)
                .onSubmit { apply() }
                .padding(.horizontal, TSpace.md)
                .frame(minHeight: 44)
                .background(Color.tSurface)
                .cornerRadius(TRadius.control)
            // Identifiants : seulement pour un proxy saisi ou réglé.
            if !store.liveProxy.isEmpty || !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                TextField(store.t("src_proxy_user"), text: $user)
                    .font(.tBody).foregroundColor(.tText)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.done)
                    .focused($focused, equals: .user)
                    .onSubmit { apply() }
                    .padding(.horizontal, TSpace.md)
                    .frame(minHeight: 44)
                    .background(Color.tSurface)
                    .cornerRadius(TRadius.control)
                SecureField(store.t("src_proxy_password"), text: $password)
                    .font(.tBody).foregroundColor(.tText)
                    .submitLabel(.done)
                    .focused($focused, equals: .password)
                    .onSubmit { apply() }
                    .padding(.horizontal, TSpace.md)
                    .frame(minHeight: 44)
                    .background(Color.tSurface)
                    .cornerRadius(TRadius.control)
            }
            if !store.liveProxy.isEmpty {
                Button { test() } label: {
                    HStack(spacing: 6) {
                        if testing { ProgressView().scaleEffect(0.7) }
                        Text(store.t("src_proxy_test"))
                    }
                }
                .font(.tLabel)
                .buttonStyle(.borderless)
                .disabled(testing)
            }
            if refused {
                Text(store.t("src_proxy_bad")).font(.tMeta).foregroundColor(.tDanger)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let status, !store.liveProxy.isEmpty, !testing {
                Text(store.t(status.messageKey).replacingOccurrences(of: "{c}", with: status.code))
                    .font(.tMeta).foregroundColor(status == .ok ? .tSuccess : .tDanger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            address = store.liveProxy
            user = store.liveProxyUser
            password = store.liveProxy.isEmpty ? "" : LiveProxy.password
            status = LiveProxy.lastStatus
        }
        // Gardé en quittant le dernier champ (pas en passant de l'un à l'autre).
        .onChange(of: focused) { field in
            if field == nil { apply() }
        }
        .onDisappear { apply() }
    }

    /// Proxy saisi : gardé si l'adresse est valable (sinon on le dit, et
    /// l'ancien reste). Rien ne se passe si rien n'a changé.
    private func apply() {
        let wanted = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = wanted.isEmpty ? "" : (LiveProxy.normalized(wanted) ?? wanted)
        let name = user.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = store.liveProxy.isEmpty ? "" : LiveProxy.password
        guard normalized != store.liveProxy || name != store.liveProxyUser || password != secret else {
            refused = false
            return
        }
        refused = !store.setLiveProxy(wanted, user: name, password: password)
        guard !refused else { return }
        address = store.liveProxy
        user = store.liveProxyUser
        if store.liveProxy.isEmpty { password = "" }
        // Résultat d'un autre proxy (ou d'autres identifiants) : périmé.
        status = nil
        logger.settingChanged("Mon proxy", value: store.liveProxy.isEmpty ? "aucun" : LiveProxy.logLabel)
    }

    /// « Tester le proxy » : ce qui est saisi d'abord gardé, puis une petite
    /// demande à Twitch par lui (LiveProxy.check).
    private func test() {
        apply()
        guard !testing, !refused, !store.liveProxy.isEmpty else { return }
        focused = nil
        testing = true
        status = nil
        Task { @MainActor in
            let result = await LiveProxy.check()
            testing = false
            status = result
        }
    }
}
