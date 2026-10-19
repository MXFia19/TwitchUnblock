# Journal traduit (LogTranslator)

Le journal de l'app (`logger.info/success/warn/error/debug`) est écrit en
français ; l'écran du journal l'affiche dans la langue de l'app grâce à
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
(« · sans traduction : … ») : les ajouter à `translations.json`
(`"français": ["anglais", "espagnol", "russe"]`) puis le relancer. Il refuse
une clé en double (elle ferait planter l'app au lancement) et une traduction
qui ne correspond plus à aucun message.

- Morceaux : textes littéraux des arguments (sauf la catégorie), coupés aux
  interpolations `\( … )` ; pour une chaîne `String(format:)`, traduire la
  partie sans `%…` (« s de retard »).
- À l'affichage : les plus longs d'abord ; un mot seul n'est remplacé que s'il
  est entier ; nombres, noms et adresses insérés restent tels quels.
