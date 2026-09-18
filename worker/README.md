# Comptage d'utilisation — mise en service

Deux routes à ajouter au Worker Cloudflare déjà utilisé par l'app
(`https://test2.kurzmathis4.workers.dev`) :

| Route | Rôle |
|---|---|
| `POST /api/ping` | Enregistre — ou efface — une installation |
| `GET /api/stats` | Renvoie les compteurs agrégés |

Tant qu'elles ne répondent pas, la carte « Utilisation de l'app » des Réglages
affiche « le serveur n'a pas encore les routes de comptage ». Le reste de l'app
est indifférent : aucun risque à déployer plus tard, ou jamais.

Suis **la voie A** si tu modifies ton Worker dans l'éditeur en ligne de
Cloudflare, **la voie B** si tu as un projet local avec `wrangler`.

---

## Étape 1 — Créer le stockage KV

Le comptage a besoin d'un espace KV. Une seule fois.

**Tableau de bord** : Cloudflare → *Storage & Databases* → *KV* → *Create a
namespace* → nom : `USAGE` → *Add*.

**En ligne de commande** :

```sh
npx wrangler kv namespace create USAGE
```

La commande affiche un `id` : garde-le pour l'étape 2B.

> **Si ton Worker a déjà un espace KV** (celui qui sert `/api/sync`), tu peux le
> réutiliser au lieu d'en créer un : passe directement à l'étape 2 et remplace
> partout `env.USAGE` par le nom de ton binding existant. Les clés du comptage
> sont préfixées `u:`, elles ne peuvent pas entrer en collision avec les tiennes.

---

## Étape 2 — Lier l'espace au Worker sous le nom `USAGE`

C'est ce qui rend `env.USAGE` disponible dans le code.

### Voie A — tableau de bord

*Workers & Pages* → ton Worker → *Settings* → *Bindings* → *Add binding* →
*KV namespace* :

- **Variable name** : `USAGE`
- **KV namespace** : celui créé à l'étape 1

### Voie B — wrangler

Dans `wrangler.toml` :

```toml
[[kv_namespaces]]
binding = "USAGE"
id = "<l'id renvoyé à l'étape 1>"
```

---

## Étape 3 — Ajouter le code

### Voie A — tableau de bord (un seul fichier)

L'éditeur en ligne ne gère pas les `import` entre fichiers. Colle le bloc
ci-dessous **tel quel** à la fin de ton Worker, puis passe à l'étape 4.

```js
// ─── Comptage d'utilisation ───────────────────────────────────────────────
const USAGE_PREFIX = "u:";
const USAGE_RETENTION_DAYS = 35;

function usageToday() {
  return new Date().toISOString().slice(0, 10);
}

function usageDaysAgo(dateStr) {
  const then = Date.parse(dateStr + "T00:00:00Z");
  if (Number.isNaN(then)) return Infinity;
  return Math.floor((Date.parse(usageToday() + "T00:00:00Z") - then) / 86400000);
}

function usageJson(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
      "Access-Control-Allow-Origin": "*",
    },
  });
}

async function handlePing(request, env) {
  let body;
  try {
    body = await request.json();
  } catch {
    return usageJson({ error: "bad json" }, 400);
  }

  const id = String(body.id || "");
  // On n'accepte que des UUID : pas question de laisser écrire des clés libres.
  if (!/^[0-9a-fA-F-]{36}$/.test(id)) return usageJson({ error: "bad id" }, 400);

  if (body.forget === true) {
    await env.USAGE.delete(USAGE_PREFIX + id);
    return usageJson({ ok: true, forgotten: true });
  }

  await env.USAGE.put(USAGE_PREFIX + id, "", {
    expirationTtl: 60 * 60 * 24 * USAGE_RETENTION_DAYS,
    metadata: {
      last: usageToday(),
      v: String(body.version || "?").slice(0, 16),
      p: String(body.platform || "ios").slice(0, 16),
    },
  });
  return usageJson({ ok: true });
}

async function handleStats(request, env) {
  let cursor;
  let known = 0, today = 0, week = 0, month = 0;
  const versions = {};

  do {
    const page = await env.USAGE.list({ prefix: USAGE_PREFIX, limit: 1000, cursor });
    for (const key of page.keys) {
      const meta = key.metadata || {};
      const age = usageDaysAgo(meta.last || "");
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

  return usageJson({
    today, week, month, known,
    versions: Object.entries(versions)
      .map(([version, count]) => ({ version, count }))
      .sort((a, b) => b.count - a.count),
    generatedAt: new Date().toISOString(),
  });
}
```

