// ═══════════════════════════════════════════════════════════════════════════
//  Connexion au chat Twitch.
//
//  Port de Sources/Chat/ChatService.swift. Le navigateur parle WebSocket
//  nativement : contrairement à la vidéo, le chat n'a besoin d'aucun proxy.
// ═══════════════════════════════════════════════════════════════════════════

import { IRC_CAPS, IRC_URL } from './config'
import { loadChannelBadges, loadGlobalBadges } from './badges'
import { buildMessage, type ChatMessage } from './message'
import { ircText, parseIRC, prefixNick, unescapeTag } from './irc'

export interface ChatState {
  connected: boolean
  authenticated: boolean
  messages: ChatMessage[]
  /** Twitch n'annonce les arrivées que sur les canaux de taille modeste. */
  present: Set<string>
}

export interface ChatOptions {
  channel: string
  channelId: string | null
  token: string | null
  login: string | null
  loadRecent: boolean
  keepDeleted: boolean
}

const MAX_MESSAGES = 250

export class ChatClient {
  private ws: WebSocket | null = null
  private pingTimer: ReturnType<typeof setInterval> | null = null
  private opts: ChatOptions
  /** Incrémenté à chaque connexion : une réponse tardive d'un canal quitté
   *  ne doit pas atterrir dans le suivant. */
  private generation = 0
  private closedByUs = false

  messages: ChatMessage[] = []
  connected = false
  authenticated = false
  present = new Set<string>()

  /** Appelé après chaque changement d'état ; React s'y abonne. */
  onChange: () => void = () => {}

  constructor(opts: ChatOptions) {
    this.opts = opts
  }

  connect(): void {
    this.disconnect()
    this.closedByUs = false
    const gen = ++this.generation

    const ws = new WebSocket(IRC_URL)
    this.ws = ws

    ws.onopen = () => {
      if (this.generation !== gen) return
      ws.send(`CAP REQ :${IRC_CAPS}`)
      const { token, login } = this.opts
      if (token && login) {
        ws.send(`PASS oauth:${token}`)
        ws.send(`NICK ${login.toLowerCase()}`)
        this.authenticated = true
      } else {
        ws.send(`NICK justinfan${Math.floor(10000 + Math.random() * 89999)}`)
        this.authenticated = false
      }
      ws.send(`JOIN #${this.opts.channel}`)
      this.emit()
    }

    ws.onmessage = (ev) => {
      if (this.generation !== gen) return
      // Twitch agrège plusieurs commandes dans une même trame.
      for (const line of String(ev.data).split('\r\n')) {
        if (line) void this.handleLine(line)
      }
    }

    ws.onclose = () => {
      if (this.generation !== gen) return
      this.connected = false
      this.emit()
      // Reconnexion automatique, sauf fermeture volontaire.
      if (!this.closedByUs) setTimeout(() => this.connect(), 3000)
    }

    this.pingTimer = setInterval(() => {
      if (ws.readyState === WebSocket.OPEN) ws.send('PING :tmi.twitch.tv')
    }, 240_000)

    void loadGlobalBadges(this.opts.token ?? '')
    if (this.opts.channelId) void loadChannelBadges(this.opts.channelId, this.opts.token ?? '')
    // En parallèle : l'historique n'a pas à attendre l'IRC, et inversement.
    if (this.opts.loadRecent) void this.loadRecentMessages(gen)
  }

  disconnect(): void {
    this.generation += 1
    this.closedByUs = true
    if (this.pingTimer) { clearInterval(this.pingTimer); this.pingTimer = null }
    this.ws?.close()
    this.ws = null
    this.connected = false
    this.authenticated = false
    this.present.clear()
  }

  send(text: string, replyParentId?: string): void {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN || !this.authenticated) return
    const prefix = replyParentId ? `@reply-parent-msg-id=${replyParentId} ` : ''
    this.ws.send(`${prefix}PRIVMSG #${this.opts.channel} :${text}`)

