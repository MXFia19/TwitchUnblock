#!/usr/bin/env node
// ═══════════════════════════════════════════════════════════════════════════
//  Serveur local de « TU Dev » (branche dev-17d298) : reçoit les requêtes que
//  l'app lui envoie (onglet PC de la bulle → « Envoyer au PC ») et les montre
//  dans une page façon onglet Réseau d'un navigateur, en direct.
//
//    node tools/devlog/server.mjs            (port 8787)
//    node tools/devlog/server.mjs 9000       (autre port)
//
//  Au démarrage : l'adresse et le code à taper dans TU Dev. Sans ce code, le
//  serveur refuse les envois (403). La page et ses données ne s'ouvrent que
//  depuis ce PC (http://localhost:8787) : les autres appareils du Wi-Fi ne
//  peuvent qu'envoyer, avec le code. Rien n'est écrit sur le disque ; 5 000
//  requêtes gardées en mémoire. Node 18 ou plus, sans dépendance.
// ═══════════════════════════════════════════════════════════════════════════
import http from 'node:http'
import os from 'node:os'
import crypto from 'node:crypto'

const PORT = Number(process.argv[2] || process.env.PORT || 8787)
const CODE = String(crypto.randomInt(100000, 1000000))
const MAX_ENTRIES = 5000
const MAX_BODY = 64 * 1024 * 1024

const entries = []
const clients = new Set()

const isLocal = (req) => ['127.0.0.1', '::1', '::ffff:127.0.0.1'].includes(req.socket.remoteAddress)

function broadcast(event, data) {
  const payload = `${event ? `event: ${event}\n` : ''}data: ${JSON.stringify(data)}\n\n`
  for (const res of clients) res.write(payload)
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://localhost')

  // Envois de TU Dev : depuis n'importe quel appareil du réseau, avec le code.
  if (req.method === 'POST' && url.pathname === '/log') {
    if (req.headers['x-tu-code'] !== CODE) {
      res.writeHead(403, { 'Content-Type': 'text/plain' })
      return res.end('code refusé')
    }
    const chunks = []
    let size = 0
    req.on('data', (c) => {
      size += c.length
      if (size > MAX_BODY) req.destroy()
      else chunks.push(c)
    })
    req.on('end', () => {
      let list
      try {
        list = JSON.parse(Buffer.concat(chunks).toString('utf8')).entries
      } catch {
        res.writeHead(400, { 'Content-Type': 'text/plain' })
        return res.end('JSON illisible')
      }
      if (!Array.isArray(list)) list = []
      const device = String(req.socket.remoteAddress || '').replace(/^::ffff:/, '')
      for (const e of list) {
        if (e && typeof e === 'object') entries.push({ ...e, device })
      }
      if (entries.length > MAX_ENTRIES) entries.splice(0, entries.length - MAX_ENTRIES)
      broadcast(null, list.map((e) => ({ ...e, device })))
      res.writeHead(200, { 'Content-Type': 'text/plain' })
      res.end('ok')
    })
    return
  }

  // Le reste (page, flux, effacement) : ce PC seulement.
  if (!isLocal(req)) {
    res.writeHead(403, { 'Content-Type': 'text/plain' })
    return res.end('page ouverte seulement depuis ce PC (http://localhost)')
  }
  if (url.pathname === '/events') {
    res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache', Connection: 'keep-alive' })
    res.write(`event: init\ndata: ${JSON.stringify(entries)}\n\n`)
    clients.add(res)
    req.on('close', () => clients.delete(res))
    return
  }
  if (url.pathname === '/clear' && req.method === 'POST') {
    entries.length = 0
    broadcast('clear', {})
    res.writeHead(200, { 'Content-Type': 'text/plain' })
    return res.end('ok')
  }
  if (url.pathname === '/') {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' })
    return res.end(PAGE)
  }
  res.writeHead(404, { 'Content-Type': 'text/plain' })
  res.end('introuvable')
})

// Le flux ne doit pas s'endormir derrière un proxy ou un pare-feu.
setInterval(() => { for (const res of clients) res.write(': ping\n\n') }, 15000)

