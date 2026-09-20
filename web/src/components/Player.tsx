import Hls from 'hls.js'
import { useEffect, useRef, useState } from 'react'
import { sortQualities, type QualityLinks } from '../lib/stream'

// ═══════════════════════════════════════════════════════════════════════════
//  Lecteur HLS, deux chemins selon le navigateur.
//
//  • Chrome, Firefox, Edge, Safari macOS : hls.js via Media Source Extensions.
//    On garde la main sur le buffer, donc sur la latence et le rattrapage.
//
//  • Safari iOS : pas de MSE pour la vidéo. hls.js y est inutilisable, on passe
//    l'URL directement à <video> et c'est Safari qui décode. Ça marche, mais la
//    latence n'est plus pilotable — d'où l'absence du bouton « direct » dans ce
//    cas, plutôt qu'un bouton qui ne ferait rien.
// ═══════════════════════════════════════════════════════════════════════════

interface Props {
  links: QualityLinks
  lowLatency: boolean
  onLatency?: (seconds: number | null) => void
}

export function Player({ links, lowLatency, onLatency }: Props) {
  const videoRef = useRef<HTMLVideoElement>(null)
  const hlsRef = useRef<Hls | null>(null)
  const [quality, setQuality] = useState<string>('')
  const [error, setError] = useState<string | null>(null)
  const [paused, setPaused] = useState(false)

  const qualities = sortQualities(Object.keys(links))
  const current = quality && links[quality] ? quality : (qualities[0] ?? '')
  const src = current ? links[current] : undefined

  const usingHls = Hls.isSupported()

  useEffect(() => {
    const video = videoRef.current
    if (!video || !src) return
    setError(null)

    if (usingHls) {
      const hls = new Hls({
        lowLatencyMode: lowLatency,
        // Marge volontairement large. Viser le bord du direct en permanence
        // fait caler dès que le réseau hésite — c'est exactement le bug de
        // « mode faible latence » corrigé côté iOS.
        liveSyncDurationCount: lowLatency ? 2 : 3,
        backBufferLength: 90,
      })
      hlsRef.current = hls
      hls.loadSource(src)
      hls.attachMedia(video)
      hls.on(Hls.Events.MANIFEST_PARSED, () => { void video.play().catch(() => {}) })
      hls.on(Hls.Events.ERROR, (_e, data) => {
        if (!data.fatal) return
        // Une erreur réseau ou média se rattrape ; le reste est terminal.
        if (data.type === Hls.ErrorTypes.NETWORK_ERROR) hls.startLoad()
        else if (data.type === Hls.ErrorTypes.MEDIA_ERROR) hls.recoverMediaError()
        else { setError('Lecture interrompue'); hls.destroy() }
      })
      return () => { hls.destroy(); hlsRef.current = null }
    }

    // Chemin natif (Safari iOS).
    video.src = src
    void video.play().catch(() => {})
    return () => { video.removeAttribute('src'); video.load() }
  }, [src, lowLatency, usingHls])

  // Latence : écart entre l'heure réelle et l'horodatage du segment lu
  // (EXT-X-PROGRAM-DATE-TIME). Même mesure que côté iOS.
  useEffect(() => {
    if (!onLatency) return
    const id = setInterval(() => {
      const hls = hlsRef.current
      if (!hls) { onLatency(null); return }
      const drift = hls.latency
      onLatency(Number.isFinite(drift) && drift > 0 ? drift : null)
    }, 1000)
    return () => clearInterval(id)
  }, [onLatency])

  function togglePlay() {
    const v = videoRef.current
    if (!v) return
    if (v.paused) { void v.play().catch(() => {}); setPaused(false) }
    else { v.pause(); setPaused(true) }
  }

  function goLive() {
    const hls = hlsRef.current
    const v = videoRef.current
    if (!hls || !v) return
    // liveSyncPosition est le point que hls.js considère comme « le direct ».
    const target = hls.liveSyncPosition
    if (typeof target === 'number' && Number.isFinite(target)) v.currentTime = target
    void v.play().catch(() => {})
    setPaused(false)
  }

  async function togglePiP() {
    const v = videoRef.current
    if (!v) return
    try {
      if (document.pictureInPictureElement) await document.exitPictureInPicture()
      else await v.requestPictureInPicture()
    } catch {
      // Refusé (réglage navigateur, ou pas de piste vidéo) : sans conséquence.
    }
  }

  return (
    <div className="player">
      <video
        ref={videoRef}
        className="player-video"
        playsInline
        autoPlay
        controls={false}
        onClick={togglePlay}
      />

      {error && <div className="player-error">{error}</div>}

      <div className="player-bar">
        <button className="icon-btn" onClick={togglePlay} title={paused ? 'Lire' : 'Pause'}>
          {paused ? '▶' : '❚❚'}
        </button>

        {usingHls && (
          <button className="icon-btn" onClick={goLive} title="Revenir au direct">
            ● DIRECT
          </button>
        )}

        <span className="spacer" />

        {qualities.length > 1 && (
          <select
            className="quality"
            value={current}
            onChange={(e) => setQuality(e.target.value)}
          >
            {qualities.map((q) => (
              <option key={q} value={q}>{q}</option>
            ))}
          </select>
        )}

        {'pictureInPictureEnabled' in document && (
          <button className="icon-btn" onClick={() => void togglePiP()} title="Image dans l'image">
            ⧉
          </button>
        )}
      </div>
    </div>
  )
}
