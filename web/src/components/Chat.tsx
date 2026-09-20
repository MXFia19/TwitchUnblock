import { useEffect, useMemo, useRef, useState } from 'react'
import { ChatClient } from '../lib/chatClient'
import { suggestEmotes, type Emote } from '../lib/emotes'
import type { ChatMessage } from '../lib/message'

interface Props {
  client: ChatClient | null
  messages: ChatMessage[]
  canSend: boolean
  showTimestamps: boolean
  fontSize: number
  spacing: number
}

export function Chat({ client, messages, canSend, showTimestamps, fontSize, spacing }: Props) {
  const [draft, setDraft] = useState('')
  const listRef = useRef<HTMLDivElement>(null)
  // Suivi automatique tant qu'on est en bas ; dès qu'on remonte pour lire,
  // on cesse de ramener la vue — sinon l'historique est illisible en rafale.
  const [follow, setFollow] = useState(true)

  useEffect(() => {
    if (!follow) return
    const el = listRef.current
    if (el) el.scrollTop = el.scrollHeight
  }, [messages, follow])

  function onScroll() {
    const el = listRef.current
    if (!el) return
    const atBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 40
    setFollow(atBottom)
  }

  const currentWord = draft.split(' ').at(-1) ?? ''
  const suggestions = useMemo<Emote[]>(
    () => (currentWord.length >= 2 && !currentWord.startsWith('@') ? suggestEmotes(currentWord, 12) : []),
    [currentWord],
  )

  function complete(name: string) {
    const words = draft.split(' ')
    words[words.length - 1] = name
    setDraft(words.join(' ') + ' ')
  }

  function submit(e: React.FormEvent) {
    e.preventDefault()
    const text = draft.trim()
    if (!text || !client) return
    client.send(text)
    setDraft('')
  }

  return (
    <div className="chat" style={{ fontSize }}>
      <div className="chat-list" ref={listRef} onScroll={onScroll}>
        {messages.map((m) => (
          <Row key={m.id} msg={m} showTimestamp={showTimestamps} spacing={spacing} />
        ))}
      </div>

      {!follow && (
        <button className="chat-follow" onClick={() => setFollow(true)}>
          ↓ Reprendre le suivi
        </button>
      )}

      {suggestions.length > 0 && (
        <div className="chat-suggest">
          {suggestions.map((e) => (
            <button key={e.id + e.name} onClick={() => complete(e.name)}>
              <img src={e.url} alt="" loading="lazy" />
              <span>{e.name}</span>
            </button>
          ))}
        </div>
      )}

      <form className="chat-input" onSubmit={submit}>
        <input
          value={draft}
          onChange={(e) => setDraft(e.target.value)}
          placeholder={canSend ? 'Envoyer un message…' : 'Connecte-toi pour écrire'}
          disabled={!canSend}
          maxLength={500}
        />
        <button type="submit" disabled={!canSend || !draft.trim()}>➤</button>
      </form>
    </div>
  )
}

function Row({ msg, showTimestamp, spacing }: {
  msg: ChatMessage
  showTimestamp: boolean
  spacing: number
}) {
  const time = new Date(msg.timestamp).toLocaleTimeString([], {
    hour: '2-digit',
    minute: '2-digit',
  })

  if (msg.systemMsg) {
    return (
      <div className="msg msg-system" style={{ padding: `${spacing / 2}px 12px` }}>
        ★ {msg.systemMsg}
      </div>
    )
  }

  const classes = ['msg']
  if (msg.isHighlight) classes.push('msg-highlight')
  if (msg.isFirstMessage) classes.push('msg-first')
  if (msg.isDeleted) classes.push('msg-deleted')

  return (
    <div className={classes.join(' ')} style={{ padding: `${spacing / 2}px 12px` }}>
      {msg.replyTo && (
        <div className="msg-reply">
          ↩ @{msg.replyTo}
          {msg.replyBody ? `: ${msg.replyBody}` : ''}
        </div>
      )}
      <span className="msg-line">
        {showTimestamp && <span className="msg-time">{time}</span>}
        {/* Repêché dans l'historique : sans ce repère on croit avoir vu la
            conversation se dérouler alors qu'elle a eu lieu avant l'arrivée. */}
        {msg.isHistorical && <span className="msg-histo" title="Message antérieur à ton arrivée">🕘</span>}
        {msg.badges.map((b) => (
          <img key={b.id} className="msg-badge" src={b.url} alt="" />
        ))}
        <span className="msg-name" style={{ color: msg.color }}>
          {msg.displayName}
        </span>
        <span className="msg-colon">: </span>
        {msg.tokens.map((t, i) => {
          switch (t.kind) {
            case 'text':
              return (
                <span key={i} style={msg.isAction ? { color: msg.color } : undefined}>
                  {t.value}{' '}
                </span>
              )
            case 'emote':
              return (
                <img
                  key={i}
                  className="msg-emote"
                  src={t.emote.url}
                  alt={t.emote.name}
                  title={t.emote.name}
                  loading="lazy"
                />
              )
            case 'mention':
              return <span key={i} className="msg-mention">@{t.value} </span>
            case 'link':
              return (
                <a
                  key={i}
                  className="msg-link"
                  href={t.value.startsWith('www.') ? `https://${t.value}` : t.value}
                  target="_blank"
                  rel="noreferrer noopener"
                >
                  {t.value}{' '}
                </a>
              )
          }
        })}
      </span>
    </div>
  )
}
