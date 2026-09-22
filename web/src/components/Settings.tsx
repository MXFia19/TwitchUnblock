import { DEFAULTS, resetSettings, setSetting, useSettings, type Settings as S } from '../lib/settings'
import { clearHistory } from '../lib/discover'
import { ChatRow } from './Chat'
import type { ChatMessage } from '../lib/message'

// ═══════════════════════════════════════════════════════════════════════════
//  Réglages. Sections de SettingsView.swift, moins ce qui n'a pas de sens ici
//  (points de chaîne, minuteur de veille, cache d'images géré par le
//  navigateur).
// ═══════════════════════════════════════════════════════════════════════════

const PREVIEW: ChatMessage[] = [
  {
    id: 'p1', userId: '0', userName: 'lewdolas', displayName: 'Lewdolas',
    color: '#e6b800', badges: [],
    tokens: [{ kind: 'text', value: "ça va y'a des sourires" }],
    timestamp: Date.now(), isAction: false, isHighlight: false,
    isFirstMessage: false, replyTo: null, replyBody: null, systemMsg: null,
    isHistorical: false, isDeleted: false,
  },
  {
    id: 'p2', userId: '0', userName: 'damonarix', displayName: 'Damonarix',
    color: '#4da6ff', badges: [],
    tokens: [
      { kind: 'text', value: "L'honnêteté d'un Skaven" },
      { kind: 'mention', value: 'toi' },
    ],
    timestamp: Date.now(), isAction: false, isHighlight: false,
    isFirstMessage: false, replyTo: null, replyBody: null, systemMsg: null,
    isHistorical: true, isDeleted: false,
  },
]

export function Settings({ onClose }: { onClose: () => void }) {
  const s = useSettings()

  return (
    <div className="settings">
      <div className="set-head">
        <h1>Réglages</h1>
        <span className="spacer" />
        <button className="ghost" onClick={onClose}>Fermer</button>
      </div>

      <Card title="Apparence du chat" icon="💬">
        {/* Aperçu rendu par le vrai composant de message : ce qu'on voit ici
            est exactement ce que donnera le chat. */}
        <div className="set-preview" style={{ fontSize: s.chatFontSize }}>
          {PREVIEW.map((m) => (
            <ChatRow key={m.id} msg={m} showTimestamp={s.chatTimestamps} spacing={s.chatSpacing} />
          ))}
        </div>

        <Toggle
          label="Horodatage"
          hint="Affiche l'heure devant chaque message."
          k="chatTimestamps"
          v={s.chatTimestamps}
        />
        <Slider label="Taille du texte" k="chatFontSize" v={s.chatFontSize}
                min={10} max={20} step={1} fmt={(n) => `${n} px`} />
        <Slider label="Espace entre messages" k="chatSpacing" v={s.chatSpacing}
                min={0} max={16} step={1} fmt={(n) => `${n} px`} />
        <Slider label="Taille des badges" k="chatBadgeScale" v={s.chatBadgeScale}
                min={0.5} max={2} step={0.05} fmt={(n) => `${n.toFixed(2)}×`} />
        <Slider label="Taille des emotes" k="chatEmoteScale" v={s.chatEmoteScale}
                min={0.5} max={2} step={0.05} fmt={(n) => `${n.toFixed(2)}×`} />
        <Slider label="Largeur du chat" k="chatRatio" v={s.chatRatio}
                min={0.2} max={0.6} step={0.01} fmt={(n) => `${Math.round(n * 100)} %`} />
      </Card>

      <Card title="Comportement du chat" icon="⚙️">
        <Toggle
          label="Charger les messages récents"
          hint="Twitch n'envoie rien d'antérieur à ton arrivée. Les dernières lignes sont récupérées auprès de recent-messages.robotty.de, un service tiers."
          k="chatLoadRecent"
          v={s.chatLoadRecent}
        />
        <Toggle
          label="Autocomplétion"
          hint="Propose des emotes pendant la frappe."
          k="chatAutocomplete"
          v={s.chatAutocomplete}
        />
        <Toggle
          label="Afficher les messages supprimés"
          hint="Garde barrés les messages retirés par la modération au lieu de les faire disparaître."
          k="chatShowDeleted"
          v={s.chatShowDeleted}
        />
        <p className="set-note">
          Ces trois réglages s'appliquent à la prochaine chaîne ouverte.
        </p>
      </Card>

      <Card title="Lecteur" icon="▶">
        <Toggle
          label="Mode faible latence"
          hint="Colle au plus près du direct. Sur une connexion instable, l'image peut saccader — c'est le compromis."
          k="lowLatency"
          v={s.lowLatency}
        />
        <Row label="Qualité par défaut">
          <select
            className="quality"
            value={s.defaultQuality}
            onChange={(e) => setSetting('defaultQuality', e.target.value)}
          >
            <option value="">Meilleure disponible</option>
            <option value="1080p60">1080p60</option>
            <option value="720p60">720p60</option>
            <option value="720p">720p</option>
            <option value="480p">480p</option>
            <option value="360p">360p</option>
            <option value="160p">160p</option>
          </select>
        </Row>
        <p className="set-note">
          Si la qualité choisie n'existe pas sur une chaîne, la meilleure
          disponible est utilisée.
        </p>
      </Card>

      <Card title="Données locales" icon="🗄">
        <p className="set-note">
          Tout reste sur cet appareil : réglages, historique et jeton de
          connexion. Rien n'est envoyé ailleurs.
        </p>
        <div className="set-actions">
          <button className="ghost" onClick={() => clearHistory()}>
            Effacer l'historique
          </button>
          <button className="ghost" onClick={resetSettings}>
            Rétablir les réglages par défaut
          </button>
        </div>
      </Card>
    </div>
  )
}

function Card({ title, icon, children }: {
  title: string
  icon: string
  children: React.ReactNode
}) {
  return (
    <section className="set-card">
      <h2><span className="set-icon">{icon}</span>{title}</h2>
      {children}
    </section>
  )
}

function Row({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="set-row">
      <span className="set-label">{label}</span>
      <span className="spacer" />
      {children}
    </div>
  )
}

function Toggle({ label, hint, k, v }: {
  label: string
  hint?: string
  k: keyof S
  v: boolean
}) {
  return (
    <div className="set-row">
      <span className="set-text">
        <span className="set-label">{label}</span>
        {hint && <span className="set-hint">{hint}</span>}
      </span>
      <span className="spacer" />
      <button
        className={`switch${v ? ' on' : ''}`}
        role="switch"
        aria-checked={v}
        aria-label={label}
        onClick={() => setSetting(k, !v as never)}
      >
        <span />
      </button>
    </div>
  )
}

function Slider({ label, k, v, min, max, step, fmt }: {
  label: string
  k: keyof S
  v: number
  min: number
  max: number
  step: number
  fmt: (n: number) => string
}) {
  return (
    <div className="set-slider">
      <div className="set-row">
        <span className="set-label">{label}</span>
        <span className="spacer" />
        <span className="set-value">{fmt(v)}</span>
      </div>
      <input
        type="range"
        min={min} max={max} step={step} value={v}
        aria-label={label}
        onChange={(e) => setSetting(k, Number(e.target.value) as never)}
      />
    </div>
  )
}

export { DEFAULTS }
