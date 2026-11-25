import SwiftUI
import UIKit
import AVFoundation

// ═══════════════════════════════════════════════════════════════════════════
//  « Connecter une TV LG » (Réglages → Compte Twitch) : la caméra lit le QR
//  code de l'app TwitchUnblock de la TV, puis, après confirmation, la
//  session web part chiffrée vers elle (TVPairing). iPhone seulement.
// ═══════════════════════════════════════════════════════════════════════════

struct TVPairSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    private enum CameraState { case checking, ready, denied, unavailable }
    private enum Phase: Equatable {
        case scanning, confirming, sending
        case done(TVPairing.SendResult)
    }

    @State private var cameraState: CameraState = .checking
    @State private var phase: Phase = .scanning
    @State private var pending: TVPairing.Request? = nil
    /// Code écarté à la confirmation : plus reproposé tant qu'il reste devant
    /// la caméra (« Scanner à nouveau » l'oublie).
    @State private var declined: String? = nil
    /// Dernier code refusé noté au journal : pas une ligne à chaque image.
    @State private var lastRefused: String? = nil
    @State private var notice: String? = nil
    @State private var noticeTask: Task<Void, Never>? = nil
    @State private var showConfirm = false

    /// Résultat de l'envoi, nil avant.
    private var result: TVPairing.SendResult? {
        if case .done(let r) = phase { return r }
        return nil
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            cameraLayer
            VStack(spacing: 0) {
                header
                Spacer(minLength: 0)
                if let notice { noticeBanner(notice) }
            }
            if phase == .sending { sendingOverlay }
            if let result { resultOverlay(result) }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(phase == .sending)
        .task { await checkCamera() }
        .onDisappear { noticeTask?.cancel() }
        .alert(store.t("tvpair_confirm_title"), isPresented: $showConfirm) {
            Button(store.t("cancel"), role: .cancel) { declinePending() }
            Button(store.t("tvpair_send")) { sendPending() }
        } message: {
            Text(store.t("tvpair_confirm_msg"))
        }
    }

    // MARK: – Caméra
    @ViewBuilder private var cameraLayer: some View {
        switch cameraState {
        case .checking:
            ProgressView().tint(.white)
        case .ready:
            ZStack {
                QRCodeScanner(isActive: phase == .scanning,
                              onCode: { handle($0) },
                              onFailure: { cameraFailed() })
                    .ignoresSafeArea()
                // Viseur : la lecture ne s'y limite pas, il montre où viser.
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.white.opacity(0.85), lineWidth: 3)
                    .frame(width: 240, height: 240)
                    .allowsHitTesting(false)
            }
        case .denied:
            cameraMessage(store.t("tvpair_camera_denied"), settingsButton: true)
        case .unavailable:
            cameraMessage(store.t("tvpair_camera_unavailable"), settingsButton: false)
        }
    }

    private func cameraMessage(_ text: String, settingsButton: Bool) -> some View {
        VStack(spacing: TSpace.lg) {
            Image(systemName: "video.slash.fill")
                .font(.tSystem(size: 34))
                .foregroundColor(.tMuted)
            Text(text)
                .font(.tBody)
                .foregroundColor(.tText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if settingsButton {
                TPrimaryButton(title: store.t("tvpair_open_settings"), icon: "gearshape.fill") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            }
        }
        .padding(TSpace.xl)
        .frame(maxWidth: 420)
    }

    // MARK: – En-tête et avis
    private var header: some View {
        HStack(alignment: .top, spacing: TSpace.md) {
            VStack(alignment: .leading, spacing: TSpace.xs) {
                Text(store.t("tvpair_title"))
                    .font(.tSection)
                    .foregroundColor(.white)
                Text(store.t("tvpair_scan_hint"))
                    .font(.tMeta)
                    .foregroundColor(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: TSpace.sm)
            TIconButton(icon: "xmark", tint: .white) { dismiss() }
                .disabled(phase == .sending)
        }
        .padding(TSpace.lg)
        .background(
            LinearGradient(colors: [Color.black.opacity(0.75), Color.black.opacity(0)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
    }

    private func noticeBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: TSpace.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.tWarning)
            Text(text)
                .font(.tLabel)
                .foregroundColor(.white)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(TSpace.md)
        .background(Color.black.opacity(0.8))
        .cornerRadius(TRadius.control)
        .padding(TSpace.lg)
        .transition(.opacity)
    }

    // MARK: – Envoi
    private var sendingOverlay: some View {
        VStack(spacing: TSpace.md) {
            ProgressView().tint(.white).scaleEffect(1.3)
            Text(store.t("tvpair_sending"))
                .font(.tLabel)
                .foregroundColor(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.6).ignoresSafeArea())
    }

    private func resultOverlay(_ result: TVPairing.SendResult) -> some View {
        let ok = result == .sent
        // Sans session web, scanner de nouveau ne mènerait nulle part.
        let canRescan = !ok && result != .noSession
        return VStack(spacing: TSpace.lg) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.tSystem(size: 44, weight: .semibold))
                .foregroundColor(ok ? .tSuccess : .tWarning)
            Text(resultText(result))
                .font(.tBody)
                .foregroundColor(.tText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if ok {
                TPrimaryButton(title: store.t("tvpair_done"), fullWidth: true) { dismiss() }
            } else {
                if canRescan {
                    TPrimaryButton(title: store.t("tvpair_rescan"), icon: "qrcode.viewfinder",
                                   fullWidth: true) { rescan() }
                }
                TSecondaryButton(title: store.t("close"), fullWidth: true) { dismiss() }
            }
        }
        .tCard(padding: TSpace.xl)
        .frame(maxWidth: 420)
        .padding(TSpace.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.6).ignoresSafeArea())
    }

    private func resultText(_ result: TVPairing.SendResult) -> String {
        switch result {
        case .sent:        return store.t("tvpair_sent")
        case .alreadyUsed: return store.t("tvpair_used")
        case .invalid:     return store.t("tvpair_invalid")
        case .tooMany:     return store.t("tvpair_too_many")
        case .network:     return store.t("tvpair_network")
        case .noSession:   return store.t("tvpair_session_gone")
        case .server(let code):
            return store.t("tvpair_server").replacingOccurrences(of: "{c}", with: "\(code)")
        }
    }

    // MARK: – Actions
    @MainActor private func checkCamera() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            cameraState = .ready
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            cameraState = granted ? .ready : .denied
            if !granted { logger.info("AUTH/TV", "Accès à la caméra refusé", nil) }
        default:
            cameraState = .denied
        }
    }

    private func cameraFailed() {
        logger.warn("AUTH/TV", "Caméra indisponible", nil)
        cameraState = .unavailable
    }

    /// QR code vu (le même au plus toutes les 1,5 s).
    private func handle(_ code: String) {
        guard phase == .scanning, code != declined else { return }
        switch TVPairing.parse(code) {
        case .success(let request):
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            hideNotice()
            pending = request
            phase = .confirming
            showConfirm = true
        case .failure(let refusal):
            showNotice(refusalText(refusal))
            guard code != lastRefused else { return }
            lastRefused = code
            switch refusal {
            case .notPairCode:
                break   // un QR code quelconque : rien à noter
            case .newerVersion:
                logger.warn("AUTH/TV", "Code de TV d'une version plus récente", nil)
            case .malformed:
                logger.warn("AUTH/TV", "Code de TV mal formé", nil)
            case .unknownWorker(let host):
                logger.warn("AUTH/TV", "Code de TV refusé : serveur inconnu", host)
            }
        }
    }

    private func refusalText(_ refusal: TVPairing.Refusal) -> String {
        switch refusal {
        case .notPairCode:  return store.t("tvpair_not_tv_code")
        case .newerVersion: return store.t("tvpair_new_version")
        case .malformed:    return store.t("tvpair_bad_code")
        case .unknownWorker(let host):
            return store.t("tvpair_unknown_server").replacingOccurrences(of: "{h}", with: host)
        }
    }

    private func declinePending() {
        declined = pending?.raw
        pending = nil
        phase = .scanning
    }

    private func sendPending() {
        guard let request = pending else { phase = .scanning; return }
        guard let token = store.twitchWebToken, !token.isEmpty else {
            phase = .done(.noSession)
            return
        }
        phase = .sending
        let login = store.twitchLogin
        let userId = store.twitchUserId
        Task { @MainActor in
            let sent = await TVPairing.send(request, token: token, knownLogin: login, knownUserId: userId)
            // Jeton refusé par Twitch : l'app le constate aussi (session
            // effacée, bandeau « Session web expirée » dans Compte).
            if sent == .noSession { await store.validateWebSession() }
            UINotificationFeedbackGenerator().notificationOccurred(sent == .sent ? .success : .error)
            phase = .done(sent)
        }
    }

    private func rescan() {
        pending = nil
        declined = nil
        lastRefused = nil
        phase = .scanning
    }

    private func showNotice(_ text: String) {
        if notice != text {
            withAnimation(.easeOut(duration: 0.2)) { notice = text }
        }
        noticeTask?.cancel()
        noticeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { notice = nil }
        }
    }

    private func hideNotice() {
        noticeTask?.cancel()
        noticeTask = nil
        notice = nil
    }
}

