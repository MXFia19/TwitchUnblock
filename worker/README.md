# Comptage d'utilisation — mise en service

Deux routes à ajouter au Worker TwitchUnblock existant
(`https://test2.kurzmathis4.workers.dev`) :

| Route | Rôle |
|---|---|
| `POST /api/ping` | Enregistre — ou efface — une installation |
| `GET /api/stats` | Renvoie les compteurs agrégés |

**Rien à créer côté Cloudflare.** Pas de nouveau Worker, pas de nouveau
stockage : le KV `TWITCH_DATA` déjà lié pour `/api/sync` sert aussi au comptage.
Les clés sont préfixées `usage_`, celles de la sync `user_` — elles ne peuvent
pas se marcher dessus.

Tant que les routes ne répondent pas, la carte « Utilisation de l'app » des
Réglages affiche « le serveur n'a pas encore les routes de comptage ». Le reste
de l'app est indifférent : aucun risque à déployer plus tard, ou jamais.

---

## Étape 1 — Ajouter les deux routes au `switch`

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

## Étape 2 — Coller les deux fonctions

Prends tout le bloc de `analytics.js` à partir de `var USAGE_PREFIX` et colle-le
à la fin du fichier, **avant** le bloc `export { worker_default as default }`.

Les `__name(fn, "fn")` qui parsèment ton fichier viennent du bundler esbuild :
inutile d'en ajouter pour ces deux fonctions, elles marchent sans.

## Étape 3 — Déployer

Bouton *Deploy* dans l'éditeur Cloudflare, ou `npx wrangler deploy`.

## Étape 4 — Vérifier

```sh
curl https://test2.kurzmathis4.workers.dev/api/stats
```

Attendu avant tout ping :

```json
{"today":0,"week":0,"month":0,"known":0,"versions":[],"generatedAt":"…"}
```

Aller-retour complet avec un identifiant bidon, pour valider la chaîne sans
attendre une vraie installation :

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

Dans l'app : Réglages → **Utilisation de l'app** → *Actualiser*.

> Les compteurs resteront à 0 tant qu'aucune installation ne fait tourner une
> version de l'app contenant `UsageService` — le Worker seul ne génère rien.

### Si ça ne marche pas

| Symptôme | Cause |
|---|---|
| `{"error":"ID invalide"}` | L'identifiant envoyé n'est pas un UUID de 36 caractères |
| `{"error":"KV 'TWITCH_DATA' non lié au Worker."}` | Le binding KV a été renommé ou retiré — c'est le même que pour `/api/sync` |
| `Not Found` sur `/api/stats` | Les `case` n'ont pas été ajoutés, ou placés après le `default` |
| `handlePing is not defined` | Le bloc de fonctions a été collé après `export { … }` — remonte-le avant |

---

## Ce qui est stocké

Une clé par installation, `usage_<uuid>`, valeur vide. Tout tient dans les
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
opération de liste par tranche de 1000 installations, au lieu d'une lecture par
installation. À l'échelle actuelle (environ 200 téléchargements cumulés), on
reste très loin du palier gratuit de Cloudflare.
