// Génère Sources/Services/LogTranslations.swift depuis fragments.json (relevé
// des appels au journal), translations.json (français → [en, es, ru]) et
// categories.json (à côté de translations.json : catégories traduites, et
// celles qui restent telles quelles).
//   node make-log-translations.mjs <fragments.json> <translations.json> <sortie.swift> [--relire]
// --relire : liste aussi les morceaux que la traduction laisse tels quels sans
// les voir comme français (mots sans accent hors de la liste ci-dessous), à
// relire à l'œil.
import fs from 'node:fs'
import path from 'node:path'

const args = process.argv.slice(2)
const review = args.includes('--relire')
const [fragFile, trFile, outFile] = args.filter((a) => a !== '--relire')
const scanned = JSON.parse(fs.readFileSync(fragFile, 'utf8'))
// Ancien format : la liste des morceaux seule.
const fragments = (Array.isArray(scanned) ? scanned : scanned.fragments).map((x) => x.fr)
const usedCategories = Array.isArray(scanned) ? [] : scanned.categories.map((x) => x.name)
const tr = JSON.parse(fs.readFileSync(trFile, 'utf8'))   // JSON.parse garde la dernière clé en double : contrôlée ci-dessous

// Clés en double dans le fichier source (JSON.parse les fusionnerait sans rien
// dire), Unicode normalisé : « é » en un ou deux caractères, c'est la même
// clé pour Swift.
const rawKeys = [...fs.readFileSync(trFile, 'utf8').matchAll(/^\s*"((?:[^"\\]|\\.)*)"\s*:/gm)]
  .map((m) => JSON.parse(`"${m[1]}"`).normalize('NFC'))
const dup = rawKeys.filter((k, i) => rawKeys.indexOf(k) !== i)
if (dup.length) throw new Error(`clés en double : ${dup.join(' | ')}`)

const complete = (v) => Array.isArray(v) && v.length === 3 && v.every((s) => typeof s === 'string' && s)

let errors = 0
for (const [fr, v] of Object.entries(tr)) {
  if (!complete(v)) { console.log('✗ traduction incomplète :', fr); errors++ }
  if (!fragments.some((f) => f.includes(fr))) { console.log('✗ absente du journal :', fr); errors++ }
}

// Morceaux encore français une fois traduits en anglais comme dans l'app
// (les plus longs d'abord, un mot seul s'il est entier) : une traduction qui
// n'en couvre qu'une partie (« Lecture refusée » dans « Lecture refusée : la
// chaîne… ») ne suffit pas. Français : un accent, une élision (« l'app »),
// ou un mot courant du journal qui n'est pas anglais.
const french = new RegExp([
  '[éèêëàâçùûüîïôœÉÈÊÀÂÇÙÛÎÏÔŒ]',
  "(?<!\\p{L})(?:d|l|qu|n|s|j|c)['’](?=\\p{L})",
  '(?<!\\p{L})(?:le|la|les|des|du|de|pour|sans|avec|une?|pas|plus|par|sur|dans|et|est|au|aux|ou|oui|aucune?|' +
    'encore|trop|lecture|erreur|hors|ligne|suivie?s?|reprise|connexion|seule?s?|seulement|depuis|chez|mais|' +
    'qui|que|quand|toute?s?|tous|rien|jamais|toujours|selon|sous|entre|retard|liste|compte|envoi|appel|' +
    'reçu|refus|chargé|terminé|indisponible|normale|compacte|spectateurs|niveau|lecteur|jeton|essai|' +
    'nouvel(?:le)?|nouveau|suivante?|coffre|dispo|manque|officiels?|langue|onglet|bouton|suivre|recherche|' +
    'utilisateur|parti|rejoint|solde|sondage|statut|vide|inattendue?|injoignable|relance|tampon|reste)(?!\\p{L})',
].join('|'), 'iu')
const escapeRe = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
const graphemes = (s) => [...s].length
const entries = Object.entries(tr)
  .sort(([a], [b]) => graphemes(a) !== graphemes(b) ? graphemes(b) - graphemes(a) : (a < b ? -1 : a > b ? 1 : 0))
  .map(([fr, t]) => ({
    fr, en: t[0],
    word: fr.includes(' ') ? null : new RegExp(`(?<![\\p{L}\\p{N}_])${escapeRe(fr)}(?![\\p{L}\\p{N}_])`, 'gu'),
  }))
const toEnglish = (text) => {
  let out = text
  for (const e of entries) {
    if (!out.includes(e.fr)) continue
    out = e.word ? out.replace(e.word, () => e.en) : out.split(e.fr).join(e.en)
  }
  return out
}
const uncovered = fragments.filter((f) => french.test(f) && french.test(toEnglish(f)))
for (const f of uncovered) {
  const en = toEnglish(f)
  console.log('· sans traduction :', JSON.stringify(f) + (en === f ? '' : `  (en anglais : ${JSON.stringify(en)})`))
}
// À relire : des mots, laissés tels quels, sans rien de français reconnu ;
// pas le code (requêtes GraphQL, clés, symboles : chart.bar.fill, camelCase).
if (review) {
  const code = /[{}=_/\\]|\p{Ll}\p{Lu}|^\W*\p{L}+(?:\.\p{L}+)+\W*$/u
  for (const f of fragments) {
    if (french.test(f) || toEnglish(f) !== f || code.test(f) || !/\p{Ll}{3}/u.test(f)) continue
    console.log('· à relire :', JSON.stringify(f))
  }
}

