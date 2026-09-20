# Autoriser le site dans le Worker

L'app iOS appelle `/api/get-live` depuis `URLSession` : aucune règle d'origine
ne s'applique. Le site, lui, l'appelle depuis une page web, et le navigateur
**bloque la lecture de la réponse** si le Worker ne dit pas explicitement que
ton domaine a le droit de la lire.

Symptôme : dans la console, `CORS policy: No 'Access-Control-Allow-Origin'
header is present`. Sur GitHub Pages, l'origine est le domaine seul
(`https://mxfia19.github.io`), **sans** le chemin du dépôt : un en-tête
`Origin` ne contient jamais de chemin. L'app iOS continue de fonctionner normalement — d'où
l'absence de tout signal si on ne regarde pas la console du navigateur.

## Le correctif

Dans le Worker, au retour de `/api/get-live`, ajoute l'en-tête :

```js
// Les origines de TES pages. Pas de domaine ? Ce sont les adresses gratuites
// que donnent les hébergeurs — une seule suffit, garde celle que tu utilises.
const ALLOWED = new Set([
  'https://mxfia19.github.io',      // GitHub Pages
  'https://ton-projet.pages.dev',   // Cloudflare Pages
  'https://ton-projet.vercel.app',  // Vercel
  'http://localhost:5173',          // développement local
])

function corsHeaders(request) {
  const origin = request.headers.get('Origin')
  // Liste blanche plutôt que « * » : le Worker consomme ton quota Cloudflare,
  // autant qu'il ne serve que tes pages.
  if (!origin || !ALLOWED.has(origin)) return {}
  return {
    'Access-Control-Allow-Origin': origin,
    'Vary': 'Origin',
  }
}
```

Puis à l'endroit où la réponse est construite :

```js
return new Response(JSON.stringify({ links }), {
  headers: {
    'Content-Type': 'application/json',
    ...corsHeaders(request),
  },
})
```

Si `request` n'est pas déjà passé à la fonction qui construit la réponse, il
faut le faire descendre — c'est le seul changement structurel.

## Pas besoin de preflight

`/api/get-live` est un `GET` sans en-tête personnalisé : le navigateur
l'envoie directement, sans requête `OPTIONS` préalable. Rien à gérer de ce
côté tant qu'on n'ajoute pas d'en-tête d'authentification.

## Les autres appels n'ont rien à faire

| Service | CORS |
|---|---|
| `api.twitch.tv/helix` | déjà autorisé par Twitch |
| `irc-ws.chat.twitch.tv` | WebSocket, hors politique d'origine |
| BTTV, FFZ, 7TV | déjà autorisés, leurs clients sont des sites web |
| `recent-messages.robotty.de` | déjà autorisé, conçu pour le web |
| Segments vidéo `*.ttvnw.net` | déjà autorisés, c'est ainsi que le lecteur Twitch fonctionne |

Seul `/api/get-live` passe par toi, donc seul lui demande cet en-tête. C'est
aussi pour ça que la bande passante reste négligeable : les segments vidéo
viennent du CDN Twitch en direct, le Worker ne sert que la playlist.
