// ═══════════════════════════════════════════════════════════════════════════
//  Comptage d'utilisation — à ajouter au Worker Cloudflare de TwitchUnblock.
//
//  Deux routes :
//    POST /api/ping   { id, version, platform }   → enregistre une installation
//    POST /api/ping   { id, forget: true }        → l'efface (retrait)
//    GET  /api/stats                              → compteurs agrégés
//
//  Astuce de coût : la date de dernière vue et la version sont rangées dans
//  les MÉTADONNÉES de la clé KV. list() les renvoie sans lecture supplémentaire,
//  donc /api/stats tient en un appel au lieu d'une lecture par installation.
//
//  Ce qui est stocké : un identifiant aléatoire, une date, une version.
//  Pas d'adresse IP, pas d'en-tête de requête, rien qui vienne du compte Twitch.
//  Les clés expirent d'elles-mêmes au bout de 35 jours.
// ═══════════════════════════════════════════════════════════════════════════

const RETENTION_DAYS = 35;
const PREFIX = "u:";

/** Date du jour en UTC, au format AAAA-MM-JJ. */
function today() {
  return new Date().toISOString().slice(0, 10);
}

/** Nombre de jours entre une date AAAA-MM-JJ et aujourd'hui. */
function daysAgo(dateStr) {
  const then = Date.parse(dateStr + "T00:00:00Z");
  if (Number.isNaN(then)) return Infinity;
  return Math.floor((Date.parse(today() + "T00:00:00Z") - then) / 86400000);
}

const json = (obj, status = 200) =>
  new Response(JSON.stringify(obj), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
      "Access-Control-Allow-Origin": "*",
    },
  });

// ── POST /api/ping ────────────────────────────────────────────────────────
export async function handlePing(request, env) {
  let body;
  try {
    body = await request.json();
  } catch {
    return json({ error: "bad json" }, 400);
  }

  const id = String(body.id || "");
  // On n'accepte que des UUID : pas question de laisser écrire des clés libres.
  if (!/^[0-9a-fA-F-]{36}$/.test(id)) return json({ error: "bad id" }, 400);

  if (body.forget === true) {
    await env.USAGE.delete(PREFIX + id);
    return json({ ok: true, forgotten: true });
  }

  const version = String(body.version || "?").slice(0, 16);
  const platform = String(body.platform || "ios").slice(0, 16);

  // Valeur vide : tout tient dans les métadonnées, lues par list().
  await env.USAGE.put(PREFIX + id, "", {
    expirationTtl: 60 * 60 * 24 * RETENTION_DAYS,
    metadata: { last: today(), v: version, p: platform },
  });

  return json({ ok: true });
}

// ── GET /api/stats ────────────────────────────────────────────────────────
export async function handleStats(request, env) {
  let cursor;
  let known = 0, todayCount = 0, week = 0, month = 0;
  const versions = {};

  // list() plafonne à 1000 clés par page : on pagine pour rester juste.
  do {
    const page = await env.USAGE.list({ prefix: PREFIX, limit: 1000, cursor });
    for (const key of page.keys) {
      const meta = key.metadata || {};
      const age = daysAgo(meta.last || "");
      known++;
      if (age === 0) todayCount++;
      if (age <= 7) week++;
      if (age <= 30) {
        month++;
        const v = meta.v || "?";
        versions[v] = (versions[v] || 0) + 1;
      }
    }
    cursor = page.list_complete ? undefined : page.cursor;
  } while (cursor);

  const versionList = Object.entries(versions)
    .map(([version, count]) => ({ version, count }))
    .sort((a, b) => b.count - a.count);

  return json({
    today: todayCount,
    week,
    month,
    known,
    versions: versionList,
    generatedAt: new Date().toISOString(),
  });
}

// ── Branchement dans le Worker existant ───────────────────────────────────
//  Dans le fetch() principal, avant les routes actuelles :
//
//    const url = new URL(request.url);
//    if (url.pathname === "/api/ping"  && request.method === "POST") {
//      return handlePing(request, env);
//    }
//    if (url.pathname === "/api/stats" && request.method === "GET") {
//      return handleStats(request, env);
//    }
//
//  Et dans wrangler.toml, un espace KV nommé USAGE :
//
//    [[kv_namespaces]]
//    binding = "USAGE"
//    id = "<identifiant renvoyé par: npx wrangler kv namespace create USAGE>"
