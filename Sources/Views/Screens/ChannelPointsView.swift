import SwiftUI

// MARK: – Bouton déclencheur (dans la barre de chat)
struct ChannelPointsButton: View {
    @ObservedObject var service: ChannelPointsService
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .topTrailing) {
                // Fond : vert si bonus dispo, violet sinon
                Circle()
                    .fill(service.pendingClaimId != nil ? Color.tSuccess : Color(hex: "1f1f23"))
                    .frame(width: 40, height: 40)
                    .overlay(Circle().stroke(
                        service.pendingClaimId != nil ? Color.tSuccess : Color.tBorder,
                        lineWidth: 1.5
                    ))
                    // Pulse animé quand coffre dispo
                    .shadow(color: service.pendingClaimId != nil
                            ? Color.tSuccess.opacity(0.6) : .clear,
                            radius: 6)

                Image(systemName: "crown.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(service.pendingClaimId != nil ? .white : .tPrimary)

                // Point blanc si bonus disponible
                if service.pendingClaimId != nil {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 9, height: 9)
                        .offset(x: 2, y: -2)
                }
            }
            .overlay(alignment: .top) {
                // Badge "+X pts" qui apparaît brièvement après un gain
                if service.lastBalanceChange > 0 {
                    Text("+\(service.lastBalanceChange)")
                        .font(.system(size: 10, weight: .black))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.tSuccess)
                        .cornerRadius(8)
                        .offset(y: -14)
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal:   .move(edge: .top).combined(with: .opacity)
                        ))
                }
            }
        }
        .frame(width: 40, height: 44)
    }
}

// MARK: – Sheet principale
struct ChannelPointsSheet: View {
    @ObservedObject var service: ChannelPointsService
    var onConnect: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    @State private var rewardForInput: ChannelReward? = nil   // récompense nécessitant du texte
    @State private var userInput      = ""
    @State private var isRedeeming    = false
    @State private var redeemResult:  RedeemResult? = nil

    enum RedeemResult { case success(String); case failure(String) }

