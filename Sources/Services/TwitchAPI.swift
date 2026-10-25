import Foundation
import CoreMedia
import VideoToolbox   // codecs décodés par l'appareil (HigherQualities)

// MARK: – Helpers
private let requestHeaders: [String: String] = [
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Safari/537.36",
    "Referer": "https://www.twitch.tv/",
    "Origin": "https://www.twitch.tv",
]

private let qualityOrder = ["chunked","source","1080p60","1080p30","720p60","720p30",
                             "480p30","360p30","160p30","audio_only"]

// MARK: – M3U8 Parser
/// Valeur d'un attribut d'une ligne #EXT-X-STREAM-INF (`,NOM="valeur"`).
private func m3u8Attr(_ line: String, _ name: String) -> String? {
    for sep in [",", ":"] {
        guard let r = line.range(of: "\(sep)\(name)=\"") else { continue }
        let rest = line[r.upperBound...]
        if let end = rest.firstIndex(of: "\"") { return String(rest[..<end]) }
    }
    return nil
}

/// Valeur sans guillemets d'un attribut (`,RESOLUTION=1920x1080`,
/// `,FRAME-RATE=60.000`). `\s` écarte un `\r` de fin de ligne.
private func m3u8Plain(_ line: String, _ name: String) -> String? {
    guard let r = line.range(of: #"[:,]\#(name)=[^,"\s]+"#, options: .regularExpression) else { return nil }
    return String(line[r].drop(while: { $0 != "=" }).dropFirst())
}

func parseM3U8(_ content: String, baseURL: URL? = nil) -> QualityLinks {
    parseMaster(content, baseURL: baseURL).links
}

/// Hauteur, cadence et débit de chaque qualité d'une liste maîtresse, sous le
/// même nom que `parseM3U8` lui donne.
func parseVariants(_ content: String) -> [String: VariantInfo] {
    parseMaster(content).variants
}

/// Liens par qualité, et ce que la liste maîtresse dit de chacune.
typealias MasterPlaylist = (links: QualityLinks, variants: [String: VariantInfo])

/// Lecture d'une liste maîtresse : un seul calcul du nom des qualités pour
/// les liens et pour les variantes, qui gardent ainsi les mêmes clés.
func parseMaster(_ content: String, baseURL: URL? = nil) -> MasterPlaylist {
    var links: QualityLinks = [:]
    var variants: [String: VariantInfo] = [:]
    let lines = content.components(separatedBy: "\n")
    // Groupes vidéo nommés « … (source) » (EXT-X-MEDIA) : certains proxys
    // appellent la version d'origine « 1080p60 » plutôt que « chunked ».
    let sourceGroups = Set(lines.compactMap { l -> String? in
        guard l.hasPrefix("#EXT-X-MEDIA"), l.lowercased().contains("(source)") else { return nil }
        return m3u8Attr(l, "GROUP-ID")
    })
    // En multi-encodage (Enhanced Broadcasting : le streamer envoie lui-même
    // chaque qualité), le format IVS marque TOUTES les variantes « source »,
    // audio seul compris : toutes devenaient « Source » et la dernière,
    // l'audio seul, l'emportait — écran noir en « Source » (gotaga, miroir
    // européen de Luminous). « Source » seulement pour une variante vidéo
    // seule de son espèce ; sinon chaque qualité garde son nom.
    let isIVSSource = { (l: String) in m3u8Attr(l, "IVS-VARIANT-SOURCE") == "source" && l.contains("RESOLUTION=") }
    let singleIVSSource = lines.filter { $0.hasPrefix("#EXT-X-STREAM-INF") && isIVSSource($0) }.count == 1
    for i in 0..<lines.count {
        let line = lines[i].trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("#EXT-X-STREAM-INF") else { continue }
        // Deux formats : VIDEO="chunked" (l'ancien) et STABLE-VARIANT-ID="1080p60"
        // + IVS-VARIANT-SOURCE="source" (serveurs IVS, que renvoie le miroir
        // européen de Luminous). Sans ce dernier, la résolution servait de nom
        // et l'audio seul devenait « unknown ».
        var quality = "unknown"
        if let name = m3u8Attr(line, "VIDEO") ?? m3u8Attr(line, "STABLE-VARIANT-ID") ?? m3u8Attr(line, "IVS-NAME") {
            quality = name == "chunked" || sourceGroups.contains(name)
                || (singleIVSSource && isIVSSource(line)) ? "Source" : name
        } else if let r = line.range(of: #"RESOLUTION=(\d+x\d+)"#, options: .regularExpression) {
            quality = String(line[r]).replacingOccurrences(of: "RESOLUTION=", with: "")
        }
        let nextLine = i + 1 < lines.count ? lines[i + 1].trimmingCharacters(in: .whitespaces) : ""
        if !nextLine.isEmpty && !nextLine.hasPrefix("#") {
            if nextLine.hasPrefix("http") {
                links[quality] = nextLine
            } else if let base = baseURL, let fullURL = URL(string: nextLine, relativeTo: base)?.absoluteString {
                links[quality] = fullURL
            } else {
                links[quality] = nextLine
            }
            // « 1920x1080 » → 1080 ; pas de RESOLUTION (audio seul) → 0.
            let height = m3u8Plain(line, "RESOLUTION")
                .flatMap { $0.split(separator: "x").last }.flatMap { Int($0) } ?? 0
            variants[quality] = VariantInfo(height: height,
                                            fps: m3u8Plain(line, "FRAME-RATE").flatMap { Double($0) } ?? 0,
                                            bandwidth: m3u8Plain(line, "BANDWIDTH").flatMap { Int($0) } ?? 0)
        }
    }
    return (links, variants)
}

/// `variants` d'une réponse du Worker ({ "720p60": { h, fps, bw } }) ; vide
/// pour un Worker d'avant (personnel ou Docker pas à jour).
private func workerVariants(_ value: Any?) -> [String: VariantInfo] {
    guard let dict = value as? [String: [String: Any]] else { return [:] }
    var out: [String: VariantInfo] = [:]
    for (key, v) in dict {
        guard let h = (v["h"] as? NSNumber)?.intValue else { continue }
        out[key] = VariantInfo(height: h, fps: (v["fps"] as? NSNumber)?.doubleValue ?? 0,
                               bandwidth: (v["bw"] as? NSNumber)?.intValue ?? 0)
    }
    return out
}

// MARK: – GQL
private func twitchGQL(_ query: String) async throws -> Any {
    guard let url = URL(string: "https://gql.twitch.tv/gql") else { throw URLError(.badURL) }
    // 10 s au plus sans réponse (au lieu de 60) : GQL répond en une seconde
    // quand il marche, et getLive l'attend avant d'essayer les sources.
    var req = URLRequest(url: url, timeoutInterval: 10)
    req.httpMethod = "POST"
    req.setValue(kGQLClientID, forHTTPHeaderField: "Client-ID")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue(requestHeaders["User-Agent"], forHTTPHeaderField: "User-Agent")
    req.setValue("MkMq8a9\(Int.random(in: 100000...999999))", forHTTPHeaderField: "Device-ID")
    req.httpBody = try JSONSerialization.data(withJSONObject: ["query": query])
    let (data, resp) = try await URLSession.shared.data(for: req)
    guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
    return try JSONSerialization.jsonObject(with: data)
}

// MARK: – Access Token
private func getAccessToken(id: String, isLive: Bool) async -> (value: String, signature: String)? {
    logger.debug("TOKEN", "Récupération token \(isLive ? "live" : "VOD") pour \"\(id)\"")
    let q = isLive
        ? "query { streamPlaybackAccessToken(channelName: \"\(gqlStr(id))\", params: {platform: \"web\", playerBackend: \"mediaplayer\", playerType: \"site\"}) { value signature } }"
        : "query { videoPlaybackAccessToken(id: \"\(gqlStr(id))\", params: {platform: \"web\", playerBackend: \"mediaplayer\", playerType: \"site\"}) { value signature } }"
    guard let json = try? await twitchGQL(q) as? [String: Any],
          let data = json["data"] as? [String: Any],
          let token = (isLive ? data["streamPlaybackAccessToken"] : data["videoPlaybackAccessToken"]) as? [String: Any],
          let value = token["value"] as? String,
          let sig   = token["signature"] as? String else {
        logger.warn("TOKEN", "Token vide pour \"\(id)\"")
        return nil
    }
    logger.success("TOKEN", "Token obtenu pour \"\(id)\"")
    return (value, sig)
}

// MARK: – Jeton de lecture du compte
/// Identifiant d'appareil gardé pour la session web (points, drops, jeton de
/// lecture du compte) : même clé que ChannelPointsService et TwitchGQL.
func twitchWebDeviceId() -> String {
    if let d = UserDefaults.standard.string(forKey: "twitch_device_id") { return d }
    let chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    let d = String((0..<32).map { _ in chars.randomElement()! })
    UserDefaults.standard.set(d, forKey: "twitch_device_id")
    return d
}

/// Jeton de lecture d'un direct au nom du compte, et ce que Twitch y a écrit.
struct AccountPlaybackToken {
    let value: String
    let signature: String
    /// Twitch ne servira pas de pub à ce jeton (abonné à la chaîne, ou Turbo
    /// quand la chaîne l'accepte) : `hide_ads`, ou `show_ads` faux.
    let adFree: Bool
    let subscriber: Bool?
    /// Lecture refusée à ce compte (géoblocage…) : les proxys prennent la main.
    let forbidden: Bool
}

enum AccountPlayback {
    case token(AccountPlaybackToken)
    /// Session web refusée par Twitch (401/403) : à revalider.
    case expired
    /// Rien d'utilisable : réseau, refus, ou jeton anonyme.
    case unavailable
}

/// Jeton de lecture au nom du compte (`webToken` : session web, cookie
/// `auth-token`), avec le Client-ID web. Sans jeton d'intégrité d'abord ; si
/// Twitch en exige un, une seule autre tentative avec `integrity` — des types
/// simples : ce fichier est compilé pour l'Apple TV, sans TwitchWebGQL ni
/// DropsService (la TV ne l'appelle d'ailleurs jamais).
/// Sert aux drops (DropsHeartbeat) et au direct sans pub des abonnés.
func accountPlaybackToken(login: String, webToken: String,
                          integrity: (() async -> (token: String, deviceId: String)?)? = nil) async -> AccountPlayback {
    let q = """
    query($l: String!) { streamPlaybackAccessToken(channelName: $l,
      params: {platform: "web", playerBackend: "mediaplayer", playerType: "site"}) { value signature } }
    """
    let body: [String: Any] = ["query": q, "variables": ["l": login]]
    var res = await accountGQL(body, webToken: webToken, integrity: nil)
    if res.status == 401 || res.status == 403 { return .expired }
    // Intégrité demandée : le jeton gardé, puis, s'il est refusé à son tour,
    // un second appel — qui en donne un neuf (voir dropsIntegrity).
    var tries = 0
    while tries < 2, gqlErrorText(res.json).lowercased().contains("integrity"), let integrity,
          let it = await integrity() {
        tries += 1
        res = await accountGQL(body, webToken: webToken, integrity: it)
        if res.status == 401 || res.status == 403 { return .expired }
    }
    guard let pat = (res.json?["data"] as? [String: Any])?["streamPlaybackAccessToken"] as? [String: Any],
          let value = pat["value"] as? String,
          let signature = pat["signature"] as? String else {
        logger.warn("TOKEN", "Jeton du compte indisponible", gqlErrorText(res.json))
        return .unavailable
    }
    // Un jeton anonyme (« user_id »: null) : session web expirée, ou ignorée.
    guard value.range(of: #""user_id":\d"#, options: .regularExpression) != nil else {
        logger.warn("TOKEN", "Jeton du compte anonyme", "session web expirée ?")
        return .unavailable
    }
    let flags = (value.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }
                 as? [String: Any]) ?? [:]
    let hideAds = flags["hide_ads"] as? Bool
    let showAds = flags["show_ads"] as? Bool
    let subscriber = flags["subscriber"] as? Bool
    let turbo = flags["turbo"] as? Bool
    let forbidden = (flags["authorization"] as? [String: Any])?["forbidden"] as? Bool ?? false
    // Jamais déduit de `turbo` seul : une chaîne peut refuser Turbo, et ce
    // jeton recevrait alors de vraies pubs.
    let adFree = hideAds == true || showAds == false
    func flag(_ b: Bool?) -> String { b.map { $0 ? "oui" : "non" } ?? "?" }
    // Plus haute résolution permise (« QUAD_HD » : 1440p, voir HigherQualities).
    let maxRes: String = (flags["maximum_resolution"] as? String).map { " · max \($0)" } ?? ""
    logger.info("TOKEN", "Jeton du compte pour \"\(login)\"",
                "abonné \(flag(subscriber)) · turbo \(flag(turbo)) · hide_ads \(flag(hideAds)) · show_ads \(flag(showAds))"
                + maxRes + (forbidden ? " · lecture refusée" : ""))
    return .token(AccountPlaybackToken(value: value, signature: signature, adFree: adFree,
                                       subscriber: subscriber, forbidden: forbidden))
}

/// Requête GQL au nom du compte, 6 s au plus. Pour le direct, getLive borne
/// en plus l'ensemble (accountPlaybackIfAsked) : jeton d'intégrité compris.
private func accountGQL(_ body: [String: Any], webToken: String,
                        integrity: (token: String, deviceId: String)?) async -> (status: Int, json: [String: Any]?) {
    guard let url = URL(string: "https://gql.twitch.tv/gql"),
          let payload = try? JSONSerialization.data(withJSONObject: body) else { return (0, nil) }
    var req = URLRequest(url: url, timeoutInterval: 6)
    req.httpMethod = "POST"
    req.setValue(kGQLClientID, forHTTPHeaderField: "Client-ID")
    req.setValue("text/plain;charset=UTF-8", forHTTPHeaderField: "Content-Type")
    req.setValue("OAuth \(webToken)", forHTTPHeaderField: "Authorization")
    // Le jeton d'intégrité est lié à l'identifiant d'appareil qui l'a obtenu.
    let device = integrity.flatMap { $0.deviceId.isEmpty ? nil : $0.deviceId } ?? twitchWebDeviceId()
    req.setValue(device, forHTTPHeaderField: "X-Device-Id")
    if let integrity { req.setValue(integrity.token, forHTTPHeaderField: "Client-Integrity") }
    req.httpBody = payload
    guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return (0, nil) }
    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 200, let obj = try? JSONSerialization.jsonObject(with: data) else { return (status, nil) }
    return (status, (obj as? [[String: Any]])?.first ?? (obj as? [String: Any]))
}

/// Messages d'erreur GQL, en une ligne (vide s'il n'y en a pas).
private func gqlErrorText(_ json: [String: Any]?) -> String {
    ((json?["errors"] as? [[String: Any]]) ?? []).compactMap { $0["message"] as? String }.joined(separator: " · ")
}

// MARK: – Storyboard Hack
private func storyboardHack(vodId: String) async -> QualityLinks {
    logger.info("STORYBOARD", "Tentative storyboard hack pour VOD \(vodId)")
    guard let json = try? await twitchGQL("query { video(id: \"\(gqlStr(vodId))\") { seekPreviewsURL } }") as? [String: Any],
          let data = json["data"] as? [String: Any],
          let video = data["video"] as? [String: Any],
          let seekUrl = video["seekPreviewsURL"] as? String,
          let parsedURL = URL(string: seekUrl) else {
        logger.warn("STORYBOARD", "seekPreviewsURL absent")
        return [:]
    }
    let parts = seekUrl.components(separatedBy: "/")
    guard let storyIndex = parts.firstIndex(of: "storyboards"), storyIndex > 0 else {
        logger.warn("STORYBOARD", "Structure URL inattendue")
        return [:]
    }
    let hash = parts[storyIndex - 1]
    guard let host = parsedURL.host else { return [:] }
    let root = "https://\(host)/\(hash)"

    var found: QualityLinks = [:]
    await withTaskGroup(of: (String, String)?.self) { group in
        for q in qualityOrder {
            group.addTask {
                let url = "\(root)/\(q)/index-dvr.m3u8"
                // 8 s au plus (au lieu de 60) : le CDN répond aussitôt.
                guard var req = URL(string: url).map({ URLRequest(url: $0, timeoutInterval: 8) }) else { return nil }
                req.httpMethod = "HEAD"
                requestHeaders.forEach { req.setValue($1, forHTTPHeaderField: $0) }
                let status = (try? await URLSession.shared.data(for: req).1 as? HTTPURLResponse)?.statusCode
                return status == 200 ? (q == "chunked" ? "Source" : q, url) : nil
            }
        }
        for await result in group {
            if let (key, url) = result { found[key] = url }
        }
    }
    logger.success("STORYBOARD", "\(found.count) qualités trouvées", found.keys.joined(separator: ", "))
    return found
}

// MARK: – Worker (principal, puis secours)
/// Workers mis de côté, jusqu'à une date : on ne retente pas à chaque requête
/// celui qui vient de refuser. Partagé entre tâches concurrentes, d'où le verrou.
private final class WorkerHealth {
    static let shared = WorkerHealth()
    private var downUntil: [String: Date] = [:]
    private let lock = NSLock()

    func isDown(_ base: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return (downUntil[base] ?? .distantPast) > Date()
    }

    func markDown(_ base: String, until: Date) {
        lock.lock(); defer { lock.unlock() }
        downUntil[base] = until
    }
}

/// Minuit UTC suivant : le quota journalier de Cloudflare repart à cette heure-là.
private func nextUTCMidnight() -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC") ?? .current
    let today = cal.startOfDay(for: Date())
    return cal.date(byAdding: .day, value: 1, to: today) ?? Date().addingTimeInterval(3600)
}

/// JSON d'une route du Worker qui ne touche pas à sa base D1 (VODs, lives), en
/// passant au Worker de secours quand le principal est hors service — quota du
/// jour atteint : 429 « error code: 1027 », jusqu'à minuit UTC.
/// Une réponse d'erreur du Worker lui-même (404…) n'est pas une panne : un
/// autre Worker répondrait la même chose, on s'arrête là.
private func workerJSON(_ path: String) async -> [String: Any]? {
    let bases = APIConfig.lookupBases
    let health = WorkerHealth.shared
    let ordered = bases.filter { !health.isDown($0) } + bases.filter { health.isDown($0) }
    var unreachable: [String] = []

    for base in ordered {
        guard let url = URL(string: base + path) else { continue }
        let data: Data, code: Int
        do {
            // 20 s au plus sans réponse (au lieu de 60) : dernier recours du
            // direct et des VODs, il essaie lui-même ses sources, mais un
            // Worker muet faisait attendre une minute par adresse.
            let (d, resp) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 20))
            data = d
            code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            // Injoignable : panne du Worker, ou réseau de l'appareil. On ne le
            // met de côté que si un autre Worker répond ensuite.
            logger.warn("WORKER", "Worker injoignable", "\(base) — \(error.localizedDescription)")
            unreachable.append(base)
            continue
        }
        if code == 429 || (502...504).contains(code) {
            let quota = String(data: data, encoding: .utf8)?.contains("1027") == true
            if bases.count > 1 {
                health.markDown(base, until: quota ? nextUTCMidnight() : Date().addingTimeInterval(30 * 60))
            }
            logger.warn("WORKER", quota ? "Quota du jour atteint (1027)" : "Worker indisponible (\(code))",
                        bases.count > 1 ? "\(base) → secours" : base)
            continue
        }
        for b in unreachable { health.markDown(b, until: Date().addingTimeInterval(30 * 60)) }
        if base != bases.first { logger.info("WORKER", "Réponse d'un autre Worker", base) }
        guard code == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
    return nil
}

