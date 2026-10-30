import Foundation
import UIKit

// ═══════════════════════════════════════════════════════════════════════════
//  Télécharger un clip : le MP4 de la qualité lue (liens signés, voir
//  getClip), puis la feuille de partage d'iOS — « Enregistrer la vidéo »
//  (Photos), Fichiers, AirDrop. Pas de file d'attente comme les VODs : un
//  clip dure une minute au plus.
// ═══════════════════════════════════════════════════════════════════════════

enum ClipSaver {
    /// Téléchargé puis proposé au partage ; false si le téléchargement a échoué.
    @MainActor
    static func save(_ url: URL, title: String) async -> Bool {
        logger.info("CLIP", "Téléchargement du clip…", title)
        guard let (tmp, resp) = try? await URLSession.shared.download(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200 else {
            logger.warn("CLIP", "Téléchargement du clip impossible", nil)
            return false
        }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(fileName(title))
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: tmp, to: dest)
        } catch {
            logger.warn("CLIP", "Téléchargement du clip impossible", error.localizedDescription)
            return false
        }
        logger.success("CLIP", "Clip téléchargé", nil)
        // Copie faite par iOS (Photos, Fichiers) : celle-ci n'a plus d'usage.
        ShareSheet.present(dest) { try? FileManager.default.removeItem(at: dest) }
        return true
    }

    /// Nom de fichier lisible : le titre du clip, sans caractère interdit.
    static func fileName(_ title: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\?%*|\"<>:").union(.newlines).union(.controlCharacters)
        let clean = title.components(separatedBy: bad).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return String((clean.isEmpty ? "Clip" : clean).prefix(80)) + ".mp4"
    }
}
