import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════
//  Texte avec liens cliquables : réponses des bots, description et panneaux
//  d'une chaîne. Un Text(AttributedString) ouvre ses liens dans Safari.
// ═══════════════════════════════════════════════════════════════════════════

private let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

/// `raw` avec ses liens : les adresses nues (https://…, www.…, discord.gg/…)
/// et, si `markdown`, les liens [texte](https://…) avec gras et italique.
func richText(_ raw: String, markdown: Bool = false) -> AttributedString {
    var out = AttributedString(raw)
    if markdown, let md = try? AttributedString(
        markdown: raw, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
        out = md
    }
    guard let linkDetector else { return out }
    let plain = String(out.characters)
    let ns = plain as NSString
    for m in linkDetector.matches(in: plain, range: NSRange(location: 0, length: ns.length)) {
        guard let url = m.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let r = Range(m.range, in: plain) else { continue }
        // Mêmes caractères des deux côtés : on se repère par leur rang.
        let chars = out.characters
        let lower = chars.index(chars.startIndex, offsetBy: plain.distance(from: plain.startIndex, to: r.lowerBound))
        let upper = chars.index(lower, offsetBy: plain.distance(from: r.lowerBound, to: r.upperBound))
        // Un lien Markdown déjà posé reste tel quel.
        if out[lower..<upper].link == nil { out[lower..<upper].link = url }
    }
    return out
}

/// Texte d'un panneau (Markdown simple de Twitch) : titres en gras, listes à
/// puces, citations sans chevron ; liens et gras dans chaque ligne.
func panelText(_ raw: String) -> AttributedString {
    let lines = raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    var out = AttributedString()
    for (i, source) in lines.enumerated() {
        var line = source
        if let r = line.range(of: #"^\s*>\s?"#, options: .regularExpression) { line.removeSubrange(r) }
        var heading = false
        if let r = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
            line.removeSubrange(r)
            heading = true
        }
        if let r = line.range(of: #"^\s*[-*+]\s+"#, options: .regularExpression) {
            line.replaceSubrange(r, with: "• ")
        }
        var part = richText(line, markdown: true)
        if heading { part.font = Font.system(size: 14, weight: .bold) }
        out += part
        if i < lines.count - 1 { out += AttributedString("\n") }
    }
    return out
}