// MARK: – Passages coupés (droits d'auteur)
/// Les playlists du CDN des VODs listent les passages coupés en
/// « N-unmuted.ts », que le CDN refuse (403) : la lecture bloquait dès le
/// premier. Seul « N-muted.ts » (son coupé) se lit. AVPlayer ne sait pas
/// réécrire une playlist : quand il y en a, elle passe par le proxy du Worker,
/// qui fait la substitution ; les segments, eux, viennent toujours du CDN
/// (`isVod=false`). Sans passage coupé, rien ne change.
/// Seulement « -unmuted.ts » : en fMP4, « N-unmuted.mp4 » est servi avec le
/// son (« -muted.mp4 » est silencieux) — ne jamais l'ajouter ici.
func playableMutedLinks(_ links: QualityLinks) async -> QualityLinks {
    guard let source = links["Source"] ?? links.values.first, let url = URL(string: source),
          let (data, _) = try? await URLSession.shared.data(from: url),
          String(decoding: data, as: UTF8.self).contains("-unmuted.ts") else { return links }
    // Aucun Worker ne répond (quota du jour, panne) : réécrites sur l'appareil
    // (VodUnmuteLoader, sans chercher le son d'origine). Les playlists brutes
    // arrêtaient la lecture au premier passage coupé ; AirPlay, qui ne lit pas
    // ces adresses, retombe alors sur le CDN.
    guard let base = await workingProxyBase(for: source) else {
        logger.warn("M3U8", "Passages coupés : aucun Worker, playlists réécrites sur l'appareil")
        return VodUnmuteLoader.wrapMuted(links)
    }
    var out: QualityLinks = [:]
    for (label, link) in links { out[label] = proxiedPlaylistURL(link, base: base) }
    logger.info("M3U8", "Passages coupés : playlists réécrites par le Worker", base)
    return out
}

private func proxiedPlaylistURL(_ url: String, base: String) -> String {
    let enc = url.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? url
    return "\(base)/api/proxy?url=\(enc)&isVod=false"
}

/// Worker (principal, puis secours) qui sert vraiment cette playlist ; nil si
/// aucun. Même tri que `workerJSON` : le quota du jour atteint (429) le met
/// de côté jusqu'à minuit UTC.
private func workingProxyBase(for url: String) async -> String? {
    let bases = APIConfig.lookupBases
    let health = WorkerHealth.shared
    let ordered = bases.filter { !health.isDown($0) } + bases.filter { health.isDown($0) }
    for base in ordered {
        guard let u = URL(string: proxiedPlaylistURL(url, base: base)),
              let (data, resp) = try? await URLSession.shared.data(from: u) else { continue }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 429 || (502...504).contains(code) {
            let quota = String(data: data, encoding: .utf8)?.contains("1027") == true
            if bases.count > 1 {
                health.markDown(base, until: quota ? nextUTCMidnight() : Date().addingTimeInterval(30 * 60))
            }
            continue
        }
        // Le Worker répond sans playlist : un autre ferait pareil.
        return code == 200 && String(decoding: data.prefix(7), as: UTF8.self) == "#EXTM3U" ? base : nil
    }
    return nil
}

// MARK: – getM3U8 (VODs)
func getM3U8(vodId: String) async -> M3U8Data {
    logger.info("M3U8", "Lancement VOD \(vodId)")

    if let token = await getAccessToken(id: vodId, isLive: false) {
        // Identifiant numérique uniquement (il peut venir de l'historique
        // synchronisé) : sinon l'adresse est invalide et le `!` plantait.
        if vodId.allSatisfy(\.isNumber), !vodId.isEmpty,
           var comps = URLComponents(string: "https://usher.ttvnw.net/vod/\(vodId).m3u8") {
        comps.queryItems = [
            .init(name: "nauth",            value: token.value),
            .init(name: "nauthsig",         value: token.signature),
            .init(name: "allow_source",     value: "true"),
            .init(name: "allow_audio_only", value: "true"),
            .init(name: "allow_spectre",    value: "true"),
            .init(name: "player_backend",   value: "mediaplayer"),
        ]
        // 8 s au plus (au lieu de 60), comme pour un direct.
        if let url = comps.url, let req = { var r = URLRequest(url: url, timeoutInterval: 8); requestHeaders.forEach { r.setValue($1, forHTTPHeaderField: $0) }; return r }() as URLRequest?,
           let (data, resp) = try? await URLSession.shared.data(for: req),
           (resp as? HTTPURLResponse)?.statusCode == 200,
           let body = String(data: data, encoding: .utf8) {
            let master = parseMaster(body, baseURL: url)
            if !master.links.isEmpty {
                logger.success("M3U8", "[1/3] ✅ \(master.links.count) qualités", master.links.keys.joined(separator: ", "))
                return M3U8Data(links: master.links, error: nil, variants: master.variants)
            }
        }
        }
        logger.warn("M3U8", "[1/3] Échec token officiel")
    }

    let sbLinks = await storyboardHack(vodId: vodId)
    if !sbLinks.isEmpty {
        logger.success("M3U8", "[2/3] ✅ Storyboard \(sbLinks.count) qualités")
        // Playlists lues directement sur le CDN : mêmes passages coupés.
        return M3U8Data(links: await playableMutedLinks(sbLinks), error: nil)
    }

    if let json = await workerJSON("/api/get-m3u8?id=\(vodId)&proxy=false"),
       let links = json["links"] as? QualityLinks, !links.isEmpty {
        logger.success("M3U8", "[3/3] ✅ Worker \(links.count) qualités")
        // Playlists du CDN (proxy=false) : mêmes passages coupés que le storyboard.
        return M3U8Data(links: await playableMutedLinks(links), error: nil,
                        variants: workerVariants(json["variants"]))
    }

    logger.error("M3U8", "❌ Toutes les tentatives ont échoué pour VOD \(vodId)")
    return M3U8Data(links: [:], error: "vod_unavailable")
}

// MARK: – Codes d'erreur
/// Clé du texte d'un code d'erreur de getLive, getM3U8 ou getChannelInfo
/// (`error`) : les messages ne sont plus écrits en français ici (affichés
/// tels quels sur iPhone et Apple TV), l'écran les traduit. Un code inconnu
/// est rendu tel quel.
func apiErrorKey(_ code: String) -> String {
    switch code {
    case "not_found":       return "not_found"
    case "network":         return "err_network"
    case "no_source":       return "err_no_source"
    case "vod_unavailable": return "err_vod_unavailable"
    case "offline":         return "offline_msg"
    default:                return code
    }
}

// MARK: – getLive (STREAMS)
/// `webToken` (session web, iPhone seulement) : si Twitch sert ce compte sans
/// pub sur cette chaîne (abonné, Turbo accepté), le direct passe par lui avant
/// les proxys — qui reçoivent, eux aussi, les pauses pub de la chaîne. Jamais
/// pour un compte qui aurait des pubs : il en recevrait de vraies, ciblées sur
/// son adresse réelle — sauf qualités supérieures (higherQualitiesMaster),
/// seulement si `hqAccount` (lecteur principal, qui bascule pendant ses
/// pauses pub ; pas le multi-live) : sa liste maîtresse au-dessus de 1080p,
/// à côté de la source habituelle qui sert ses pauses pub. `integrity` : voir
/// accountPlaybackToken. `onSource` : appelé avec chaque source avant de
/// l'essayer (« as », « al », « eu », « twitch », « worker »), pour l'écran
/// de chargement ; hors du fil principal.
func getLive(channelName: String, webToken: String? = nil,
             integrity: (() async -> (token: String, deviceId: String)?)? = nil,
             hqAccount: Bool = false,
             onSource: ((String) -> Void)? = nil) async -> LiveData {
    let login = channelName.trimmingCharacters(in: .whitespaces).lowercased()
    logger.info("LIVE", "Lancement stream \"\(login)\"")

    // ← id ajouté à la query pour récupérer le userId Twitch du canal
    let q = """
    query { user(login: "\(gqlStr(login))") {
        id
        profileImageURL(width: 70)
        stream {
            title game { name } previewImageURL(width: 320, height: 180) viewersCount createdAt
            archiveVideo { id }
        }
    }}
    """
    async let streamTask = twitchGQL(q)
    async let tokenTask  = getAccessToken(id: login, isLive: true)
    // En même temps que le reste : 6 s au plus en tout (accountPlaybackIfAsked).
    async let accountTask = accountPlaybackIfAsked(login: login, webToken: webToken, integrity: integrity)

    // Réponse de Twitch lue : « user » nul, sans erreur, = la chaîne n'existe
    // pas. Sans réponse lisible (réseau filtré, GQL en panne ou qui ralentit),
    // on ne sait rien : les sources sont essayées quand même — elles ne
    // passent pas par GQL, et le Worker rend titre, jeu et avatar. Avant,
    // toute erreur de transport disait « Streamer introuvable » sans rien
    // essayer.
    let gql = (try? await streamTask) as? [String: Any]
    let token = await tokenTask
    let gqlData = gql?["data"] as? [String: Any]
    let gqlErrors = !((gql?["errors"] as? [Any]) ?? []).isEmpty
    let userValue = gqlData?["user"]
    let user = userValue as? [String: Any]
    if user == nil, userValue is NSNull, !gqlErrors {
        logger.error("LIVE", "Streamer \"\(login)\" introuvable")
        return LiveData(title: "", game: "", thumbnail: "", error: "not_found")
    }

    var avatar = user?["profileImageURL"] as? String
    let userId = user?["id"] as? String   // ← récupéré ici
    let stream = user?["stream"] as? [String: Any]

    if user != nil, stream == nil {
        logger.warn("LIVE", "\"\(login)\" est hors ligne")
        return LiveData(title: "Hors ligne", game: "", thumbnail: "", avatar: avatar,
                        userId: userId, error: "offline")
    }

    var title       = stream?["title"] as? String ?? ""
    var game        = (stream?["game"] as? [String: Any])?["name"] as? String ?? ""
    var thumbnail   = stream?["previewImageURL"] as? String ?? ""
    let viewerCount = stream?["viewersCount"] as? Int ?? 0
    // VOD en cours d'enregistrement → rembobinage du live (DVR)
    let dvrVideoId  = (stream?["archiveVideo"] as? [String: Any])?["id"] as? String
    if user == nil {
        logger.warn("LIVE", "Twitch ne répond pas pour \"\(login)\"", "sources essayées quand même")
    } else if let d = dvrVideoId {
        logger.success("LIVE", "Rembobinage disponible (DVR)", "vod \(d)")
    } else {
        logger.debug("LIVE", "Pas de rembobinage", "le streamer n'archive pas ses lives")
    }

    var startedAt: Date? = nil
    if let createdAtStr = stream?["createdAt"] as? String {
        let df = ISO8601DateFormatter()
        df.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        startedAt = df.date(from: createdAtStr) ?? ISO8601DateFormatter().date(from: createdAtStr)
    }

    // Mode faible latence (réglage, actif par défaut comme dans AppStore) :
    // demandé à chaque source, et plus seulement au flux officiel — Luminous
    // et TTV.LOL demandaient toujours la variante faible latence, même quand
    // on la coupe pour éviter des coupures.
    let lowLatency = UserDefaults.standard.object(forKey: "cfg_low_latency") as? Bool ?? true

    var found: MasterPlaylist = ([:], [:])
    var usedSource: String? = nil
    var webSessionExpired = false
    var subscriber: Bool? = nil
    // Qualités supérieures pour un compte qui aurait des pubs : son jeton.
    var hqToken: (value: String, signature: String)? = nil

    // Compte sans pub sur cette chaîne : son flux officiel d'abord. S'il ne
    // répond pas (géoblocage, réseau filtré), l'ordre habituel reprend.
    switch await accountTask {
    case .token(let pat):
        subscriber = pat.subscriber
        if pat.adFree && !pat.forbidden {
            // Jeton lié au compte : le seul que Twitch serve au-dessus de 1080p.
            found = await usherLiveLinks(login: login, token: (value: pat.value, signature: pat.signature),
                                         lowLatency: lowLatency, codecs: HigherQualities.requested)
            if !found.links.isEmpty {
                usedSource = "account"
                logger.success("LIVE", "✅ Direct par le compte (sans pub)", "\(found.links.count) qualités")
            } else {
                logger.warn("LIVE", "⚠️ Flux du compte indisponible", "sources habituelles…")
            }
        } else if !pat.forbidden, hqAccount, HigherQualities.enabled {
            // Pas sans pub ici, mais seul ce jeton dépasse 1080p : sa liste
            // maîtresse est demandée en même temps que les sources habituelles,
            // qui restent celles du direct (voir hqAccountLinks).
            hqToken = (value: pat.value, signature: pat.signature)
            logger.info("LIVE", "Compte pas sans pub : qualités supérieures demandées en parallèle",
                        "sources habituelles")
        } else {
            logger.info("LIVE", "Compte pas sans pub sur cette chaîne", "jeton anonyme, sources habituelles")
        }
    case .expired:
        webSessionExpired = true
        logger.warn("LIVE", "Session web refusée par Twitch", "sources habituelles")
    case .unavailable:
        break
    }
    let hqTokenValue = hqToken
    async let hqTask = higherQualitiesMaster(login: login, token: hqTokenValue, lowLatency: lowLatency)

    // Ordre des sources (Réglages → Lecteur, ou menu du lecteur) : essayées
    // l'une après l'autre, pour que le direct se lance quand même.
    let steps = liveSourceSteps()
    logger.info("LIVE", "Ordre des sources : \(steps.joined(separator: " → ").uppercased())")
    var workerInfo: [String: Any]? = nil
    for src in steps where found.links.isEmpty {
        onSource?(src)
        switch src {
        case "as":     found = await luminousLiveLinks(hosts: ["as.luminous.dev"], login: login, lowLatency: lowLatency)
        case "al":     found = await ttvlolLiveLinks(login: login, lowLatency: lowLatency)
        case "eu":     found = await luminousLiveLinks(hosts: kLuminousHosts.filter { $0 != "as.luminous.dev" },
                                                       login: login, lowLatency: lowLatency)
        case "twitch": if let token { found = await usherLiveLinks(login: login, token: token, lowLatency: lowLatency) }
        default:
            let worker = await workerLiveLinks(login: login)
            found = worker.master
            workerInfo = worker.info
        }
        if !found.links.isEmpty { usedSource = src }
    }

    // Qualités supérieures par le compte : à côté de la source habituelle,
    // que MainTabView garde pour les pauses pub. Aucune source habituelle :
    // le flux du compte, pubs de Twitch comprises, plutôt que rien.
    var hqMaster = await hqTask
    var accountAds = false
    if let master = hqMaster, found.links.isEmpty {
        found = master
        usedSource = "account"
        accountAds = true
        hqMaster = nil
        logger.warn("LIVE", "Aucune source habituelle : direct par le compte", "pubs de Twitch comprises")
    }

    if let uid = userId {
        logger.success("LIVE", "userId récupéré : \(uid) → emotes canal disponibles")
    }

    // Twitch n'a rien dit : titre, jeu, miniature et avatar du Worker, s'il
    // a servi le direct (une chaîne vide de sa part ne remplace rien).
    if user == nil, let info = workerInfo {
        func text(_ key: String) -> String? { (info[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        title = text("title") ?? title
        game = text("game") ?? game
        thumbnail = text("thumbnail") ?? thumbnail
        avatar = text("avatar") ?? avatar
    }

    // Aucune source n'a répondu alors que Twitch dit « en direct » : on le
    // dit, au lieu de laisser croire la chaîne hors ligne. Sans réponse de
    // Twitch non plus, c'est le réseau.
    var error: String? = nil
    if found.links.isEmpty {
        error = user == nil ? "network" : "no_source"
        logger.error("LIVE", user == nil ? "❌ Ni Twitch ni aucune source n'ont répondu"
                                         : "❌ Aucune source n'a répondu", login)
    }

    return LiveData(title: title, game: game, thumbnail: thumbnail, avatar: avatar,
                    userId: userId, links: found.links, viewerCount: viewerCount,
                    startedAt: startedAt, dvrVideoId: dvrVideoId, error: error, source: usedSource,
                    variants: found.variants, webSessionExpired: webSessionExpired,
                    subscriber: subscriber, hqAccountLinks: hqMaster?.links,
                    hqAccountVariants: hqMaster?.variants ?? [:], accountAds: accountAds)
}

/// Liste maîtresse du compte avec les qualités supérieures (HigherQualities),
/// pour un jeton à qui Twitch sert des pubs : seulement si elle dépasse
/// 1080p — sinon la source habituelle suffit, aucune pub risquée pour rien.
/// nil aussi sans jeton (réglage coupé, compte sans pub, multi-live, Apple TV).
private func higherQualitiesMaster(login: String, token: (value: String, signature: String)?,
                                   lowLatency: Bool) async -> MasterPlaylist? {
    guard let token, let codecs = HigherQualities.requested else { return nil }
    // 2 s au plus : le direct l'attend, puis la playlist du compte
    // (MainTabView.hqLaunch, 2 s aussi) — 4 s de plus au pire. Au-delà, la
    // source habituelle, comme sans le réglage.
    let master = await usherLiveLinks(login: login, token: token, lowLatency: lowLatency,
                                      codecs: codecs, timeout: 2)
    let top = master.variants.values.map(\.height).max() ?? 0
    guard top > 1080 else {
        if !master.links.isEmpty {
            logger.info("LIVE", "Rien au-dessus de 1080p par le compte", "source habituelle, sans pub")
        }
        return nil
    }
    logger.success("LIVE", "✅ Qualités supérieures par le compte : \(top)p",
                   "pauses pub de Twitch par la source habituelle")
    return master
}

/// Jeton du compte seulement si on en a donné un (iPhone, réglage actif).
/// 6 s au plus EN TOUT : si Twitch exige le jeton d'intégrité, sa fabrication
/// (WebView twitch.tv, jusqu'à ~20 s) et la seconde requête dépasseraient,
/// et getLive attend ce résultat avant les sources. Au-delà, ou si getLive
/// abandonne (chaîne hors ligne), on rend `.unavailable` tout de suite ; la
/// demande continue sans nous et le jeton d'intégrité fabriqué reste en cache
/// (DropsService) pour le direct suivant.
private func accountPlaybackIfAsked(login: String, webToken: String?,
                                    integrity: (() async -> (token: String, deviceId: String)?)?) async -> AccountPlayback {
    guard let webToken, !webToken.isEmpty else { return .unavailable }
    let work = Task { await accountPlaybackToken(login: login, webToken: webToken, integrity: integrity) }
    let gate = AccountPlaybackGate()
    return await withTaskCancellationHandler {
        await withCheckedContinuation { (cont: CheckedContinuation<AccountPlayback, Never>) in
            gate.wait(cont)
            Task { gate.resume(await work.value) }
            Task {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                if gate.resume(.unavailable) {
                    logger.warn("TOKEN", "Jeton du compte trop lent (6 s)", "sources habituelles")
                }
            }
        }
    } onCancel: {
        gate.resume(.unavailable)
    }
}

/// Reprend l'attente du jeton du compte une seule fois : le premier arrivé
/// l'emporte (jeton, délai ou abandon). Un abandon qui arrive avant que
/// l'attente commence est gardé et rendu dès qu'elle commence.
private final class AccountPlaybackGate: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<AccountPlayback, Never>?
    private var early: AccountPlayback?
    private var done = false

    func wait(_ c: CheckedContinuation<AccountPlayback, Never>) {
        lock.lock()
        if let early {
            self.early = nil
            lock.unlock()
            c.resume(returning: early)
            return
        }
        cont = c
        lock.unlock()
    }

    /// true si c'est cette valeur qui a été rendue.
    @discardableResult
    func resume(_ value: AccountPlayback) -> Bool {
        lock.lock()
        guard !done else { lock.unlock(); return false }
        done = true
        guard let c = cont else {
            early = value
            lock.unlock()
            return true
        }
        cont = nil
        lock.unlock()
        c.resume(returning: value)
        return true
    }
}

// MARK: – Sources du direct
/// Ordre des sources du direct : celui des réglages (« liveSourceOrder »),
/// sinon la source préférée d'avant (« liveSource », celle que garde l'app
/// Apple TV) en tête de l'ordre automatique — Luminous Asie, proxy albanais,
/// Luminous Europe, Twitch officiel (avec ses pubs). Une source inconnue est
/// ignorée, une oubliée ajoutée à la fin ; le Worker toujours en dernier.
func liveSourceSteps() -> [String] {
    let ud = UserDefaults.standard
    let saved = ud.stringArray(forKey: "liveSourceOrder") ?? [ud.string(forKey: "liveSource") ?? "auto"]
    var order: [String] = []
    for id in saved where kLiveSources.contains(id) && !order.contains(id) { order.append(id) }
    return order + kLiveSources.filter { !order.contains($0) } + ["worker"]
}

/// Miroirs Luminous, essayés dans l'ordre ; vide si aucun ne répond. Pas
/// « sans pub » : les pré-rolls et les pauses pub de la chaîne y arrivent
/// comme sur Twitch (écran « Commercial break in progress » ou vraie pub,
/// cousus dans la playlist ; voir AdBreakMonitor).
private func luminousLiveLinks(hosts: [String], login: String, lowLatency: Bool) async -> MasterPlaylist {
    for host in hosts {
        logger.info("LIVE", "Tentative Luminous…", host)
        guard var comps = URLComponents(string: "https://\(host)/live/\(login)") else { continue }
        comps.queryItems = [
            .init(name: "allow_source",     value: "true"),
            .init(name: "allow_audio_only", value: "true"),
            // fast_bread = variante faible latence côté Twitch.
            .init(name: "fast_bread",       value: lowLatency ? "true" : "false")
        ]
        guard let url = comps.url else { continue }
        // 8 s au plus par miroir (au lieu de 60), comme le flux officiel : un
        // miroir muet faisait attendre des minutes avant la source suivante.
        var req = URLRequest(url: url, timeoutInterval: 8)
        requestHeaders.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200, let body = String(data: data, encoding: .utf8) {
                let master = parseMaster(body, baseURL: url)
                if !master.links.isEmpty {
                    logger.success("LIVE", "✅ Luminous OK (\(host))", "\(master.links.count) qualités")
                    return master
                }
                logger.warn("LIVE", "⚠️ Luminous \(host) : playlist vide", "miroir suivant…")
            } else {
                logger.warn("LIVE", "⚠️ Luminous \(host) échec (\(code))", "miroir suivant…")
            }
        } catch {
            logger.error("LIVE", "❌ Erreur Luminous \(host)", error.localizedDescription)
        }
    }
    return ([:], [:])
}

/// Proxy albanais (format TTV.LOL : la requête usher encodée après
/// /playlist/<chaîne>.m3u8). Mêmes pauses pub de la chaîne que Luminous.
private func ttvlolLiveLinks(login: String, lowLatency: Bool) async -> MasterPlaylist {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    let query = "allow_source=true&allow_audio_only=true&fast_bread=\(lowLatency)"
        .addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    for host in kTTVLOLHosts {
        guard let url = URL(string: "https://\(host)/playlist/\(login).m3u8%3F\(query)") else { continue }
        logger.info("LIVE", "Tentative proxy TTV.LOL…", host)
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("https://ttv.lol/donate", forHTTPHeaderField: "X-Donate-To")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else {
            logger.warn("LIVE", "⚠️ Proxy \(host) indisponible", "source suivante…")
            continue
        }
        let body = String(decoding: data, as: UTF8.self)
        guard body.contains("#EXT-X-STREAM-INF") else { continue }
        let master = parseMaster(body, baseURL: url)
        if !master.links.isEmpty {
            logger.success("LIVE", "✅ Proxy TTV.LOL OK (\(host))", "\(master.links.count) qualités")
            return master
        }
    }
    return ([:], [:])
}

// MARK: – Qualités supérieures (Enhanced Broadcasting)
/// Réglage « Qualités supérieures » (iPhone, coupé par défaut) : la demande
/// de playlist du direct par le compte annonce à Twitch les codecs que
/// l'appareil décode (`supported_codecs`), et les chaînes en Enhanced
/// Broadcasting y ajoutent leurs variantes 1440p et plus, parfois en HEVC ou
/// AV1. Jamais pour un jeton anonyme (proxys, Worker, Twitch officiel sans
/// compte) : Twitch le plafonne à 1080p (`maximum_resolution` FULL_HD,
/// « AUTHZ_NOT_LOGGED_IN » au-delà) et ces demandes restent telles quelles.
/// Compte sans abonnement ni Turbo : le direct passe aussi par lui, mais
/// seulement au-dessus de 1080p, et la source habituelle (sans pub) prend
/// le relais pendant ses pauses pub (MainTabView.adBreakChanged).
enum HigherQualities {
    static let key = "cfg_higher_qualities"
    static var enabled: Bool { UserDefaults.standard.bool(forKey: key) }

    /// H.264 toujours ; HEVC et AV1 seulement si l'appareil les décode en
    /// matériel (AV1 : puces A17 Pro, M3 et suivantes). Le plus efficace d'abord.
    static let codecs: [String] = {
        var list: [String] = []
        // « av01 » écrit en clair : la constante manque aux SDK plus anciens.
        if VTIsHardwareDecodeSupported(CMVideoCodecType(0x6176_3031)) { list.append("av1") }
        if VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) { list.append("h265") }
        list.append("h264")
        return list
    }()

    /// Valeur de `supported_codecs` si le réglage est actif, sinon nil.
    static var requested: String? { enabled ? codecs.joined(separator: ",") : nil }

    /// « H.264 · HEVC · AV1 » (Réglages).
    static var label: String { codecs.reversed().map { names[$0] ?? $0 }.joined(separator: " · ") }
    private static let names: [String: String] = ["h264": "H.264", "h265": "HEVC", "av1": "AV1"]
}

