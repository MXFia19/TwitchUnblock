// Relève les morceaux de texte du journal dans les sources Swift, et ses
// catégories.
//   node extract-log-fragments.mjs <dossier> <sortie.json>
//
// Morceaux : textes littéraux, coupés aux interpolations \( … ), pris dans
//  - les appels logger.info/success/warn/error/debug( (self. dans AppLogger,
//    et ses appels sans préfixe) : leurs arguments, sauf le premier (la
//    catégorie) ;
//  - les autres méthodes du journal (logger.settingChanged(…), syncPull…) :
//    tous leurs arguments ;
//  - les lignes écrites directement (LogEntry( : arrêt brutal, plantage) ;
//  - les chaînes écrites dans les interpolations (`name ?? "par défaut"`) ;
//  - une variable passée en argument : ce qu'elle reçoit dans le même
//    fichier (`let why = … ? "a" : "b"`, `reason = "…"`), ou, si c'est le
//    paramètre d'une fonction, les arguments de ses appels
//    (`scheduleReconnect(…, reason: "…")`) ;
//  - une fonction appelée en argument (`Self.describe(h)`) : les chaînes de
//    son corps.
// Catégories : premier argument des appels (LogEntry : `category:`),
// traduites à part (categories.json).
import fs from 'node:fs'
import path from 'node:path'

const [dir, outFile] = process.argv.slice(2)
const files = []
const walk = (d) => {
  for (const e of fs.readdirSync(d, { withFileTypes: true })) {
    const p = path.join(d, e.name)
    // Dossiers cachés écartés : .claude/worktrees contient d'autres copies
    // des sources (dépôt principal), .git rien d'utile.
    if (e.isDirectory()) { if (!e.name.startsWith('.') && e.name !== 'node_modules') walk(p) }
    else if (e.name.endsWith('.swift')) files.push(p)
  }
}
walk(dir)
const sources = new Map(files.map((f) => [f, fs.readFileSync(f, 'utf8')]))

const ESC = { n: '\n', t: '\t', '"': '"', '\\': '\\', "'": "'", r: '\r', '0': '\0' }
const LEVELS = new Set(['info', 'success', 'warn', 'error', 'debug'])
/** Méthodes du journal sans texte à relever. */
const NOT_TEXT = new Set(['clear', 'saveNow', 'count', 'sessionStart'])
/** Jamais des variables à suivre : mots-clés, et noms de données (pseudo,
 *  adresse…) qui ne reçoivent pas de texte du journal, mais sont affectés
 *  partout (leur suivi ramenait des textes sans rapport). */
const KEYWORDS = new Set(['nil', 'true', 'false', 'self', 'Self', 'in', 'as', 'is', 'try', 'await', 'let',
  'var', 'if', 'else', 'return', 'case', 'default', 'some', 'any', 'inout', 'where', 'guard', 'switch',
  'id', 'login', 'channel', 'channelId', 'channelName', 'name', 'url', 'host', 'title', 'user', 'userId',
  'data', 'json', 'value', 'key', 'index', 'token', 'base', 'path', 'count', 'total', 'error'])

/** Fin du commentaire qui commence en src[i], ou -1. */
function skipComment(src, i) {
  if (src[i] !== '/') return -1
  if (src[i + 1] === '/') { const e = src.indexOf('\n', i); return e < 0 ? src.length : e }
  if (src[i + 1] === '*') { const e = src.indexOf('*/', i + 2); return e < 0 ? src.length : e + 2 }
  return -1
}

/** Une chaîne commence en src[i] : `"`, ou `#"` (chaîne brute). */
function isStringStart(src, i) {
  if (src[i] === '"') return true
  if (src[i] !== '#' || /\w/.test(src[i - 1] || '')) return false
  let j = i
  while (src[j] === '#') j++
  return src[j] === '"'
}

/** Chaîne Swift qui commence en src[i] : { end, parts, inner } ; parts
 *  alterne texte littéral et null (interpolation), inner : début et fin de
 *  chaque interpolation. */