    var body: some View {
        VStack(spacing: 0) {

            // ── Handle + header ─────────────────────────────────────
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.tBorder)
                .frame(width: 40, height: 4)
                .padding(.top, 10)
                .padding(.bottom, 14)

            HStack(spacing: 10) {
                Image(systemName: "crown.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.tPrimary)

                Text("Points de chaîne")
                    .font(.system(size: 17, weight: .heavy))
                    .foregroundColor(.tText)

                Spacer()

                // Balance (masquée tant que le compte n'est pas connecté pour les points)
                if !service.isLoading && !service.needsWebLogin {
                    HStack(spacing: 4) {
                        Image(systemName: "crown.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.tPrimary)
                        Text(service.formatted(service.balance))
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.tText)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.tSurface)
                    .cornerRadius(20)
                    .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.tBorder, lineWidth: 1))
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            // ── Message de retour (succès / erreur) ──────────────────
            if let result = redeemResult {
                HStack(spacing: 8) {
                    switch result {
                    case .success(let msg):
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.tSuccess)
                        Text(msg).foregroundColor(.tSuccess)
                    case .failure(let msg):
                        Image(systemName: "xmark.circle.fill").foregroundColor(.tDanger)
                        Text(msg).foregroundColor(.tDanger)
                    }
                }
                .font(.system(size: 13, weight: .semibold))
                .padding(10)
                .frame(maxWidth: .infinity)
                .background(Color.tSurface)
                .cornerRadius(10)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            Divider().background(Color.tBorder)

            // ── Bandeau connexion (token web manquant/expiré) ────────
            if service.needsWebLogin {
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: "lock.circle.fill")
                            .font(.system(size: 22))
                            .foregroundColor(.tPrimary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Connecte ton compte Twitch")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.tText)
                            Text("Nécessaire pour afficher ton solde et réclamer les coffres.")
                                .font(.system(size: 11))
                                .foregroundColor(.tMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    Button(action: onConnect) {
                        HStack(spacing: 8) {
                            Image(systemName: "person.crop.circle.badge.checkmark")
                            Text("Se connecter").font(.system(size: 14, weight: .bold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.tPrimary)
                        .cornerRadius(12)
                    }
                }
                .padding(14)
                .background(Color.tCard)
                .cornerRadius(14)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.tBorder, lineWidth: 1))
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }

            // ── Contenu ──────────────────────────────────────────────
            if service.isLoading {
                Spacer()
                VStack(spacing: 12) {
                    ProgressView().tint(.tPrimary).scaleEffect(1.2)
                    Text("Chargement des récompenses…")
                        .font(.system(size: 13))
                        .foregroundColor(.tMuted)
                }
                Spacer()

            } else if service.rewards.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "crown")
                        .font(.system(size: 40))
                        .foregroundColor(.tMuted)
                    Text("Aucune récompense disponible")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.tMuted)
                }
                Spacer()

            } else {
                ScrollView {
                    VStack(spacing: 0) {

                        // ── Bouton "Réclamer le bonus" ────────────────
                        if service.pendingClaimId != nil {
                            Button {
                                Task {
                                    await service.claimBonus()
                                    withAnimation {
                                        redeemResult = .success("Bonus réclamé ! 🎉")
                                    }
                                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                                    withAnimation { redeemResult = nil }
                                }
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "gift.fill")
                                        .font(.system(size: 18))
                                    Text("Réclamer le bonus")
                                        .font(.system(size: 15, weight: .bold))
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 13))
                                        .foregroundColor(.white.opacity(0.7))
                                }
                                .foregroundColor(.white)
                                .padding(.horizontal, 16).padding(.vertical, 14)
                                .background(Color.tSuccess)
                                .cornerRadius(12)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        }

                        // ── Liste des récompenses ─────────────────────
                        LazyVStack(spacing: 1) {
                            ForEach(service.rewards) { reward in
                                RewardRow(
                                    reward:    reward,
                                    canAfford: service.balance >= reward.cost,
                                    service:   service,
                                    isRedeeming: isRedeeming
                                ) { result in
                                    withAnimation { redeemResult = result }
                                    Task {
                                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                                        withAnimation { redeemResult = nil }
                                    }
                                } onNeedsInput: {
                                    rewardForInput = reward
                                    userInput = ""
                                }
                            }
                        }
                        .padding(.bottom, 24)
                    }
                }
            }
        }
        .background(Color.tDark)
        // ── Sheet saisie texte ──────────────────────────────────────
        .sheet(item: $rewardForInput) { reward in
            UserInputSheet(
                reward: reward,
                userInput: $userInput,
                isRedeeming: $isRedeeming
            ) {
                Task {
                    isRedeeming = true
                    let ok = await service.redeem(reward: reward, userInput: userInput)
                    isRedeeming = false
                    rewardForInput = nil
                    withAnimation {
                        redeemResult = ok
                            ? .success("« \(reward.title) » réclamé ✓")
                            : .failure(service.errorMsg ?? "Erreur")
                    }
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    withAnimation { redeemResult = nil }
                }
            }
        }
    }
}

// MARK: – Ligne de récompense
private struct RewardRow: View {
    let reward:    ChannelReward
    let canAfford: Bool
    let service:   ChannelPointsService
    let isRedeeming: Bool
    let onResult:  (ChannelPointsSheet.RedeemResult) -> Void
    let onNeedsInput: () -> Void

    @State private var localRedeeming = false

    var body: some View {
        HStack(spacing: 12) {

            // ── Icône / image de la récompense ──────────────────────
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(hex: reward.backgroundColor).opacity(0.25))
                    .frame(width: 48, height: 48)

                if let imgURL = reward.imageURL, let url = URL(string: imgURL) {
                    AsyncImage(url: url) { phase in
                        if let img = phase.image {
                            img.resizable().scaledToFit().padding(6)
                        } else {
                            rewardFallbackIcon
                        }
                    }
                    .frame(width: 48, height: 48)
                } else {
                    rewardFallbackIcon
                }
            }

