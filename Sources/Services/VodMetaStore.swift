import Foundation
import Combine

// MARK: – Cache des métadonnées de VOD (durée + nombre de vues)
//
// L'historique ne stocke que l'id, le titre et la miniature. Pour afficher
// « où on en est / durée totale » et le nombre de vues, on complète à la
// demande : chaque ligne visible déclenche une récupération, mise en cache
// pour la session (une seule requête par VOD, même si la ligne réapparaît).
@MainActor
final class VodMetaStore: ObservableObject {
    static let shared = VodMetaStore()
    private init() {}

    @Published private(set) var metas: [String: VodMeta] = [:]
    private var inFlight = Set<String>()

    func meta(_ id: String) -> VodMeta? { metas[id] }

    func load(_ id: String) async {
        guard !id.isEmpty, metas[id] == nil, !inFlight.contains(id) else { return }
        inFlight.insert(id)
        let m = await getVodMetaGQL(id)
        inFlight.remove(id)
        if let m = m { metas[id] = m }
    }
}