server.listen(PORT, '0.0.0.0', () => {
  const ips = Object.values(os.networkInterfaces()).flat()
    .filter((i) => i && i.family === 'IPv4' && !i.internal).map((i) => i.address)
  console.log('')
  console.log('  TU Dev · serveur des requêtes')
  console.log('')
  console.log('  Dans TU Dev → bulle → onglet PC :')
  for (const ip of ips.length ? ips : ['(adresse du PC sur le Wi-Fi)']) console.log(`    adresse  ${ip}:${PORT}`)
  console.log(`    code     ${CODE}`)
  console.log('')
  console.log(`  Page, sur ce PC : http://localhost:${PORT}`)
  console.log('  (Windows : autorise Node dans le pare-feu, réseaux privés. Ctrl+C pour arrêter.)')
  console.log('')
})

server.on('error', (e) => {
  console.error(e.code === 'EADDRINUSE' ? `Le port ${PORT} est déjà pris : node tools/devlog/server.mjs <autre port>` : e.message)
  process.exit(1)
})

// ── Page ────────────────────────────────────────────────────────────────────
// Tout ce qui vient de l'app s'affiche en texte (textContent), jamais en HTML :
// une réponse capturée ne peut rien exécuter dans la page.
const PAGE = String.raw`<!doctype html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>TU Dev · Réseau</title>
<style>
  :root { color-scheme: dark; --bg: #1e1e22; --panel: #26262b; --line: #3a3a42; --text: #e6e6ea; --muted: #9a9aa6; --accent: #9146ff; --ok: #4ade80; --warn: #fbbf24; --bad: #f87171; --sel: #3b3270; }
  * { box-sizing: border-box; }
  body { margin: 0; background: var(--bg); color: var(--text); font: 13px/1.4 system-ui, -apple-system, Segoe UI, sans-serif; height: 100vh; display: flex; flex-direction: column; }
  header { display: flex; flex-wrap: wrap; align-items: center; gap: 8px; padding: 8px 12px; border-bottom: 1px solid var(--line); background: var(--panel); }
  header h1 { font-size: 14px; margin: 0 8px 0 0; }
  .dot { width: 9px; height: 9px; border-radius: 50%; background: var(--bad); display: inline-block; }
  .dot.on { background: var(--ok); }
  input[type=search] { background: var(--bg); color: var(--text); border: 1px solid var(--line); border-radius: 6px; padding: 5px 8px; width: 240px; }
  button { background: var(--bg); color: var(--text); border: 1px solid var(--line); border-radius: 6px; padding: 4px 10px; cursor: pointer; font: inherit; }
  button:hover { border-color: var(--accent); }
  .chip.on { background: var(--accent); border-color: var(--accent); color: #fff; }
  #count { color: var(--muted); margin-left: auto; }
  main { flex: 1; display: flex; min-height: 0; }
  #list { flex: 1; overflow: auto; }
  table { width: 100%; border-collapse: collapse; table-layout: fixed; }
  th, td { padding: 4px 8px; border-bottom: 1px solid var(--line); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; text-align: left; }
  th { position: sticky; top: 0; background: var(--panel); color: var(--muted); font-weight: 600; }
  tbody tr { cursor: pointer; }
  tbody tr:hover { background: #2c2c33; }
  tbody tr.sel { background: var(--sel); }
  tr.failed td.name { color: var(--bad); }
  td.num { text-align: right; font-variant-numeric: tabular-nums; }
  td.st.ok { color: var(--ok); } td.st.warn { color: var(--warn); } td.st.bad { color: var(--bad); }
  aside { width: 48%; min-width: 360px; border-left: 1px solid var(--line); display: flex; flex-direction: column; background: var(--panel); }
  aside[hidden] { display: none; }
  .dhead { display: flex; align-items: center; gap: 8px; padding: 8px 12px; border-bottom: 1px solid var(--line); }
  .dhead strong { flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .tabs { display: flex; gap: 4px; padding: 6px 12px; border-bottom: 1px solid var(--line); flex-wrap: wrap; }
  .tab.on { background: var(--accent); border-color: var(--accent); color: #fff; }
  #dbody { flex: 1; overflow: auto; padding: 10px 12px; }
  .kv { display: grid; grid-template-columns: 170px 1fr; gap: 4px 12px; margin-bottom: 14px; }
  .kv .k { color: var(--muted); word-break: break-all; }
  .kv .v { word-break: break-all; user-select: text; }
  h3 { font-size: 12px; color: var(--muted); text-transform: uppercase; letter-spacing: .04em; margin: 10px 0 6px; }
  pre { margin: 0; white-space: pre-wrap; word-break: break-word; font: 12px/1.45 ui-monospace, Consolas, monospace; user-select: text; }
  .empty { color: var(--muted); padding: 24px; }
</style>
</head>
<body>
<header>
  <h1>TU Dev · Réseau</h1>
  <span class="dot" id="dot" title="Liaison avec le serveur"></span>
  <input type="search" id="q" placeholder="Filtrer (adresse, nom)">
  <span id="chips"></span>
  <button id="pause">Pause</button>
  <button id="clear">Effacer</button>
  <span id="count"></span>
</header>
<main>
  <div id="list">
    <table>
      <colgroup><col style="width:30%"><col style="width:8%"><col style="width:9%"><col style="width:23%"><col style="width:10%"><col style="width:10%"><col style="width:10%"></colgroup>
      <thead><tr><th>Nom</th><th>Statut</th><th>Type</th><th>Hôte</th><th class="num">Taille</th><th class="num">Durée</th><th class="num">Heure</th></tr></thead>
      <tbody id="rows"></tbody>
    </table>
    <div class="empty" id="empty">En attente de TU Dev : allume « Envoyer au PC » dans l'onglet PC de la bulle.</div>
  </div>
  <aside id="detail" hidden>
    <div class="dhead"><strong id="dtitle"></strong><button id="copyUrl">Copier l'adresse</button><button id="copyCurl">Copier en cURL</button><button id="close">✕</button></div>
    <div class="tabs" id="tabs"></div>
    <div id="dbody"></div>
  </aside>
</main>
<script>
const KINDS = ['Tout', 'GQL', 'Playlist', 'Worker', 'Proxy', 'Helix', 'Images', 'Autre', 'Erreurs']
const TABS = ['Général', 'En-têtes', 'Requête', 'Réponse']
const $ = (id) => document.getElementById(id)
const rows = $('rows'), list = $('list')
let all = [], held = [], paused = false, kind = 'Tout', query = '', selected = null, tab = 'Général'

const el = (tag, cls, text) => { const n = document.createElement(tag); if (cls) n.className = cls; if (text != null) n.textContent = String(text); return n }
const failed = (e) => (e.error && e.error !== 'annulée') || (e.status || 0) >= 400
const size = (b) => { if (!b) return '0 o'; const u = ['o', 'Ko', 'Mo', 'Go']; let i = 0; while (b >= 1024 && i < 3) { b /= 1024; i++ } return (i ? b.toFixed(1) : b) + ' ' + u[i] }
const dur = (ms) => ms == null ? '…' : ms < 1000 ? Math.round(ms) + ' ms' : (ms / 1000).toFixed(2) + ' s'
const host = (u) => { try { return new URL(u).host } catch { return '' } }
const statusText = (e) => e.error === 'annulée' ? 'annulée' : e.error ? 'erreur' : e.status != null ? String(e.status) : '—'
const statusClass = (e) => e.error === 'annulée' ? 'warn' : (e.error || (e.status || 0) >= 400) ? 'bad' : (e.status || 0) >= 300 ? 'warn' : 'ok'
const visible = (e) => {
  if (kind === 'Erreurs' ? !failed(e) : kind !== 'Tout' && e.kind !== kind) return false
  return !query || String(e.url).toLowerCase().includes(query) || String(e.name || '').toLowerCase().includes(query)
}

function row(e) {
  const tr = el('tr')
  if (failed(e)) tr.classList.add('failed')
  if (e === selected) tr.classList.add('sel')
  tr.append(el('td', 'name', e.name || e.url), el('td', 'st ' + statusClass(e), statusText(e)), el('td', null, e.kind || ''),
    el('td', null, host(e.url)), el('td', 'num', size(e.bytes)), el('td', 'num', dur(e.duration)),
    el('td', 'num', new Date(e.started).toLocaleTimeString()))
  tr.title = e.url
  tr.onclick = () => { selected = e; render(); show() }
  return tr
}

function counts() {
  const shown = all.filter(visible).length
  const bytes = all.reduce((n, e) => n + (Number(e.bytes) || 0), 0)
  $('count').textContent = shown + ' / ' + all.length + ' requêtes · ' + size(bytes) + (paused ? ' · en pause (' + held.length + ' en attente)' : '')
  $('empty').hidden = all.length > 0
}

function render() { rows.replaceChildren(...all.filter(visible).map(row)); counts() }

function add(batch) {
  const atBottom = list.scrollTop + list.clientHeight >= list.scrollHeight - 40
  for (const e of batch) { all.push(e); if (visible(e)) rows.append(row(e)) }
  if (all.length > 5000) { all.splice(0, all.length - 5000); render() }
  counts()
  if (atBottom) list.scrollTop = list.scrollHeight
}

for (const k of KINDS) {
  const b = el('button', 'chip' + (k === kind ? ' on' : ''), k)
  b.onclick = () => { kind = k; for (const c of $('chips').children) c.classList.toggle('on', c.textContent === k); render() }
  $('chips').append(b)
}
$('q').oninput = (ev) => { query = ev.target.value.trim().toLowerCase(); render() }
$('pause').onclick = () => {
  paused = !paused
  $('pause').textContent = paused ? 'Reprendre' : 'Pause'
  if (!paused && held.length) { const h = held; held = []; add(h) }
  counts()
}
$('clear').onclick = () => fetch('/clear', { method: 'POST' })
$('close').onclick = () => { selected = null; $('detail').hidden = true; render() }

function bodyText(b) {
  if (!b) return '(vide)'
  if (b.base64) return 'binaire (' + Math.round(b.base64.length * 3 / 4) + ' octets)'
  try { return JSON.stringify(JSON.parse(b.text), null, 2) } catch { return b.text }
}

function kv(pairs) {
  const box = el('div', 'kv')
  for (const [k, v] of pairs) if (v != null && v !== '') box.append(el('div', 'k', k), el('div', 'v', v))
  return box
}

function curl(e) {
  const parts = ["curl -X " + e.method + " '" + e.url + "'"]
  for (const [k, v] of Object.entries(e.requestHeaders || {})) parts.push("-H '" + k + ': ' + v + "'")
  if (e.requestBody && e.requestBody.text) parts.push("--data-raw '" + e.requestBody.text.replace(/'/g, "'\\''") + "'")
  return parts.join(' \\\n  ')
}

function show() {
  const e = selected
  if (!e) return
  $('detail').hidden = false
  $('dtitle').textContent = e.name || e.url
  $('tabs').replaceChildren(...TABS.map((t) => { const b = el('button', 'tab' + (t === tab ? ' on' : ''), t); b.onclick = () => { tab = t; show() }; return b }))
  const box = $('dbody')
  box.replaceChildren()
  if (tab === 'Général') {
    box.append(kv([
      ['Adresse', e.url], ['Adresse finale', e.finalURL], ['Méthode', e.method], ['Statut', e.status],
      ['Erreur', e.error], ['Type', [e.kind, e.mime].filter(Boolean).join(' · ')], ['Taille', size(e.bytes)],
      ['Durée', dur(e.duration)], ['Heure', new Date(e.started).toLocaleString()], ['Opération GQL', e.gql],
      ['Réponse tronquée', e.truncated ? 'oui (512 Ko gardés)' : ''], ['Appareil', e.device],
    ]))
  } else if (tab === 'En-têtes') {
    box.append(el('h3', null, 'Requête'), kv(Object.entries(e.requestHeaders || {}).sort()))
    box.append(el('h3', null, 'Réponse'), kv(Object.entries(e.responseHeaders || {}).sort()))
  } else {
    const b = tab === 'Requête' ? e.requestBody : e.responseBody
    const copy = el('button', null, 'Copier')
    copy.onclick = () => navigator.clipboard.writeText(bodyText(b))
    box.append(copy, el('h3', null, tab === 'Requête' ? 'Corps de la requête' : 'Corps de la réponse'), el('pre', null, bodyText(b)))
  }
}
$('copyUrl').onclick = () => selected && navigator.clipboard.writeText(selected.url)
$('copyCurl').onclick = () => selected && navigator.clipboard.writeText(curl(selected))

const source = new EventSource('/events')
source.addEventListener('init', (ev) => { all = []; held = []; add(JSON.parse(ev.data)); render(); $('dot').classList.add('on') })
source.addEventListener('clear', () => { all = []; held = []; selected = null; $('detail').hidden = true; render() })
source.onmessage = (ev) => { const batch = JSON.parse(ev.data); if (paused) { held.push(...batch); counts() } else add(batch) }
source.onerror = () => $('dot').classList.remove('on')
source.onopen = () => $('dot').classList.add('on')
counts()
</script>
</body>
</html>`
