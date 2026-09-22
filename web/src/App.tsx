import { useCallback, useEffect, useRef, useState } from 'react'
import { Chat } from './components/Chat'
import { Categories, Home, Search } from './components/Home'
import { Player } from './components/Player'
import { Settings } from './components/Settings'
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
import { getSettings, save as saveSettings, setSetting, useSettings } from './lib/settings'
import type { ChatMessage } from './lib/message'
import {
  formatUptime,
  formatViewers,
  getQualityLinks,
  getStreamInfo,
  type QualityLinks,
  type StreamInfo,
} from './lib/stream'

type Tab = 'home' | 'categories' | 'search'

const TABS: { id: Tab; label: string; icon: string }[] = [
  { id: 'home', label: 'Accueil', icon: '🏠' },
  { id: 'categories', label: 'Catégories', icon: '🎮' },
  { id: 'search', label: 'Recherche', icon: '🔍' },
]

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

  const settings = useSettings()
  const [dragging, setDragging] = useState(false)
  const [tab, setTab] = useState<Tab>('home')
  const [showSettings, setShowSettings] = useState(false)

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
      // Lus au moment de la connexion : ce sont des options du client IRC,
      // pas un état qui se recalcule — d'où la note « prochaine chaîne
      // ouverte » dans les réglages.
      loadRecent: getSettings().chatLoadRecent,
      keepDeleted: getSettings().chatShowDeleted,
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
      setSetting('chatRatio', Math.min(0.6, Math.max(0.2, ratio)), false)
    }
    function onUp() {
      setDragging(false)
      // Une seule écriture disque, à la fin du geste.
      saveSettings()
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
        <button className="brand" onClick={() => { closeChannel(); setTab('home') }}>
          TwitchUnblock
        </button>

        {/* Les onglets restent visibles pendant la lecture : cliquer dessus
            ferme la chaîne et revient à la découverte, comme une barre
            d'onglets d'application. */}
        <nav className="tabs">
          {TABS.map((t) => (
            <button
              key={t.id}
              className={!info && tab === t.id ? 'on' : ''}
              onClick={() => { closeChannel(); setTab(t.id) }}
            >
              <span className="tab-icon">{t.icon}</span>
              <span className="tab-label">{t.label}</span>
            </button>
          ))}
        </nav>

        <span className="spacer" />

        <button
          className={`icon-btn${showSettings ? ' on' : ''}`}
          onClick={() => setShowSettings((v) => !v)}
          title="Réglages"
          aria-label="Réglages"
        >
          ⚙
        </button>
        {user.avatar && <img className="avatar" src={user.avatar} alt="" />}
        <span className="me">{user.displayName}</span>
        <button className="ghost" onClick={() => { logout(); setToken(null); setUser(null) }}>
          Déconnexion
        </button>
      </header>

      {error && <div className="banner">{error}</div>}

      {showSettings ? (
        <Settings onClose={() => setShowSettings(false)} />
      ) : !info && !loading ? (
        <>
          {tab === 'home' && (
            <Home token={token} userId={user.id} onOpen={(l) => void openChannel(l)} />
          )}
          {tab === 'categories' && (
            <Categories token={token} onOpen={(l) => void openChannel(l)} />
          )}
          {tab === 'search' && (
            <Search token={token} onOpen={(l) => void openChannel(l)} />
          )}
        </>
      ) : (
        <main className="split" style={{ ['--chat' as string]: `${settings.chatRatio * 100}%` }}>
          <section className="stage">
            {loading && <div className="placeholder">Chargement…</div>}

            {!loading && info && (
              <>
                {info.live && Object.keys(links).length > 0 ? (
                  <Player
                    links={links}
                    lowLatency={settings.lowLatency}
                    preferredQuality={settings.defaultQuality}
                    onLatency={setLatency}
                  />
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