function readString(src, i) {
  let hashes = 0
  while (src[i] === '#') { hashes++; i++ }
  const close = '"' + '#'.repeat(hashes)
  const esc = '\\' + '#'.repeat(hashes)
  if (src.startsWith('"""', i)) {   // multi-ligne : ignorée (rare dans le journal)
    const end = src.indexOf('"""' + '#'.repeat(hashes), i + 3)
    return { end: end < 0 ? src.length : end + 3 + hashes, parts: [], inner: [] }
  }
  let j = i + 1
  let cur = ''
  const parts = []
  const inner = []
  while (j < src.length) {
    if (src.startsWith(esc, j)) {
      const k = j + esc.length
      const n = src[k]
      if (n === '(') {
        parts.push(cur); cur = ''
        parts.push(null)
        const end = skipBlock(src, k)
        inner.push([k + 1, end - 1])
        j = end
        continue
      }
      if (n === 'u' && src[k + 1] === '{') {
        const c = src.indexOf('}', k)
        cur += String.fromCodePoint(parseInt(src.slice(k + 2, c), 16))
        j = c + 1
        continue
      }
      cur += ESC[n] ?? n
      j = k + 1
      continue
    }
    if (src.startsWith(close, j)) { parts.push(cur); return { end: j + close.length, parts, inner } }
    if (src[j] === '\n') break
    cur += src[j]
    j++
  }
  parts.push(cur)
  return { end: j, parts, inner }
}

/** src[i] ouvre ( [ ou { : position après la fermeture (chaînes et
 *  commentaires compris). */
function skipBlock(src, i) {
  let depth = 0
  let j = i
  while (j < src.length) {
    const cm = skipComment(src, j)
    if (cm >= 0) { j = cm; continue }
    if (isStringStart(src, j)) { j = readString(src, j).end; continue }
    const c = src[j]
    if (c === '(' || c === '[' || c === '{') depth++
    else if (c === ')' || c === ']' || c === '}') { depth--; if (depth === 0) return j + 1 }
    j++
  }
  return j
}

/** Textes littéraux entre start et end, interpolations comprises. */
function literalsIn(src, start, end) {
  const out = []
  let j = start
  while (j < end) {
    const cm = skipComment(src, j)
    if (cm >= 0) { j = cm; continue }
    if (isStringStart(src, j)) {
      const s = readString(src, j)
      for (const p of s.parts) if (p !== null) out.push(p)
      for (const [a, b] of s.inner) out.push(...literalsIn(src, a, b))
      j = s.end
      continue
    }
    j++
  }
  return out
}

/** Noms du code entre start et end (interpolations comprises, texte des
 *  chaînes écarté) : variables simples, et fonctions appelées. */
function namesIn(src, start, end) {
  const vars = new Set()
  const calls = new Set()
  let j = start
  while (j < end) {
    const cm = skipComment(src, j)
    if (cm >= 0) { j = cm; continue }
    if (isStringStart(src, j)) {
      const s = readString(src, j)
      for (const [a, b] of s.inner) {
        const n = namesIn(src, a, b)
        n.vars.forEach((v) => vars.add(v))
        n.calls.forEach((c) => calls.add(c))
      }
      j = s.end
      continue
    }
    const m = /^[A-Za-z_]\w*/.exec(src.slice(j, j + 80))
    if (m && !/\w/.test(src[j - 1] || '')) {
      const name = m[0]
      const before = src.slice(Math.max(0, j - 6), j)
      const after = src.slice(j + name.length).match(/^\s*(\S)/)?.[1]
      const member = /\.$/.test(before)
      const viaSelf = /\b[Ss]elf\.$/.test(before)
      if (after === '(' && /^[a-z]/.test(name) && (!member || viaSelf)) calls.add(name)
      // Variables d'une ou deux lettres (d, q, ms) : des valeurs, pas du texte.
      else if (!member && after !== '.' && after !== '(' && /^[a-z]\w{2,}$/.test(name) && !KEYWORDS.has(name)) vars.add(name)
      j += name.length
      continue
    }
    j++
  }
  return { vars, calls }
}

