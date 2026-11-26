#!/usr/bin/env node
// ═══════════════════════════════════════════════════════════════════════════
//  TestFlight sans Mac : App Store Connect par sa clé d'API (Node 18+, aucune
//  dépendance). Voir DOCUMENTATION.md → « TestFlight ».
//
//  node tools/testflight/asc.mjs setup --key AuthKey_XXXXXXXXXX.p8 --issuer <Issuer ID>
//    Sur le PC, une fois (et à chaque renouvellement du certificat, un an) :
//    vérifie la clé, déclare les identifiants de l'app et de son extension
//    (tools/testflight/config.json), crée le certificat de distribution
//    — clé privée faite ici, gardée dans ~/.twitchunblock/testflight, jamais
//    envoyée à Apple — et les profils App Store, pose les quatre secrets du
//    dépôt (gh secret set) et dit si l'app existe déjà dans App Store Connect.
//    Aucune valeur secrète n'est affichée. Relancé, il reprend ce qui existe.
//
//  node tools/testflight/asc.mjs signing
//    Dans la CI (testflight.yml) : retrouve le certificat qui va avec la clé
//    privée (secret TF_DIST_KEY), vérifie ou refait les profils App Store,
//    les installe pour Xcode, écrit le certificat dans $RUNNER_TEMP et l'équipe
//    dans $GITHUB_OUTPUT. Le nom du titulaire du compte (dans le certificat)
//    est masqué dans les journaux, publics.
// ═══════════════════════════════════════════════════════════════════════════

