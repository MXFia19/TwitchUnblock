// ═══════════════════════════════════════════════════════════════════════════
//  Analyse des lignes IRC de Twitch.
//
//  Port direct de Sources/Chat/IRCParser.swift. Un point y gagne : les plages
//  d'emotes du tag `emotes` sont exprimées en unités UTF-16, ce qui demandait
//  en Swift une conversion d'index — les chaînes JavaScript étant déjà en
//  UTF-16, les bornes s'utilisent telles quelles.
// ═══════════════════════════════════════════════════════════════════════════

export interface IRCMessage {
  raw: string
  tags: Record<string, string>
  command: string
  params: string[]
  prefix: string | null
}

export function parseIRC(raw: string): IRCMessage | null {
  let rest = raw
  const tags: Record<string, string> = {}
  let prefix: string | null = null

  // 1 — Tags : @key=value;key2=value2 …
  if (rest.startsWith('@')) {
    const space = rest.indexOf(' ')
    if (space < 0) return null
    for (const pair of rest.slice(1, space).split(';')) {
      const eq = pair.indexOf('=')
      if (eq < 0) tags[pair] = ''
      else tags[pair.slice(0, eq)] = pair.slice(eq + 1)
    }
    rest = rest.slice(space + 1).trim()
  }

  // 2 — Préfixe : :nick!user@host
  if (rest.startsWith(':')) {
    const parts = rest.slice(1).split(' ')
    prefix = parts[0] ?? null
    rest = parts.slice(1).join(' ').trim()
  }

  // 3 — Commande et paramètres
  const components = rest.split(' ')
  const command = components.shift()
  if (!command) return null

  const params: string[] = []
  for (let i = 0; i < components.length; i++) {
    const c = components[i]!
    if (c.startsWith(':')) {
      // Paramètre final : tout le reste de la ligne, espaces compris.
      params.push(components.slice(i).join(' ').slice(1))
      break
    }
    params.push(c)
  }

  return { raw, tags, command, params, prefix }
}

/** Pseudo extrait du préfixe `nick!user@host` (JOIN et PART n'ont pas de tags). */
export function prefixNick(msg: IRCMessage): string | null {
  if (!msg.prefix) return null
  const nick = msg.prefix.split('!')[0] ?? msg.prefix
  return nick.includes('@') ? null : nick.toLowerCase()
}

export function ircChannel(msg: IRCMessage): string | null {
  const first = msg.params[0]
  return first?.startsWith('#') ? first.slice(1) : null
}

/** Corps du message, c'est-à-dire le paramètre final. */
export function ircText(msg: IRCMessage): string | null {
  return msg.params.length > 1 ? (msg.params[1] ?? null) : null
}

/** Twitch échappe les espaces et quelques caractères dans les valeurs de tags. */
export function unescapeTag(value: string): string {
  return value
    .replace(/\\s/g, ' ')
    .replace(/\\:/g, ';')
    .replace(/\\r/g, '\r')
    .replace(/\\n/g, '\n')
    .replace(/\\\\/g, '\\')
}

export interface EmoteRange {
  id: string
  start: number
  end: number // exclusif
}

/**
 * Plages d'emotes Twitch depuis le tag `emotes`.
 * Format : `id:debut-fin,debut-fin/id2:debut-fin`, bornes incluses.
 */
export function parseEmoteRanges(raw: string, text: string): EmoteRange[] {
  if (!raw) return []
  const out: EmoteRange[] = []
  for (const part of raw.split('/')) {
    const [id, ranges] = part.split(':')
    if (!id || !ranges) continue
    for (const r of ranges.split(',')) {
      const [a, b] = r.split('-')
      const start = Number(a)
      const end = Number(b)
      if (!Number.isFinite(start) || !Number.isFinite(end)) continue
      if (start < 0 || end >= text.length) continue
      out.push({ id, start, end: end + 1 })
    }
  }
  return out.sort((x, y) => x.start - y.start)
}
