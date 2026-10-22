# Journal traduit (LogTranslator)

Le journal de l'app (`logger.info/success/warn/error/debug`) est écrit en
français ; l'écran du journal (et son export, et celui de l'Apple TV)
l'affiche dans la langue de l'app grâce à
`Sources/Services/LogTranslations.swift`, **généré** par ces scripts — ne pas le
modifier à la main.

Après avoir ajouté ou changé des messages du journal (depuis la racine du
dépôt : `.` couvre aussi l'Apple TV, dont des messages sont traduits — avec
`Sources` seul, ils seraient signalés « absente du journal » et rien ne
serait écrit) :

```bash
node tools/log-translations/extract-log-fragments.mjs . tools/log-translations/fragments.json
node tools/log-translations/make-log-translations.mjs tools/log-translations/fragments.json tools/log-translations/translations.json Sources/Services/LogTranslations.swift
```

Le second script liste les morceaux français encore sans traduction
(« · sans traduction : … », avec ce qu'en ferait la traduction anglaise) :
les ajouter à `translations.json` (`"français": ["anglais", "espagnol",
"russe"]`) puis le relancer. Il refuse une clé en double (elle ferait
planter l'app au lancement ; « é » en un ou deux caractères compte pour la
même) et une traduction qui ne correspond plus à aucun message. Avec
`--relire` en dernier argument, il liste aussi les morceaux laissés tels
quels sans rien de français reconnu, à relire à l'œil : un mot français sans
accent ni place dans sa liste (« normale ») passerait sinon inaperçu.

- Morceaux relevés : textes littéraux, coupés aux interpolations `\( … )`, des
  arguments des appels au journal (sauf la catégorie) ; des autres méthodes du
  journal (`logger.settingChanged("Qualité préférée", value: on ? "activé" :
  "désactivé")`, et les appels sans `self.` dans `Logger.swift`) ; des lignes
  écrites directement (`LogEntry(` : arrêt brutal, plantage) ; des chaînes
  écrites dans les interpolations (`name ?? "par défaut"`). Une variable passée
  en argument est suivie dans son fichier : ce qu'elle reçoit (`let why = … ?
  "a" : "b"`), ou, si c'est le paramètre d'une fonction, les arguments de ses
  appels (`scheduleReconnect(…, reason: "…")`) ; une fonction appelée en
  argument (`Self.describe(h)`) donne les chaînes de son corps. Les noms de
  données (`login`, `id`, `url`…) et les variables d'une ou deux lettres ne
  sont pas suivis. Pour une chaîne `String(format:)`, traduire la partie sans
  `%…` (« s de retard »).
- « Sans traduction » : un morceau français qui, traduit en anglais comme dans
  l'app, garde du français — une traduction qui n'en couvre qu'une partie ne
  suffit pas.
- Catégories (« LECTEUR », « RÉSEAU »…) : dans `categories.json`, traduites
  (`traduites`) ou laissées telles quelles (`telles_quelles` : GQL, CHAT…).
  Une catégorie nouvelle est signalée « à classer » ; « TV/LECTEUR » se
  traduit partie par partie.
- À l'affichage : les plus longs d'abord ; un mot seul n'est remplacé que s'il
  est entier ; nombres, noms et adresses insérés restent tels quels. Les
  messages d'iOS (`localizedDescription`) restent dans la langue d'iOS.
- Les erreurs jointes à un retour (bug, idée) partent en français, telles
  qu'écrites : elles sont lues par le développeur.
