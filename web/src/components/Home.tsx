import { useEffect, useState } from 'react'
import {
  type Category,
  type HistoryEntry,
  clearHistory,
  getFollowedStreams,
  getStreamsByCategory,
  getTopCategories,
  getTopStreams,
  readHistory,
  searchChannels,
  type Stream,
} from '../lib/discover'
import { setSetting, useSettings } from '../lib/settings'
import { formatViewers } from '../lib/stream'

// ═══════════════════════════════════════════════════════════════════════════
//  Écran d'accueil : ce qu'on suit, ce qui marche, et où on était.
//  Reprend les sections de HomeView.swift.
// ═══════════════════════════════════════════════════════════════════════════

interface Props {
  token: string
  userId: string
  onOpen: (login: string) => void
}

export function Home({ token, userId, onOpen }: Props) {
  const s = useSettings()
  const [followed, setFollowed] = useState<Stream[]>([])
  const [top, setTop] = useState<Stream[]>([])
  const [history, setHistory] = useState<HistoryEntry[]>(readHistory)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    let alive = true
    void (async () => {
      setLoading(true)
      const f = await getFollowedStreams(token, userId)
      if (!alive) return
      setFollowed(f)
      setLoading(false)
    })()
    return () => { alive = false }
  }, [token, userId])

  useEffect(() => {
    let alive = true
    void (async () => {
      const t = await getTopStreams(token, s.topLang === 'fr' ? 'fr' : null)
      if (alive) setTop(t)
    })()
    return () => { alive = false }
  }, [token, s.topLang])

  function open(login: string) {
    onOpen(login)
    // L'historique est écrit par le parent une fois la chaîne résolue ; ici on
    // se contente de le relire au retour.
    setTimeout(() => setHistory(readHistory()), 0)
  }

  return (
    <div className="home">
      {history.length > 0 && (
        <Section
          title="Repris récemment"
          action={
            <button className="ghost sm" onClick={() => { clearHistory(); setHistory([]) }}>
              Effacer
            </button>
          }
        >
          <div className="chips">
            {history.map((h) => (
              <button key={h.login} className="chip" onClick={() => open(h.login)}>
                {h.avatar && <img src={h.avatar} alt="" />}
                <span>{h.displayName}</span>
              </button>
            ))}
          </div>
        </Section>
      )}

      <Section title="Tes chaînes en direct" count={followed.length}>
        {loading
          ? <Empty text="Chargement…" />
          : followed.length === 0
            ? <Empty text="Aucune de tes chaînes n'est en direct." />
            : <Grid streams={followed} onOpen={open} />}
      </Section>

      <Section
        title="Top des directs"
        action={
          <div className="toggle">
            <button
              className={s.topLang === 'fr' ? 'on' : ''}
              onClick={() => setSetting('topLang', 'fr')}
            >
              France
            </button>
            <button
              className={s.topLang === 'all' ? 'on' : ''}
              onClick={() => setSetting('topLang', 'all')}
            >
              Monde
            </button>
          </div>
        }
      >
        {top.length === 0 ? <Empty text="Chargement…" /> : <Grid streams={top} onOpen={open} />}
      </Section>
    </div>
  )
}

// ── Onglet Catégories ───────────────────────────────────────────────────
export function Categories({ token, onOpen }: { token: string; onOpen: (l: string) => void }) {
  const [cats, setCats] = useState<Category[]>([])
  // Une catégorie ouverte remplace la grille sur place : on revient d'un clic,
  // sans quitter l'onglet ni perdre le défilement.
  const [open, setOpen] = useState<Category | null>(null)
  const [streams, setStreams] = useState<Stream[]>([])

  useEffect(() => { void getTopCategories(token).then(setCats) }, [token])

  useEffect(() => {
    if (!open) return
    let alive = true
    setStreams([])
    void getStreamsByCategory(token, open.id).then((r) => { if (alive) setStreams(r) })
    return () => { alive = false }
  }, [token, open])

  if (open) {
    return (
      <div className="home">
        <Section
          title={open.name}
          count={streams.length}
          action={<button className="ghost sm" onClick={() => setOpen(null)}>← Catégories</button>}
        >
          {streams.length === 0
            ? <Empty text="Chargement…" />
            : <Grid streams={streams} onOpen={onOpen} />}
        </Section>
      </div>
    )
  }

  return (
    <div className="home">
      <Section title="Catégories" count={cats.length}>
        {cats.length === 0 ? <Empty text="Chargement…" /> : (
          <div className="cats">
            {cats.map((c) => (
              <button key={c.id} className="cat" onClick={() => setOpen(c)}>
                <img src={c.boxArt} alt="" loading="lazy" />
                <span>{c.name}</span>
              </button>
            ))}
          </div>
        )}
      </Section>
    </div>
  )
}

// ── Onglet Recherche ────────────────────────────────────────────────────
export function Search({ token, onOpen }: { token: string; onOpen: (l: string) => void }) {
  const [query, setQuery] = useState('')
  const [results, setResults] = useState<Stream[] | null>(null)
  const [searching, setSearching] = useState(false)

  // Recherche différée : une requête par frappe saturerait l'API pour rien.
  useEffect(() => {
    const q = query.trim()
    if (q.length < 2) { setResults(null); setSearching(false); return }
    setSearching(true)
    const id = setTimeout(() => {
      void searchChannels(token, q).then((r) => { setResults(r); setSearching(false) })
    }, 350)
    return () => clearTimeout(id)
  }, [query, token])

  return (
    <div className="home">
      <div className="home-search">
        <input
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          placeholder="Chercher une chaîne…"
          autoFocus
          autoCapitalize="none"
          autoCorrect="off"
          spellCheck={false}
        />
        {query && <button className="ghost" onClick={() => setQuery('')}>Effacer</button>}
      </div>

      {results === null
        ? <Empty text="Tape au moins deux caractères." />
        : searching
          ? <Empty text="Recherche…" />
          : results.length === 0
            ? <Empty text="Aucune chaîne en direct pour cette recherche." />
            : <Grid streams={results} onOpen={onOpen} />}
    </div>
  )
}

function Section({ title, count, action, children }: {
  title: string
  count?: number
  action?: React.ReactNode
  children: React.ReactNode
}) {
  return (
    <section className="sec">
      <div className="sec-head">
        <h2>{title}</h2>
        {count !== undefined && count > 0 && <span className="count">{count}</span>}
        <span className="spacer" />
        {action}
      </div>
      {children}
    </section>
  )
}

function Empty({ text }: { text: string }) {
  return <div className="sec-empty">{text}</div>
}

function Grid({ streams, onOpen }: { streams: Stream[]; onOpen: (login: string) => void }) {
  return (
    <div className="grid">
      {streams.map((s) => (
        <button key={s.userId + s.login} className="card" onClick={() => onOpen(s.login)}>
          <div className="thumb">
            {s.thumbnail
              ? <img src={s.thumbnail} alt="" loading="lazy" />
              : <div className="thumb-empty" />}
            <span className="live">EN DIRECT</span>
            {s.viewers > 0 && <span className="viewers">👁 {formatViewers(s.viewers)}</span>}
          </div>
          <div className="card-title">{s.title || s.displayName}</div>
          <div className="card-sub">
            <strong>{s.displayName}</strong>
            {s.game && <> · {s.game}</>}
          </div>
        </button>
      ))}
    </div>
  )
}