/// Flux officiel de Twitch (usher), avec ses pubs.
/// `lowLatency` : Twitch sert alors la variante « low latency » (segments
/// plus courts, playlist rafraîchie plus souvent). `codecs` :
/// `supported_codecs`, pour le jeton du compte seulement (HigherQualities) ;
/// nil, la demande ne change pas. `timeout` : voir higherQualitiesMaster.
private func usherLiveLinks(login: String, token: (value: String, signature: String),
                            lowLatency wantsLowLatency: Bool, codecs: String? = nil,
                            timeout: TimeInterval = 8) async -> MasterPlaylist {
    guard login.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }), !login.isEmpty,
          var comps = URLComponents(string: "https://usher.ttvnw.net/api/channel/hls/\(login).m3u8")
    else { return ([:], [:]) }
    logger.info("LIVE", "Tentative Twitch officiel...")
    comps.queryItems = [
        .init(name: "allow_source",              value: "true"),
        .init(name: "allow_audio_only",           value: "true"),
        .init(name: "allow_spectre",              value: "true"),
        .init(name: "fast_bread",                 value: wantsLowLatency ? "true" : "false"),
        .init(name: "low_latency",                value: wantsLowLatency ? "true" : "false"),
        .init(name: "player_backend",             value: "mediaplayer"),
        .init(name: "playlist_include_framerate", value: "true"),
        .init(name: "segment_preference",         value: "4"),
        .init(name: "sig",                        value: token.signature),
        .init(name: "token",                      value: token.value),
    ]
    if let codecs {
        comps.queryItems?.append(.init(name: "supported_codecs", value: codecs))
        logger.info("LIVE", "Qualités supérieures demandées à Twitch", codecs)
    }
    if wantsLowLatency { logger.info("LIVE", "Mode faible latence demandé à Twitch") }
    // 8 s au plus par défaut (au lieu des 60 s d'URLSession) : réseau
    // filtré, la source suivante doit prendre le relais sans faire attendre.
    guard let url = comps.url,
          let (data, resp) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: timeout)),
          (resp as? HTTPURLResponse)?.statusCode == 200,
          let body = String(data: data, encoding: .utf8) else { return ([:], [:]) }
    let master = parseMaster(body, baseURL: url)
    logger.success("LIVE", "✅ Twitch officiel : \(master.links.count) qualités")
    return master
}

/// Worker Cloudflare : sa propre chaîne de sources, en dernier recours.
/// `info` : sa réponse (titre, jeu, miniature, avatar), pour quand Twitch
/// n'a rien dit à l'app.
private func workerLiveLinks(login: String) async -> (master: MasterPlaylist, info: [String: Any]?) {
    logger.info("LIVE", "Tentative Cloudflare Worker...")
    guard let json = await workerJSON("/api/get-live?name=\(login)&proxy=false"),
          let links = json["links"] as? QualityLinks else { return (([:], [:]), nil) }
    logger.success("LIVE", "✅ Cloudflare Worker : \(links.count) qualités")
    return ((links, workerVariants(json["variants"])), json)
}

// MARK: – getStreamStats (rafraîchissement LÉGER viewers/uptime, sans re-fetch des liens)
func getStreamStats(channelName: String) async -> (viewerCount: Int, startedAt: Date?) {
    let login = channelName.trimmingCharacters(in: .whitespaces).lowercased()
    let q = "query { user(login: \"\(gqlStr(login))\") { stream { viewersCount createdAt } } }"
    guard let json   = try? await twitchGQL(q) as? [String: Any],
          let data   = json["data"]   as? [String: Any],
          let user   = data["user"]   as? [String: Any],
          let stream = user["stream"] as? [String: Any] else {
        return (0, nil)
    }
    let viewerCount = stream["viewersCount"] as? Int ?? 0
    var startedAt: Date? = nil
    if let createdAtStr = stream["createdAt"] as? String {
        let df = ISO8601DateFormatter()
        df.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        startedAt = df.date(from: createdAtStr) ?? ISO8601DateFormatter().date(from: createdAtStr)
    }
    return (viewerCount, startedAt)
}

// MARK: – Page d'une chaîne (bandeau)
/// Ce qu'affiche la page d'une chaîne, en une requête GQL publique : avatar,
/// identifiant, direct en cours (titre, jeu, spectateurs, aperçu, début) et
/// début du dernier live (`lastStart`, pour « hors ligne depuis » quand le
/// dernier live n'a pas laissé de VOD). Sans résoudre les liens du direct :
/// getLive essayait toutes les sources (jusqu'à une minute par miroir muet)
/// avant d'afficher la page, et « Regarder » les résout de toute façon.
/// `live.error` : "offline" hors ligne, "not_found" si la chaîne n'existe
/// pas, "network" si Twitch n'a pas répondu (voir apiErrorKey).
func getChannelInfo(channelName: String) async -> (live: LiveData, lastStart: String?) {
    let login = channelName.trimmingCharacters(in: .whitespaces).lowercased()
    let q = """
    query($l: String!) { user(login: $l) {
        id profileImageURL(width: 70)
        lastBroadcast { startedAt }
        stream { title game { name } previewImageURL(width: 320, height: 180) viewersCount createdAt }
    } }
    """
    guard let d = await gqlRequest(q, ["l": login]) else {
        logger.warn("VIDEOS", "Page de \"\(login)\" : Twitch ne répond pas")
        return (LiveData(title: "", game: "", thumbnail: "", error: "network"), nil)
    }
    guard let user = d["user"] as? [String: Any] else {
        logger.warn("VIDEOS", "Streamer \"\(login)\" introuvable")
        return (LiveData(title: "", game: "", thumbnail: "", error: "not_found"), nil)
    }
    let avatar = user["profileImageURL"] as? String
    let userId = user["id"] as? String
    let lastStart = (user["lastBroadcast"] as? [String: Any])?["startedAt"] as? String
    guard let stream = user["stream"] as? [String: Any] else {
        return (LiveData(title: "Hors ligne", game: "", thumbnail: "", avatar: avatar,
                         userId: userId, error: "offline"), lastStart)
    }
    return (LiveData(title: stream["title"] as? String ?? "",
                     game: (stream["game"] as? [String: Any])?["name"] as? String ?? "",
                     thumbnail: stream["previewImageURL"] as? String ?? "",
                     avatar: avatar, userId: userId,
                     viewerCount: stream["viewersCount"] as? Int ?? 0,
                     startedAt: parseTwitchDate(stream["createdAt"] as? String)),
            lastStart)
}

// MARK: – getChannelVideos
func getChannelVideos(channelName: String, cursor: String? = nil) async -> (videos: [VodData], avatar: String?, error: String?, cursor: String?) {
    let page = await getChannelVideosPage(channelName: channelName, cursor: cursor)
    return (page.videos, page.avatar, page.error, page.cursor)
}

/// Comme getChannelVideos, plus `refused` : Twitch a refusé la page suivante
/// (intégrité, 400/401/403). La page 1 passe par le Client-ID web, la suite
/// par celui d'Android (gqlNextRequest) : avec le web, Twitch refuse tout
/// au-delà des 100 premières. Panne de la suite : `error` non nil, curseur gardé.
func getChannelVideosPage(channelName: String, cursor: String? = nil) async
    -> (videos: [VodData], avatar: String?, error: String?, cursor: String?, refused: Bool) {
    logger.info("VIDEOS", "Chargement VODs de \"\(channelName)\"\(cursor != nil ? " (Page suivante)" : "")")

    let afterCursor = cursor != nil ? ", after: \"\(gqlStr(cursor!))\"" : ""
    let q = """
    query {
        user(login: "\(gqlStr(channelName))") {
            profileImageURL(width: 70)
            videos(first: 100, type: ARCHIVE, sort: TIME\(afterCursor)) {
                edges { cursor node { id title previewThumbnailURL(height: 180, width: 320) publishedAt lengthSeconds } }
                pageInfo { hasNextPage }
            }
        }
    }
    """

    let data: [String: Any]?
    if let cursor {
        // Suite : même règle que les autres listes (gqlNextRequest) : refus
        // d'intégrité ou rejet en 400/401/403 = refus, nil = panne.
        guard let page = await gqlNextRequest(q, [:]) else {
            logger.warn("VIDEOS", "Suite des VODs de \"\(channelName)\" indisponible (réseau)")
            return (videos: [], avatar: nil, error: "network", cursor: cursor, refused: false)
        }
        if page.refused {
            logger.warn("VIDEOS", "Twitch refuse la suite des VODs de \"\(channelName)\"")
            return (videos: [], avatar: nil, error: nil, cursor: nil, refused: true)
        }
        data = page.data
    } else {
        data = (try? await twitchGQL(q) as? [String: Any])?["data"] as? [String: Any]
    }
    guard let user = data?["user"] as? [String: Any] else {
        logger.error("VIDEOS", "Streamer \"\(channelName)\" introuvable")
        return (videos: [], avatar: nil, error: "not_found", cursor: nil, refused: false)
    }

    let avatar     = user["profileImageURL"] as? String
    let videosDict = user["videos"] as? [String: Any]
    let edges      = (videosDict?["edges"] as? [[String: Any]]) ?? []

    let videos: [VodData] = edges.compactMap { e in
        guard let node  = e["node"] as? [String: Any],
              let id    = node["id"] as? String,
              let title = node["title"] as? String else { return nil }
        return VodData(
            id: id, title: title,
            previewThumbnailURL: node["previewThumbnailURL"] as? String ?? "",
            publishedAt: node["publishedAt"] as? String ?? "",
            lengthSeconds: node["lengthSeconds"] as? Int ?? 0
        )
    }

    let pageInfo    = videosDict?["pageInfo"] as? [String: Any]
    let hasNextPage = pageInfo?["hasNextPage"] as? Bool ?? false
    let nextCursor  = hasNextPage ? (edges.last?["cursor"] as? String) : nil

    logger.success("VIDEOS", "\(videos.count) VODs trouvées pour \"\(channelName)\"")
    return (videos: videos, avatar: avatar, error: nil, cursor: nextCursor, refused: false)
}

// MARK: – Couleur du pseudo (Helix)
/// Change la couleur du pseudo dans le chat.
///
/// Les commandes de modération et de compte (`/color`, `/ban`…) ont été
/// retirées de l'IRC par Twitch en 2023 : les envoyer en PRIVMSG renvoie
/// « Unrecognized command ». Tout passe maintenant par Helix.
///
/// Renvoie nil si tout s'est bien passé, sinon une clé de message d'erreur.
func setChatColor(token: String, userId: String, color: String) async -> String? {
    guard !userId.isEmpty,
          let url = URL(string: "https://api.twitch.tv/helix/chat/color?user_id=\(userId)&color=\(color)")
    else { return "color_bad_request" }

    var req = URLRequest(url: url)
    req.httpMethod = "PUT"
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue(kHelixClientID, forHTTPHeaderField: "Client-Id")

    guard let (_, resp) = try? await URLSession.shared.data(for: req) else {
        return "color_network"
    }
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    switch code {
    case 204, 200:
        logger.success("CHAT", "Couleur du pseudo changée", color)
        return nil
    case 401:
        // Jeton émis avant l'ajout du scope user:manage:chat_color.
        logger.warn("CHAT", "Couleur refusée : scope manquant", "reconnexion nécessaire")
        return "color_needs_relogin"
    default:
        logger.warn("CHAT", "Couleur refusée", "HTTP \(code)")
        return "color_failed"
    }
}

