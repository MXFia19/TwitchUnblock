// ═══════════════════════════════════════════════════════════════════════════
//  Emotes Twitch, BTTV, FFZ et 7TV.
//
//  Port de Sources/Chat/EmoteService.swift. Les trois API tierces répondent
//  avec les en-têtes CORS qu'il faut : le navigateur les appelle en direct,
//  sans passer par le Worker.
// ═══════════════════════════════════════════════════════════════════════════

export type EmoteSource = 'twitch' | 'bttv' | 'ffz' | '7tv'

export interface Emote {
  id: string
  name: string
  url: string
  source: EmoteSource
}

const globals = new Map<string, Emote>() // nom → emote
const channel = new Map<string, Emote>() // nom → emote (canal courant)
/// Les emotes Twitch n'arrivent que par les messages : on les mémorise au vol
/// pour l'autocomplétion, le tag `emotes` ne donnant l'identifiant qu'une fois.
const twitchSeen = new Map<string, Emote>()

let loadedGlobals = false
let loadedChannelId: string | null = null

async function getJSON(url: string): Promise<any | null> {
  try {
    const res = await fetch(url)
    if (!res.ok) return null
    return await res.json()
  } catch {
    // Une source tierce indisponible ne doit pas empêcher le chat de tourner.
    return null
  }
}

export async function loadGlobalEmotes(): Promise<void> {
  if (loadedGlobals) return
  loadedGlobals = true

  const [bttv, ffz, stv] = await Promise.all([
    getJSON('https://api.betterttv.net/3/cached/emotes/global'),
    getJSON('https://api.frankerfacez.com/v1/set/global'),
    getJSON('https://7tv.io/v3/emote-sets/global'),
  ])

  for (const e of readBTTV(bttv)) globals.set(e.name, e)
  for (const e of readFFZSets(ffz?.sets)) globals.set(e.name, e)
  for (const e of read7TV(stv?.emotes)) globals.set(e.name, e)
}

export async function loadChannelEmotes(channelId: string, login: string): Promise<void> {
  if (loadedChannelId === channelId) return
  loadedChannelId = channelId
  channel.clear()

  const [bttv, ffz, stv] = await Promise.all([
    getJSON(`https://api.betterttv.net/3/cached/users/twitch/${channelId}`),
    getJSON(`https://api.frankerfacez.com/v1/room/${login}`),
    getJSON(`https://7tv.io/v3/users/twitch/${channelId}`),
  ])

  for (const e of readBTTV(bttv?.channelEmotes)) channel.set(e.name, e)
  for (const e of readBTTV(bttv?.sharedEmotes)) channel.set(e.name, e)
  for (const e of readFFZSets(ffz?.sets)) channel.set(e.name, e)
  for (const e of read7TV(stv?.emote_set?.emotes)) channel.set(e.name, e)
}

function readBTTV(arr: any): Emote[] {
  if (!Array.isArray(arr)) return []
  const out: Emote[] = []
  for (const o of arr) {
    if (typeof o?.id !== 'string' || typeof o?.code !== 'string') continue
    out.push({
      id: o.id,
      name: o.code,
      url: `https://cdn.betterttv.net/emote/${o.id}/2x`,
      source: 'bttv',
    })
  }
  return out
}

function readFFZSets(sets: any): Emote[] {
  if (!sets || typeof sets !== 'object') return []
  const out: Emote[] = []
  for (const set of Object.values<any>(sets)) {
    if (!Array.isArray(set?.emoticons)) continue
    for (const o of set.emoticons) {
      const raw = o?.urls?.['2'] ?? o?.urls?.['1']
      if (typeof o?.name !== 'string' || typeof raw !== 'string') continue
      out.push({
        id: String(o.id),
        name: o.name,
        url: raw.startsWith('//') ? `https:${raw}` : raw,
        source: 'ffz',
      })
    }
  }
  return out
}

function read7TV(arr: any): Emote[] {
  if (!Array.isArray(arr)) return []
  const out: Emote[] = []
  for (const o of arr) {
    const host = o?.data?.host?.url
    if (typeof o?.id !== 'string' || typeof o?.name !== 'string' || typeof host !== 'string') continue
    out.push({ id: o.id, name: o.name, url: `https:${host}/2x.webp`, source: '7tv' })
  }
  return out
}

/** Le canal l'emporte sur le global : un streamer peut redéfinir une emote. */
export function resolveEmote(name: string): Emote | null {
  return channel.get(name) ?? globals.get(name) ?? null
}

export function registerTwitchEmote(id: string, name: string): Emote {
  const existing = twitchSeen.get(name)
  if (existing) return existing
  const emote: Emote = {
    id,
    name,
    url: `https://static-cdn.jtvnw.net/emoticons/v2/${id}/default/dark/2.0`,
    source: 'twitch',
  }
  twitchSeen.set(name, emote)
  return emote
}

/**
 * Propositions pour l'autocomplétion. Le préfixe l'emporte sur l'occurrence :
 * en tapant « Kappa » on veut Kappa avant KappaPride.
 */
export function suggestEmotes(prefix: string, limit = 24): Emote[] {
  const kw = prefix.toLowerCase()
  if (!kw) return []

  const pool = new Map<string, Emote>()
  for (const [name, e] of channel) pool.set(name, e)
  for (const [name, e] of globals) if (!pool.has(name)) pool.set(name, e)
  for (const [name, e] of twitchSeen) if (!pool.has(name)) pool.set(name, e)

  const starts: Emote[] = []
  const contains: Emote[] = []
  for (const e of pool.values()) {
    const n = e.name.toLowerCase()
    if (n.startsWith(kw)) starts.push(e)
    else if (n.includes(kw)) contains.push(e)
  }
  const byName = (a: Emote, b: Emote) => a.name.toLowerCase().localeCompare(b.name.toLowerCase())
  return [...starts.sort(byName), ...contains.sort(byName)].slice(0, limit)
}