// MARK: – Lecteur de QR code
/// Caméra plein cadre qui lit les QR codes (AVCaptureSession +
/// AVCaptureMetadataOutput). Elle reste allumée pendant la confirmation et
/// l'envoi (`isActive` faux : les codes vus sont ignorés).
struct QRCodeScanner: UIViewControllerRepresentable {
    var isActive: Bool
    /// Texte d'un QR code vu, sur le fil principal.
    let onCode: (String) -> Void
    /// La caméra ne s'ouvre pas (absente, prise par une autre app).
    let onFailure: () -> Void

    func makeUIViewController(context: Context) -> QRScannerController {
        let vc = QRScannerController()
        vc.onCode = onCode
        vc.onFailure = onFailure
        vc.isActive = isActive
        return vc
    }

    func updateUIViewController(_ vc: QRScannerController, context: Context) {
        vc.onCode = onCode
        vc.onFailure = onFailure
        vc.isActive = isActive
    }

    static func dismantleUIViewController(_ vc: QRScannerController, coordinator: ()) {
        vc.stopCamera()
    }
}

/// Vue dont le calque est l'aperçu de la caméra : il suit sa taille
/// (feuille, rotation) sans rien recalculer.
final class QRPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

final class QRScannerController: UIViewController {
    var onCode: ((String) -> Void)?
    var onFailure: (() -> Void)?
    var isActive = true
    private let camera = QRCamera()

