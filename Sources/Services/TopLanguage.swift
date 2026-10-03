import Foundation

// MARK: – Langue du top des lives
//
// Twitch ne filtre pas par pays mais par langue du streamer : on prend la
// langue choisie dans les réglages, sinon la première langue de l'appareil
// que Twitch connaît (« pt-BR » → portugais), sinon l'anglais.
enum TopLanguage {
    /// Codes acceptés par Helix (`language=`).
    static let codes = ["ar", "bg", "ca", "cs", "da", "de", "el", "en", "es", "fi", "fr", "hi", "hu", "id", "it",
                        "ja", "ko", "ms", "nl", "no", "pl", "pt", "ro", "ru", "sk", "sv", "th", "tl", "tr", "uk",
                        "vi", "zh", "zh-hk"]
    private static let aliases = ["nb": "no", "nn": "no", "fil": "tl"]

    static var device: String {
        for raw in Locale.preferredLanguages {
            let tag = raw.lowercased()
            if tag.hasPrefix("zh-hk") || tag.hasPrefix("zh-mo") || tag.hasPrefix("zh-hant") { return "zh-hk" }
            let base = String(tag.split(separator: "-").first ?? "")
            let code = aliases[base] ?? base
            if codes.contains(code) { return code }
        }
        return "en"
    }

    /// Le choix des réglages s'il est valable, sinon celui de l'appareil.
    static func resolved(_ choice: String?) -> String {
        if let choice, codes.contains(choice) { return choice }
        return device
    }

    /// « Portugais », « Japanese »… dans la langue de l'interface.
    static func name(_ code: String, in lang: Lang) -> String {
        let id = code == "zh-hk" ? "zh-HK" : code
        let n = Locale(identifier: lang.rawValue).localizedString(forIdentifier: id) ?? code.uppercased()
        return n.prefix(1).uppercased() + n.dropFirst()
    }
}
