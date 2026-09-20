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

type Lang = 'fr' | 'all'

export function Home({ token, userId, onOpen }: Props) {
  const [followed, setFollowed] = useState<Stream[]>([])
  const [top, setTop] = useState<Stream[]>([])
  const [lang, setLang] = useState<Lang>('fr')
  const [categories, setCategories] = useState<Category[]>([])
  const [history, setHistory] = useState<HistoryEntry[]>(readHistory)
  const [loading, setLoading] = useState(true)

  // Catégorie ouverte : on remplace la grille du haut par ses directs plutôt
  // que d'ouvrir une page — on revient d'un clic.
  const [openCat, setOpenCat] = useState<Category | null>(null)
  const [catStreams, setCatStreams] = useState<Stream[]>([])

  const [query, setQuery] = useState('')
  const [results, setResults] = useState<Stream[] | null>(null)

  useEffect(() => {
    let alive = true
    void (async () => {
      setLoading(true)
      const [f, c] = await Promise.all([
        getFollowedStreams(token, userId),
        getTopCategories(token),
      ])
      if (!alive) return
      setFollowed(f)
      setCategories(c)
      setLoading(false)
    })()
    return () => { alive = false }
  }, [token, userId])

  useEffect(() => {
    let alive = true
    void (async () => {
      const t = await getTopStreams(token, lang === 'fr' ? 'fr' : null)
      if (alive) setTop(t)
    })()
    return () => { alive = false }
  }, [token, lang])

  // Recherche différée : une requête par frappe saturerait l'API pour rien.
  useEffect(() => {
    const q = query.trim()
    if (q.length < 2) { setResults(null); return }
    const id = setTimeout(() => {
      void searchChannels(token, q).then(setResults)
    }, 350)
    return () => clearTimeout(id)
  }, [query, token])

  function open(login: string) {
    onOpen(login)
    // L'historique est écrit par le parent une fois la chaîne résolue ; ici on
    // se contente de le relire au retour.
    setTimeout(() => setHistory(readHistory()), 0)
  }

  async function openCategory(cat: Category) {
    setOpenCat(cat)
    setCatStreams([])
    setCatStreams(await getStreamsByCategory(token, cat.id))
  }

  return (
    <div className="home">
      <div className="home-search">
        <input
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          placeholder="Chercher une chaîne…"
          autoCapitalize="none"
          autoCorrect="off"
          spellCheck={false}
        />
        {query && <button className="ghost" onClick={() => setQuery('')}>Effacer</button>}
      </div>

      {results !== null && (
        <Section title="Résultats" count={results.length}>
          {results.length === 0
            ? <Empty text="Aucune chaîne en direct pour cette recherche." />
            : <Grid streams={results} onOpen={open} />}
        </Section>
      )}

      {results === null && (
        <>
          {history.length > 0 && (
            <Section
              title="Repris récemment"
              action={
                <button
                  className="ghost sm"
                  onClick={() => { clearHistory(); setHistory([]) }}
                >
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

          {openCat ? (
            <Section
              title={openCat.name}
              count={catStreams.length}
              action={
                <button className="ghost sm" onClick={() => setOpenCat(null)}>
                  ← Retour
                </button>
              }
            >
              {catStreams.length === 0
                ? <Empty text="Chargement…" />
                : <Grid streams={catStreams} onOpen={open} />}
            </Section>
          ) : (
            <>
              <Section
                title="Top des directs"
                action={
                  <div className="toggle">
                    <button
                      className={lang === 'fr' ? 'on' : ''}
                      onClick={() => setLang('fr')}
                    >
                      France
                    </button>
                    <button
                      className={lang === 'all' ? 'on' : ''}
                      onClick={() => setLang('all')}
                    >
                      Monde
                    </button>
                  </div>
                }
              >
                {top.length === 0
                  ? <Empty text="Chargement…" />
                  : <Grid streams={top} onOpen={open} />}
              </Section>

              <Section title="Catégories">
                <div className="cats">
                  {categories.map((c) => (
                    <button key={c.id} className="cat" onClick={() => void openCategory(c)}>
                      <img src={c.boxArt} alt="" loading="lazy" />
                      <span>{c.name}</span>
                    </button>
                  ))}
                </div>
              </Section>
            </>
          )}
        </>
      )}
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