    override func loadView() {
        let preview = QRPreviewView()
        preview.backgroundColor = .black
        preview.previewLayer.videoGravity = .resizeAspectFill
        preview.previewLayer.session = camera.session
        view = preview
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        camera.onCode = { [weak self] code in
            guard let self, self.isActive else { return }
            self.onCode?(code)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        camera.start { [weak self] ok in
            guard let self else { return }
            if ok { self.updateRotation() } else { self.onFailure?() }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        camera.stop()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateRotation()
    }

    /// Feuille fermée (dismantleUIViewController).
    func stopCamera() { camera.teardown() }

    /// Aperçu droit quelle que soit l'orientation de l'écran (l'iPad tourne,
    /// l'iPhone aussi quand le lecteur permet le paysage).
    private func updateRotation() {
        guard let preview = view as? QRPreviewView,
              let connection = preview.previewLayer.connection else { return }
        let orientation = view.window?.windowScene?.effectiveGeometry.interfaceOrientation ?? .portrait
        if #available(iOS 17.0, *) {
            let angle: CGFloat
            switch orientation {
            case .landscapeRight:     angle = 0
            case .landscapeLeft:      angle = 180
            case .portraitUpsideDown: angle = 270
            default:                  angle = 90
            }
            if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
        } else {
            let videoOrientation: AVCaptureVideoOrientation
            switch orientation {
            case .landscapeRight:     videoOrientation = .landscapeRight
            case .landscapeLeft:      videoOrientation = .landscapeLeft
            case .portraitUpsideDown: videoOrientation = .portraitUpsideDown
            default:                  videoOrientation = .portrait
            }
            if connection.isVideoOrientationSupported { connection.videoOrientation = videoOrientation }
        }
    }
}

/// Session de la caméra : préparée et lancée sur sa propre file
/// (startRunning bloque), codes rendus sur le fil principal.
final class QRCamera: NSObject, AVCaptureMetadataOutputObjectsDelegate {
    let session = AVCaptureSession()
    /// Appelé sur le fil principal avec le texte d'un QR code.
    var onCode: ((String) -> Void)?
    private let queue = DispatchQueue(label: "com.mxfia19.twitchunblock.qrcamera")
    /// Sur `queue` seulement.
    private var configured = false
    /// Sur le fil principal seulement.
    private var lastCode: String?
    private var lastCodeAt = Date.distantPast

    /// Prépare la caméra (la première fois) et la lance ; `completion` sur le
    /// fil principal, faux si elle ne s'ouvre pas.
    func start(completion: @escaping (Bool) -> Void) {
        queue.async {
            let ok = self.configureIfNeeded()
            if ok, !self.session.isRunning { self.session.startRunning() }
            DispatchQueue.main.async { completion(ok) }
        }
    }

    func stop() {
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    /// Feuille fermée : caméra arrêtée et délégué lâché (la session garde son
    /// délégué, qui la garde : sans ça, ni l'un ni l'autre ne partirait).
    func teardown() {
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
            for output in self.session.outputs {
                (output as? AVCaptureMetadataOutput)?.setMetadataObjectsDelegate(nil, queue: nil)
            }
        }
    }

    private func configureIfNeeded() -> Bool {
        if configured { return true }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return false }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return false }
        session.addOutput(output)
        // Types demandés une fois la sortie reliée à la caméra : avant, la
        // liste des types possibles est vide, et demander .qr fait planter.
        guard output.availableMetadataObjectTypes.contains(.qr) else { return false }
        output.metadataObjectTypes = [.qr]
        output.setMetadataObjectsDelegate(self, queue: .main)
        configured = true
        return true
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard let code = metadataObjects
                .compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue })
                .first(where: { !$0.isEmpty }) else { return }
        // Le même code revient à chaque image : signalé au plus toutes les 1,5 s.
        let now = Date()
        if code == lastCode, now.timeIntervalSince(lastCodeAt) < 1.5 { return }
        lastCode = code
        lastCodeAt = now
        onCode?(code)
    }
}
