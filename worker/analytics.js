// ═══════════════════════════════════════════════════════════════════════════
//  Comptage d'utilisation — à coller dans le Worker TwitchUnblock existant.
//
//  Écrit pour TON worker tel qu'il est aujourd'hui :
//    • il expose déjà un KV lié sous le nom `TWITCH_DATA` (routes /api/sync)
//      → on le réutilise, rien de nouveau à créer côté Cloudflare ;
//    • son routage est un `switch (url.pathname)` → deux `case` à ajouter ;
//    • il a déjà `jsonResponse()` et `jsonError()` → on s'en sert.
//
//  Les clés du comptage sont préfixées `usage_`, celles de la sync `user_` :
//  aucun risque de collision, et `list({ prefix: "usage_" })` ne voit que les
//  siennes.
//
//  Ce qui est stocké : un identifiant aléatoire, une date, une version.
//  Pas d'adresse IP, pas d'en-tête de requête, rien qui vienne du compte Twitch.
//  Les clés expirent d'elles-mêmes au bout de 35 jours.
// ═══════════════════════════════════════════════════════════════════════════

// ──────────────────────────────────────────────────────────────────────────
//  1. Dans le `switch (url.pathname)` du fetch(), ajoute ces deux cas
//     à côté des routes /api/sync :
//
//        case "/api/ping":
//          return await handlePing(request, env);
//        case "/api/stats":
//          return await handleStats(env);
//
//  2. Colle tout ce qui suit à la fin du fichier, avant le bloc `export`.
//     Les `__name(...)` de ton fichier viennent du bundler : inutile d'en
//     ajouter pour ces fonctions.
// ──────────────────────────────────────────────────────────────────────────

var USAGE_PREFIX = "usage_";
var USAGE_RETENTION_DAYS = 35;

// ── POST /api/ping ────────────────────────────────────────────────────────
//  { id, version, platform }  → enregistre l'installation
//  { id, forget: true }       → l'efface
async function handlePing(request, env) {
  if (request.method !== "POST") return jsonError("Method Not Allowed", 405);
  if (!env.TWITCH_DATA) return jsonError("KV 'TWITCH_DATA' non lié au Worker.", 500);

  let body;
  try {
    body = await request.json();
  } catch (e) {
    return jsonError("JSON invalide", 400);
  }

  // On n'accepte que des UUID : pas question de laisser écrire des clés libres.
  const id = String(body.id || "");
  if (!/^[0-9a-fA-F-]{36}$/.test(id)) return jsonError("ID invalide", 400);

  if (body.forget === true) {
    await env.TWITCH_DATA.delete(USAGE_PREFIX + id);
    return jsonResponse({ ok: true, forgotten: true });
  }

  // Valeur vide : tout tient dans les métadonnées, que list() renvoie
  // sans lecture supplémentaire (voir handleStats).
  await env.TWITCH_DATA.put(USAGE_PREFIX + id, "", {
    expirationTtl: 60 * 60 * 24 * USAGE_RETENTION_DAYS,
    metadata: {
      last: new Date().toISOString().slice(0, 10),
      v: String(body.version || "?").slice(0, 16),
      p: String(body.platform || "ios").slice(0, 16)
    }
  });

  return jsonResponse({ ok: true });
}

// ── GET /api/stats ────────────────────────────────────────────────────────
async function handleStats(env) {
  if (!env.TWITCH_DATA) return jsonError("KV 'TWITCH_DATA' non lié au Worker.", 500);

  const todayMs = Date.parse(new Date().toISOString().slice(0, 10) + "T00:00:00Z");
  let cursor, known = 0, today = 0, week = 0, month = 0;
  const versions = {};

  // list() plafonne à 1000 clés par page : on pagine pour rester juste.
  do {
    const page = await env.TWITCH_DATA.list({
      prefix: USAGE_PREFIX,
      limit: 1000,
      cursor
    });

    for (const key of page.keys) {
      const meta = key.metadata || {};
      const then = Date.parse((meta.last || "") + "T00:00:00Z");
      const age = Number.isNaN(then) ? Infinity : Math.floor((todayMs - then) / 86400000);

      known++;
      if (age === 0) today++;
      if (age <= 7) week++;
      if (age <= 30) {
        month++;
        const v = meta.v || "?";
        versions[v] = (versions[v] || 0) + 1;
      }
    }

    cursor = page.list_complete ? undefined : page.cursor;
  } while (cursor);

  const payload = {
    today,
    week,
    month,
    known,
    versions: Object.entries(versions)
      .map(([version, count]) => ({ version, count }))
      .sort((a, b) => b.count - a.count),
    generatedAt: new Date().toISOString()
  };

  // no-store : sans ça, une réponse peut être resservie telle quelle et le
  // bouton « Actualiser » de l'app afficherait deux fois les mêmes chiffres.
  return new Response(JSON.stringify(payload), {
    headers: {
      ...RESPONSE_HEADERS,
      "Content-Type": "application/json",
      "Cache-Control": "no-store"
    }
  });
}
