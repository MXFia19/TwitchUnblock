// Badges de chat (Helix). Port de Sources/Chat/BadgeService.swift.
import { HELIX_CLIENT_ID } from './config'

type VersionMap = Record<string, string>        // version → URL
const globalBadges: Record<string, VersionMap> = {}
const channelBadges: Record<string, VersionMap> = {}

let loadedGlobals = false
let loadedChannelId: string | null = null

async function fetchBadges(url: string, token: string): Promise<Record<string, VersionMap>> {
  const out: Record<string, VersionMap> = {}
  try {
    const res = await fetch(url, {
      headers: { Authorization: `Bearer ${token}`, 'Client-Id': HELIX_CLIENT_ID },
    })
    if (!res.ok) return out
    const json = await res.json()
    for (const set of json?.data ?? []) {
      const setId = set?.set_id
      if (typeof setId !== 'string') continue
      const versions: VersionMap = {}
      for (const v of set?.versions ?? []) {
        if (typeof v?.id === 'string' && typeof v?.image_url_2x === 'string') {
          versions[v.id] = v.image_url_2x
        }
      }
      out[setId] = versions
    }
  } catch {
    // Les badges sont décoratifs : leur absence ne casse rien.
  }
  return out
}

export async function loadGlobalBadges(token: string): Promise<void> {
  if (loadedGlobals || !token) return
  loadedGlobals = true
  Object.assign(globalBadges, await fetchBadges('https://api.twitch.tv/helix/chat/badges/global', token))
}

export async function loadChannelBadges(channelId: string, token: string): Promise<void> {
  if (loadedChannelId === channelId || !token) return
  loadedChannelId = channelId
  for (const k of Object.keys(channelBadges)) delete channelBadges[k]
  Object.assign(
    channelBadges,
    await fetchBadges(`https://api.twitch.tv/helix/chat/badges?broadcaster_id=${channelId}`, token),
  )
}

/** Le badge de chaîne l'emporte : un abonnement a son propre visuel par canal. */
export function resolveBadge(set: string, version: string): string {
  return channelBadges[set]?.[version] ?? globalBadges[set]?.[version] ?? ''
}
