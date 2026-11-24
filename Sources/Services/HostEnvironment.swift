import Foundation
import MachO

// ═══════════════════════════════════════════════════════════════════════════
//  Où l'app tourne vraiment.
//
//  LiveContainer (et les outils du même genre) lance l'app dans son propre
//  processus en lui faisant croire qu'elle est chez elle : Bundle.main pointe
//  vers notre .app. En mode multitâche, chaque app y tourne dans une
//  extension (LiveProcess.appex) affichée en fenêtre flottante, et l'image
//  dans l'image n'y marche pas (joey, 13/11 : « en mode une seule app, elle
//  marche » — bamy s'en sert ainsi). Une app normale ne lance jamais son code
//  principal depuis une extension : c'est le signe retenu, lu sur le vrai
//  exécutable du processus (image 0 de dyld), que LiveContainer ne remplace
//  pas, contrairement à Bundle.main.
// ═══════════════════════════════════════════════════════════════════════════

enum HostEnvironment {
    /// Chemin de l'exécutable du processus (pas celui de Bundle.main).
    static let processExecutable: String = {
        if let path = _dyld_get_image_name(0) { return String(cString: path) }
        return CommandLine.arguments.first ?? ""
    }()

    /// Le processus est une extension d'app (…/PlugIns/X.appex/X).
    static let inAppExtension: Bool = processExecutable.contains(".appex/")

    /// Mode multitâche de LiveContainer : l'image dans l'image y est coupée
    /// (ni bouton, ni départ automatique en quittant l'app, ni « PiP en
    /// quittant le lecteur »). En mode « une seule app », rien ne change.
    static let pipBlocked: Bool = inAppExtension

    /// Nom de l'app hôte quand l'app tourne dans une autre (LiveContainer, ou
    /// un outil du même genre) ; nil pour une installation normale. Joint aux
    /// signalements : l'écran verrouillé et la Dynamic Island ouvrent alors
    /// l'hôte, et lui ce qu'il veut — Spotify chez un utilisateur
    /// (fb_mwqgdld9). En mode « une seule app », Bundle.main est le nôtre
    /// mais pas l'exécutable du processus.
    static let hostName: String? = {
        let process = (processExecutable as NSString).lastPathComponent
        if inAppExtension { return process + " (extension)" }
        guard !process.isEmpty, let ours = Bundle.main.executableURL?.lastPathComponent,
              process != ours else { return nil }
        return process
    }()

    /// Pour le journal : ce qui a été vu au lancement, sans le chemin entier.
    static var summary: String {
        let name = (processExecutable as NSString).lastPathComponent
        return inAppExtension ? "extension « \(name) » (multitâche de LiveContainer)" : "app « \(name) »"
    }

    private static var pipLogged = false
    /// Une ligne au journal, la première fois que le lecteur renonce au PiP.
    static func notePiPBlocked() {
        guard pipBlocked, !pipLogged else { return }
        pipLogged = true
        logger.info("LECTEUR", "Image dans l'image coupée : mode multitâche de LiveContainer", summary)
    }
}