// MARK: – Chatteurs
//  Il n'existe plus d'API publique pour lister les personnes présentes :
//    • tmi.twitch.tv/group/user/<canal>/chatters a été fermé en 2023 ;
//    • la requête GQL `channel { chatters }` répond « failed integrity check »,
//      elle exige un jeton signé obtenu par un défi JavaScript ;
//    • Helix /chat/chatters impose d'être modérateur du canal.
//  La liste est donc constituée depuis l'IRC (voir ChatService.presentUsers).

// MARK: – Helix
func getTwitchUser(token: String) async -> TwitchUser? {
    try? await fetchTwitchUser(token: token)
}

/// Compte du jeton. Un jeton refusé par Twitch (401 : expiré, révoqué) lève
/// `.userAuthenticationRequired`, comme les lives suivis : l'accueil
/// déconnecte et invite à se reconnecter, au lieu d'afficher « erreur de
/// chargement » à chaque ouverture. nil : panne réseau, réponse inattendue.
func fetchTwitchUser(token: String) async throws -> TwitchUser? {
    guard let url = URL(string: "https://api.twitch.tv/helix/users") else { return nil }
    var req = URLRequest(url: url)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue(kHelixClientID, forHTTPHeaderField: "Client-Id")
    guard let (data, resp) = try? await URLSession.shared.data(for: req) else {
        logger.warn("HELIX", "Lecture du compte : pas de réponse (réseau)", nil)
        return nil
    }
    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
    if status == 401 { throw URLError(.userAuthenticationRequired) }
    guard status == 200,
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let arr  = json["data"] as? [[String: Any]], let u = arr.first else {
        logger.warn("HELIX", "Lecture du compte refusée", "HTTP \(status)")
        return nil
    }
    logger.success("HELIX", "Connecté en tant que \"\(u["display_name"] as? String ?? "")\"")
    return TwitchUser(
        id: u["id"] as? String ?? "",
        login: u["login"] as? String ?? "",
        displayName: u["display_name"] as? String ?? "",
        profileImageURL: u["profile_image_url"] as? String ?? ""
    )
}

/// Photo de profil d'un pseudo du chat. Mise en cache pour la session : on la
/// redemanderait sinon à chaque message ouvert, pour une image qui ne bouge pas.
actor AvatarCache {
    static let shared = AvatarCache()
    private var cache: [String: String] = [:]
    /// Pas de photo obtenue (compte disparu, ou réseau en panne) : pas
    /// redemandée avant 5 min, pour ne pas boucler sur un compte disparu,
    /// mais plus retenue pour toute la session : un échec passager (métro)
    /// laissait un rond gris jusqu'au redémarrage de l'app.
    private var misses: [String: Date] = [:]
    private static let missDelay: TimeInterval = 300

    func avatar(login: String, token: String?) async -> String? {
        let key = login.lowercased()
        guard !key.isEmpty else { return nil }
        if let hit = cache[key] { return hit }
        if let miss = misses[key], Date().timeIntervalSince(miss) < Self.missDelay { return nil }
        if let img = await fetch(key, token: token), !img.isEmpty {
            cache[key] = img
            misses[key] = nil
            return img
        }
        misses[key] = Date()
        return nil
    }

    private func fetch(_ key: String, token: String?) async -> String? {
        // Sans compte Twitch, pas de Helix : la photo vient de l'API publique
        // (GQL). Avant, la fonction renvoyait nil et le bandeau du lecteur
        // restait sur un rond gris.
        guard let token,
              let url = URL(string: "https://api.twitch.tv/helix/users?login=\(key)") else {
            return await publicAvatar(login: key)
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(kHelixClientID, forHTTPHeaderField: "Client-Id")

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr  = json["data"] as? [[String: Any]],
              let img  = arr.first?["profile_image_url"] as? String else {
            // Jeton expiré ou refusé : on tente encore l'API publique.
            return await publicAvatar(login: key)
        }
        return img
    }

    private func publicAvatar(login: String) async -> String? {
        await getUserAvatarGQL(login: login)
    }
}

/// Photo de profil par l'API publique (sans compte).
func getUserAvatarGQL(login: String) async -> String? {
    let q = "query($l: String!) { user(login: $l) { profileImageURL(width: 150) } }"
    guard let d = await gqlRequest(q, ["l": login.lowercased()]),
          let user = d["user"] as? [String: Any],
          let img = user["profileImageURL"] as? String, !img.isEmpty else { return nil }
    return img
}

/// Fiche d'une personne du chat : date de création de son compte (API
/// publique). nil : compte introuvable, ou Twitch n'a pas répondu. Gardée
/// pour la session (UserCardCache) : rouvrir la fiche ne redemande rien.
func getUserCreatedAt(login: String) async -> Date? {
    await UserCardCache.shared.createdAt(login: login.lowercased())
}

/// Depuis quand `login` suit la chaîne `channel` (API publique). Requête à
/// part de getUserCreatedAt : si Twitch refuse ce champ, la date de création
/// du compte reste affichée. nil : ne la suit pas, ou Twitch ne le dit pas.
func getFollowedAt(login: String, channel: String) async -> Date? {
    guard !channel.isEmpty else { return nil }
    return await UserCardCache.shared.followedAt(login: login.lowercased(), channel: channel.lowercased())
}

/// Fiche d'une personne du chat (MessageSheet) : dates gardées pour la
/// session — chaque ouverture refaisait les deux requêtes. Sans réponse
/// (réseau) : redemandées à la fiche suivante.
actor UserCardCache {
    static let shared = UserCardCache()
    private var created: [String: Date] = [:]
    /// Par personne et chaîne : la date, ou nil (ne la suit pas).
    private var followed: [String: Date?] = [:]
    /// Date de suivi refusée par Twitch (champ réservé ou retiré) : plus
    /// demandée de la session, et notée une fois au journal — avant, un
    /// « Requête refusée » à chaque fiche ouverte.
    private var followRefused = false

    func createdAt(login: String) async -> Date? {
        guard !login.isEmpty else { return nil }
        if let hit = created[login] { return hit }
        guard let date = await fetchUserCreatedAt(login) else { return nil }
        created[login] = date
        return date
    }

    func followedAt(login: String, channel: String) async -> Date? {
        guard !followRefused, !login.isEmpty else { return nil }
        let key = login + "|" + channel
        if let hit = followed[key] { return hit }
        switch await fetchFollowedAt(login, channel) {
        case .date(let date):
            followed.updateValue(date, forKey: key)
            return date
        case .refused(let why):
            // Deux fiches ouvertes coup sur coup : une seule ligne au journal.
            if !followRefused {
                followRefused = true
                logger.warn("GQL", "Date de suivi refusée par Twitch : plus demandée de la session", why)
            }
            return nil
        case .unreachable:
            return nil
        }
    }
}

private func fetchUserCreatedAt(_ login: String) async -> Date? {
    let q = "query($l: String!) { user(login: $l) { createdAt } }"
    guard let d = await gqlRequest(q, ["l": login]),
          let user = d["user"] as? [String: Any] else { return nil }
    return parseTwitchDate(user["createdAt"] as? String)
}

/// Réponse de Twitch à la date de suivi : la date (nil : ne suit pas), un
/// refus (ses messages), ou rien (réseau).
private enum FollowLookup {
    case date(Date?)
    case refused(String)
    case unreachable
}

private func fetchFollowedAt(_ login: String, _ channel: String) async -> FollowLookup {
    let q = "query($l: String!, $c: String!) { user(login: $l) { follow(targetLogin: $c) { followedAt } } }"
    guard let json = await gqlResponse(q, ["l": login, "c": channel]) else { return .unreachable }
    if json["errors"] != nil { return .refused(gqlErrorSummary(json)) }
    let user = (json["data"] as? [String: Any])?["user"] as? [String: Any]
    let follow = user?["follow"] as? [String: Any]
    return .date(parseTwitchDate(follow?["followedAt"] as? String))
}

/// Diffusion en cours d'une chaîne, pour en créer un clip : id de la chaîne,
/// id de la diffusion et heure de début (nils hors ligne).
struct LiveBroadcast {
    let channelId: String
    let broadcastId: String?
    let startedAt: Date?
}

/// nil : pas de réponse de Twitch (ou chaîne introuvable).
func getLiveBroadcast(login: String) async -> LiveBroadcast? {
    let q = "query($l: String!) { user(login: $l) { id stream { id createdAt } } }"
    guard let d = await gqlRequest(q, ["l": login.lowercased()]),
          let user = d["user"] as? [String: Any],
          let id = user["id"] as? String, !id.isEmpty else { return nil }
    let stream = user["stream"] as? [String: Any]
    return LiveBroadcast(channelId: id, broadcastId: stream?["id"] as? String,
                         startedAt: parseTwitchDate(stream?["createdAt"] as? String))
}

/// Lives suivis par le compte : 100 par page (le plafond de Helix), puis les
/// pages suivantes jusqu'à 300. Avant, les 50 premiers seulement : au-delà,
/// des chaînes manquaient à l'accueil, et les notifications revenaient pour
/// celles qui oscillaient autour de la 50ᵉ place (LiveNotifier les croyait
/// reparties). Une page suivante en panne n'annule pas les précédentes ; la
/// première lève l'erreur, comme avant.
func getFollowedStreams(token: String, userId: String) async throws -> [TwitchStream] {
    try await getFollowedStreamsPaged(token: token, userId: userId).streams
}

/// La même liste, et si elle est complète : faux quand une page suivante n'a
/// pas répondu, ou au-delà de 300. L'accueil et la TV s'en passent ;
/// LiveNotifier, lui, prenait les lives absents d'une liste partielle pour
/// finis, et les notifiait tous de nouveau au contrôle suivant.
func getFollowedStreamsPaged(token: String, userId: String) async throws -> (streams: [TwitchStream], complete: Bool) {
    var streams: [TwitchStream] = []
    var seen = Set<String>()
    var cursor: String? = nil
    var complete = true
    for page in 0..<3 {
        var address = "https://api.twitch.tv/helix/streams/followed?user_id=\(userId)&first=100"
        if let cursor {
            address += "&after=\(cursor.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? cursor)"
        }
        guard let url = URL(string: address) else { break }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(kHelixClientID, forHTTPHeaderField: "Client-Id")
        let data: Data, status: Int
        do {
            let (d, resp) = try await URLSession.shared.data(for: req)
            data = d
            status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            if page == 0 { throw error }
            complete = false
            break
        }
        guard status == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            guard page == 0 else { complete = false; break }
            // 401 distingué : l'accueil s'en sert pour déconnecter un jeton
            // expiré (le test sur le texte de l'erreur ne correspondait jamais).
            if status == 401 { throw URLError(.userAuthenticationRequired) }
            throw URLError(.badServerResponse)
        }
        let arr = json["data"] as? [[String: Any]] ?? []
        // Un live peut glisser d'une page à l'autre entre deux requêtes.
        for d in arr {
            let s = streamFromDict(d)
            if seen.insert(s.id).inserted { streams.append(s) }
        }
        cursor = (json["pagination"] as? [String: Any])?["cursor"] as? String
        guard let next = cursor, !next.isEmpty, !arr.isEmpty else { break }
        // 300 atteints, et il en reste.
        if page == 2 { complete = false }
    }
    logger.success("HELIX", "\(streams.count) streams suivis en direct" + (complete ? "" : " (liste partielle)"))
    return (streams, complete)
}

/// `count` : 50 d'habitude, 100 (le plafond de Helix) quand des chaînes ou
/// des catégories sont masquées, pour que le top reste plein une fois filtré.
func getTopStreams(token: String, lang: String? = nil, count: Int = 50) async throws -> [TwitchStream] {
    var urlStr = "https://api.twitch.tv/helix/streams?first=\(min(max(count, 1), 100))"
    if let lang { urlStr += "&language=\(lang)" }
    guard let url = URL(string: urlStr) else { return [] }
    var req = URLRequest(url: url)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue(kHelixClientID, forHTTPHeaderField: "Client-Id")
    let (data, resp) = try await URLSession.shared.data(for: req)
    // Erreur Helix (jeton refusé, 429, panne) : levée, et pas un top vide
    // sans message (sa réponse n'a pas de `data`) ; l'accueil passe alors
    // par le top public.
    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
    if status == 401 { throw URLError(.userAuthenticationRequired) }
    guard status == 200 else { throw URLError(.badServerResponse) }
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let arr  = json?["data"] as? [[String: Any]] ?? []
    logger.success("HELIX", "\(arr.count) top streams chargés")
    return arr.map { streamFromDict($0) }
}

// MARK: – Catégories (Helix)
/// Top des catégories, triées par audience décroissante côté Twitch.
func getTopCategories(token: String, cursor: String? = nil) async throws -> (categories: [TwitchCategory], cursor: String?) {
    var urlStr = "https://api.twitch.tv/helix/games/top?first=100"
    if let cursor { urlStr += "&after=\(cursor)" }
    guard let url = URL(string: urlStr) else { return ([], nil) }
    var req = URLRequest(url: url)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue(kHelixClientID, forHTTPHeaderField: "Client-Id")
    let (data, resp) = try await URLSession.shared.data(for: req)
    guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let arr  = json?["data"] as? [[String: Any]] ?? []
    let next = (json?["pagination"] as? [String: Any])?["cursor"] as? String
    logger.success("HELIX", "\(arr.count) catégories chargées")
    return (arr.map { categoryFromDict($0) }, arr.isEmpty ? nil : next)
}

/// Recherche de catégories par nom (barre de recherche de l'onglet Catégories).
func searchCategories(token: String, query: String) async throws -> [TwitchCategory] {
    // « & », « + », « = » encodés aussi : « Dungeons & Dragons » était coupé,
    // « C++ » devenait « C  ».
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "&+=?#")
    let q = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    guard !q.isEmpty,
          let url = URL(string: "https://api.twitch.tv/helix/search/categories?first=50&query=\(q)")
    else { return [] }
    var req = URLRequest(url: url)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue(kHelixClientID, forHTTPHeaderField: "Client-Id")
    let (data, resp) = try await URLSession.shared.data(for: req)
    guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let arr  = json?["data"] as? [[String: Any]] ?? []
    logger.success("HELIX", "\(arr.count) catégories pour « \(query) »")
    return arr.map { categoryFromDict($0) }
}

/// Lives d'une catégorie. Twitch les renvoie déjà par audience décroissante ;
/// les autres tris sont appliqués côté app (voir CategoriesView).
func getStreamsByCategory(token: String, gameId: String, cursor: String? = nil,
                          lang: String? = nil) async throws -> (streams: [TwitchStream], cursor: String?) {
    var urlStr = "https://api.twitch.tv/helix/streams?first=100&game_id=\(gameId)"
    // Langue au format Helix (« fr », « zh-hk »).
    if let lang { urlStr += "&language=\(lang)" }
    if let cursor { urlStr += "&after=\(cursor)" }
    guard let url = URL(string: urlStr) else { return ([], nil) }
    var req = URLRequest(url: url)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue(kHelixClientID, forHTTPHeaderField: "Client-Id")
    let (data, resp) = try await URLSession.shared.data(for: req)
    guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let arr  = json?["data"] as? [[String: Any]] ?? []
    let next = (json?["pagination"] as? [String: Any])?["cursor"] as? String
    logger.success("HELIX", "\(arr.count) lives dans la catégorie \(gameId)")
    return (arr.map { streamFromDict($0) }, arr.isEmpty ? nil : next)
}

/// Audience par catégorie, en une requête pour toute une page.
///
/// Helix ne la donne pas : `games/top` renvoie un classement, pas de chiffres.
/// GQL, lui, expose `viewersCount` par identifiant. Les champs sont aliasés
/// pour tenir dans un seul aller-retour — cent alias passent sans broncher —
/// et la requête ne demande aucun jeton d'intégrité, contrairement à
/// `channel { chatters }`.
///
/// Un échec n'est pas une erreur ici : la carte affiche simplement la
/// catégorie sans son audience.
func categoryViewers(ids: [String]) async -> [String: Int] {
    guard !ids.isEmpty else { return [:] }
    var out: [String: Int] = [:]

    for start in stride(from: 0, to: ids.count, by: 100) {
        let chunk = Array(ids[start ..< min(start + 100, ids.count)])
        let fields = chunk.enumerated()
            .map { "g\($0.offset): game(id: \"\(gqlStr($0.element))\") { id viewersCount }" }
            .joined(separator: " ")

        guard let json = try? await twitchGQL("query { \(fields) }") as? [String: Any],
              let data = json["data"] as? [String: Any] else { continue }

        for (_, value) in data {
            guard let game = value as? [String: Any],
                  let id    = game["id"] as? String,
                  let count = game["viewersCount"] as? Int else { continue }
            out[id] = count
        }
    }

    logger.success("GQL", "\(out.count) audiences de catégories sur \(ids.count)")
    return out
}

/// Jaquette en 570×760 quelle que soit l'adresse reçue : gabarit
/// {width}×{height} (top Helix) ou taille fixe (recherche Helix en 52×72,
/// catégories suivies enregistrées avec une ancienne taille).
func sharpBoxArt(_ url: String) -> String {
    url.replacingOccurrences(of: "{width}", with: "570")
        .replacingOccurrences(of: "{height}", with: "760")
        .replacingOccurrences(of: #"-\d+x\d+(\.(?:jpe?g|png|webp))$"#,
                              with: "-570x760$1", options: .regularExpression)
}

/// Le nom exact d'abord (« valorant » → VALORANT), puis l'ordre de Twitch.
func rankCategories(_ list: [TwitchCategory], for query: String) -> [TwitchCategory] {
    let fold = { (s: String) -> String in
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespaces)
    }
    let q = fold(query)
    return list.filter { fold($0.name) == q } + list.filter { fold($0.name) != q }
}

private func categoryFromDict(_ d: [String: Any]) -> TwitchCategory {
    // 570×760, soit le double de la taille de référence de Twitch. La grille
    // fait deux colonnes : une jaquette y occupe environ 170 pt, donc plus de
    // 500 px sur un écran ×3. À 144×192 l'image était agrandie quatre fois et
    // sortait floue. Le CDN sert la taille demandée telle quelle, sans
    // agrandissement de son côté. La recherche Helix, elle, ne donne pas de
    // gabarit mais une taille fixe de 52×72 : remplacée aussi.
    let raw = sharpBoxArt(d["box_art_url"] as? String ?? "")
    return TwitchCategory(
        id:   d["id"]   as? String ?? UUID().uuidString,
        name: d["name"] as? String ?? "",
        boxArtURL: raw
    )
}

private func streamFromDict(_ d: [String: Any]) -> TwitchStream {
    TwitchStream(
        id: d["user_id"] as? String ?? UUID().uuidString,
        userLogin: d["user_login"] as? String ?? "",
        userName:  d["user_name"]  as? String ?? "",
        title:     d["title"]      as? String ?? "",
        gameName:  d["game_name"]  as? String ?? "",
        viewerCount: d["viewer_count"] as? Int ?? 0,
        thumbnailURL: d["thumbnail_url"] as? String ?? "",
        tags: d["tags"] as? [String] ?? [],
        gameId: d["game_id"] as? String ?? ""
    )
}

