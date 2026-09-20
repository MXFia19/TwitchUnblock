import { useSyncExternalStore } from 'react'

// ═══════════════════════════════════════════════════════════════════════════
//  Réglages, persistés dans localStorage.
//
//  Mêmes valeurs par défaut que l'app iOS (AppStore.swift) : à réglages
//  inchangés, les deux clients se ressemblent.
//
//  Pas de contexte React : un store externe lu par `useSyncExternalStore`.
//  Ça évite de faire descendre huit propriétés jusqu'aux lignes de message,
//  et seuls les composants qui lisent les réglages se redessinent.
// ═══════════════════════════════════════════════════════════════════════════

export interface Settings {
  // Chat — apparence
  chatFontSize: number
  /** Espace entre deux messages, en pixels ; chacun en porte la moitié. */
  chatSpacing: number
  chatBadgeScale: number
  chatEmoteScale: number
  chatTimestamps: boolean
  /** Part de la largeur prise par le chat, en fraction. */
  chatRatio: number

  // Chat — comportement
  chatLoadRecent: boolean
  chatAutocomplete: boolean
  chatShowDeleted: boolean

  // Lecteur
  lowLatency: boolean
  /** Qualité retenue, « » = la meilleure disponible. */
  defaultQuality: string

  // Découverte
  topLang: 'fr' | 'all'
}

export const DEFAULTS: Settings = {
  chatFontSize: 13,
  chatSpacing: 8,
  chatBadgeScale: 1,
  chatEmoteScale: 1,
  chatTimestamps: true,
  chatRatio: 0.32,
  chatLoadRecent: true,
  chatAutocomplete: true,
  chatShowDeleted: false,
  lowLatency: false,
  defaultQuality: '',
  topLang: 'fr',
}

const KEY = 'tu_settings'

function load(): Settings {
  try {
    const raw = localStorage.getItem(KEY)
    if (!raw) return DEFAULTS
    const saved: unknown = JSON.parse(raw)
    if (!saved || typeof saved !== 'object') return DEFAULTS
    // Fusion avec les valeurs par défaut : un réglage ajouté plus tard ne doit
    // pas arriver à `undefined` chez quelqu'un qui a déjà un enregistrement.
    return { ...DEFAULTS, ...(saved as Partial<Settings>) }
  } catch {
    return DEFAULTS
  }
}

let current: Settings = load()
const listeners = new Set<() => void>()

function emit(): void {
  for (const l of listeners) l()
}

export function getSettings(): Settings {
  return current
}

/**
 * Applique un changement. `persist: false` sert au glissement de la largeur du
 * chat : écrire dans localStorage à chaque image du geste hache l'animation,
 * on n'enregistre qu'au relâcher.
 */
export function setSetting<K extends keyof Settings>(
  key: K,
  value: Settings[K],
  persist = true,
): void {
  if (current[key] === value) return
  current = { ...current, [key]: value }
  if (persist) save()
  emit()
}

export function save(): void {
  try {
    localStorage.setItem(KEY, JSON.stringify(current))
  } catch {
    // Mode privé, stockage plein : les réglages valent pour la session.
  }
}

export function resetSettings(): void {
  current = { ...DEFAULTS }
  save()
  emit()
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener)
  return () => listeners.delete(listener)
}

export function useSettings(): Settings {
  return useSyncExternalStore(subscribe, getSettings, getSettings)
}
