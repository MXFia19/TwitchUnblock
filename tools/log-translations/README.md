# Journal traduit

Le journal de l'app (`logger.info/success/warn/error/debug`) est écrit en français. L'écran du journal, son export et celui de l'Apple TV l'affichent dans la langue de l'app grâce à `Sources/Services/LogTranslations.swift`, **généré** par ces scripts : ne pas le modifier à la main.

## Après avoir ajouté ou changé des messages du journal

Depuis la racine du dépôt (`.` couvre aussi l'Apple TV ; avec `Sources` seul, ses messages seraient signalés « absente du journal » et rien ne serait écrit) :

```bash
node tools/log-translations/extract-log-fragments.mjs . tools/log-translations/fragments.json
node tools/log-translations/make-log-translations.mjs tools/log-translations/fragments.json tools/log-translations/translations.json Sources/Services/LogTranslations.swift
```

Le second script liste les morceaux français encore sans traduction (« · sans traduction : … », avec ce qu'en ferait la traduction anglaise). Les ajouter à `translations.json` (`"français": ["anglais", "espagnol", "russe"]`), puis le relancer.

> [!WARNING]
> Une clé en double fait planter l'app au lancement. Le script la refuse (« é » en un ou deux caractères compte pour la même), comme une traduction qui ne correspond plus à aucun message.

`--relire` en dernier argument liste aussi les morceaux laissés tels quels sans rien de français reconnu, à relire à l'œil : un mot français sans accent ni place dans sa liste (« normale ») passerait sinon inaperçu.

Les erreurs jointes à un signalement partent **en anglais**, traduites ainsi, quelle que soit la langue de l'app : elles se lisent sur Discord et dans /stats.

<details>
<summary><b>Ce que relève le premier script</b></summary>

- Textes littéraux, coupés aux interpolations `\( … )`, des arguments des appels au journal (sauf la catégorie).
- Les autres méthodes du journal (`logger.settingChanged("Qualité préférée", value: on ? "activé" : "désactivé")`), et les appels sans `self.` dans `Logger.swift`.
- Les lignes écrites directement (`LogEntry(` : arrêt brutal, plantage), et les chaînes écrites dans les interpolations (`name ?? "par défaut"`).
- Une variable passée en argument est suivie dans son fichier : ce qu'elle reçoit (`let why = … ? "a" : "b"`), ou, si c'est le paramètre d'une fonction, les arguments de ses appels (`scheduleReconnect(…, reason: "…")`). Une fonction appelée en argument (`Self.describe(h)`) donne les chaînes de son corps.
- Ne sont pas suivis : les noms de données (`login`, `id`, `url`…) et les variables d'une ou deux lettres. Pour une chaîne `String(format:)`, traduire la partie sans `%…` (« s de retard »).
- « Sans traduction » : un morceau français qui, traduit en anglais comme dans l'app, garde du français. Une traduction qui n'en couvre qu'une partie ne suffit pas.

</details>

<details>
<summary><b>Catégories et affichage</b></summary>

- Catégories (« LECTEUR », « RÉSEAU »…) : dans `categories.json`, traduites (`traduites`) ou laissées telles quelles (`telles_quelles` : GQL, CHAT…). Une catégorie nouvelle est signalée « à classer » ; « TV/LECTEUR » se traduit partie par partie.
- À l'affichage : les plus longs morceaux d'abord ; un mot seul n'est remplacé que s'il est entier ; nombres, noms et adresses insérés restent tels quels.
- Les messages d'iOS (`localizedDescription`) restent dans la langue d'iOS.

</details>
