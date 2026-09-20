// ═══════════════════════════════════════════════════════════════════════════
//  Métadonnées de la chaîne et résolution de la playlist.
//
//  Deux différences assumées par rapport à l'app iOS :
//
//  • Les métadonnées passent par Helix, pas par GQL. Helix garantit le CORS ;
//    l'endpoint GQL public ne le garantit pas, et il exige de toute façon un
//    jeton d'intégrité pour une partie de ses champs.
//
//  • La playlist vient exclusivement du Worker. Tenter Luminous depuis le
//    navigateur se heurterait au CORS — le Worker, lui, n'a pas de navigateur
//    au-dessus de lui et c'est déjà là qu'est la logique de repli.
// ═══════════════════════════════════════════════════════════════════════════

import { HELIX_CLIENT_ID, WORKER_URL } from './config'

export interface StreamInfo {
  userId: string
  login: string
  displayName: string
  avatar: string
  live: boolean
  title: string
  game: string
  viewers: number
  startedAt: number | null
}

export type QualityLinks = Record<string, string>

async function helix(path: string, token: string): Promise<any | null> {
  try {
    const res = await fetch(`https://api.twitch.tv/helix/${path}`, {
      headers: { Authorization: `Bearer ${token}`, 'Client-Id': HELIX_CLIENT_ID },
    })
    if (!res.ok) return null
    return await res.json()
  } catch {
    return null
  }
}

export async function getStreamInfo(login: string, token: string): Promise<StreamInfo | null> {
  const name = login.trim().toLowerCase()
  if (!name) return null

  const [users, streams] = await Promise.all([
    helix(`users?login=${encodeURIComponent(name)}`, token),
    helix(`streams?user_login=${encodeURIComponent(name)}`, token),
  ])

  const u = users?.data?.[0]
  if (!u) return null
  const s = streams?.data?.[0]

  const startedAt = s?.started_at ? Date.parse(s.started_at) : NaN

  return {
    userId: String(u.id ?? ''),
    login: String(u.login ?? name),
    displayName: String(u.display_name ?? u.login ?? name),
    avatar: String(u.profile_image_url ?? ''),
    live: Boolean(s),
    title: String(s?.title ?? ''),
    game: String(s?.game_name ?? ''),
    viewers: Number(s?.viewer_count ?? 0),
    startedAt: Number.isFinite(startedAt) ? startedAt : null,
  }
}

/**
 * Liens de qualité, via `/api/get-live` du Worker.
 *
 * Le Worker doit répondre avec `Access-Control-Allow-Origin` — voir
 * web/WORKER.md pour l'en-tête exact à ajouter s'il manque.
 */
export async function getQualityLinks(login: string): Promise<QualityLinks> {
  try {
    const res = await fetch(
      `${WORKER_URL}/api/get-live?name=${encodeURIComponent(login.toLowerCase())}&proxy=false`,
    )
    if (!res.ok) return {}
    const json = await res.json()
    const links = json?.links
    if (!links || typeof links !== 'object') return {}

    const out: QualityLinks = {}
    for (const [k, v] of Object.entries(links)) {
      if (typeof v === 'string') out[k] = v
    }
    return out
  } catch {
    return {}
  }
}

/** Source d'abord, puis du plus fin au plus grossier. Port de sortQualities. */
export function sortQualities(keys: string[]): string[] {
  const score = (k: string): number => {
    if (/source/i.test(k)) return 100000
    const m = k.match(/(\d+)/)
    return m ? Number(m[1]) : 0
  }
  return [...keys].sort((a, b) => score(b) - score(a))
}

export function formatViewers(n: number): string {
  if (n >= 1000) return `${(n / 1000).toFixed(1).replace(/\.0$/, '')}k`
  return String(n)
}

export function formatUptime(startedAt: number | null): string {
  if (!startedAt) return ''
  const s = Math.max(0, Math.floor((Date.now() - startedAt) / 1000))
  const h = Math.floor(s / 3600)
  const m = Math.floor((s % 3600) / 60)
  return h > 0 ? `${h}h${String(m).padStart(2, '0')}` : `${m}min`
}
