# TwitchUnblock — Swift / SwiftUI

Port complet de l'app React Native vers Swift natif iOS.

---

## Structure du projet

```
TwitchUnblock/
├── TwitchUnblockApp.swift          # Entry point (@main)
├── AppDelegate.swift               # AVAudioSession (background audio)
├── Info.plist                      # URL scheme, background modes, ATS
├── Constants.swift                 # Couleurs, URLs API, traductions (FR/EN/ES)
├── Models.swift                    # Tous les types de données
├── AppStore.swift                  # État global (ObservableObject) + UserDefaults
│
├── Services/
│   ├── TwitchAPI.swift             # Tous les appels API (GQL, Helix, M3U8)
│   └── Logger.swift                # Logger singleton (remplace logger.ts)
│
├── Auth/
│   └── TwitchAuthManager.swift     # OAuth Twitch (ASWebAuthenticationSession)
│
└── Views/
    ├── MainTabView.swift           # Navigation + player overlay + mini-barre
    ├── HeaderView.swift            # Header (logo, proxy toggle, langue)
    │
    ├── Player/
    │   └── VideoPlayerView.swift   # AVPlayerViewController + PiP natif + qualités + apps externes
    │
    ├── Screens/
    │   ├── DiscoveryView.swift     # Chaînes suivies + Top streams
    │   ├── StreamerView.swift      # Recherche streamer + live + VODs
    │   ├── DirectView.swift        # Lecture par ID/lien VOD
    │   ├── SettingsView.swift      # Paramètres (langue, proxy, compte, logs)
    │   └── LogsView.swift          # Logs système filtrables + export
    │
    └── Components/
        ├── CardViews.swift         # StreamCardView, VodCardView, LiveCardView
        └── InputComponents.swift   # AutocompleteInputView, ChannelHistoryTagsView, VodHistoryRowView
```

---

## Mapping React Native → Swift

| React Native              | Swift                                 |
|---------------------------|---------------------------------------|
| `AsyncStorage`            | `UserDefaults`                        |
| `Context` + `useState`    | `AppStore: ObservableObject` + `@EnvironmentObject` |
| `react-native-video`      | `AVPlayerViewController` (UIViewControllerRepresentable) |
| PiP (`react-native-pip`)  | `canStartPictureInPictureAutomaticallyFromInline = true` |
| `expo-auth-session`       | `ASWebAuthenticationSession`          |
| `Linking.openURL`         | `UIApplication.shared.open()`         |
| `fetch` / GQL             | `URLSession` + `async/await`          |
| `Alert`                   | `.alert()` SwiftUI modifier           |
| `Share`                   | `UIActivityViewController`            |
| Tabs custom               | Custom `HStack` tab bar               |
| `ScrollView` + `FlatList` | `ScrollView` + `LazyVGrid` / `List`   |

---

## Configuration Xcode

### 1. Créer le projet

1. **File → New → Project → App**
2. Product Name : `TwitchUnblock`
3. Interface : **SwiftUI**
4. Language : **Swift**
5. Deployment Target : **iOS 16.0+**

### 2. Ajouter les fichiers

Glisser-déposer tous les fichiers `.swift` dans le projet Xcode en respectant la structure des groupes.

### 3. Remplacer Info.plist

Coller le contenu de `Info.plist` dans le fichier Info.plist du projet **ou** configurer via **Signing & Capabilities** :

- ✅ **Background Modes** → Audio, AirPlay, Picture in Picture
- ✅ **URL Schemes** → Ajouter `twitchunblock`

### 4. Identifiant bundle

Changer `com.yourname.TwitchUnblock` par votre identifiant réel dans `Info.plist` et les **Signing settings**.

---

## Fonctionnalités portées

- ✅ Lecture VODs Twitch sans sub (3 méthodes : token GQL → storyboard hack → worker Cloudflare)
- ✅ Lecture streams live
- ✅ Sélecteur de qualité (Source, 1080p60, 720p60, …)
- ✅ PiP natif (automatique en background via `AVPlayerViewController`)
- ✅ Ouverture dans VLC / Outplayer / Infuse
- ✅ Copie du lien M3U8
- ✅ Auth Twitch OAuth (ASWebAuthenticationSession)
- ✅ Chaînes suivies + Top Streams (FR / Monde)
- ✅ Recherche streamer avec autocomplete GQL
- ✅ Filtre VODs par mot-clé
- ✅ Historique VODs + chaînes (persisté en UserDefaults)
- ✅ Progression VOD sauvegardée
- ✅ Sync cloud (Cloudflare Worker)
- ✅ 3 langues : Français, English, Español
- ✅ Toggle Proxy
- ✅ Logger système avec filtres + export
- ✅ Mini-barre "lecture en cours" (player réduit)
- ✅ Thème sombre natif

---

## Notes importantes

### PiP
Le PiP est géré nativement par `AVPlayerViewController` avec :
```swift
vc.allowsPictureInPicturePlayback = true
vc.canStartPictureInPictureAutomaticallyFromInline = true
```
Il se déclenche **automatiquement** quand l'app passe en arrière-plan. Aucune lib tierce nécessaire.

### Background Audio
Déclaré dans `Info.plist` via `UIBackgroundModes: [audio]` et configuré dans `AppDelegate` :
```swift
try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
```

### OAuth Flow
La page `auth.html` sur GitHub Pages intercepte le token et redirige vers `twitchunblock://`.  
`ASWebAuthenticationSession` intercepte automatiquement ce scheme.

### NSAppTransportSecurity
`NSAllowsArbitraryLoads: true` est nécessaire car les URLs M3U8 de Twitch CDN utilisent HTTP dans certains cas. Pour la production, vous pouvez restreindre aux domaines Twitch uniquement.

---

## Backend Cloudflare

Le worker `https://test2.kurzmathis4.workers.dev` reste **inchangé** — l'app Swift fait exactement les mêmes appels HTTP que la version React Native.

---

## Dépendances

**Aucune** — le projet utilise uniquement des frameworks Apple :
- `SwiftUI` — UI
- `AVKit` / `AVFoundation` — lecteur vidéo HLS + PiP
- `AuthenticationServices` — OAuth Twitch
- `Foundation` — URLSession, UserDefaults, JSON