// Catégories : traduites (« LECTEUR » → [en, es, ru]), ou laissées telles
// quelles (« GQL ») ; « TV/LECTEUR » se traduit partie par partie.
const catFile = path.join(path.dirname(trFile), 'categories.json')
const cats = fs.existsSync(catFile) ? JSON.parse(fs.readFileSync(catFile, 'utf8')) : { traduites: {}, telles_quelles: [] }
const translatedCats = cats.traduites ?? {}
const keptCats = cats.telles_quelles ?? []
const usedParts = new Set(usedCategories.flatMap((c) => c.split('/')))
for (const [fr, v] of Object.entries(translatedCats)) {
  if (!complete(v)) { console.log('✗ catégorie incomplète :', fr); errors++ }
  if (!usedParts.has(fr)) { console.log('✗ catégorie absente du journal :', fr); errors++ }
  if (keptCats.includes(fr)) { console.log('✗ catégorie traduite et laissée telle quelle :', fr); errors++ }
}
for (const c of keptCats) {
  if (!usedParts.has(c)) { console.log('✗ catégorie absente du journal :', c); errors++ }
}
const unsorted = [...usedParts].filter((c) => c && !(c in translatedCats) && !keptCats.includes(c)).sort()
for (const c of unsorted) console.log('· catégorie à classer (traduite ou telle quelle) :', c)
if (errors) process.exit(1)

const q = (s) => `"${s.replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n')}"`
/** Littéral de dictionnaire Swift (« [:] » s'il est vide). */
const dict = (obj) => {
  const lines = Object.entries(obj).sort((a, b) => a[0].localeCompare(b[0], 'fr'))
    .map(([fr, [en, es, ru]]) => `        ${q(fr)}: [${q(en)}, ${q(es)}, ${q(ru)}],`)
  return lines.length ? `[\n${lines.join('\n')}\n    ]` : '[:]'
}

const swift = `import Foundation

// ═══════════════════════════════════════════════════════════════════════════
//  Journal traduit — FICHIER GÉNÉRÉ (tools/log-translations, voir son README.md,
//  depuis les appels au journal) : ne pas le modifier à la main.
//  Le journal reste écrit en français ; à l'affichage, ses morceaux français
//  sont remplacés par leur traduction dans la langue de l'app. Les nombres,
//  noms et adresses insérés dans les messages ne changent pas.
// ═══════════════════════════════════════════════════════════════════════════

enum LogTranslator {
    /// Français → [anglais, espagnol, russe].
    private static let table: [String: [String]] = ${dict(tr)}

    /// Catégories en français → [anglais, espagnol, russe] ; les autres
    /// (GQL, CHAT…) restent telles quelles.
    private static let categories: [String: [String]] = ${dict(translatedCats)}

    private struct Entry {
        let fr: String
        let tr: [String]
        /// Un seul mot : remplacé seulement s'il est entier (pas dans un pseudo).
        let word: NSRegularExpression?
    }

    /// Les plus longs d'abord : une phrase passe avant les mots qu'elle contient.
    private static let entries: [Entry] = table
        .sorted { $0.key.count != $1.key.count ? $0.key.count > $1.key.count : $0.key < $1.key }
        .map { fr, tr in
            let word = fr.contains(" ") ? nil : try? NSRegularExpression(
                pattern: "(?<![\\\\p{L}\\\\p{N}_])" + NSRegularExpression.escapedPattern(for: fr) + "(?![\\\\p{L}\\\\p{N}_])")
            return Entry(fr: fr, tr: tr, word: word)
        }

    /// Textes déjà traduits (« langue|texte »), vidé au-delà de 4 000.
    private static var cache: [String: String] = [:]

    /// Colonne de la langue dans les tables (nil : le français, tel quel ;
    /// les langues sans colonne prennent l'anglais).
    private static func column(_ lang: Lang) -> Int? {
        switch lang.rawValue {
        case "fr": return nil
        case "es": return 1
        case "ru": return 2
        default:   return 0
        }
    }

    /// Texte du journal dans la langue de l'app (le français tel quel).
    static func translate(_ text: String, _ lang: Lang) -> String {
        guard let col = column(lang), !text.isEmpty else { return text }
        let key = "\\(lang.rawValue)|\\(text)"
        if let hit = cache[key] { return hit }
        var out = text
        for e in entries where out.contains(e.fr) {
            let t = e.tr[col]
            if let re = e.word {
                out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out),
                                                  withTemplate: NSRegularExpression.escapedTemplate(for: t))
            } else {
                out = out.replacingOccurrences(of: e.fr, with: t)
            }
        }
        if cache.count > 4000 { cache.removeAll() }
        cache[key] = out
        return out
    }

    /// Catégorie d'une ligne dans la langue de l'app (« LECTEUR » → « PLAYER »),
    /// partie par partie (« TV/LECTEUR »).
    static func category(_ name: String, _ lang: Lang) -> String {
        guard let col = column(lang) else { return name }
        return name.split(separator: "/", omittingEmptySubsequences: false)
            .map { categories[String($0)]?[col] ?? String($0) }
            .joined(separator: "/")
    }
}
`
fs.writeFileSync(outFile, swift)
console.log(`${Object.keys(tr).length} traductions et ${Object.keys(translatedCats).length} catégories écrites dans ${outFile}`
  + ` (${uncovered.length} morceaux français sans traduction, ${unsorted.length} catégories à classer)`)