// MARK: – Autocomplete GQL
/// Suggestions pendant la frappe : les 5 premières chaînes trouvées.
func searchUsersGQL(_ query: String) async -> [AutocompleteSuggestion] {
    await searchChannelsGQL(query, first: 5) ?? []
}

/// Chaînes dont le nom correspond (GQL public) : suggestions de la frappe et
/// onglet « Chaînes » des résultats. nil si Twitch n'a pas répondu.
func searchChannelsGQL(_ query: String, first: Int = 30) async -> [AutocompleteSuggestion]? {
    // `stream` : présent seulement si la chaîne est en live (pastille dans la liste).
    let q = "query($q: String!) { searchUsers(userQuery: $q, first: \(min(max(first, 1), 50))) { edges { node { login displayName profileImageURL(width: 70) followers { totalCount } stream { viewersCount game { displayName } } } } } }"
    guard let data = await gqlRequest(q, ["q": query]),
          let edges = (data["searchUsers"] as? [String: Any])?["edges"] as? [[String: Any]] else { return nil }
    let list: [AutocompleteSuggestion] = edges.compactMap { e in
        guard let node  = e["node"] as? [String: Any],
              let login = node["login"] as? String else { return nil }
        let stream = node["stream"] as? [String: Any]
        return AutocompleteSuggestion(login: login,
                                      name: node["displayName"] as? String ?? login,
                                      avatar: node["profileImageURL"] as? String,
                                      viewers: stream.map { $0["viewersCount"] as? Int ?? 0 },
                                      game: (stream?["game"] as? [String: Any])?["displayName"] as? String,
                                      followers: (node["followers"] as? [String: Any])?["totalCount"] as? Int)
    }
    // Les chaînes en live d'abord, sans changer l'ordre de Twitch entre elles.
    return list.filter(\.isLive) + list.filter { !$0.isLive }
}

func getVodMetaGQL(_ vodId: String) async -> VodMeta? {
    let q = "query { video(id: \"\(gqlStr(vodId))\") { title lengthSeconds viewCount owner { login displayName } previewThumbnailURL(height: 180, width: 320) } }"
    guard let json = try? await twitchGQL(q) as? [String: Any],
          let data = json["data"] as? [String: Any],
          let v    = data["video"] as? [String: Any],
          let title = v["title"] as? String else { return nil }
    let owner = v["owner"] as? [String: Any]
    return VodMeta(
        title: title,
        // Pas de nom affiché : le login, sinon rien (« Inconnu », en français
        // dans toutes les langues, partait dans l'historique et l'écran
        // verrouillé).
        streamer: owner?["displayName"] as? String ?? owner?["login"] as? String ?? "",
        thumb: v["previewThumbnailURL"] as? String ?? "",
        lengthSeconds: v["lengthSeconds"] as? Int ?? 0,
        viewCount: v["viewCount"] as? Int ?? 0,
        login: owner?["login"] as? String ?? ""
    )
}

// MARK: – Utilities
func extractVodId(_ input: String) -> String? {
    let pattern = #"\d{8,}"#
    guard let range = input.range(of: pattern, options: .regularExpression) else { return nil }
    return String(input[range])
}

/// La saisie désigne-t-elle une VOD (lien …/videos/…, ou identifiant : un
/// nombre de 8 chiffres ou plus) ? Recherche et multi-live.
func isVodInput(_ input: String) -> Bool {
    let t = input.trimmingCharacters(in: .whitespaces)
    guard !t.isEmpty else { return false }
    if t.lowercased().contains("/videos/") { return true }
    return t.allSatisfy(\.isNumber) && t.count >= 8
}

/// Pages du site de Twitch, pas des chaînes (« twitch.tv/directory »,
/// « twitch.tv/settings/profile »…).
private let twitchSitePaths: Set<String> = [
    "videos", "directory", "settings", "subscriptions", "inventory", "wallet", "drops",
    "search", "downloads", "jobs", "p", "collections", "moderator", "popout", "embed",
    "login", "signup", "logout", "payments",
]

