# Comptage d'utilisation — mise en service

`analytics.js` ajoute deux routes au Worker Cloudflare déjà utilisé par l'app
(`https://test2.kurzmathis4.workers.dev`). Tant qu'elles ne sont pas déployées,
l'écran « Utilisation » des Réglages affiche « en attente du serveur » — l'app
fonctionne normalement par ailleurs.

## 1. Créer l'espace de stockage

```sh
npx wrangler kv namespace create USAGE
```

La commande renvoie un identifiant. Reporte-le dans `wrangler.toml` :

```toml
[[kv_namespaces]]
binding = "USAGE"
id = "<identifiant renvoyé ci-dessus>"
```

## 2. Brancher les routes

Copie `analytics.js` à côté du Worker, puis dans le `fetch()` principal, avant
les routes existantes :

```js
import { handlePing, handleStats } from "./analytics.js";

// …
const url = new URL(request.url);
if (url.pathname === "/api/ping"  && request.method === "POST") {
  return handlePing(request, env);
}
if (url.pathname === "/api/stats" && request.method === "GET") {
  return handleStats(request, env);
}
```

## 3. Déployer

```sh
npx wrangler deploy
```

Vérification :

```sh
curl https://test2.kurzmathis4.workers.dev/api/stats
# {"today":0,"week":0,"month":0,"known":0,"versions":[],"generatedAt":"…"}
```

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
