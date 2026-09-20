# TwitchUnblock — version web

Socle de la version navigateur : lecteur, chat et connexion. Même Worker
Cloudflare et même application Twitch que l'app iOS — seule l'interface change.

```bash
cd web
npm install
npm run dev        # http://localhost:5173
npm test           # portage du parseur IRC (aucun réseau)
npm run build      # typecheck strict + bundle dans dist/
```

## Ce qui est là

| | |
|---|---|
| Lecture du direct | hls.js, avec repli sur le HLS natif de Safari |
| Qualités | listées depuis la playlist maîtresse, sélecteur dans la barre |
| Chat | IRC en WebSocket, en direct depuis le navigateur |
| Emotes | Twitch, BTTV, FFZ, 7TV — canal et globales |
| Badges | Helix, canal et globaux |
| Messages récents | `recent-messages.robotty.de`, marqués d'une horloge |
| Autocomplétion | emotes, pendant la frappe |
| Envoi de messages | avec réponse à un message |
| Messages modérés | retirés, ou barrés selon le réglage du client |
| Chat redimensionnable | poignée entre la vidéo et le chat, mémorisée |
| Connexion | OAuth Twitch, flux implicite |

## Ce qui ne peut pas exister sur le web

**Les points de chaîne**, et avec eux sondages, prédictions et hype train. Ils
exigent le cookie `auth-token` de `twitch.tv`, que l'app iOS capture dans une
`WKWebView`. Un site tiers ne peut pas lire les cookies d'un autre domaine :
c'est le fondement du modèle de sécurité du navigateur, il n'y a pas de
contournement. Tout le reste du chat fonctionne sans.

**La lecture en arrière-plan.** Safari iOS coupe dès que l'écran se verrouille
ou que l'onglet passe en fond. C'est précisément ce qu'une app native apporte.

## Deux chemins de lecture

Sur ordinateur (et Safari macOS), `hls.js` charge la playlist via Media Source
Extensions : on garde la main sur le buffer, donc sur la latence, le retour au
direct et le choix de qualité.

Safari **iOS** n'expose pas MSE pour la vidéo. `hls.js` y est inutilisable :
l'URL part directement dans `<video>` et c'est Safari qui décode. La lecture
marche, mais la latence n'est plus pilotable — le bouton « direct » est donc
masqué dans ce cas, plutôt que de proposer un bouton sans effet.

## Héberger — aucun domaine nécessaire

Les trois options donnent une adresse gratuite en HTTPS. Rien à acheter.

### GitHub Pages — le plus simple ici

Tu y publies déjà `auth.html`. Le workflow `.github/workflows/web.yml` fait
tout : `Actions → Site web → Run workflow`, puis une fois
`Settings → Pages → Source : GitHub Actions`.

Adresse : `https://<utilisateur>.github.io/<depot>/`

Publie dans un sous-chemin, d'où la variable `VITE_BASE` que le workflow
renseigne tout seul. À savoir : Pages depuis un dépôt **privé** demande un
compte payant.

### Cloudflare Pages — le plus cohérent

Ton Worker y est déjà : même compte, même tableau de bord, et l'origine à
autoriser est sous la main. Fonctionne depuis un dépôt privé, gratuitement.

Connecte le dépôt, puis : racine `web`, build `npm run build`, sortie
`web/dist`. Adresse : `https://<projet>.pages.dev`

### Vercel

Connecte le dépôt, racine `web`, le reste est détecté.
Adresse : `https://<projet>.vercel.app`

## Les deux réglages à faire une fois

**1. Déclarer l'URL de retour** dans la console développeur Twitch, à côté de
celle de l'app iOS. Twitch en accepte plusieurs, et exige une correspondance
au caractère près — **barre oblique finale comprise** :

| Hébergement | URL de retour |
|---|---|
| GitHub Pages | `https://<utilisateur>.github.io/<depot>/` |
| Cloudflare Pages | `https://<projet>.pages.dev/` |
| Vercel | `https://<projet>.vercel.app/` |
| Développement | `http://localhost:5173/` |

C'est la racine du site, pas une page dédiée : le jeton revient dans le
fragment de l'URL, n'importe quelle page sait le lire. Ça évite d'exiger une
réécriture d'URL de l'hébergeur — GitHub Pages n'en propose pas.

**2. Autoriser l'origine dans le Worker** : `/api/get-live` est appelé depuis
le navigateur, il lui faut les en-têtes CORS. Voir [WORKER.md](WORKER.md).

## Ce qui vient du Swift

Le vrai travail était déjà fait dans l'app iOS ; ces fichiers en sont le
portage, pas une réécriture :

| Web | iOS |
|---|---|
| `lib/irc.ts` | `Chat/IRCParser.swift` |
| `lib/message.ts` | `ChatService.buildMessage` + `tokenizeChatSegment` |
| `lib/emotes.ts` | `Chat/EmoteService.swift` |
| `lib/badges.ts` | `Chat/BadgeService.swift` |
| `lib/chatClient.ts` | `Chat/ChatService.swift` |
| `lib/stream.ts` | `Services/TwitchAPI.swift` (partie Helix) |

`test/parser.test.ts` vérifie les points qui se portent mal : le paramètre
final d'une ligne IRC, les tags contenant un `=`, la liste du `353` qui est en
dernière position et non en deuxième, les plages d'emotes en unités UTF-16, et
l'éclaircissement des couleurs de pseudo.