### Voie B — wrangler

Copie `analytics.js` à côté de ton Worker, puis en haut du fichier principal :

```js
import { handlePing, handleStats } from "./analytics.js";
```

---

## Étape 4 — Brancher les routes

Dans le `fetch()` principal, **avant** tes routes existantes :

```js
const url = new URL(request.url);

if (url.pathname === "/api/ping" && request.method === "POST") {
  return handlePing(request, env);
}
if (url.pathname === "/api/stats" && request.method === "GET") {
  return handleStats(request, env);
}
```

Si ton `fetch()` construit déjà un `const url = new URL(request.url)`, réutilise-le
plutôt que de le déclarer deux fois — sinon le Worker refusera de démarrer.

---

## Étape 5 — Déployer et vérifier

**Tableau de bord** : bouton *Deploy*.
**wrangler** : `npx wrangler deploy`.

Puis, depuis n'importe quel terminal :

```sh
curl https://test2.kurzmathis4.workers.dev/api/stats
```

Réponse attendue au premier lancement, avant tout ping :

```json
{"today":0,"week":0,"month":0,"known":0,"versions":[],"generatedAt":"…"}
```

Test complet du ping, avec un identifiant bidon :

```sh
curl -X POST https://test2.kurzmathis4.workers.dev/api/ping \
  -H 'Content-Type: application/json' \
  -d '{"id":"00000000-0000-0000-0000-000000000001","version":"test","platform":"ios"}'
# {"ok":true}

curl https://test2.kurzmathis4.workers.dev/api/stats
# {"today":1,"week":1,"month":1,"known":1,"versions":[{"version":"test","count":1}],…}
```

Puis efface l'identifiant de test :

```sh
curl -X POST https://test2.kurzmathis4.workers.dev/api/ping \
  -H 'Content-Type: application/json' \
  -d '{"id":"00000000-0000-0000-0000-000000000001","forget":true}'
```

Dans l'app : Réglages → **Utilisation de l'app** → *Actualiser*.

### Si ça ne marche pas

| Symptôme | Cause la plus probable |
|---|---|
| `{"error":"bad id"}` | L'identifiant envoyé n'est pas un UUID de 36 caractères |
| Erreur 500 sur `/api/stats` | Le binding KV ne s'appelle pas `USAGE` (étape 2) |
| `/api/stats` renvoie du HTML ou une 404 | Les routes sont déclarées après un `return` existant : remonte-les plus haut dans le `fetch()` |
| Les compteurs restent à 0 | Normal tant qu'aucune app à jour n'a envoyé de ping — teste avec le `curl` ci-dessus |

---

## Ce qui est stocké

Une clé par installation, `u:<uuid>`, valeur vide. Tout tient dans les
métadonnées : date de dernière ouverture, version de l'app, plateforme.

| Stocké | Pas stocké |
|---|---|
| Identifiant aléatoire tiré à l'installation | Compte Twitch, pseudo |
| Date du jour (sans l'heure) | Adresse IP, en-têtes |
| Version de l'app | Chaînes regardées, historique |
| `"ios"` | Identifiant d'appareil (IDFV, série) |

Les clés expirent seules au bout de 35 jours : une installation qui cesse d'être
utilisée disparaît du comptage sans intervention.

Couper « Partager mon utilisation » dans les Réglages arrête les pings **et**
efface la clé côté serveur (`{ id, forget: true }`).

## Coût

`list()` renvoie les métadonnées sans lecture par clé : `/api/stats` coûte une
opération de liste par tranche de 1000 installations. À l'échelle actuelle
(environ 200 téléchargements cumulés), on reste très loin du palier gratuit
de Cloudflare.
