// ═══════════════════════════════════════════════════════════════════════════
//  Connexion Twitch (flux implicite).
//
//  Twitch ne gère pas PKCE pour les clients publics et le code d'autorisation
//  exige un secret — qu'on ne peut pas mettre dans une page web. Il reste donc
//  le flux implicite : le jeton revient dans le fragment de l'URL, jamais
//  envoyé au serveur, et on le range dans localStorage.
// ═══════════════════════════════════════════════════════════════════════════

import { HELIX_CLIENT_ID, redirectURI, SCOPES } from './config'

const TOKEN_KEY = 'tu_token'
const USER_KEY = 'tu_user'

export interface TwitchUser {
  id: string
  login: string
  displayName: string
  avatar: string
}

export function loginURL(): string {
  const p = new URLSearchParams({
    client_id: HELIX_CLIENT_ID,
    redirect_uri: redirectURI(),
    response_type: 'token',
    scope: SCOPES,
  })
  return `https://id.twitch.tv/oauth2/authorize?${p}`
}

export function storedToken(): string | null {
  return localStorage.getItem(TOKEN_KEY)
}

export function storedUser(): TwitchUser | null {
  const raw = localStorage.getItem(USER_KEY)
  if (!raw) return null
  try { return JSON.parse(raw) as TwitchUser } catch { return null }
}

export function saveSession(token: string, user: TwitchUser): void {
  localStorage.setItem(TOKEN_KEY, token)
  localStorage.setItem(USER_KEY, JSON.stringify(user))
}

export function logout(): void {
  localStorage.removeItem(TOKEN_KEY)
  localStorage.removeItem(USER_KEY)
}

/**
 * Récupère le jeton laissé dans le fragment au retour de Twitch, puis efface
 * le fragment : un jeton ne doit pas rester dans la barre d'adresse ni dans
 * l'historique du navigateur.
 */
export function consumeRedirect(): string | null {
  if (!location.hash.includes('access_token')) return null
  const params = new URLSearchParams(location.hash.slice(1))
  const token = params.get('access_token')
  history.replaceState(null, '', location.pathname + location.search)
  return token
}

export async function fetchSelf(token: string): Promise<TwitchUser | null> {
  try {
    const res = await fetch('https://api.twitch.tv/helix/users', {
      headers: { Authorization: `Bearer ${token}`, 'Client-Id': HELIX_CLIENT_ID },
    })
    if (!res.ok) return null
    const u = (await res.json())?.data?.[0]
    if (!u) return null
    return {
      id: String(u.id ?? ''),
      login: String(u.login ?? ''),
      displayName: String(u.display_name ?? u.login ?? ''),
      avatar: String(u.profile_image_url ?? ''),
    }
  } catch {
    return null
  }
}
