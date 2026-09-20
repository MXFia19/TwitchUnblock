// ═══════════════════════════════════════════════════════════════════════════
//  Découverte : chaînes suivies, top des directs, catégories, recherche.
//  Port de la partie Helix de Sources/Services/TwitchAPI.swift.
// ═══════════════════════════════════════════════════════════════════════════

import { HELIX_CLIENT_ID } from './config'

export interface Stream {
  userId: string
  login: string
  displayName: string
  title: string
  game: string
  viewers: number
  /** Gabarits {width}/{height} déjà remplis. */
  thumbnail: string
}

export interface Category {
  id: string
  name: string
  boxArt: string
}

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

function toStream(o: any): Stream {
  return {
    userId: String(o?.user_id ?? ''),
    login: String(o?.user_login ?? ''),
    displayName: String(o?.user_name ?? o?.user_login ?? ''),
    title: String(o?.title ?? ''),
    game: String(o?.game_name ?? ''),
    viewers: Number(o?.viewer_count ?? 0),
    thumbnail: String(o?.thumbnail_url ?? '')
      .replace('{width}', '440')
      .replace('{height}', '248'),
  }
}

export async function getFollowedStreams(token: string, userId: string): Promise<Stream[]> {
  const json = await helix(`streams/followed?user_id=${userId}&first=50`, token)
  return (json?.data ?? []).map(toStream)
}

/** `lang` au format ISO (« fr »), ou null pour le classement mondial. */
export async function getTopStreams(token: string, lang: string | null): Promise<Stream[]> {
  const suffix = lang ? `&language=${lang}` : ''
  const json = await helix(`streams?first=40${suffix}`, token)
  return (json?.data ?? []).map(toStream)
}

export async function getTopCategories(token: string): Promise<Category[]> {
  const json = await helix('games/top?first=24', token)
  return (json?.data ?? []).map((o: any) => ({
    id: String(o?.id ?? ''),
    name: String(o?.name ?? ''),
    boxArt: String(o?.box_art_url ?? '').replace('{width}', '144').replace('{height}', '192'),
  }))
}

export async function getStreamsByCategory(token: string, gameId: string): Promise<Stream[]> {
  const json = await helix(`streams?game_id=${gameId}&first=40`, token)
  return (json?.data ?? []).map(toStream)
}

/**
 * Recherche de chaînes. `live_only` écarte les hors-ligne : sur un écran de
 * découverte, proposer une chaîne éteinte n'aide personne.
 */
export async function searchChannels(token: string, query: string): Promise<Stream[]> {
  const q = query.trim()
  if (!q) return []
  const json = await helix(
    `search/channels?query=${encodeURIComponent(q)}&first=20&live_only=true`,
    token,
  )
  // Cette route a sa propre forme : pas de viewer_count, et broadcaster_login
  // au lieu de user_login.
  return (json?.data ?? []).map((o: any) => ({
    userId: String(o?.id ?? ''),
    login: String(o?.broadcaster_login ?? ''),
    displayName: String(o?.display_name ?? o?.broadcaster_login ?? ''),
    title: String(o?.title ?? ''),
    game: String(o?.game_name ?? ''),
    viewers: 0,
    thumbnail: String(o?.thumbnail_url ?? ''),
  }))
}

// ── Historique local ────────────────────────────────────────────────────
// Rien ne part côté serveur : c'est la liste de ce qu'on a regardé, sur cet
// appareil, et elle n'intéresse personne d'autre.

const HISTORY_KEY = 'tu_history'
const HISTORY_MAX = 12

export interface HistoryEntry {
  login: string
  displayName: string
  avatar: string
  at: number
}

export function readHistory(): HistoryEntry[] {
  try {
    const raw = localStorage.getItem(HISTORY_KEY)
    if (!raw) return []
    const arr: unknown = JSON.parse(raw)
    return Array.isArray(arr) ? (arr as HistoryEntry[]) : []
  } catch {
    return []
  }
}

export function pushHistory(entry: Omit<HistoryEntry, 'at'>): HistoryEntry[] {
  const next = [
    { ...entry, at: Date.now() },
    ...readHistory().filter((h) => h.login !== entry.login),
  ].slice(0, HISTORY_MAX)
  try {
    localStorage.setItem(HISTORY_KEY, JSON.stringify(next))
  } catch {
    // Mode privé, stockage plein : l'historique est un confort, pas une
    // fonctionnalité dont dépend le reste.
  }
  return next
}

export function clearHistory(): void {
  try { localStorage.removeItem(HISTORY_KEY) } catch { /* idem */ }
}
