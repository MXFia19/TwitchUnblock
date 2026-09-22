# Correctif — `getRequestHeaders` n'existe pas

## Le symptôme

Aucun. C'est ce qui rend le bug durable : `/api/get-live` répond correctement,
mais jamais par le chemin prévu.

## Ce qui se passe

Dans `handleGetLive`, la tentative Luminous appelle une fonction qui n'est
définie nulle part dans le Worker :

```js
const resLuminous = await fetch(
  `https://as.luminous.dev/live/${login}?allow_source=true`,
  { headers: getRequestHeaders(login) }   // ← ReferenceError
);
```

Le fichier ne contient que la **constante** `REQUEST_HEADERS`, pas de fonction
`getRequestHeaders`. L'appel lève donc une `ReferenceError` à chaque requête,
avant même que `fetch` ne parte.

Comme tout est dans un `try`, l'erreur est avalée par le `catch` juste en
dessous, qui bascule sur le jeton Twitch officiel :

```js
} catch (e) {
  try {
    const token = await getAccessToken(login, true);   // ← toujours ce chemin
```

**Conséquence : la route sert systématiquement le flux Twitch officiel, avec
les publicités.** Luminous, la source sans pub, n'est jamais réellement tentée.

## Le correctif

Définir la fonction manquante, plutôt que de la remplacer par la constante :
le nom indique clairement l'intention d'origine — un `Referer` pointant sur la
chaîne demandée, ce qui est plus crédible côté Twitch qu'un `Referer` générique.

À coller à côté de `jsonResponse` / `jsonError` :

```js
function getRequestHeaders(login) {
  return {
    ...REQUEST_HEADERS,
    "Referer": `https://www.twitch.tv/${login}`
  };
}
```

Rien d'autre à changer : l'appel existant devient valide.

> Variante minimale, si tu préfères ne rien ajouter : remplacer
> `getRequestHeaders(login)` par `REQUEST_HEADERS` dans `handleGetLive`.
> Ça corrige le plantage, mais perd le `Referer` par chaîne.

## Vérifier que Luminous répond enfin

Avant correctif, sur une chaîne **en direct**, la réponse contient les liens
mais passe par usher. Après correctif, l'URL du flux doit venir de
`luminous.dev`. Le plus simple est de regarder le lien renvoyé :

```sh
curl -s "https://test2.kurzmathis4.workers.dev/api/get-live?name=UNE_CHAINE_EN_DIRECT" \
  | python3 -m json.tool | head -20
```

Un lien qui contient `luminous` (ou un `Auto` pointant sur un master Luminous)
signe le bon chemin.

## Pendant que tu y es

Deux écarts avec ce que fait l'app aujourd'hui, si tu veux aligner le Worker
(facultatif, sans rapport avec le bug) :

1. **Un seul miroir.** Le Worker tape `as.luminous.dev` (Asie). L'app essaie
   quatre miroirs dans l'ordre `as`, `eu`, `eu2`, `eu3` et passe au suivant si
   l'un tombe — voir `kLuminousHosts` dans `Sources/Constants.swift`.
2. **Pas de `fast_bread`.** L'app ajoute `fast_bread=true`, la variante faible
   latence de Twitch. Le Worker ne demande que `allow_source=true`.

## Portée réelle

L'app n'appelle `/api/get-live` qu'en **troisième recours**, après Luminous en
direct puis le jeton Twitch officiel (`getLive` dans
`Sources/Services/TwitchAPI.swift`). Le bug n'a donc jamais dégradé l'app de
façon visible — il rendait juste le filet de sécurité moins utile qu'il n'y
paraissait.
