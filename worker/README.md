# Comptage d'utilisation (archive)

> [!NOTE]
> **Rien à faire ici.** `POST /api/ping` et `GET /api/stats` sont dans le Worker du site, [TwitchUnblock-Web/worker.js](https://github.com/MXFia19/TwitchUnblock-Web/blob/main/worker.js). Il se déploie tout seul depuis `main`, avec sa base D1. Ce qui est compté, et comment : [documentation du site](https://github.com/MXFia19/TwitchUnblock-Web/blob/main/DOCUMENTATION.md#usage-count).

Ce dossier garde la trace de la première mise en service (septembre 2026), quand ces routes se collaient à la main dans le Worker :
- `analytics.js` : le code d'alors ;
- `fix-get-live.md` : un correctif de la même époque.

Si l'app affiche « le serveur n'a pas encore les routes de comptage », elle parle à un Worker qui ne les a pas : par exemple un ancien Worker personnel (Réglages → Autres → Réglages experts).

<details>
<summary><b>Ancienne mise en service (stockage KV, septembre 2026)</b></summary>

Deux routes ajoutées au Worker TwitchUnblock (`https://test2.kurzmathis4.workers.dev`) :

| Route | Rôle |
|---|---|
| `POST /api/ping` | Enregistre — ou efface — une installation |
| `GET /api/stats` | Renvoie les compteurs agrégés |

Rien à créer côté Cloudflare : le KV `TWITCH_DATA` déjà lié pour `/api/sync` servait aussi au comptage. Les clés étaient préfixées `usage_`, celles de la sync `user_`.

Tant que les routes ne répondaient pas, la carte « Utilisation de l'app » des Réglages affichait « le serveur n'a pas encore les routes de comptage ». Le reste de l'app n'en dépendait pas.

### Étape 1 — Ajouter les deux routes au `switch`

Dans `fetch()`, à côté des routes de sync :

```js
        // Routes Sync (Sauvegarde Cloud)
        case "/api/sync/get":
          return await handleSyncGet(url, env);
        case "/api/sync/post":
          return await handleSyncPost(request, env);

        // Comptage d'utilisation
        case "/api/ping":
          return await handlePing(request, env);
        case "/api/stats":
          return await handleStats(env);
```

### Étape 2 — Coller les deux fonctions

Tout le bloc de `analytics.js` à partir de `var USAGE_PREFIX`, collé à la fin du fichier, **avant** `export { worker_default as default }`. Les `__name(fn, "fn")` du fichier venaient du bundler esbuild : inutiles pour ces deux fonctions.

### Étape 3 — Déployer

Bouton *Deploy* dans l'éditeur Cloudflare, ou `npx wrangler deploy`.

### Étape 4 — Vérifier

```sh
curl https://test2.kurzmathis4.workers.dev/api/stats
```

Attendu avant tout ping :

```json
{"today":0,"week":0,"month":0,"known":0,"versions":[],"generatedAt":"…"}
```

Aller-retour complet avec un identifiant bidon :

```sh
# 1. Enregistrer
curl -X POST https://test2.kurzmathis4.workers.dev/api/ping \
  -H 'Content-Type: application/json' \
  -d '{"id":"00000000-0000-0000-0000-000000000001","version":"test","platform":"ios"}'
# {"ok":true}

# 2. Relire
curl https://test2.kurzmathis4.workers.dev/api/stats
# {"today":1,"week":1,"month":1,"known":1,"versions":[{"version":"test","count":1}],…}

# 3. Effacer le test
curl -X POST https://test2.kurzmathis4.workers.dev/api/ping \
  -H 'Content-Type: application/json' \
  -d '{"id":"00000000-0000-0000-0000-000000000001","forget":true}'
# {"ok":true,"forgotten":true}
```

Dans l'app : Réglages → **Utilisation de l'app** → *Actualiser*. Les compteurs restaient à 0 tant qu'aucune installation ne faisait tourner une version contenant `UsageService`.

| Symptôme | Cause |
|---|---|
| `{"error":"ID invalide"}` | L'identifiant envoyé n'est pas un UUID de 36 caractères |
| `{"error":"KV 'TWITCH_DATA' non lié au Worker."}` | Le binding KV a été renommé ou retiré (le même que pour `/api/sync`) |
| `Not Found` sur `/api/stats` | Les `case` manquent, ou sont après le `default` |
| `handlePing is not defined` | Le bloc de fonctions est collé après `export { … }` |

### Mesure de fidélité (2e version)

Une seconde version d'`analytics.js` ajoutait, par installation, les dates de **première** et de **dernière** ouverture et le nombre de **jours distincts** d'utilisation : de quoi distinguer « essayée une fois » de « utilisée tous les jours ». `handlePing` faisait alors une lecture (`getWithMetadata`) avant d'écrire, au pire une par installation et par heure. `/api/stats` renvoyait en plus :

```json
{
  "returning": 3,
  "loyalty": { "once": 5, "few": 2, "regular": 1, "daily": 0 },
  "avgDays": 2.4,
  "oldestFirst": "2026-09-18"
}
```

### Ce qui était stocké

Une clé par installation, `usage_<uuid>`, valeur vide ; tout tenait dans les métadonnées (date de dernière ouverture, version de l'app, plateforme). Les clés expiraient seules au bout de 35 jours, et couper « Partager mon utilisation » effaçait la clé (`{ id, forget: true }`).

| Stocké | Pas stocké |
|---|---|
| Identifiant aléatoire tiré à l'installation | Compte Twitch, pseudo |
| Date du jour (sans l'heure) | Adresse IP, en-têtes |
| Version de l'app | Chaînes regardées, historique |
| `"ios"` | Identifiant d'appareil (IDFV, série) |

`list()` renvoyait les métadonnées sans lecture par clé : `/api/stats` coûtait une opération de liste par tranche de 1000 installations.

</details>