/// Chaîne désignée par une saisie : le premier mot en minuscules, sans
/// « @ », ou la chaîne d'un lien Twitch collé (« twitch.tv/xqc »,
/// « https://www.twitch.tv/xqc/clips »). Un lien vers une page du site ou
/// vers un clip (clips.twitch.tv) n'en désigne pas : la saisie reste telle
/// quelle. Pas forcément un nom valide : voir `isValidLogin`.
func loginFromInput(_ input: String) -> String {
    var login = input.trimmingCharacters(in: .whitespaces)
        .components(separatedBy: " ").first?.lowercased() ?? ""
    if login.range(of: #"(^|[/.])clips\.twitch\.tv/"#, options: .regularExpression) == nil,
       let r = login.range(of: #"twitch\.tv/([a-z0-9_]{1,25})"#, options: .regularExpression) {
        let path = login[r].replacingOccurrences(of: "twitch.tv/", with: "")
        if !twitchSitePaths.contains(path) { login = path }
    }
    if login.hasPrefix("@") { login.removeFirst() }
    return login
}

private let clipLinkPattern = try? NSRegularExpression(
    pattern: #"^(?:https?://)?(?:www\.|m\.)?(?:clips\.twitch\.tv/|twitch\.tv/[a-z0-9_]+/clip/)([A-Za-z0-9_-]{3,100})"#,
    options: [.caseInsensitive])
private let twitchTimePattern = try? NSRegularExpression(
    pattern: #"^(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s?)?$"#, options: [.caseInsensitive])

/// Clip désigné par un lien (« clips.twitch.tv/Slug »,
/// « twitch.tv/chaine/clip/Slug »), nil sinon. Même règle que le site
/// (clipSlugFrom) ; la casse du slug compte.
func clipSlugFromInput(_ input: String) -> String? {
    let t = input.trimmingCharacters(in: .whitespaces)
    guard let m = clipLinkPattern?.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
          let r = Range(m.range(at: 1), in: t) else { return nil }
    return String(t[r])
}

/// Instant de départ d'un lien de VOD (« ?t=1h2m3s », « &t=3723s »,
/// « ?t=3723 »), en secondes ; nil sans « t » ou s'il est nul. Même règle
/// que le site (twitchTime).
func vodStartFromInput(_ input: String) -> Double? {
    guard let r = input.range(of: #"[?&]t=[^&#\s]+"#, options: .regularExpression) else { return nil }
    let raw = String(input[r].drop(while: { $0 != "=" }).dropFirst())
    guard let m = twitchTimePattern?.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw))
    else { return nil }
    func part(_ i: Int) -> Int {
        guard let r = Range(m.range(at: i), in: raw) else { return 0 }
        return Int(raw[r]) ?? 0
    }
    let seconds = part(1) * 3600 + part(2) * 60 + part(3)
    return seconds > 0 ? Double(seconds) : nil
}

/// Nom de chaîne Twitch possible : 1 à 25 caractères parmi a-z, 0-9 et « _ ».
func isValidLogin(_ login: String) -> Bool {
    login.range(of: #"^[a-z0-9_]{1,25}$"#, options: .regularExpression) != nil
}

func formatViewers(_ count: Int) -> String {
    count >= 1000 ? String(format: "%.1fk", Double(count) / 1000) : "\(count)"
}

func formatDuration(_ seconds: Int) -> String {
    let h = seconds / 3600, m = (seconds % 3600) / 60
    return h > 0 ? "\(h)h \(m)min" : "\(m)min"
}

/// Twitch date ses VODs sans fractions de seconde et ses lives avec : on
/// accepte les deux formats.
func parseTwitchDate(_ s: String?) -> Date? {
    guard let s else { return nil }
    let df = ISO8601DateFormatter()
    df.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return df.date(from: s) ?? ISO8601DateFormatter().date(from: s)
}

/// Fin du dernier live : la dernière VOD (début + durée) ou, si plus tard, le
/// dernier live lancé (un live sans VOD n'en laisse pas).
func lastLiveEnd(publishedAt: String?, lengthSeconds: Int, lastStart: String?) -> Date? {
    let fromVod = parseTwitchDate(publishedAt)?.addingTimeInterval(TimeInterval(lengthSeconds))
    let started = parseTwitchDate(lastStart)
    switch (fromVod, started) {
    case let (a?, b?): return max(a, b)
    case let (a?, nil): return a
    case let (nil, b?): return b
    default: return nil
    }
}

#if os(iOS)
/// « 13 d · 21 sept. » : durée dans la langue de l'app, puis la date (avec
/// l'année si ce n'est pas celle en cours).
func offlineLabel(since end: Date, store: AppStore) -> String {
    let diff = Date().timeIntervalSince(end)
    guard diff > 0 else { return "" }
    let days = Int(diff / 86400), hours = Int(diff / 3600), minutes = Int(diff / 60)
    let span = days > 0 ? "\(days) \(store.t("day"))"
             : hours > 0 ? "\(hours) \(store.t("hour"))"
             : "\(minutes) \(store.t("min"))"
    let df = DateFormatter()
    df.locale = Locale(identifier: store.lang.rawValue)
    let sameYear = Calendar.current.component(.year, from: end) == Calendar.current.component(.year, from: Date())
    df.setLocalizedDateFormatFromTemplate(sameYear ? "d MMM" : "d MMM y")
    return "\(span) · \(df.string(from: end))"
}
#endif

// MARK: – Qualités : ordre, hauteur, préférence, libellé
/// Qualités préférées possibles (réglage, sauvegarde) : celles du site, sans
/// son « auto » (l'app et l'Apple TV n'ont pas d'Auto pour l'instant).
let kQualityPrefs = ["source", "1080", "720", "480", "360", "160", "audio"]

func isSourceQuality(_ key: String) -> Bool { ["source", "chunked"].contains(key.lowercased()) }
func isAudioQuality(_ key: String) -> Bool { key.lowercased().contains("audio") }
/// « Auto » : la liste maîtresse, que seuls les liens du Worker proposent.
func isAutoQuality(_ key: String) -> Bool { key.lowercased() == "auto" }

/// Choix possibles pour les données mobiles : « auto » (la liste adaptative :
/// la qualité suit le débit), « same » (comme en Wi-Fi), ou un palier.
let kCellularQualityPrefs = ["auto", "same", "720", "480", "360", "audio"]

/// Qualité à lancer selon la connexion. En données mobiles, la préférence
/// des données mobiles : « auto » prend la liste adaptative si le flux en a
/// une, sinon 720p au plus — une qualité fixe trop haute pour le débit
/// gelait l'image (calages en boucle) pendant que le chat continuait.
func launchQualityKey(_ keys: [String], pref: String, cellularPref: String, cellular: Bool,
                      variants: [String: VariantInfo] = [:]) -> String {
    guard cellular, cellularPref != "same" else { return preferredQualityKey(keys, pref: pref, variants: variants) }
    if cellularPref == "auto" {
        if pref == "audio" { return preferredQualityKey(keys, pref: pref, variants: variants) }
        if let auto = keys.first(where: isAutoQuality) { return auto }
        return preferredQualityKey(keys, pref: String(min(Int(pref) ?? 720, 720)), variants: variants)
    }
    return preferredQualityKey(keys, pref: cellularPref, variants: variants)
}

/// Hauteur écrite dans le nom : « 720p60 » → 720, « 1920x1080 » → 1080.
private func nameHeight(_ key: String) -> Int? {
    if let r = key.range(of: #"\d+x\d+"#, options: .regularExpression) {
        return key[r].split(separator: "x").last.flatMap { Int($0) }
    }
    if let r = key.range(of: #"\d+(?=p)"#, options: .regularExpression) { return Int(key[r]) }
    return nil
}

/// Hauteur d'une qualité : celle de la liste maîtresse (ou du Worker) quand
/// on l'a, sinon celle de son nom. « Source » sans information : le palier
/// standard au-dessus de la meilleure qualité transcodée (1080 s'il y a une
/// 720p, 720 si la meilleure est une 480p) — une chaîne en 720p60 sans
/// transcodage 720 garde ainsi sa Source pour une préférence 720p.
/// Audio seul : 0.
func qualityHeight(_ key: String, among keys: [String], variants: [String: VariantInfo] = [:]) -> Int {
    if isAudioQuality(key) { return 0 }
    if let h = variants[key]?.height, h > 0 { return h }
    if let h = nameHeight(key) { return h }
    guard isSourceQuality(key) else { return 0 }
    let best = keys.filter { !isSourceQuality($0) }.compactMap { nameHeight($0) }.max() ?? 0
    guard best > 0 else { return 1080 }
    return [360, 480, 720, 1080, 1440, 2160].first { $0 > best } ?? best
}

/// Cadence : celle de la liste maîtresse, sinon celle du nom (« 720p60 »).
private func qualityFPS(_ key: String, variants: [String: VariantInfo]) -> Double {
    if let f = variants[key]?.fps, f > 0 { return f }
    if let r = key.range(of: #"(?<=p)\d+"#, options: .regularExpression) { return Double(String(key[r])) ?? 0 }
    return 0
}

/// Ordre des menus : Source en tête, puis « Auto » (liens du Worker), puis de
/// la plus haute à la plus basse (à hauteur égale, la plus fluide), l'audio
/// seul en dernier. `.first` reste Source.
func sortQualities(_ keys: [String], variants: [String: VariantInfo] = [:]) -> [String] {
    func group(_ k: String) -> Int {
        isSourceQuality(k) ? 0 : isAutoQuality(k) ? 1 : isAudioQuality(k) ? 3 : 2
    }
    return keys.sorted { a, b in
        if group(a) != group(b) { return group(a) < group(b) }
        let ha = qualityHeight(a, among: keys, variants: variants)
        let hb = qualityHeight(b, among: keys, variants: variants)
        if ha != hb { return ha > hb }
        let fa = qualityFPS(a, variants: variants), fb = qualityFPS(b, variants: variants)
        if fa != fb { return fa > fb }
        return a < b
    }
}

/// Qualité à lancer d'après la préférence (`kQualityPrefs`), même règle que
/// le site : une hauteur prend la même hauteur à la cadence la plus haute,
/// sinon la plus haute en dessous, sinon la plus basse au-dessus ; « source »
/// prend Source, sinon la vidéo la plus haute ; « audio » l'audio seul, sinon
/// la vidéo la plus basse. Une valeur inconnue (« auto » venu du site) compte
/// comme « source ». « Auto » n'est choisi que s'il n'y a rien d'autre.
func preferredQualityKey(_ keys: [String], pref: String, variants: [String: VariantInfo] = [:]) -> String {
    let h = { (k: String) in qualityHeight(k, among: keys, variants: variants) }
    let f = { (k: String) in qualityFPS(k, variants: variants) }
    // Vidéos de la plus haute à la plus basse (« Auto » n'en est pas une).
    let video = keys.filter { !isAudioQuality($0) && !isAutoQuality($0) }
        .sorted { (h($0), f($0), $1) > (h($1), f($1), $0) }
    let audio = keys.first(where: isAudioQuality)
    let fallback = video.first ?? audio ?? keys.first ?? ""
    if pref == "audio" { return audio ?? video.last ?? fallback }
    if let want = Int(pref) {
        return video.first { h($0) == want } ?? video.first { h($0) < want } ?? video.last ?? fallback
    }
    return video.first(where: isSourceQuality) ?? fallback
}

/// Préférence déduite d'une qualité choisie dans le lecteur : « audio »,
/// « source » pour une vraie Source (comme le site) ou une vidéo au-dessus
/// de 1080p, sinon le palier standard le plus proche (une 936p devient
/// « 1080 », qui la reprendra faute de 1080p). La plus haute d'une liste
/// sans Source (clip, multi-encodage) donne son palier, pas « source » :
/// sinon toucher la 720p d'un clip ferait partir les directs en Source.
/// nil pour « Auto », que l'app ne retient pas, et pour une qualité dont
/// on ne sait rien.
func qualityPreference(for key: String, among keys: [String], variants: [String: VariantInfo] = [:]) -> String? {
    if isAudioQuality(key) { return "audio" }
    if isAutoQuality(key) { return nil }
    if isSourceQuality(key) { return "source" }
    let height = qualityHeight(key, among: keys, variants: variants)
    guard height > 0 else { return nil }
    if height > 1080 { return "source" }
    let tier = [1080, 720, 480, 360, 160].min { abs($0 - height) < abs($1 - height) } ?? 1080
    return String(tier)
}

/// Nom d'une qualité dans les menus (iPhone et Apple TV) : « Source »
/// (chunked compris) avec sa résolution quand la liste maîtresse ou le
/// Worker la donnent (`variants` : « 1440p (Source) », « 1080p60 (Source) »),
/// « Audio seul » traduit, « 720p » pour « 720p30 » (la cadence ordinaire),
/// « 1080p » pour « 1920x1080 ». Seul l'affichage change : la clé reste
/// « Source » (qualité préférée, liens, synchro). Les noms de fichiers des
/// téléchargements gardent la clé brute.
func qualityText(_ key: String, _ lang: Lang, variants: [String: VariantInfo] = [:]) -> String {
    if isSourceQuality(key) {
        guard let v = variants[key], v.height > 0 else { return "Source" }
        // La cadence au-delà de 30 i/s, comme le nom des autres qualités.
        let rate = v.fps.isFinite ? Int(v.fps.rounded()) : 0
        return "\(v.height)p" + (rate > 30 ? "\(rate)" : "") + " (Source)"
    }
    if isAudioQuality(key) { return translate("q_audio", lang) }
    if key.hasSuffix("p30") { return String(key.dropLast(2)) }
    if key.range(of: #"^\d+x\d+$"#, options: .regularExpression) != nil, let h = nameHeight(key) { return "\(h)p" }
    return key
}

// MARK: – Validité de la session web
/// La session web (cookie `auth-token`) n'a pas de date d'expiration connue :
/// elle meurt quand Twitch le décide — déconnexion ailleurs, changement de mot
/// de passe, révocation. Sans vérification, on s'en aperçoit seulement quand
/// les points de chaîne cessent silencieusement de répondre.
///
/// `.invalid` uniquement quand Twitch dit explicitement que le jeton ne vaut
/// rien : une panne réseau (`.unknown`) laisse la session en place, la couper
/// sur un wifi capricieux serait pire que le mal. `.valid` donne le compte de
/// la session, comparé à celui de l'app (AppStore.validateWebSession).
enum WebSessionCheck {
    case valid(id: String, login: String)
    case invalid
    case unknown
}

func webSessionIdentity(token: String) async -> WebSessionCheck {
    guard !token.isEmpty, let url = URL(string: "https://gql.twitch.tv/gql") else { return .invalid }

    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue(kGQLClientID,       forHTTPHeaderField: "Client-ID")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("OAuth \(token)",   forHTTPHeaderField: "Authorization")
    req.httpBody = try? JSONSerialization.data(
        withJSONObject: ["query": "query { currentUser { id login } }"])

    guard let (data, resp) = try? await URLSession.shared.data(for: req) else {
        logger.debug("AUTH/WEB", "Vérification impossible", "réseau — session conservée")
        return .unknown
    }
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    if code == 401 || code == 403 {
        logger.warn("AUTH/WEB", "Session web expirée", "HTTP \(code)")
        return .invalid
    }
    guard code == 200,
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let payload = json["data"] as? [String: Any] else {
        return .unknown   // réponse inattendue : on ne tranche pas
    }
    // `currentUser` à null = jeton rejeté, même avec un HTTP 200.
    guard let user = payload["currentUser"] as? [String: Any] else {
        logger.warn("AUTH/WEB", "Session web expirée", "currentUser vide")
        return .invalid
    }
    guard let id = user["id"] as? String else { return .unknown }
    logger.debug("AUTH/WEB", "Session web valide", "@\(user["login"] as? String ?? "?")")
    return .valid(id: id, login: user["login"] as? String ?? "")
}

// MARK: – Photo de profil d'une chaîne
/// L'avatar du bandeau du lecteur. En direct, `getLive` le ramène déjà ; pour
/// une VOD il n'était jamais demandé, d'où le rond gris. On passe par le cache
/// partagé avec la feuille de message : une requête par chaîne et par session.
func channelAvatar(login: String, token: String?) async -> String? {
    await AvatarCache.shared.avatar(login: login, token: token)
}

/// Texte rendu sûr pour une chaîne GQL entre guillemets. Sans cela, un `"`
/// tapé dans la recherche (ou venu de l'historique synchronisé) cassait la
/// requête ou permettait d'en réécrire le contenu.
func gqlStr(_ s: String) -> String {
    var out = ""
    for ch in s.unicodeScalars {
        switch ch {
        case "\\": out += "\\\\"
        case "\"": out += "\\\""
        case "\n", "\r", "\t": out += " "
        default:
            if ch.value >= 0x20 { out.unicodeScalars.append(ch) }
        }
    }
    return out
}

// MARK: – Clips
/// Requête GQL avec variables (les valeurs ne sont jamais collées dans le texte).
private func gqlRequest(_ query: String, _ variables: [String: Any]) async -> [String: Any]? {
    guard let json = await gqlResponse(query, variables) else { return nil }
    if json["errors"] != nil { logger.warn("GQL", "Requête refusée", gqlErrorSummary(json)) }
    return json["data"] as? [String: Any]
}

/// Réponse entière (données et erreurs), sans noter les refus : l'appelant
/// en juge (date de suivi de la fiche d'une personne, notée une fois).
private func gqlResponse(_ query: String, _ variables: [String: Any]) async -> [String: Any]? {
    guard let url = URL(string: "https://gql.twitch.tv/gql"),
          let body = try? JSONSerialization.data(withJSONObject: ["query": query, "variables": variables]) else { return nil }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue(kGQLClientID, forHTTPHeaderField: "Client-ID")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = body
    guard let (data, _) = try? await URLSession.shared.data(for: req),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        logger.warn("GQL", "Requête sans réponse (réseau)", String(query.prefix(60)))
        return nil
    }
    return json
}

/// Messages d'erreur d'une réponse GQL (codes compris), pour le journal.
func gqlErrorSummary(_ json: [String: Any]?) -> String {
    guard let errors = json?["errors"] as? [[String: Any]], !errors.isEmpty else { return "réponse inattendue" }
    return errors.prefix(3).map { e in
        let code = (e["extensions"] as? [String: Any])?["code"] as? String
        return [e["message"] as? String, code].compactMap { $0 }.joined(separator: " · ")
    }.joined(separator: " | ")
}

// MARK: – Pages suivantes des listes (Client-ID Android)
/// Twitch refuse la page faute de jeton d'intégrité : réponse HTTP 200, liste
/// à null et `errors[].extensions.code` = IntegrityCheckFailed. Sans cette
/// lecture, un refus ressemblerait à une fin de liste.
private func gqlIntegrityRefused(_ json: [String: Any]) -> Bool {
    guard let errors = json["errors"] as? [[String: Any]] else { return false }
    return errors.contains { e in
        (e["extensions"] as? [String: Any])?["code"] as? String == "IntegrityCheckFailed"
            || ((e["message"] as? String)?.lowercased().contains("integrity check") ?? false)
    }
}

/// Page suivante d'une liste, sans jeton, avec le Client-ID d'Android
/// (kGQLNextClientID). nil : panne réseau ou réponse illisible (on pourra
/// réessayer). `refused` : Twitch refuse ce Client-ID (intégrité, ou rejet
/// d'office en 400/401/403) ; inutile de rejouer la même requête.
private func gqlNextRequest(_ query: String, _ variables: [String: Any]) async -> (data: [String: Any]?, refused: Bool)? {
    guard let url = URL(string: "https://gql.twitch.tv/gql"),
          let body = try? JSONSerialization.data(withJSONObject: ["query": query, "variables": variables]) else { return nil }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue(kGQLNextClientID, forHTTPHeaderField: "Client-ID")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = body
    guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return nil }
    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
    if [400, 401, 403].contains(status) {
        logger.warn("GQL", "Page suivante refusée (HTTP \(status))")
        return (nil, true)
    }
    guard status == 200,
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    if gqlIntegrityRefused(json) {
        logger.warn("GQL", "Page suivante refusée (intégrité)")
        return (nil, true)
    }
    return (json["data"] as? [String: Any], false)
}

/// Une page de liste : la 1ʳᵉ (`after` nil) par le Client-ID web, comme
/// avant ; la suite par gqlNextRequest, `after` passé en variable `$after`.
private func gqlListPage(_ query: String, _ variables: [String: Any],
                         after: String?) async -> (data: [String: Any]?, refused: Bool)? {
    guard let after else {
        guard let d = await gqlRequest(query, variables) else { return nil }
        return (d, false)
    }
    var vars = variables
    vars["after"] = after
    return await gqlNextRequest(query, vars)
}

/// Curseur de la page suivante d'une connexion GQL (`edges { cursor }` +
/// `pageInfo { hasNextPage }`) : celui de la dernière arête, seulement si
/// Twitch annonce une suite. Sans suite, les curseurs des clips sont nuls,
/// et `after: null` redonnerait la page 1.
private func gqlNextCursor(_ connection: [String: Any]?) -> String? {
    guard (connection?["pageInfo"] as? [String: Any])?["hasNextPage"] as? Bool == true,
          let c = (connection?["edges"] as? [[String: Any]])?.last?["cursor"] as? String,
          !c.isEmpty else { return nil }
    return c
}

// MARK: – Lives sans compte (GQL public)
private func streamFromGQL(user u: [String: Any], stream s: [String: Any]) -> TwitchStream? {
    guard let login = u["login"] as? String else { return nil }
    return TwitchStream(
        id: u["id"] as? String ?? login,
        userLogin: login,
        userName: u["displayName"] as? String ?? login,
        title: s["title"] as? String ?? "",
        gameName: (s["game"] as? [String: Any])?["displayName"] as? String ?? "",
        viewerCount: s["viewersCount"] as? Int ?? 0,
        thumbnailURL: s["previewImageURL"] as? String ?? "",
        tags: (s["freeformTags"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String },
        gameId: (s["game"] as? [String: Any])?["id"] as? String ?? "")
}

/// Lesquelles de ces chaînes sont en live (suivis sans compte). 100 max par requête.
/// nil si Twitch n'a pas répondu (réseau, requête annulée) : à ne pas
/// confondre avec « personne en live », sinon la liste se viderait.
/// La catégorie vient avec son identifiant : sans lui, une catégorie masquée
/// n'était pas écartée (onglet « Lives » de la recherche, quand il reprend
/// les chaînes trouvées en live).
func getLiveStreamsGQL(logins: [String]) async -> [TwitchStream]? {
    guard !logins.isEmpty else { return [] }
    let q = """
    query($l: [String!]) { users(logins: $l) { id login displayName
      stream { title viewersCount previewImageURL(width: 440, height: 248) game { id displayName } freeformTags { name } } } }
    """
    var out: [TwitchStream] = []
    for start in stride(from: 0, to: logins.count, by: 100) {
        let chunk = Array(logins[start..<min(start + 100, logins.count)])
        guard let d = await gqlRequest(q, ["l": chunk]),
              let users = d["users"] as? [Any] else { return nil }
        for case let u as [String: Any] in users {
            if let s = u["stream"] as? [String: Any], let st = streamFromGQL(user: u, stream: s) { out.append(st) }
        }
    }
    return out.sorted { $0.viewerCount > $1.viewerCount }
}

// MARK: – Chaînes suivies (en live ou non)
/// Une chaîne suivie : son live s'il y en a un, sinon de quoi ouvrir sa page.
struct ChannelBrief: Identifiable {
    let login: String
    let name: String
    let avatar: String
    let stream: TwitchStream?
    /// Fin du dernier live connu (pour « hors ligne depuis »).
    var lastEnd: Date? = nil
    var id: String { login }
}

/// Infos de ces chaînes (avatar, live éventuel) par GQL public, 100 par requête.
/// nil si Twitch n'a pas répondu, pour ne pas vider une liste affichée.
func getChannelsGQL(logins: [String]) async -> [ChannelBrief]? {
    guard !logins.isEmpty else { return [] }
    let q = """
    query($l: [String!]) { users(logins: $l) { id login displayName profileImageURL(width: 70)
      lastBroadcast { startedAt }
      videos(first: 1, type: ARCHIVE, sort: TIME) { edges { node { publishedAt lengthSeconds } } }
      stream { title viewersCount previewImageURL(width: 440, height: 248) game { displayName } freeformTags { name } } } }
    """
    var out: [ChannelBrief] = []
    for start in stride(from: 0, to: logins.count, by: 100) {
        let chunk = Array(logins[start..<min(start + 100, logins.count)])
        guard let d = await gqlRequest(q, ["l": chunk]),
              let users = d["users"] as? [Any] else { return nil }
        for case let u as [String: Any] in users {
            guard let login = u["login"] as? String else { continue }
            let stream = (u["stream"] as? [String: Any]).flatMap { streamFromGQL(user: u, stream: $0) }
            let video = ((u["videos"] as? [String: Any])?["edges"] as? [[String: Any]])?.first?["node"] as? [String: Any]
            let lastEnd = lastLiveEnd(publishedAt: video?["publishedAt"] as? String,
                                      lengthSeconds: video?["lengthSeconds"] as? Int ?? 0,
                                      lastStart: (u["lastBroadcast"] as? [String: Any])?["startedAt"] as? String)
            out.append(ChannelBrief(login: login, name: u["displayName"] as? String ?? login,
                                    avatar: u["profileImageURL"] as? String ?? "", stream: stream,
                                    lastEnd: lastEnd))
        }
    }
    return out
}

/// Toutes les chaînes suivies par le compte (Helix, pages de 100, 1 000 au plus).
func getFollowedLogins(token: String, userId: String) async -> [String]? {
    var logins: [String] = []
    var cursor: String? = nil
    repeat {
        var urlStr = "https://api.twitch.tv/helix/channels/followed?user_id=\(userId)&first=100"
        if let cursor { urlStr += "&after=\(cursor)" }
        guard let url = URL(string: urlStr) else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(kHelixClientID, forHTTPHeaderField: "Client-Id")
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else {
            logger.warn("HELIX", "Chaînes suivies : pas de réponse (réseau)", "page \(logins.count / 100 + 1)")
            return nil
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logger.warn("HELIX", "Chaînes suivies refusées", "HTTP \(status)")
            return nil
        }
        for f in json["data"] as? [[String: Any]] ?? [] {
            if let l = f["broadcaster_login"] as? String { logins.append(l) }
        }
        cursor = (json["pagination"] as? [String: Any])?["cursor"] as? String
    } while cursor != nil && logins.count < 1000
    return logins
}

// MARK: – Catégories suivies (compte Twitch, session web)
/// Catégories suivies sur Twitch. Demande la session web (cookie auth-token) :
/// Helix n'a pas d'équivalent. nil si indisponible.
func getFollowedCategoriesGQL(webToken: String) async -> [TwitchCategory]? {
    guard let url = URL(string: "https://gql.twitch.tv/gql") else { return nil }
    let q = """
    query { currentUser { followedGames(first: 100, type: ALL) { nodes { id displayName boxArtURL(width: 285, height: 380) viewersCount } } } }
    """
    guard let body = try? JSONSerialization.data(withJSONObject: ["query": q]) else { return nil }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue(kGQLClientID, forHTTPHeaderField: "Client-ID")
    req.setValue("OAuth \(webToken)", forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = body
    guard let (data, _) = try? await URLSession.shared.data(for: req),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        logger.warn("GQL", "Catégories suivies : pas de réponse (réseau)", nil)
        return nil
    }
    guard let nodes = (((json["data"] as? [String: Any])?["currentUser"] as? [String: Any])?["followedGames"] as? [String: Any])?["nodes"] as? [[String: Any]]
    else {
        logger.warn("GQL", "Catégories suivies refusées", gqlErrorSummary(json))
        return nil
    }
    return nodes.compactMap { n in
        guard let id = n["id"] as? String else { return nil }
        return TwitchCategory(id: id, name: n["displayName"] as? String ?? "",
                              boxArtURL: n["boxArtURL"] as? String ?? "",
                              viewers: n["viewersCount"] as? Int)
    }
}

/// Identifiant Twitch d'une chaîne (GQL public).
func getUserIdGQL(login: String) async -> String? {
    let d = await gqlRequest("query($l: String!) { user(login: $l) { id } }", ["l": login.lowercased()])
    return (d?["user"] as? [String: Any])?["id"] as? String
}

// MARK: – Catégories sans compte (GQL public)
// Helix demande un jeton ; ces requêtes-là non. Avec le Client-ID web, Twitch
// refuse leur pagination (« failed integrity check » dès la 2ᵉ page) : la
// page 1 reste sur le web, la suite passe par le Client-ID d'Android
// (gqlListPage). Si Twitch le refuse aussi, `refused` le dit : Helix prend le
// relais avec un compte, sinon un message. Les fonctions sans « Page »
// (page 1 seule) gardent leur forme : l'Apple TV les appelle.
private func categoryFromGQL(_ n: [String: Any]) -> TwitchCategory? {
    guard let id = n["id"] as? String else { return nil }
    return TwitchCategory(id: id, name: n["displayName"] as? String ?? "",
                          boxArtURL: n["boxArtURL"] as? String ?? "",
                          viewers: n["viewersCount"] as? Int)
}

/// Lives d'une connexion GQL `streams` (arêtes `node { … broadcaster }`).
private func streamsFromGQL(_ edges: [[String: Any]]) -> [TwitchStream] {
    edges.compactMap { e in
        guard let n = e["node"] as? [String: Any], let b = n["broadcaster"] as? [String: Any] else { return nil }
        return streamFromGQL(user: b, stream: n)
    }
}

/// Langue au format Helix (« fr », « zh-hk ») → format GQL (« FR », « ZH_HK »).
private func gqlLanguages(_ lang: String?) -> [String]? {
    lang.map { [$0.uppercased().replacingOccurrences(of: "-", with: "_")] }
}

/// Catégories les plus regardées, avec leur audience. nil si Twitch n'a pas répondu.
func getTopCategoriesGQL() async -> [TwitchCategory]? {
    await getTopCategoriesPageGQL(after: nil)?.categories
}

/// Une page de 100 catégories. `after` nil = la 1ʳᵉ ; `next` : curseur de la
/// suivante. nil si Twitch n'a pas répondu (réseau).
func getTopCategoriesPageGQL(after: String?) async -> (categories: [TwitchCategory], next: String?, refused: Bool)? {
    let q = """
    query($after: Cursor) { games(first: 100, after: $after) {
      edges { cursor node { id displayName boxArtURL(width: 570, height: 760) viewersCount } }
      pageInfo { hasNextPage }
    } }
    """
    guard let page = await gqlListPage(q, [:], after: after) else { return nil }
    if page.refused { return ([], nil, true) }
    guard let games = page.data?["games"] as? [String: Any],
          let edges = games["edges"] as? [[String: Any]] else { return nil }
    return (edges.compactMap { ($0["node"] as? [String: Any]).flatMap(categoryFromGQL) },
            gqlNextCursor(games), false)
}

/// Recherche de catégories par nom. nil si Twitch n'a pas répondu.
func searchCategoriesGQL(query: String) async -> [TwitchCategory]? {
    let q = "query($q: String!) { searchCategories(query: $q, first: 30) { edges { node { id displayName boxArtURL(width: 570, height: 760) viewersCount } } } }"
    guard let d = await gqlRequest(q, ["q": query]),
          let edges = (d["searchCategories"] as? [String: Any])?["edges"] as? [[String: Any]] else { return nil }
    return edges.compactMap { ($0["node"] as? [String: Any]).flatMap(categoryFromGQL) }
}

/// Lives trouvés par la recherche de Twitch (titre, tags, catégorie, nom de
/// la chaîne), GQL public : onglet « Lives » des résultats. nil si Twitch
/// n'a pas répondu ou refuse la requête.
func searchStreamsGQL(query: String) async -> [TwitchStream]? {
    let q = """
    query($q: String!) { searchStreams(userQuery: $q, first: 30) {
      edges { node { title viewersCount previewImageURL(width: 440, height: 248) game { id displayName } freeformTags { name }
        broadcaster { id login displayName } } }
    } }
    """
    guard let d = await gqlRequest(q, ["q": query]),
          let edges = (d["searchStreams"] as? [String: Any])?["edges"] as? [[String: Any]] else { return nil }
    return streamsFromGQL(edges)
}

/// VODs trouvées par la recherche de Twitch (GQL public, celle de sa page de
/// résultats) : onglet « VODs » des résultats. D'abord l'index des VODs seul
/// (30 au plus), puis, si Twitch refuse ce ciblage, l'aperçu de la page de
/// résultats (quelques VODs). nil si Twitch n'a pas répondu ou refuse.
func searchVideosGQL(query: String) async -> [SearchVod]? {
    let fields = """
    videos { edges { item { ... on Video { id title lengthSeconds publishedAt
      previewThumbnailURL(width: 320, height: 180) owner { login displayName } game { id } } } } }
    """
    let requests = [
        "query($q: String!) { searchFor(userQuery: $q, platform: \"web\", target: { index: VOD, limit: 30 }) { \(fields) } }",
        "query($q: String!) { searchFor(userQuery: $q, platform: \"web\") { \(fields) } }",
    ]
    for q in requests {
        guard let d = await gqlRequest(q, ["q": query]),
              let found = d["searchFor"] as? [String: Any] else { continue }
        // `videos` nul : aucune VOD trouvée.
        let edges = (found["videos"] as? [String: Any])?["edges"] as? [[String: Any]] ?? []
        let list: [SearchVod] = edges.compactMap { e in
            guard let v = e["item"] as? [String: Any], let id = v["id"] as? String else { return nil }
            let owner = v["owner"] as? [String: Any]
            let login = owner?["login"] as? String ?? ""
            let vod = VodData(id: id,
                              title: v["title"] as? String ?? "",
                              previewThumbnailURL: v["previewThumbnailURL"] as? String ?? "",
                              publishedAt: v["publishedAt"] as? String ?? "",
                              lengthSeconds: v["lengthSeconds"] as? Int ?? 0)
            return SearchVod(vod: vod, login: login,
                             name: owner?["displayName"] as? String ?? login,
                             gameId: (v["game"] as? [String: Any])?["id"] as? String ?? "")
        }
        return list
    }
    return nil
}

/// Les 100 lives les plus regardés d'une catégorie, d'une langue si `lang`
/// (format Helix). nil si Twitch n'a pas répondu.
func getStreamsByCategoryGQL(gameId: String, lang: String? = nil) async -> [TwitchStream]? {
    await getStreamsByCategoryPageGQL(gameId: gameId, lang: lang, after: nil)?.streams
}

/// Une page de 100 lives d'une catégorie (même langue d'une page à l'autre).
func getStreamsByCategoryPageGQL(gameId: String, lang: String?,
                                 after: String?) async -> (streams: [TwitchStream], next: String?, refused: Bool)? {
    let q = """
    query($id: ID!, $langs: [Language!], $after: Cursor) { game(id: $id) {
      streams(first: 100, after: $after, options: { broadcasterLanguages: $langs }) {
        edges { cursor node {
          title viewersCount previewImageURL(width: 440, height: 248) game { id displayName } freeformTags { name }
          broadcaster { id login displayName } } }
        pageInfo { hasNextPage }
    } } }
    """
    var vars: [String: Any] = ["id": gameId]
    if let langs = gqlLanguages(lang) { vars["langs"] = langs }
    guard let page = await gqlListPage(q, vars, after: after) else { return nil }
    if page.refused { return ([], nil, true) }
    guard let streams = (page.data?["game"] as? [String: Any])?["streams"] as? [String: Any],
          let edges = streams["edges"] as? [[String: Any]] else { return nil }
    return (streamsFromGQL(edges), gqlNextCursor(streams), false)
}

/// Top des lives sans jeton (GQL public) ; `lang` au format Helix (« fr », « zh-hk »).
func getTopStreamsGQL(lang: String?) async -> [TwitchStream] {
    await getTopStreamsPageGQL(lang: lang, after: nil)?.streams ?? []
}

/// Une page du top des lives sans jeton : 30, le plafond de Twitch pour
/// `streams` à la racine, quel que soit le Client-ID. Sert à l'accueil sans
/// compte (« Charger plus ») et à compléter le top.
func getTopStreamsPageGQL(lang: String?,
                          after: String?) async -> (streams: [TwitchStream], next: String?, refused: Bool)? {
    let q = """
    query($langs: [Language!], $after: Cursor) { streams(first: 30, after: $after, options: { broadcasterLanguages: $langs }) {
      edges { cursor node { title viewersCount previewImageURL(width: 440, height: 248) game { id displayName } freeformTags { name }
        broadcaster { id login displayName } } }
      pageInfo { hasNextPage }
    } }
    """
    var vars: [String: Any] = [:]
    if let langs = gqlLanguages(lang) { vars["langs"] = langs }
    guard let page = await gqlListPage(q, vars, after: after) else { return nil }
    if page.refused { return ([], nil, true) }
    guard let streams = page.data?["streams"] as? [String: Any],
          let edges = streams["edges"] as? [[String: Any]] else { return nil }
    return (streamsFromGQL(edges), gqlNextCursor(streams), false)
}

/// Clips les plus vus d'une chaîne sur la période (LAST_DAY, LAST_WEEK,
/// LAST_MONTH, ALL_TIME), par pages de 100. `next` : curseur GQL de la suite ;
/// `more` : Twitch en a d'autres (si la suite GQL est refusée, Helix la
/// reprend avec le compte, getClipsHelix). nil si Twitch n'a pas répondu.
func getClipsPage(login: String, period: String,
                  after: String?) async -> (clips: [ClipData], next: String?, more: Bool, refused: Bool)? {
    let q = """
    query($l: String!, $p: ClipsPeriod, $after: Cursor) { user(login: $l) {
      clips(first: 100, after: $after, criteria: { period: $p, sort: VIEWS_DESC }) {
        edges { cursor node { slug title viewCount durationSeconds createdAt thumbnailURL(width: 480, height: 272) curator { displayName } } }
        pageInfo { hasNextPage }
    } } }
    """
    guard let page = await gqlListPage(q, ["l": login.lowercased(), "p": period], after: after) else { return nil }
    if page.refused { return ([], nil, true, true) }
    guard let data = page.data else { return nil }
    // Chaîne introuvable : liste vide, pas une panne.
    guard let user = data["user"] as? [String: Any],
          let clips = user["clips"] as? [String: Any],
          let edges = clips["edges"] as? [[String: Any]] else { return ([], nil, false, false) }
    let list: [ClipData] = edges.compactMap { e in
        guard let n = e["node"] as? [String: Any], let slug = n["slug"] as? String else { return nil }
        return ClipData(id: slug,
                        title: n["title"] as? String ?? "",
                        thumbnailURL: n["thumbnailURL"] as? String ?? "",
                        viewCount: n["viewCount"] as? Int ?? 0,
                        durationSeconds: n["durationSeconds"] as? Int ?? 0,
                        createdAt: n["createdAt"] as? String ?? "",
                        curator: (n["curator"] as? [String: Any])?["displayName"] as? String)
    }
    let more = (clips["pageInfo"] as? [String: Any])?["hasNextPage"] as? Bool ?? false
    return (list, gqlNextCursor(clips), more, false)
}

/// Clips les plus vus des dernières 24 h de quelques chaînes (fil Découvrir) :
/// deux par chaîne au plus, les plus vus d'abord. Twitch refuse plus de 15
/// alias par requête (« root field aliases limit ») : par paquets de 10,
/// envoyés en même temps. nil si aucun paquet n'a eu de réponse.
func getTopClipsGQL(logins: [String]) async -> [FeedClip]? {
    let list = Array(logins.prefix(20))
    guard !list.isEmpty else { return [] }
    let chunks = stride(from: 0, to: list.count, by: 10).map { Array(list[$0..<min($0 + 10, list.count)]) }
    var results: [[FeedClip]?] = Array(repeating: nil, count: chunks.count)
    await withTaskGroup(of: (Int, [FeedClip]?).self) { group in
        for (i, chunk) in chunks.enumerated() {
            group.addTask { (i, await topClipsChunk(chunk)) }
        }
        for await (i, r) in group { results[i] = r }
    }
    let answered = results.compactMap { $0 }
    guard !answered.isEmpty else { return nil }
    return answered.flatMap { $0 }.sorted { $0.viewCount > $1.viewCount }
}

/// Un paquet de getTopClipsGQL : une requête, un alias par chaîne.
private func topClipsChunk(_ list: [String]) async -> [FeedClip]? {
    let fields = "id login displayName profileImageURL(width: 70) "
        + "clips(first: 2, criteria: { period: LAST_DAY, sort: VIEWS_DESC }) { edges { node { "
        + "slug title viewCount durationSeconds thumbnailURL(width: 480, height: 272) game { displayName } } } }"
    let q = "query { " + list.enumerated().map { i, login in
        "c\(i): user(login: \"\(gqlStr(login.lowercased()))\") { \(fields) }"
    }.joined(separator: " ") + " }"
    guard let d = await gqlRequest(q, [:]) else { return nil }
    var out: [FeedClip] = []
    for i in list.indices {
        guard let u = d["c\(i)"] as? [String: Any], let login = u["login"] as? String else { continue }
        let edges = (u["clips"] as? [String: Any])?["edges"] as? [[String: Any]] ?? []
        for e in edges {
            guard let n = e["node"] as? [String: Any], let slug = n["slug"] as? String else { continue }
            out.append(FeedClip(id: slug,
                                title: n["title"] as? String ?? "",
                                thumbnailURL: n["thumbnailURL"] as? String ?? "",
                                viewCount: n["viewCount"] as? Int ?? 0,
                                durationSeconds: n["durationSeconds"] as? Int ?? 0,
                                game: (n["game"] as? [String: Any])?["displayName"] as? String ?? "",
                                login: login,
                                channelId: u["id"] as? String ?? "",
                                channelName: u["displayName"] as? String ?? login,
                                avatar: u["profileImageURL"] as? String))
        }
    }
    return out
}

/// Suite des clips avec le compte (Helix) : même période, même ordre (vues
/// décroissantes). Helix repart du début : ses 100 premiers recouvrent ceux
/// de GQL, l'appelant écarte les doublons. `cursor` nil = depuis le début.
func getClipsHelix(token: String, broadcasterId: String, period: String,
                   cursor: String? = nil) async -> (clips: [ClipData], cursor: String?) {
    var urlStr = "https://api.twitch.tv/helix/clips?broadcaster_id=\(broadcasterId)&first=100"
    let days: [String: Double] = ["LAST_DAY": 1, "LAST_WEEK": 7, "LAST_MONTH": 30]
    if let n = days[period] {
        // Sans date de fin, Helix s'arrête une semaine après le début.
        let f = ISO8601DateFormatter()
        let now = Date()
        urlStr += "&started_at=\(f.string(from: now.addingTimeInterval(-n * 86_400)))&ended_at=\(f.string(from: now))"
    }
    if let cursor { urlStr += "&after=\(cursor)" }
    guard let url = URL(string: urlStr) else { return ([], nil) }
    var req = URLRequest(url: url)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue(kHelixClientID, forHTTPHeaderField: "Client-Id")
    guard let (data, resp) = try? await URLSession.shared.data(for: req) else {
        logger.warn("HELIX", "Clips : pas de réponse (réseau)", nil)
        return ([], nil)
    }
    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
    guard status == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        logger.warn("HELIX", "Clips refusés", "HTTP \(status)")
        return ([], nil)
    }
    let arr = json["data"] as? [[String: Any]] ?? []
    let next = (json["pagination"] as? [String: Any])?["cursor"] as? String
    let list: [ClipData] = arr.compactMap { c in
        guard let slug = c["id"] as? String else { return nil }
        return ClipData(id: slug,
                        title: c["title"] as? String ?? "",
                        thumbnailURL: c["thumbnail_url"] as? String ?? "",
                        viewCount: c["view_count"] as? Int ?? 0,
                        durationSeconds: Int(c["duration"] as? Double ?? 0),
                        createdAt: c["created_at"] as? String ?? "",
                        curator: c["creator_name"] as? String)
    }
    logger.success("HELIX", "\(list.count) clips (suite)")
    return (list, arr.isEmpty ? nil : next)
}

/// Fiche « À propos » d'une chaîne (requête GQL publique).
func getChannelAbout(login: String) async -> ChannelAbout? {
    let q = """
    query($l: String!) { user(login: $l) {
      description followers { totalCount }
      channel { socialMedias { id name title url } }
      panels { id type ... on DefaultPanel { title imageURL linkURL description } }
    } }
    """
    guard let d = await gqlRequest(q, ["l": login.lowercased()]),
          let u = d["user"] as? [String: Any] else { return nil }
    // Adresses web seulement (pas de javascript:, mailto:…).
    func web(_ v: Any?) -> URL? {
        guard let s = v as? String, let url = URL(string: s),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }
    var socials: [ChannelAbout.Social] = []
    let rawSocials = (u["channel"] as? [String: Any])?["socialMedias"] as? [[String: Any]] ?? []
    for s in rawSocials {
        guard let url = web(s["url"]) else { continue }
        let name = s["name"] as? String ?? ""
        let title = s["title"] as? String ?? ""
        socials.append(ChannelAbout.Social(id: s["id"] as? String ?? url.absoluteString, name: name,
                                           title: title.isEmpty ? name : title, url: url))
    }
    var panels: [ChannelAbout.Panel] = []
    for p in u["panels"] as? [[String: Any]] ?? [] where p["type"] as? String == "DEFAULT" {
        let title = p["title"] as? String ?? ""
        let text = p["description"] as? String ?? ""
        let image = web(p["imageURL"])
        guard !title.isEmpty || !text.isEmpty || image != nil else { continue }
        panels.append(ChannelAbout.Panel(id: p["id"] as? String ?? UUID().uuidString, title: title,
                                         imageURL: image, linkURL: web(p["linkURL"]), text: text))
    }
    return ChannelAbout(description: u["description"] as? String ?? "",
                        followers: (u["followers"] as? [String: Any])?["totalCount"] as? Int,
                        socials: socials, panels: panels)
}

// MARK: – Planning d'une chaîne
/// Planning d'une chaîne : ses créneaux à venir et ses vacances. Avec le
/// jeton du compte, Helix `schedule` (documenté : il dit aussi les créneaux
/// répétés, annulés et les vacances). Sans compte, ou si Helix échoue, GQL
/// public ; s'il refuse la requête ou ne donne rien, l'export iCalendar de
/// Helix, public lui aussi (sans jeton). Chaîne sans planning : planning
/// vide. nil si rien n'a répondu.
func getChannelSchedule(login: String, channelId: String?, token: String?) async -> ChannelSchedule? {
    let l = login.lowercased()
    var id = channelId ?? ""
    if let token, !id.isEmpty, let s = await helixSchedule(channelId: id, token: token) {
        logSchedule(l, s, source: "Helix")
        return s
    }
    let fromGQL = await gqlSchedule(login: l)
    if let s = fromGQL, !s.isEmpty() {
        logSchedule(l, s, source: "GQL")
        return s
    }
    // GQL refuse la requête, ou ne donne rien (peut-être faute d'en lire la
    // réponse comme il faut) : l'export iCalendar tranche.
    if id.isEmpty { id = await getUserIdGQL(login: l) ?? "" }
    if !id.isEmpty, let s = await icalSchedule(channelId: id) {
        logSchedule(l, s, source: "iCalendar")
        return s
    }
    if fromGQL == nil { logger.warn("PLANNING", "Planning de \"\(l)\" indisponible") }
    return fromGQL
}

/// Journal : seulement un planning qui a quelque chose à montrer (la plupart
/// des chaînes n'en ont pas).
private func logSchedule(_ login: String, _ s: ChannelSchedule, source: String) {
    guard !s.isEmpty() else { return }
    logger.info("PLANNING", "Planning de \"\(login)\" : \(s.upcoming().count) créneaux à venir", source)
}

/// Planning par Helix, avec le jeton du compte. 404 : la chaîne n'a pas de
/// planning. nil si Twitch n'a pas répondu ou refuse (jeton expiré…).
private func helixSchedule(channelId: String, token: String) async -> ChannelSchedule? {
    guard !channelId.isEmpty, channelId.allSatisfy(\.isNumber),
          let url = URL(string: "https://api.twitch.tv/helix/schedule?broadcaster_id=\(channelId)&first=25")
    else { return nil }
    var req = URLRequest(url: url)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue(kHelixClientID, forHTTPHeaderField: "Client-Id")
    guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return nil }
    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
    if status == 404 { return .empty }
    guard status == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let d = json["data"] as? [String: Any] else {
        logger.warn("PLANNING", "Planning refusé par Helix", "HTTP \(status)")
        return nil
    }
    var segments: [ScheduleSegment] = []
    for s in d["segments"] as? [[String: Any]] ?? [] {
        guard let start = parseTwitchDate(s["start_time"] as? String) else { continue }
        segments.append(ScheduleSegment(
            id: "\(s["id"] as? String ?? "")-\(Int(start.timeIntervalSince1970))",
            start: start,
            end: parseTwitchDate(s["end_time"] as? String),
            title: s["title"] as? String ?? "",
            category: (s["category"] as? [String: Any])?["name"] as? String ?? "",
            recurring: s["is_recurring"] as? Bool ?? false,
            // Annulé par le streamer, ou pendant ses vacances.
            canceled: (s["canceled_until"] as? String) != nil))
    }
    var vacation: ScheduleVacation? = nil
    if let v = d["vacation"] as? [String: Any],
       let start = parseTwitchDate(v["start_time"] as? String),
       let end = parseTwitchDate(v["end_time"] as? String) {
        vacation = ScheduleVacation(start: start, end: end)
    }
    return ChannelSchedule(segments: segments.sorted { $0.start < $1.start }, vacation: vacation)
}

/// Planning par GQL public : `segments(relativeDate:)` rend la semaine qui
/// contient la date (Twitch refuse `startAt`/`endAt`). Il n'en sert qu'une
/// par requête et par chaîne (plusieurs semaines dans une même requête
/// reviennent vides ou mêlées) : une requête par semaine, celle en cours,
/// puis les trois suivantes en parallèle. Pas de « répété » dans GQL, mais
/// `repeatEndsAfterCount` vaut 1 pour un créneau unique (0 : répété sans
/// fin). Les vacances sont son « interruption ». nil si Twitch n'a pas
/// répondu ou refuse une des requêtes ; chaîne introuvable ou sans
/// planning : vide.
private func gqlSchedule(login: String) async -> ChannelSchedule? {
    let now = Date()
    let week: TimeInterval = 7 * 86400
    func scheduleOf(_ d: [String: Any]) -> [String: Any]? {
        ((d["user"] as? [String: Any])?["channel"] as? [String: Any])?["schedule"] as? [String: Any]
    }
    guard let first = await gqlScheduleWeek(login: login, at: now,
                                            extra: "nextSegment { id } interruption { startAt endAt }")
    else { return nil }
    guard let schedule = scheduleOf(first) else { return .empty }
    var weeks = [schedule]
    // Ni prochain live ni vacances (la plupart des chaînes) : les semaines
    // suivantes n'ont rien à dire.
    if schedule["nextSegment"] is [String: Any] || schedule["interruption"] is [String: Any] {
        async let second = gqlScheduleWeek(login: login, at: now.addingTimeInterval(week))
        async let third = gqlScheduleWeek(login: login, at: now.addingTimeInterval(2 * week))
        async let fourth = gqlScheduleWeek(login: login, at: now.addingTimeInterval(3 * week))
        let rest = await [second, third, fourth]
        for result in rest {
            guard let data = result else { return nil }
            weeks.append(scheduleOf(data) ?? [:])
        }
    }
    // Fenêtre : douze heures en arrière (un créneau en cours), quatre
    // semaines devant, comme l'export iCalendar ; la semaine en cours
    // commence avant aujourd'hui.
    let windowStart = now.addingTimeInterval(-12 * 3600)
    let windowEnd = now.addingTimeInterval(28 * 86400)
    var segments: [ScheduleSegment] = []
    var seen = Set<String>()
    for w in weeks {
        for s in w["segments"] as? [[String: Any]] ?? [] {
            guard let start = parseTwitchDate(s["startAt"] as? String) else { continue }
            let end = parseTwitchDate(s["endAt"] as? String)
            guard (end ?? start.addingTimeInterval(3600)) > windowStart, start < windowEnd else { continue }
            // Un créneau répété garde son id d'une semaine à l'autre : l'heure
            // le distingue. Rendu deux fois : gardé une fois.
            let id = "\(s["id"] as? String ?? "")-\(Int(start.timeIntervalSince1970))"
            guard seen.insert(id).inserted else { continue }
            let repeats = s["repeatEndsAfterCount"] as? Int
            segments.append(ScheduleSegment(
                id: id,
                start: start,
                end: end,
                title: s["title"] as? String ?? "",
                category: (s["categories"] as? [[String: Any]])?.first?["displayName"] as? String ?? "",
                recurring: repeats != nil && repeats != 1,
                canceled: s["isCancelled"] as? Bool ?? false))
        }
    }
    var vacation: ScheduleVacation? = nil
    if let v = schedule["interruption"] as? [String: Any],
       let start = parseTwitchDate(v["startAt"] as? String),
       let end = parseTwitchDate(v["endAt"] as? String) {
        vacation = ScheduleVacation(start: start, end: end)
    }
    return ChannelSchedule(segments: segments.sorted { $0.start < $1.start }, vacation: vacation)
}

/// Une semaine du planning par GQL public : celle qui contient `date`, avec
/// `extra` (champs du planning demandés en plus). Ses données ; nil si
/// Twitch n'a pas répondu ou refuse la requête, même en partie.
private func gqlScheduleWeek(login: String, at date: Date, extra: String = "") async -> [String: Any]? {
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    // Date calculée ici, jamais saisie : écrite dans la requête, son type GQL
    // n'a pas à être nommé.
    let q = """
    query($l: String!) { user(login: $l) { channel { schedule {
      \(extra)
      segments(relativeDate: "\(iso.string(from: date))") {
        id startAt endAt title isCancelled repeatEndsAfterCount categories { displayName }
      }
    } } } }
    """
    guard let json = await gqlResponse(q, ["l": login]) else { return nil }
    if let errors = json["errors"] as? [Any], !errors.isEmpty {
        logger.warn("GQL", "Requête refusée", gqlErrorSummary(json))
        return nil
    }
    return json["data"] as? [String: Any] ?? [:]
}

/// Planning par l'export iCalendar de Helix, public (sans jeton) : créneaux
/// répétés compris (RRULE). Les vacances n'y sont qu'un texte : ignorées.
/// 404 : pas de planning. nil si Twitch n'a pas répondu.
private func icalSchedule(channelId: String) async -> ChannelSchedule? {
    guard !channelId.isEmpty, channelId.allSatisfy(\.isNumber),
          let url = URL(string: "https://api.twitch.tv/helix/schedule/icalendar?broadcaster_id=\(channelId)")
    else { return nil }
    guard let (data, resp) = try? await URLSession.shared.data(from: url) else { return nil }
    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
    if status == 404 { return .empty }
    guard status == 200 else {
        logger.warn("PLANNING", "Export iCalendar refusé", "HTTP \(status)")
        return nil
    }
    return parseICalSchedule(icalUnfolded(data), now: Date())
}

/// Texte d'un export iCalendar, lignes repliées (RFC 5545, 3.1) recollées
/// sur les octets, avant le décodage : un repli peut couper en deux un
/// caractère UTF-8 (accent, émoji d'un titre), et le décodage strict
/// rejetait alors tout le planning.
private func icalUnfolded(_ data: Data) -> String {
    let raw = [UInt8](data)
    var bytes: [UInt8] = []
    bytes.reserveCapacity(raw.count)
    var i = 0
    while i < raw.count {
        // Fin de ligne (LF ou CRLF) suivie d'une espace ou d'une tabulation :
        // la ligne continue, les trois (ou deux) octets disparaissent.
        var eol = 0
        if raw[i] == 10 {
            eol = 1
        } else if raw[i] == 13, i + 1 < raw.count, raw[i + 1] == 10 {
            eol = 2
        }
        if eol > 0, i + eol < raw.count, raw[i + eol] == 32 || raw[i + eol] == 9 {
            i += eol + 1
            continue
        }
        bytes.append(raw[i])
        i += 1
    }
    return String(decoding: bytes, as: UTF8.self)
}

/// Propriété d'un VEVENT : ses paramètres (TZID…) et sa valeur.
private typealias ICalProperty = (params: [String: String], value: String)

/// Créneaux d'un calendrier iCalendar (RFC 5545) des quatre prochaines
/// semaines : chaque VEVENT, et ses répétitions.
private func parseICalSchedule(_ text: String, now: Date) -> ChannelSchedule {
    // Lignes repliées (RFC 5545, 3.1) : une ligne qui commence par une
    // espace ou une tabulation prolonge la précédente.
    var lines: [String] = []
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    for line in normalized.components(separatedBy: "\n") {
        if line.hasPrefix(" ") || line.hasPrefix("\t"), !lines.isEmpty {
            lines[lines.count - 1] += String(line.dropFirst())
        } else if !line.isEmpty {
            lines.append(line)
        }
    }
    let windowStart = now.addingTimeInterval(-12 * 3600)
    let windowEnd = now.addingTimeInterval(28 * 86400)
    var events: [(props: [String: ICalProperty], exdates: [Date])] = []
    var event: [String: ICalProperty]? = nil
    var exdates: [Date] = []
    for line in lines {
        let upper = line.trimmingCharacters(in: .whitespaces).uppercased()
        if upper == "BEGIN:VEVENT" { event = [:]; exdates = []; continue }
        if upper == "END:VEVENT" {
            if let e = event { events.append((props: e, exdates: exdates)) }
            event = nil
            continue
        }
        guard event != nil, let colon = line.firstIndex(of: ":") else { continue }
        var parts = line[..<colon].components(separatedBy: ";")
        let name = parts.removeFirst().uppercased()
        var params: [String: String] = [:]
        for p in parts {
            let kv = p.components(separatedBy: "=")
            if kv.count == 2 { params[kv[0].uppercased()] = kv[1].replacingOccurrences(of: "\"", with: "") }
        }
        let value = String(line[line.index(after: colon)...])
        if name == "EXDATE" {
            exdates += value.components(separatedBy: ",").compactMap { icalDate($0, tzid: params["TZID"]) }
        } else {
            event?[name] = (params: params, value: value)
        }
    }
    // Occurrence d'une série modifiée ou annulée à part (même UID, avec
    // RECURRENCE-ID) : elle remplace celle que donnerait la répétition, qui
    // sinon restait affichée en double (et maintenue, si l'autre est annulée).
    var replaced: [String: [Date]] = [:]
    for e in events {
        guard let r = e.props["RECURRENCE-ID"], let uid = e.props["UID"]?.value,
              let at = icalDate(r.value, tzid: r.params["TZID"]) else { continue }
        replaced[uid, default: []].append(at)
    }
    var segments: [ScheduleSegment] = []
    for e in events {
        var excluded = e.exdates
        if e.props["RECURRENCE-ID"] == nil, let uid = e.props["UID"]?.value {
            excluded += replaced[uid] ?? []
        }
        segments += icalOccurrences(e.props, exdates: excluded, from: windowStart, to: windowEnd)
    }
    return ChannelSchedule(segments: segments.sorted { $0.start < $1.start })
}

/// Occurrences d'un VEVENT dans la fenêtre : lui seul, ou ses répétitions
/// (RRULE quotidienne ou hebdomadaire ; dates exclues par EXDATE).
private func icalOccurrences(_ e: [String: ICalProperty], exdates: [Date],
                             from windowStart: Date, to windowEnd: Date) -> [ScheduleSegment] {
    guard let startProp = e["DTSTART"],
          let start = icalDate(startProp.value, tzid: startProp.params["TZID"]) else { return [] }
    let end = e["DTEND"].flatMap { icalDate($0.value, tzid: $0.params["TZID"]) }
    let duration = end.map { $0.timeIntervalSince(start) }
    let uid = e["UID"]?.value ?? ""
    let title = icalText(e["SUMMARY"]?.value ?? "")
    let category = icalText(e["CATEGORIES"]?.value ?? "")
    let canceled = e["STATUS"]?.value.uppercased() == "CANCELLED"
    func segment(_ at: Date, recurring: Bool) -> ScheduleSegment {
        ScheduleSegment(id: "\(uid)-\(Int(at.timeIntervalSince1970))", start: at,
                        end: duration.map { at.addingTimeInterval($0) },
                        title: title, category: category, recurring: recurring, canceled: canceled)
    }
    // Règle de répétition : FREQ, INTERVAL, COUNT, UNTIL.
    var rule: [String: String] = [:]
    for part in (e["RRULE"]?.value ?? "").components(separatedBy: ";") {
        let kv = part.components(separatedBy: "=")
        if kv.count == 2 { rule[kv[0].uppercased()] = kv[1] }
    }
    let freq = rule["FREQ"]?.uppercased() ?? ""
    let stepDays = freq == "DAILY" ? 1 : freq == "WEEKLY" ? 7 : 0
    guard stepDays > 0 else {
        let last = end ?? start.addingTimeInterval(3600)
        return last > windowStart && start < windowEnd ? [segment(start, recurring: false)] : []
    }
    // Calendrier du fuseau du créneau : l'heure reste la même d'une semaine
    // à l'autre, passage à l'heure d'été compris.
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = icalTimeZone(startProp.params["TZID"], value: startProp.value)
    // INTERVAL borné : une valeur démesurée faisait déborder le calcul (plantage).
    let step = stepDays * min(max(1, Int(rule["INTERVAL"] ?? "") ?? 1), 1000)
    let count = rule["COUNT"].flatMap { Int($0) }
    let until = rule["UNTIL"].flatMap { icalDate($0, tzid: startProp.params["TZID"]) }
    // Droit vers la fenêtre, sans parcourir des années de répétitions.
    var k = max(0, Int(windowStart.timeIntervalSince(start) / (Double(step) * 86400)) - 1)
    var out: [ScheduleSegment] = []
    while out.count < 60 {
        if let count, k >= count { break }
        guard let at = cal.date(byAdding: .day, value: k * step, to: start), at < windowEnd else { break }
        if let until, at > until { break }
        let last = duration.map { at.addingTimeInterval($0) } ?? at.addingTimeInterval(3600)
        if last > windowStart, !exdates.contains(where: { abs($0.timeIntervalSince(at)) < 60 }) {
            out.append(segment(at, recurring: true))
        }
        k += 1
    }
    return out
}

/// Date iCalendar : « 20261020T200000Z » (UTC), « 20261020T200000 » dans le
/// fuseau du TZID, ou « 20261020 ».
private func icalDate(_ raw: String, tzid: String?) -> Date? {
    let v = raw.trimmingCharacters(in: .whitespaces)
    let df = DateFormatter()
    df.locale = Locale(identifier: "en_US_POSIX")
    df.calendar = Calendar(identifier: .gregorian)
    df.timeZone = icalTimeZone(tzid, value: v)
    df.dateFormat = v.hasSuffix("Z") ? "yyyyMMdd'T'HHmmss'Z'" : v.count == 8 ? "yyyyMMdd" : "yyyyMMdd'T'HHmmss"
    return df.date(from: v)
}

/// Fuseau d'une date iCalendar : UTC pour « …Z », sinon celui du TZID
/// (« /America/New_York » chez Twitch, barre de tête comprise), UTC à défaut.
private func icalTimeZone(_ tzid: String?, value: String) -> TimeZone {
    let utc = TimeZone(secondsFromGMT: 0) ?? TimeZone.current
    guard !value.hasSuffix("Z"), var id = tzid, !id.isEmpty else { return utc }
    if id.hasPrefix("/") { id.removeFirst() }
    if let tz = TimeZone(identifier: id) { return tz }
    // Préfixe d'éditeur (« /mozilla.org/…/Europe/Paris ») : les deux derniers éléments.
    return TimeZone(identifier: id.split(separator: "/").suffix(2).joined(separator: "/")) ?? utc
}

/// Texte iCalendar : « \, », « \; » et « \\ » rendus, retours à la ligne en espaces.
private func icalText(_ raw: String) -> String {
    var out = ""
    var escaped = false
    for ch in raw {
        if escaped {
            out.append(ch == "n" || ch == "N" ? " " : ch)
            escaped = false
        } else if ch == "\\" {
            escaped = true
        } else {
            out.append(ch)
        }
    }
    return out.trimmingCharacters(in: .whitespaces)
}

/// Highlights d'une chaîne (les 50 plus récents).
func getHighlights(login: String) async -> [VodData] {
    let q = """
    query($l: String!) { user(login: $l) { videos(first: 50, type: HIGHLIGHT, sort: TIME) {
      edges { node { id title lengthSeconds createdAt previewThumbnailURL(width: 320, height: 180) } }
    } } }
    """
    guard let d = await gqlRequest(q, ["l": login.lowercased()]),
          let user = d["user"] as? [String: Any],
          let videos = user["videos"] as? [String: Any],
          let edges = videos["edges"] as? [[String: Any]] else { return [] }
    return edges.compactMap { e in
        guard let v = e["node"] as? [String: Any], let id = v["id"] as? String else { return nil }
        return VodData(id: id,
                       title: v["title"] as? String ?? "",
                       previewThumbnailURL: v["previewThumbnailURL"] as? String ?? "",
                       publishedAt: v["createdAt"] as? String ?? "",
                       lengthSeconds: v["lengthSeconds"] as? Int ?? 0)
    }
}

/// Playlists (collections) d'une chaîne, avec leurs vidéos — vides exclues.
func getCollections(login: String) async -> [PlaylistData] {
    let q = """
    query($l: String!) { user(login: $l) { collections(first: 20) { edges { node {
      id title description
      items(first: 50) { totalCount edges { node { ... on Video {
        id title lengthSeconds createdAt previewThumbnailURL(width: 320, height: 180)
      } } } }
    } } } }
    """
    guard let d = await gqlRequest(q, ["l": login.lowercased()]),
          let user = d["user"] as? [String: Any],
          let cols = user["collections"] as? [String: Any],
          let edges = cols["edges"] as? [[String: Any]] else { return [] }
    return edges.compactMap { e -> PlaylistData? in
        guard let n = e["node"] as? [String: Any], let id = n["id"] as? String,
              let items = n["items"] as? [String: Any] else { return nil }
        let videos: [VodData] = (items["edges"] as? [[String: Any]] ?? []).compactMap { ie in
            guard let v = ie["node"] as? [String: Any], let vid = v["id"] as? String else { return nil }
            return VodData(id: vid,
                           title: v["title"] as? String ?? "",
                           previewThumbnailURL: v["previewThumbnailURL"] as? String ?? "",
                           publishedAt: v["createdAt"] as? String ?? "",
                           lengthSeconds: v["lengthSeconds"] as? Int ?? 0)
        }
        guard !videos.isEmpty else { return nil }
        return PlaylistData(id: id,
                            title: n["title"] as? String ?? "",
                            description: n["description"] as? String ?? "",
                            total: items["totalCount"] as? Int ?? videos.count,
                            videos: videos)
    }
}

/// MP4 signés d'un clip (lus directement par AVPlayer) et sa VOD d'origine.
func getClip(slug: String) async -> ClipPlayback? {
    let q = """
    query($s: ID!) { clip(slug: $s) {
      title broadcaster { login displayName } video { id } videoOffsetSeconds
      playbackAccessToken(params: { platform: "web", playerType: "site", playerBackend: "mediaplayer" }) { signature value }
      videoQualities { quality frameRate sourceURL }
    } }
    """
    guard let d = await gqlRequest(q, ["s": slug]),
          let c = d["clip"] as? [String: Any],
          let tok = c["playbackAccessToken"] as? [String: Any],
          let sig = tok["signature"] as? String, let value = tok["value"] as? String,
          let qualities = c["videoQualities"] as? [[String: Any]] else { return nil }
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "&+=?#")
    let token = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    var links: QualityLinks = [:]
    for qd in qualities {
        guard let src = qd["sourceURL"] as? String, src.hasPrefix("https://") else { continue }
        let fps = (qd["frameRate"] as? Double) ?? Double(qd["frameRate"] as? Int ?? 30)
        let label = "\(qd["quality"] as? String ?? "?")p\(fps >= 50 ? String(Int(fps.rounded())) : "")"
        links[label] = src + (src.contains("?") ? "&" : "?") + "sig=\(sig)&token=\(token)"
    }
    guard !links.isEmpty else { return nil }
    let b = c["broadcaster"] as? [String: Any]
    let vodId = (c["video"] as? [String: Any])?["id"] as? String
    let offset = (c["videoOffsetSeconds"] as? Double) ?? (c["videoOffsetSeconds"] as? Int).map(Double.init)
    return ClipPlayback(links: links, title: c["title"] as? String ?? "Clip",
                        broadcasterLogin: b?["login"] as? String,
                        broadcasterName: b?["displayName"] as? String,
                        vodId: vodId, vodOffset: offset)
}

// MARK: – Repères de VOD
/// Changements de jeu d'une VOD (repères sur la barre de lecture), passages
/// dont Twitch a coupé le son, et date de diffusion — en une seule requête.
///
/// Twitch publie les passages coupés (`muteInfo`) par blocs de 3 min ; les
/// blocs qui se suivent sont fusionnés.
func getVodMarkers(vodId: String) async -> VodMarkers {
    let q = """
    query($id: ID!) { video(id: $id) {
      createdAt
      moments(first: 50, momentRequestType: VIDEO_CHAPTER_MARKERS) {
        edges { node { positionMilliseconds durationMilliseconds description } }
      }
      muteInfo { mutedSegmentConnection { nodes { offset duration } } }
    } }
    """
    guard let d = await gqlRequest(q, ["id": vodId]),
          let v = d["video"] as? [String: Any] else { return VodMarkers() }
    var out = VodMarkers()

    let edges = (v["moments"] as? [String: Any])?["edges"] as? [[String: Any]] ?? []
    let chapters: [VodChapter] = edges.compactMap { e in
        guard let n = e["node"] as? [String: Any] else { return nil }
        let pos = (n["positionMilliseconds"] as? Double) ?? Double(n["positionMilliseconds"] as? Int ?? 0)
        let dur = (n["durationMilliseconds"] as? Double) ?? Double(n["durationMilliseconds"] as? Int ?? 0)
        return VodChapter(start: pos / 1000, duration: dur / 1000, title: n["description"] as? String ?? "")
    }
    // Un seul chapitre n'apporte rien (toute la VOD sur le même jeu).
    out.chapters = chapters.count > 1 ? chapters.sorted { $0.start < $1.start } : []

    let nodes = ((v["muteInfo"] as? [String: Any])?["mutedSegmentConnection"] as? [String: Any])?["nodes"]
        as? [[String: Any]] ?? []
    func num(_ x: Any?) -> Double? { (x as? Double) ?? (x as? Int).map(Double.init) }
    let raw = nodes.compactMap { n -> MutedRange? in
        guard let o = num(n["offset"]), let len = num(n["duration"]), len > 0 else { return nil }
        return MutedRange(start: o, end: o + len)
    }.sorted { $0.start < $1.start }
    var merged: [MutedRange] = []
    for r in raw {
        if let last = merged.last, r.start <= last.end + 1 {
            merged[merged.count - 1] = MutedRange(start: last.start, end: max(last.end, r.end))
        } else {
            merged.append(r)
        }
    }
    out.muted = merged

    if let s = v["createdAt"] as? String {
        let df = ISO8601DateFormatter()
        out.createdAt = df.date(from: s) ?? {
            df.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return df.date(from: s)
        }()
    }
    return out
}
