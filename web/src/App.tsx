import { useCallback, useEffect, useRef, useState } from 'react'
import { Chat } from './components/Chat'
import { Home } from './components/Home'
import { Player } from './components/Player'
import {
  consumeRedirect,
  fetchSelf,
  loginURL,
  logout,
  saveSession,
  storedToken,
  storedUser,
  type TwitchUser,
} from './lib/auth'
import { ChatClient } from './lib/chatClient'
import { pushHistory } from './lib/discover'
import { loadChannelEmotes, loadGlobalEmotes } from './lib/emotes'
import type { ChatMessage } from './lib/message'
import {
  formatUptime,
  formatViewers,
  getQualityLinks,
  getStreamInfo,
  type QualityLinks,
  type StreamInfo,
} from './lib/stream'

export default function App() {
  const [token, setToken] = useState<string | null>(storedToken)
  const [user, setUser] = useState<TwitchUser | null>(storedUser)
  const [info, setInfo] = useState<StreamInfo | null>(null)
  const [links, setLinks] = useState<QualityLinks>({})
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [latency, setLatency] = useState<number | null>(null)

  const [messages, setMessages] = useState<ChatMessage[]>([])
  const clientRef = useRef<ChatClient | null>(null)

  // Largeur du chat, en fraction de la fenêtre. Pendant un glissement la
  // valeur vit dans un état local et n'est enregistrée qu'au relâcher —
  // écrire dans localStorage à chaque image du geste hache l'animation.
  const [chatRatio, setChatRatio] = useState(() => {
    const saved = Number(localStorage.getItem('tu_chat_ratio'))
    return Number.isFinite(saved) && saved >= 0.2 && saved <= 0.6 ? saved : 0.32
  })
  const [dragging, setDragging] = useState(false)

  // ── Retour de Twitch ────────────────────────────────────────────────
  useEffect(() => {
    const fresh = consumeRedirect()
    const t = fresh ?? storedToken()
    if (!t) return
    void (async () => {
      const me = await fetchSelf(t)
      if (!me) { logout(); setToken(null); setUser(null); return }
      saveSession(t, me)
      setToken(t)
      setUser(me)
    })()
  }, [])

  useEffect(() => { void loadGlobalEmotes() }, [])

  // ── Ouverture d'une chaîne ──────────────────────────────────────────
  const openChannel = useCallback(async (loginName: string) => {
    const name = loginName.trim().toLowerCase()
    if (!name || !token) return

    setLoading(true)
    setError(null)
    clientRef.current?.disconnect()
    clientRef.current = null
    setMessages([])

    const meta = await getStreamInfo(name, token)
    if (!meta) {
      setLoading(false)
      setError('Chaîne introuvable')
      return
    }
    setInfo(meta)
    pushHistory({ login: meta.login, displayName: meta.displayName, avatar: meta.avatar })

    await loadChannelEmotes(meta.userId, meta.login)

    const client = new ChatClient({
      channel: meta.login,
      channelId: meta.userId,
      token,
      login: user?.login ?? null,
      loadRecent: true,
      keepDeleted: false,
    })
    client.onChange = () => setMessages([...client.messages])
    client.connect()
    clientRef.current = client

    if (meta.live) {
      const l = await getQualityLinks(meta.login)
      setLinks(l)
      if (Object.keys(l).length === 0) {
        setError("Flux indisponible — vérifie que le Worker autorise ce domaine (voir WORKER.md)")
      }
    } else {
      setLinks({})
    }
    setLoading(false)
  }, [token, user])

  useEffect(() => () => clientRef.current?.disconnect(), [])

  const closeChannel = useCallback(() => {
    clientRef.current?.disconnect()
    clientRef.current = null
    setMessages([])
    setInfo(null)
    setLinks({})
    setError(null)
    setLatency(null)
  }, [])

  // ── Glissement de la séparation ─────────────────────────────────────
  useEffect(() => {
    if (!dragging) return
    function onMove(e: PointerEvent) {
      // Tirer vers la gauche élargit le chat.
      const ratio = (window.innerWidth - e.clientX) / window.innerWidth
      setChatRatio(Math.min(0.6, Math.max(0.2, ratio)))
    }
    function onUp() {
      setDragging(false)
      setChatRatio((r) => { localStorage.setItem('tu_chat_ratio', String(r)); return r })
    }
    window.addEventListener('pointermove', onMove)
    window.addEventListener('pointerup', onUp)
    return () => {
      window.removeEventListener('pointermove', onMove)
      window.removeEventListener('pointerup', onUp)
    }
  }, [dragging])

  if (!token || !user) return <LoginScreen />

  return (
    <div className="app">
      <header className="header">
        <button className="brand" onClick={closeChannel} title="Accueil">
          TwitchUnblock
        </button>

        {info && (
          <button className="ghost" onClick={closeChannel}>← Accueil</button>
        )}

        <span className="spacer" />
        {user.avatar && <img className="avatar" src={user.avatar} alt="" />}
        <span className="me">{user.displayName}</span>
        <button className="ghost" onClick={() => { logout(); setToken(null); setUser(null) }}>
          Déconnexion
        </button>
      </header>

      {error && <div className="banner">{error}</div>}

      {!info && !loading ? (
        <Home token={token} userId={user.id} onOpen={(l) => void openChannel(l)} />
      ) : (
        <main className="split" style={{ ['--chat' as string]: `${chatRatio * 100}%` }}>
          <section className="stage">
            {loading && <div className="placeholder">Chargement…</div>}

            {!loading && info && (
              <>
                {info.live && Object.keys(links).length > 0 ? (
                  <Player links={links} lowLatency={false} onLatency={setLatency} />
                ) : (
                  <div className="placeholder">
                    {info.live ? 'Flux indisponible' : `${info.displayName} est hors ligne`}
                  </div>
                )}

                <div className="meta">
                  {info.avatar && <img className="avatar lg" src={info.avatar} alt="" />}
                  <div className="meta-text">
                    <div className="meta-title">{info.title || info.displayName}</div>
                    <div className="meta-sub">
                      <strong>{info.displayName}</strong>
                      {info.game && <> · {info.game}</>}
                      {info.live && <> · 👁 {formatViewers(info.viewers)}</>}
                      {info.live && info.startedAt && <> · {formatUptime(info.startedAt)}</>}
                      {latency !== null && <> · {latency.toFixed(0)} s de latence</>}
                    </div>
                  </div>
                </div>
              </>
            )}
          </section>

          {/* Le trait visible reste fin ; c'est une bande large qui reçoit le
              geste, sous peine de viser deux pixels avec un pouce. */}
          <div
            className={`gutter${dragging ? ' gutter-active' : ''}`}
            onPointerDown={() => setDragging(true)}
            role="separator"
            aria-label="Redimensionner le chat"
          >
            <span className="grip" />
          </div>

          <aside className="side">
            <Chat
              client={clientRef.current}
              messages={messages}
              canSend={Boolean(token && user)}
              showTimestamps
              fontSize={13}
              spacing={8}
            />
          </aside>
        </main>
      )}

    </div>
  )
}

function LoginScreen() {
  return (
    <div className="login">
      <h1>TwitchUnblock</h1>
      <p>Connecte ton compte Twitch pour accéder aux chaînes et au chat.</p>
      <a className="cta" href={loginURL()}>Se connecter avec Twitch</a>
    </div>
  )
}