            // ── Titre + prompt ───────────────────────────────────────
            VStack(alignment: .leading, spacing: 3) {
                Text(reward.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(reward.canRedeem && canAfford ? .tText : .tMuted)
                    .lineLimit(2)

                if let prompt = reward.prompt, !prompt.isEmpty {
                    Text(prompt)
                        .font(.system(size: 11))
                        .foregroundColor(.tMuted)
                        .lineLimit(1)
                }

                if !reward.isInStock {
                    Text("Rupture de stock")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.tDanger)
                } else if reward.isPaused {
                    Text("En pause")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.tWarning)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // ── Coût + bouton ────────────────────────────────────────
            VStack(spacing: 6) {
                HStack(spacing: 3) {
                    Image(systemName: "crown.fill")
                        .font(.system(size: 9, weight: .bold))
                    Text(service.formatted(reward.cost))
                        .font(.system(size: 12, weight: .bold))
                }
                .foregroundColor(canAfford ? .tPrimary : .tMuted)

                if reward.canRedeem {
                    Button {
                        if reward.isUserInputRequired {
                            onNeedsInput()
                        } else {
                            Task {
                                localRedeeming = true
                                let ok = await service.redeem(reward: reward)
                                localRedeeming = false
                                onResult(ok
                                    ? .success("« \(reward.title) » réclamé ✓")
                                    : .failure(service.errorMsg ?? "Erreur")
                                )
                            }
                        }
                    } label: {
                        Group {
                            if localRedeeming {
                                ProgressView().tint(.white).scaleEffect(0.7)
                            } else {
                                Text(canAfford ? "Racheter" : "Insuff.")
                                    .font(.system(size: 11, weight: .bold))
                            }
                        }
                        .frame(width: 68, height: 28)
                        .background(canAfford ? Color.tPrimary : Color.tSurface)
                        .foregroundColor(canAfford ? .white : .tMuted)
                        .cornerRadius(14)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(canAfford ? Color.clear : Color.tBorder, lineWidth: 1)
                        )
                    }
                    .disabled(localRedeeming || isRedeeming || !canAfford)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.tCard)
    }

    private var rewardFallbackIcon: some View {
        Image(systemName: "crown.fill")
            .font(.system(size: 20))
            .foregroundColor(Color(hex: reward.backgroundColor))
    }
}

// MARK: – Sheet saisie texte (pour les récompenses avec input)
private struct UserInputSheet: View {
    let reward: ChannelReward
    @Binding var userInput: String
    @Binding var isRedeeming: Bool
    let onConfirm: () -> Void

    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Handle
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.tBorder)
                .frame(width: 40, height: 4)
                .padding(.top, 10)
                .padding(.bottom, 20)

            // Titre
            Text(reward.title)
                .font(.system(size: 18, weight: .heavy))
                .foregroundColor(.tText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            if let prompt = reward.prompt, !prompt.isEmpty {
                Text(prompt)
                    .font(.system(size: 13))
                    .foregroundColor(.tMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.top, 6)
            }

            // Coût
            HStack(spacing: 4) {
                Image(systemName: "crown.fill")
                    .font(.system(size: 13, weight: .bold))
                Text("\(reward.cost) points")
                    .font(.system(size: 14, weight: .bold))
            }
            .foregroundColor(.tPrimary)
            .padding(.top, 10)

            // Champ texte
            TextField("Votre message…", text: $userInput, axis: .vertical)
                .focused($focused)
                .foregroundColor(.tText)
                .padding(12)
                .background(Color.tSurface)
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.tBorder, lineWidth: 1))
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .lineLimit(3...6)

            // Boutons
            HStack(spacing: 12) {
                Button("Annuler") { dismiss() }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.tMuted)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(Color.tSurface).cornerRadius(12)

                Button {
                    focused = false
                    onConfirm()
                } label: {
                    Group {
                        if isRedeeming {
                            ProgressView().tint(.white)
                        } else {
                            Text("Racheter")
                                .font(.system(size: 15, weight: .bold))
                        }
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(userInput.trimmingCharacters(in: .whitespaces).isEmpty
                                ? Color.tMuted.opacity(0.4) : Color.tPrimary)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                .disabled(userInput.trimmingCharacters(in: .whitespaces).isEmpty || isRedeeming)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .background(Color.tDark)
        .onAppear { focused = true }
    }
}