    // Twitch ne nous renvoie pas nos propres messages : on l'affiche nous-mêmes.
    this.insert({
      id: crypto.randomUUID(),
      userId: 'self',
      userName: this.opts.login ?? '',
      displayName: this.opts.login ?? '',
      color: '#9146ff',
      badges: [],
      tokens: text.split(' ').filter(Boolean).map((w) => ({ kind: 'text', value: w })),
      timestamp: Date.now(),
      isAction: false,
      isHighlight: false,
      isFirstMessage: false,
      replyTo: null,
      replyBody: null,
      systemMsg: null,
      isHistorical: false,
      isDeleted: false,
    })
  }

  // MARK: – Réception
  private async handleLine(line: string): Promise<void> {
    const irc = parseIRC(line)
    if (!irc) return

    switch (irc.command) {
      case '001':
        this.connected = true
        this.emit()
        break
      case 'PING':
        this.ws?.send('PONG :tmi.twitch.tv')
        break
      case 'PRIVMSG': {
        const msg = buildMessage(irc, false)
        if (msg) this.insert(msg)
        break
      }
      case 'USERNOTICE': {
        const sys = unescapeTag(irc.tags['system-msg'] ?? '')
        if (sys) this.insert(this.systemMessage(sys))
        break
      }
      case 'NOTICE': {
        const text = ircText(irc)
        if (text) this.insert(this.systemMessage(text))
        break
      }
      case '353': {
        // RPL_NAMREPLY : le pseudo et le canal occupent params[0..2], la liste
        // est le dernier paramètre — pas params[1], qui vaut « = ».
        const names = irc.params.length >= 4 ? irc.params[irc.params.length - 1] : null
        if (names) {
          for (const n of names.split(' ')) if (n) this.present.add(n.toLowerCase())
          this.emit()
        }
        break
      }
      case 'JOIN': {
        const who = irc.tags['login'] ?? prefixNick(irc)
        if (who) { this.present.add(who.toLowerCase()); this.emit() }
        break
      }
      case 'PART': {
        const who = irc.tags['login'] ?? prefixNick(irc)
        if (who) { this.present.delete(who.toLowerCase()); this.emit() }
        break
      }
      case 'CLEARMSG': {
        const target = irc.tags['target-msg-id']
        if (target) this.moderate((m) => m.id === target)
        break
      }
      case 'CLEARCHAT': {
        const target = irc.params[irc.params.length - 1]
        if (target && !target.startsWith('#')) this.moderate((m) => m.userName === target)
        else { this.messages = []; this.emit() }
        break
      }
    }
  }

  private systemMessage(text: string): ChatMessage {
    return {
      id: crypto.randomUUID(),
      userId: 'system',
      userName: '',
      displayName: '',
      color: '#888888',
      badges: [],
      tokens: [],
      timestamp: Date.now(),
      isAction: false,
      isHighlight: false,
      isFirstMessage: false,
      replyTo: null,
      replyBody: null,
      systemMsg: text,
      isHistorical: false,
      isDeleted: false,
    }
  }

  /** Retire les messages visés, ou les barre si le réglage le demande. */
  private moderate(match: (m: ChatMessage) => boolean): void {
    if (this.opts.keepDeleted) {
      this.messages = this.messages.map((m) => (match(m) ? { ...m, isDeleted: true } : m))
    } else {
      this.messages = this.messages.filter((m) => !match(m))
    }
    this.emit()
  }

  private insert(msg: ChatMessage): void {
    // La liste va du plus ancien au plus récent, comme à l'écran.
    this.messages = [...this.messages, msg]
    if (this.messages.length > MAX_MESSAGES) {
      this.messages = this.messages.slice(this.messages.length - MAX_MESSAGES)
    }
    this.emit()
  }

  /**
   * Twitch n'envoie rien d'antérieur au JOIN : on arriverait dans un chat vide
   * en plein débat. recent-messages.robotty.de rejoue les dernières lignes IRC
   * brutes, qu'on fait passer par le même analyseur que le direct.
   *
   * Service tiers : un échec est silencieux, le chat démarre simplement vide.
   */
  private async loadRecentMessages(gen: number): Promise<void> {
    try {
      const res = await fetch(
        `https://recent-messages.robotty.de/api/v2/recent-messages/${this.opts.channel}?limit=60`,
      )
      if (!res.ok) return
      const json = await res.json()
      const raw: unknown = json?.messages
      if (!Array.isArray(raw)) return
      if (this.generation !== gen) return

      const older: ChatMessage[] = []
      for (const line of raw) {
        if (typeof line !== 'string') continue
        const irc = parseIRC(line)
        if (!irc || irc.command !== 'PRIVMSG') continue
        const msg = buildMessage(irc, true)
        if (msg) older.push(msg)
      }
      if (this.generation !== gen || older.length === 0) return

      const known = new Set(this.messages.map((m) => m.id))
      this.messages = [...older.filter((m) => !known.has(m.id)), ...this.messages].sort(
        (a, b) => a.timestamp - b.timestamp,
      )
      this.emit()
    } catch {
      // idem : l'historique est un bonus, pas une dépendance.
    }
  }

  private emit(): void {
    this.onChange()
  }
}
