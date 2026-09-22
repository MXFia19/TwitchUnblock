// Mêmes identifiants que l'app iOS : le Worker et l'application Twitch sont
// partagés, seule l'interface change.
export const WORKER_URL = 'https://test2.kurzmathis4.workers.dev'
export const HELIX_CLIENT_ID = '1e68ku2ehgzy5cy0di3xvfy82sxpf6'

/// Twitch ne gère pas PKCE pour les clients publics : c'est le flux implicite,
/// le jeton revient dans le fragment de l'URL. Le `redirect_uri` doit être
/// déclaré au mot près dans la console développeur Twitch.
///
/// On renvoie sur la racine de l'app, pas sur une route dédiée : le jeton est
/// dans le fragment, n'importe quelle page sait le lire. Ça évite d'exiger de
/// l'hébergeur une réécriture d'URL — GitHub Pages n'en propose pas — et ça
/// gère du même coup les hébergements en sous-chemin.
///
/// `BASE_URL` vaut « / » à la racine d'un domaine, « /TwitchUnblock/ » sur
/// GitHub Pages. Fonction et non constante : lu au chargement du module,
/// `location` n'existe pas hors navigateur et ferait tomber les tests.
export function redirectURI(): string {
  return new URL(import.meta.env.BASE_URL, location.origin).href
}

export const SCOPES = [
  'user:read:follows',
  'chat:read',
  'chat:edit',
  'user:manage:chat_color',
].join(' ')

export const IRC_URL = 'wss://irc-ws.chat.twitch.tv:443'
export const IRC_CAPS = 'twitch.tv/tags twitch.tv/commands twitch.tv/membership'
