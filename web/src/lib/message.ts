// ═══════════════════════════════════════════════════════════════════════════
//  Du message IRC brut au message affichable.
//  Port de handlePrivmsg / tokenizeChatSegment (Sources/Chat/).
// ═══════════════════════════════════════════════════════════════════════════

import { type Emote, registerTwitchEmote, resolveEmote } from './emotes'
import {
  type IRCMessage,
  ircText,
  parseEmoteRanges,
  prefixNick,
  unescapeTag,
} from './irc'
import { resolveBadge } from './badges'

export type Token =
  | { kind: 'text'; value: string }
  | { kind: 'emote'; emote: Emote }
  | { kind: 'mention'; value: string }
  | { kind: 'link'; value: string }

export interface Badge {
  id: string
  url: string
}

export interface ChatMessage {
  id: string
  userId: string
  userName: string
  displayName: string
  color: string
  badges: Badge[]
  tokens: Token[]
  timestamp: number
  isAction: boolean
  isHighlight: boolean
  isFirstMessage: boolean
  replyTo: string | null
  replyBody: string | null
  systemMsg: string | null
  /** Repêché dans l'historique à l'arrivée, pas reçu en direct. */
  isHistorical: boolean
  /** Supprimé par la modération mais conservé à l'écran. */
  isDeleted: boolean
}

/**
 * Éclaircit une couleur de pseudo trop sombre pour rester lisible sur fond
 * noir. Port de `Color.readableChat` (Sources/Constants.swift).
 */
export function readableChatColor(hex: string): string {
  let h = hex.trim().replace(/^#/, '')
  if (h.length !== 6) return '#9146ff'
  const n = Number.parseInt(h, 16)
  if (!Number.isFinite(n)) return '#9146ff'

  let r = ((n >> 16) & 0xff) / 255
  let g = ((n >> 8) & 0xff) / 255
  let b = (n & 0xff) / 255

  const lum = 0.299 * r + 0.587 * g + 0.114 * b
  const minLum = 0.45
  if (lum < minLum) {
    const f = Math.min(1, (minLum - lum) / minLum + 0.15)
    r += (1 - r) * f
    g += (1 - g) * f
    b += (1 - b) * f
  }
  const to255 = (v: number) => Math.round(v * 255).toString(16).padStart(2, '0')
  return `#${to255(r)}${to255(g)}${to255(b)}`
}

/** Découpe un segment en liens, mentions, emotes tierces et texte. */
function tokenizeSegment(segment: string): Token[] {
  const out: Token[] = []
  for (const word of segment.split(' ')) {
    if (!word) continue
    const lower = word.toLowerCase()
    if (lower.startsWith('http://') || lower.startsWith('https://') || lower.startsWith('www.')) {
      out.push({ kind: 'link', value: word })
    } else if (word.startsWith('@') && word.length > 1) {
      out.push({ kind: 'mention', value: word.slice(1) })
    } else {
      const emote = resolveEmote(word)
      if (emote) out.push({ kind: 'emote', emote })
      else out.push({ kind: 'text', value: word })
    }
  }
  return out
}

/**
 * Construit le message affichable. `historical` bascule l'horodatage sur le
 * tag `tmi-sent-ts` : en rejeu, l'heure d'arrivée n'a aucun sens.
 */
export function buildMessage(irc: IRCMessage, historical: boolean): ChatMessage | null {
  let text = ircText(irc)
  if (text === null) return null

  let isAction = false
  if (text.startsWith('\u0001ACTION ') && text.endsWith('\u0001')) {
    text = text.slice(8, -1)
    isAction = true
  }

  // Les emotes Twitch sont données par position : on découpe autour d'elles,
  // et seuls les intervalles restants passent par la tokenisation par mot.
  const ranges = parseEmoteRanges(irc.tags['emotes'] ?? '', text)
  const tokens: Token[] = []
  let cursor = 0
  for (const r of ranges) {
    if (r.start < cursor) continue
    if (r.start > cursor) tokens.push(...tokenizeSegment(text.slice(cursor, r.start)))
    tokens.push({ kind: 'emote', emote: registerTwitchEmote(r.id, text.slice(r.start, r.end)) })
    cursor = r.end
  }
  if (cursor < text.length) tokens.push(...tokenizeSegment(text.slice(cursor)))

  const login = irc.tags['login'] || prefixNick(irc) || ''
  const displayName = irc.tags['display-name'] || login
  const rawColor = (irc.tags['color'] ?? '').trim()

  let timestamp = Date.now()
  if (historical) {
    const ms = Number(irc.tags['tmi-sent-ts'])
    if (Number.isFinite(ms) && ms > 0) timestamp = ms
  }

  const replyBodyRaw = irc.tags['reply-parent-msg-body']

  return {
    id: irc.tags['id'] || crypto.randomUUID(),
    userId: irc.tags['user-id'] ?? '',
    userName: login,
    displayName,
    color: readableChatColor(rawColor || '9146ff'),
    badges: parseBadges(irc.tags['badges'] ?? ''),
    tokens,
    timestamp,
    isAction,
    isHighlight: irc.tags['msg-id'] === 'highlighted-message',
    isFirstMessage: irc.tags['first-msg'] === '1',
    replyTo: irc.tags['reply-parent-display-name'] ?? null,
    replyBody: replyBodyRaw ? unescapeTag(replyBodyRaw) : null,
    systemMsg: null,
    isHistorical: historical,
    isDeleted: false,
  }
}

function parseBadges(raw: string): Badge[] {
  if (!raw) return []
  const out: Badge[] = []
  for (const part of raw.split(',')) {
    const [set, version] = part.split('/')
    if (!set || !version) continue
    const url = resolveBadge(set, version)
    if (url) out.push({ id: `${set}/${version}`, url })
  }
  return out
}

/** Texte brut du message, emotes remplacées par leur nom. */
export function plainText(msg: ChatMessage): string {
  return msg.tokens
    .map((t) => {
      switch (t.kind) {
        case 'text': return t.value
        case 'emote': return t.emote.name
        case 'mention': return `@${t.value}`
        case 'link': return t.value
      }
    })
    .join(' ')
}