/** Arguments de l'appel dont la parenthèse ouvrante est en src[open]. */
function splitArgs(src, open) {
  const end = skipBlock(src, open)
  const close = end - 1
  const args = []
  const push = (a, b) => {
    const text = src.slice(a, b)
    if (!text.trim()) return
    const m = /^\s*([A-Za-z_]\w*)\s*:(?!:)/.exec(text)
    args.push({ start: m ? a + m[0].length : a, end: b, label: m ? m[1] : null })
  }
  let j = open + 1
  let start = j
  let depth = 0
  while (j < close) {
    const cm = skipComment(src, j)
    if (cm >= 0) { j = cm; continue }
    if (isStringStart(src, j)) { j = readString(src, j).end; continue }
    const c = src[j]
    if (c === '(' || c === '[' || c === '{') depth++
    else if (c === ')' || c === ']' || c === '}') depth--
    else if (c === ',' && depth === 0) { push(start, j); start = j + 1 }
    j++
  }
  push(start, close)
  return { args, end }
}

/** Fin de l'instruction qui commence en src[i] (affectation) : fin de
 *  ligne, sauf si l'expression continue à la ligne suivante. */
function statementEnd(src, i) {
  let j = i
  let depth = 0
  let last = ''
  while (j < src.length) {
    const cm = skipComment(src, j)
    if (cm >= 0) { j = cm; continue }
    if (isStringStart(src, j)) { j = readString(src, j).end; last = '"'; continue }
    const c = src[j]
    if (c === '(' || c === '[' || c === '{') depth++
    else if (c === ')' || c === ']' || c === '}') { if (depth === 0) return j; depth-- }
    else if (c === ';' && depth === 0) return j
    else if (c === '\n' && depth === 0) {
      const next = src.slice(j + 1).match(/^\s*(\S\S?)/)?.[1] ?? ''
      if (/[?:+=(,&|]$/.test(last) || /^(\?|:|\+|\.|&&|\|\|)/.test(next)) { j++; continue }
      return j
    }
    if (!/\s/.test(c)) last = c
    j++
  }
  return j
}

const fragments = new Map()
const categories = new Map()
const addFragment = (p) => {
  const t = p.trim()
  // Au moins 3 lettres, et pas un simple jeton technique (HTTP, GQL…).
  if ((t.match(/\p{L}/gu) || []).length < 3) return
  if (/^[\p{Lu}0-9_./:-]+$/u.test(t)) return
  // Adresse : jamais traduite.
  if (/^\w+:\/\//.test(t)) return
  fragments.set(t, (fragments.get(t) || 0) + 1)
}
/** Catégorie écrite telle quelle (une chaîne sans interpolation). */
const addCategory = (src, a) => {
  const text = src.slice(a.start, a.end).trim()
  if (!/^"[^"\\]*"$/.test(text)) return
  const name = text.slice(1, -1)
  categories.set(name, (categories.get(name) || 0) + 1)
}

const escapeRe = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')

/** Expression d'un argument : ses textes, et ce que reçoivent ses variables
 *  et ses fonctions (deux niveaux au plus). */
function collect(file, start, end, depth = 0, seen = new Set()) {
  const src = sources.get(file)
  literalsIn(src, start, end).forEach(addFragment)
  if (depth >= 2) return
  const { vars, calls } = namesIn(src, start, end)
  for (const v of vars) {
    const key = `${file}|v|${v}`
    if (seen.has(key)) continue
    seen.add(key)
    // Ce qu'elle reçoit : let/var v = …, v = …, v += …
    const assign = new RegExp(`(?<![\\w.])${escapeRe(v)}\\s*(?::[^=\\n{}()]*)?\\+?=(?!=)`, 'g')
    let m
    while ((m = assign.exec(src))) {
      const from = m.index + m[0].length
      collect(file, from, statementEnd(src, from), depth + 1, seen)
    }
    // Paramètre d'une fonction : les arguments de ses appels.
    const decl = /\bfunc\s+(\w+)\s*(?:<[^>]*>)?\s*\(/g
    while ((m = decl.exec(src))) {
      const open = m.index + m[0].length - 1
      const params = src.slice(open, skipBlock(src, open))
      if (!new RegExp(`[(,]\\s*(?:\\w+\\s+)?${escapeRe(v)}\\s*:`).test(params)) continue
      const call = new RegExp(`(?<![\\w])${escapeRe(m[1])}\\s*\\(`, 'g')
      let c
      while ((c = call.exec(src))) {
        if (/func\s+$/.test(src.slice(Math.max(0, c.index - 10), c.index))) continue
        const o = c.index + c[0].length - 1
        collect(file, o + 1, skipBlock(src, o) - 1, depth + 1, seen)
      }
    }
  }
  for (const f of calls) {
    const key = `|f|${f}`
    if (seen.has(key)) continue
    seen.add(key)
    // Corps de la fonction : dans ce fichier, sinon le seul qui la définit.
    const re = new RegExp(`\\bfunc\\s+${escapeRe(f)}\\s*(?:<[^>]*>)?\\s*\\(`)
    const where = re.test(src) ? [file] : [...sources.keys()].filter((k) => re.test(sources.get(k)))
    if (where.length !== 1) continue
    const s = sources.get(where[0])
    const m = re.exec(s)
    const sigEnd = skipBlock(s, m.index + m[0].length - 1)
    const body = s.indexOf('{', sigEnd)
    if (body < 0) continue
    literalsIn(s, body, skipBlock(s, body)).forEach(addFragment)
  }
}

let calls = 0
for (const [file, src] of sources) {
  // [regex, genre] : méthode du journal (niveau : catégorie en premier ;
  // sinon tout est texte), LogEntry (arguments nommés), add (catégorie en
  // second).
  const patterns = [
    [/(?:\blogger|\bAppLogger\.shared)\.(\w+)\(/g, 'method'],
    [/\bself\??\.(info|success|warn|error|debug)\(/g, 'level'],
    [/\bLogEntry\(/g, 'entry'],
  ]
  // Dans AppLogger : ses appels sans « self. ».
  if (/\bfinal class AppLogger\b/.test(src)) {
    patterns.push([/(?<![\w.])(info|success|warn|error|debug)\(/g, 'level'])
    patterns.push([/(?<![\w.])add\(/g, 'add'])
  }
  for (const [re, kind] of patterns) {
    let m
    while ((m = re.exec(src))) {
      // Déclaration (func info(…)) : pas un appel.
      if (/func\s+\w*$/.test(src.slice(Math.max(0, m.index - 12), m.index + 1))) continue
      const open = m.index + m[0].length - 1
      const { args } = splitArgs(src, open)
      if (!args.length) continue
      let k = kind
      if (kind === 'method') {
        if (NOT_TEXT.has(m[1])) continue
        k = LEVELS.has(m[1]) ? 'level' : 'method'
      }
      calls++
      if (k === 'level') {
        addCategory(src, args[0])
        for (const a of args.slice(1)) collect(file, a.start, a.end)
      } else if (k === 'method') {
        for (const a of args) collect(file, a.start, a.end)
      } else if (k === 'entry') {
        for (const a of args) {
          if (a.label === 'category') addCategory(src, a)
          else if (a.label === 'message' || a.label === 'detail') collect(file, a.start, a.end)
        }
      } else if (k === 'add') {
        if (args.length < 3 || !/^\s*"/.test(src.slice(args[1].start, args[1].end))) continue
        addCategory(src, args[1])
        for (const a of args.slice(2)) collect(file, a.start, a.end)
      }
    }
  }
}

const sortFr = (a, b) => a[0].localeCompare(b[0], 'fr')
const out = {
  fragments: [...fragments.entries()].sort(sortFr).map(([fr, n]) => ({ fr, n })),
  categories: [...categories.entries()].sort(sortFr).map(([name, n]) => ({ name, n })),
}
fs.writeFileSync(outFile, JSON.stringify(out, null, 1))
console.log(`${calls} appels, ${out.fragments.length} morceaux distincts, ${out.categories.length} catégories`)