import { X509Certificate, createPrivateKey, createPublicKey, generateKeyPairSync, sign } from 'node:crypto'
import { appendFileSync, existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs'
import { spawnSync } from 'node:child_process'
import { homedir } from 'node:os'
import { basename, dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const CONFIG = JSON.parse(readFileSync(join(HERE, 'config.json'), 'utf8'))
const API = 'https://api.appstoreconnect.apple.com/v1'
const REPO = 'MXFia19/TwitchUnblock'
// Un profil App Store par identifiant ; testflight.yml reprend ces noms.
const TARGETS = [
  { suffix: '', profile: 'TU TestFlight App', name: 'TU TestFlight' },
  { suffix: '.Widgets', profile: 'TU TestFlight Widgets', name: 'TU TestFlight Widgets' },
]
const LOCAL_KEY = join(homedir(), '.twitchunblock', 'testflight', 'dist-key.pem')
const DAY = 864e5

class Fail extends Error {}

const day = (iso) => String(iso || '?').slice(0, 10)

// ── API ──────────────────────────────────────────────────────────────────

/** Jeton de l'API (ES256, 15 min), refait à chaque appel. */
export function jwt({ keyId, issuer, p8 }) {
  const b64u = (v) => Buffer.from(v).toString('base64url')
  const now = Math.floor(Date.now() / 1000)
  const head = b64u(JSON.stringify({ alg: 'ES256', kid: keyId, typ: 'JWT' }))
  const body = b64u(JSON.stringify({ iss: issuer, iat: now, exp: now + 900, aud: 'appstoreconnect-v1' }))
  const signature = sign('sha256', Buffer.from(`${head}.${body}`), { key: createPrivateKey(p8), dsaEncoding: 'ieee-p1363' })
  return `${head}.${body}.${b64u(signature)}`
}

async function api(auth, method, path, body) {
  const res = await fetch(API + path, {
    method,
    headers: { Authorization: `Bearer ${jwt(auth)}`, ...(body ? { 'Content-Type': 'application/json' } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  })
  const text = await res.text()
  let json = {}
  try { json = text ? JSON.parse(text) : {} } catch { /* réponse non JSON : texte brut dans l'erreur */ }
  if (!res.ok) {
    const detail = (json.errors || []).map((e) => [e.title || e.code, e.detail].filter(Boolean).join(' : ')).join(' / ')
    const hint = res.status === 401 ? ' (clé refusée : Issuer ID, Key ID, ou clé révoquée ?)'
      : res.status === 403 ? ' (droits insuffisants : la clé doit avoir le rôle Admin)' : ''
    throw new Fail(`${method} ${path.split('?')[0]} → HTTP ${res.status}${hint} : ${detail || text.slice(0, 300)}`)
  }
  return json
}

// ── Demande de certificat (PKCS #10), sans openssl ───────────────────────

function derLength(n) {
  if (n < 0x80) return Buffer.from([n])
  const bytes = []
  for (; n > 0; n = Math.floor(n / 256)) bytes.unshift(n % 256)
  return Buffer.from([0x80 | bytes.length, ...bytes])
}
const tlv = (tag, ...parts) => {
  const content = Buffer.concat(parts)
  return Buffer.concat([Buffer.from([tag]), derLength(content.length), content])
}
const seq = (...parts) => tlv(0x30, ...parts)
function oid(dotted) {
  const [a, b, ...rest] = dotted.split('.').map(Number)
  const out = [40 * a + b]
  for (let v of rest) {
    const chunk = [v % 128]
    for (v = Math.floor(v / 128); v > 0; v = Math.floor(v / 128)) chunk.unshift(0x80 | (v % 128))
    out.push(...chunk)
  }
  return tlv(0x06, Buffer.from(out))
}

/** CSR signée par la clé RSA : nom commun seul (Apple remplace le sujet). */
export function csrPem(privateKey, commonName) {
  const spki = createPublicKey(privateKey).export({ type: 'spki', format: 'der' })
  const subject = seq(tlv(0x31, seq(oid('2.5.4.3'), tlv(0x0c, Buffer.from(commonName, 'utf8')))))
  const info = seq(Buffer.from([0x02, 0x01, 0x00]), subject, spki, Buffer.from([0xa0, 0x00]))
  const signature = sign('sha256', info, privateKey)
  const sha256WithRSA = seq(oid('1.2.840.113549.1.1.11'), Buffer.from([0x05, 0x00]))
  const der = seq(info, sha256WithRSA, tlv(0x03, Buffer.from([0x00]), signature))
  const lines = der.toString('base64').match(/.{1,64}/g).join('\n')
  return `-----BEGIN CERTIFICATE REQUEST-----\n${lines}\n-----END CERTIFICATE REQUEST-----\n`
}

// ── Identifiants, certificat, profils ────────────────────────────────────

async function bundleId(auth, identifier, name) {
  const found = (await api(auth, 'GET', `/bundleIds?filter[identifier]=${encodeURIComponent(identifier)}&limit=200`))
    .data.find((b) => b.attributes.identifier === identifier)
  if (found) return found
  const body = { data: { type: 'bundleIds', attributes: { identifier, name, platform: 'IOS' } } }
  return (await api(auth, 'POST', '/bundleIds', body)).data
}

const spki = (key) => createPublicKey(key).export({ type: 'spki', format: 'der' })

/** Certificat « Apple Distribution » de cette clé privée, encore valable
 *  `minDays` jours ; undefined sinon. */
async function certificateFor(auth, privateKey, minDays) {
  const want = spki(privateKey)
  const list = (await api(auth, 'GET', '/certificates?filter[certificateType]=DISTRIBUTION&limit=200')).data
  for (const c of list) {
    const x509 = new X509Certificate(Buffer.from(c.attributes.certificateContent, 'base64'))
    if (!x509.publicKey.export({ type: 'spki', format: 'der' }).equals(want)) continue
    if (Date.parse(c.attributes.expirationDate) < Date.now() + minDays * DAY) continue
    return { id: c.id, x509, expires: c.attributes.expirationDate }
  }
  return undefined
}

/** Profil App Store `name` pour cet identifiant et ce certificat : repris
 *  s'il est valable encore 7 jours, sinon supprimé et refait. */
async function appStoreProfile(auth, name, bundle, certId) {
  const query = `/profiles?filter[name]=${encodeURIComponent(name)}&include=bundleId,certificates&limit=200`
  for (const p of (await api(auth, 'GET', query)).data.filter((x) => x.attributes.name === name)) {
    const a = p.attributes, rel = p.relationships || {}
    const usable = a.profileState === 'ACTIVE' && a.profileType === 'IOS_APP_STORE'
      && Date.parse(a.expirationDate) > Date.now() + 7 * DAY
      && rel.bundleId?.data?.id === bundle.id
      && (rel.certificates?.data || []).some((c) => c.id === certId)
    if (usable) return p
    await api(auth, 'DELETE', `/profiles/${p.id}`)
  }
  const body = {
    data: {
      type: 'profiles',
      attributes: { name, profileType: 'IOS_APP_STORE' },
      relationships: {
        bundleId: { data: { type: 'bundleIds', id: bundle.id } },
        certificates: { data: [{ type: 'certificates', id: certId }] },
      },
    },
  }
  return (await api(auth, 'POST', '/profiles', body)).data
}

// ── setup (PC) ───────────────────────────────────────────────────────────

async function setup(args) {
  if (!args.key || !args.issuer) {
    throw new Fail('usage : node tools/testflight/asc.mjs setup --key AuthKey_XXXXXXXXXX.p8 --issuer <Issuer ID> [--key-id XXXXXXXXXX]')
  }
  const p8 = readFileSync(args.key, 'utf8')
  const keyId = typeof args['key-id'] === 'string' ? args['key-id'] : (basename(args.key).match(/^AuthKey_([A-Z0-9]+)\.p8$/i) || [])[1]
  if (!keyId) throw new Fail('Key ID introuvable dans le nom du fichier : ajouter --key-id')
  try { createPrivateKey(p8) } catch { throw new Fail(`${args.key} n'est pas une clé .p8 d'App Store Connect`) }
  const auth = { keyId, issuer: String(args.issuer), p8 }
  const base = CONFIG.bundleId

  console.log('1. Clé d’API')
  await api(auth, 'GET', '/apps?limit=1')
  console.log('   acceptée')

  console.log('2. Identifiants')
  const bundles = []
  for (const t of TARGETS) {
    bundles.push(await bundleId(auth, base + t.suffix, t.name))
    console.log(`   ${base + t.suffix} : prêt`)
  }

  console.log('3. Certificat de distribution')
  let key = existsSync(LOCAL_KEY) ? readFileSync(LOCAL_KEY, 'utf8') : null
  let cert = key ? await certificateFor(auth, key, 30) : undefined
  if (cert) {
    console.log(`   repris (expire le ${day(cert.expires)})`)
  } else {
    const { privateKey } = generateKeyPairSync('rsa', { modulusLength: 2048 })
    key = privateKey.export({ type: 'pkcs8', format: 'pem' })
    mkdirSync(dirname(LOCAL_KEY), { recursive: true })
    writeFileSync(`${LOCAL_KEY}.new`, key, { mode: 0o600 })
    const body = { data: { type: 'certificates', attributes: { certificateType: 'DISTRIBUTION', csrContent: csrPem(privateKey, 'TwitchUnblock TestFlight') } } }
    let made
    try {
      made = (await api(auth, 'POST', '/certificates', body)).data
    } catch (e) {
      throw new Fail(`${e.message}\n   Apple limite le nombre de certificats de distribution : en révoquer un ancien sur https://developer.apple.com/account/resources/certificates/list, puis relancer.`)
    }
    renameSync(`${LOCAL_KEY}.new`, LOCAL_KEY)
    cert = { id: made.id, expires: made.attributes.expirationDate }
    console.log(`   créé (expire le ${day(cert.expires)}) ; clé privée gardée dans ${LOCAL_KEY}`)
  }

  console.log('4. Profils App Store')
  for (const [i, t] of TARGETS.entries()) {
    const p = await appStoreProfile(auth, t.profile, bundles[i], cert.id)
    console.log(`   ${t.profile} : prêt (expire le ${day(p.attributes.expirationDate)})`)
  }

  console.log('5. Secrets du dépôt')
  const secrets = [['ASC_KEY_ID', keyId], ['ASC_ISSUER_ID', auth.issuer], ['ASC_KEY_P8', p8], ['TF_DIST_KEY', key]]
  for (const [name, value] of secrets) {
    const r = spawnSync('gh', ['secret', 'set', name, '--repo', REPO], { input: value, encoding: 'utf8' })
    if (r.status !== 0) throw new Fail(`gh secret set ${name} : ${(r.stderr || r.error?.message || 'échec').trim()}`)
  }
  console.log(`   ${secrets.map(([n]) => n).join(', ')} posés (valeurs non affichées)`)

  console.log('6. App dans App Store Connect')
  const apps = (await api(auth, 'GET', `/apps?filter[bundleId]=${encodeURIComponent(base)}&limit=200`)).data
  if (apps.some((a) => a.attributes.bundleId === base)) console.log('   trouvée')
  else console.log(`   à créer : App Store Connect → Apps → + → Nouvelle app, plateforme iOS, identifiant de lot ${base}`)
  if (!String(CONFIG.displayName || '').trim()) {
    console.log('   nom de l’app à mettre dans tools/testflight/config.json (displayName) : sans lui, la CI n’envoie rien')
  }
}

// ── signing (CI) ─────────────────────────────────────────────────────────

async function signing() {
  const env = process.env
  for (const k of ['ASC_KEY_ID', 'ASC_ISSUER_ID', 'ASC_KEY_P8', 'TF_DIST_KEY', 'RUNNER_TEMP', 'GITHUB_OUTPUT']) {
    if (!env[k]) throw new Fail(`${k} manquant`)
  }
  const auth = { keyId: env.ASC_KEY_ID, issuer: env.ASC_ISSUER_ID, p8: env.ASC_KEY_P8 }
  const base = env.TF_BUNDLE || CONFIG.bundleId

  const cert = await certificateFor(auth, env.TF_DIST_KEY, 0)
  if (!cert) {
    throw new Fail('aucun certificat de distribution valable pour TF_DIST_KEY (expiré ou révoqué ?) : relancer « node tools/testflight/asc.mjs setup » sur le PC')
  }
  // Compte individuel : le certificat porte le vrai nom du titulaire, que
  // xcodebuild affiche en signant. Masqué avant toute autre sortie.
  const subject = cert.x509.subject
  for (const [, raw] of subject.matchAll(/^(?:CN|O)=(.+)$/gm)) {
    const value = raw.replace(/\\(.)/g, '$1')
    console.log(`::add-mask::${value}`)
    const inner = value.match(/^Apple Distribution: (.+) \([A-Z0-9]{10}\)$/)
    if (inner) console.log(`::add-mask::${inner[1]}`)
  }
  const team = (subject.match(/^OU=([A-Z0-9]{10})$/m) || [])[1]
  if (!team) throw new Fail('équipe introuvable dans le certificat')

  const folders = [
    join(homedir(), 'Library/MobileDevice/Provisioning Profiles'),
    join(homedir(), 'Library/Developer/Xcode/UserData/Provisioning Profiles'),
  ]
  for (const t of TARGETS) {
    const bundle = await bundleId(auth, base + t.suffix, t.name)
    const p = await appStoreProfile(auth, t.profile, bundle, cert.id)
    const content = Buffer.from(p.attributes.profileContent, 'base64')
    for (const folder of folders) {
      mkdirSync(folder, { recursive: true })
      writeFileSync(join(folder, `${p.attributes.uuid}.mobileprovision`), content)
    }
    console.log(`${t.profile} (${base + t.suffix}) : installé, expire le ${day(p.attributes.expirationDate)}`)
  }
  writeFileSync(join(env.RUNNER_TEMP, 'tf-dist-cert.pem'), cert.x509.toString())
  appendFileSync(env.GITHUB_OUTPUT, `team_id=${team}\n`)
  console.log(`Certificat de distribution : expire le ${day(cert.expires)}`)
}

// ── Lancement ────────────────────────────────────────────────────────────

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [cmd, ...rest] = process.argv.slice(2)
  const args = {}
  for (let i = 0; i < rest.length; i++) {
    if (!rest[i].startsWith('--')) continue
    const next = rest[i + 1]
    args[rest[i].slice(2)] = next === undefined || next.startsWith('--') ? true : rest[++i]
  }
  try {
    if (cmd === 'setup') await setup(args)
    else if (cmd === 'signing') await signing()
    else {
      console.log('usage : node tools/testflight/asc.mjs setup --key AuthKey_XXXXXXXXXX.p8 --issuer <Issuer ID>\n' +
        '        node tools/testflight/asc.mjs signing   (CI)')
      process.exitCode = cmd ? 2 : 0
    }
  } catch (e) {
    const message = e instanceof Fail ? e.message : (e?.stack || String(e))
    // Dans la CI, l'annotation (::error::) se lit sur la sortie standard.
    if (process.env.GITHUB_ACTIONS) console.log(`::error::${message.split('\n')[0]}`)
    console.error(`Échec : ${message}`)
    process.exitCode = 1
  }
}
