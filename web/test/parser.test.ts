// Vérification du portage depuis le Swift, sur de vraies lignes IRC Twitch.
// Aucun réseau, aucun DOM : `npm test` suffit.

import { parseEmoteRanges, parseIRC, prefixNick, unescapeTag } from '../src/lib/irc'
import { buildMessage, readableChatColor } from '../src/lib/message'

let failures = 0

function check(name: string, actual: unknown, expected: unknown): void {
  const a = JSON.stringify(actual)
  const b = JSON.stringify(expected)
  if (a === b) {
    console.log(`  ok   ${name}`)
  } else {
    failures++
    console.log(`  FAIL ${name}\n       attendu ${b}\n       obtenu  ${a}`)
  }
}

console.log('parseIRC')
{
  const line =
    '@badge-info=subscriber/12;badges=subscriber/12,premium/1;color=#1E90FF;' +
    'display-name=Damonarix;emotes=;first-msg=0;id=abc-123;user-id=4242;' +
    'tmi-sent-ts=1700000000000 ' +
    ':damonarix!damonarix@damonarix.tmi.twitch.tv PRIVMSG #mistermv :Bonjour à tous ^^'
  const m = parseIRC(line)!
  check('commande', m.command, 'PRIVMSG')
  check('canal', m.params[0], '#mistermv')
  // Le paramètre final garde ses espaces : c'est le piège classique.
  check('corps avec espaces', m.params[1], 'Bonjour à tous ^^')
  check('tag display-name', m.tags['display-name'], 'Damonarix')
  check('pseudo depuis le préfixe', prefixNick(m), 'damonarix')
}

{
  // Un tag dont la valeur contient « = » ne doit pas être coupé au premier.
  const m = parseIRC('@a=1;b=x=y;c= :tmi.twitch.tv NOTICE #c :hi')!
  check('tag avec =', m.tags['b'], 'x=y')
  check('tag vide', m.tags['c'], '')
}

{
  // RPL_NAMREPLY : la liste est le DERNIER paramètre, pas params[1]
  // (qui vaut « = »). C'est exactement le bug corrigé côté iOS.
  const m = parseIRC(':moi.tmi.twitch.tv 353 moi = #canal :alice bob carol')!
  check('353 : params[1] est bien "="', m.params[1], '=')
  check('353 : la liste est en dernier', m.params[m.params.length - 1], 'alice bob carol')
}

console.log('parseEmoteRanges')
{
  // Bornes incluses côté Twitch, exclusives chez nous.
  const text = 'Kappa test Kappa'
  const r = parseEmoteRanges('25:0-4,11-15', text)
  check('deux occurrences', r.length, 2)
  check('première découpe', text.slice(r[0]!.start, r[0]!.end), 'Kappa')
  check('seconde découpe', text.slice(r[1]!.start, r[1]!.end), 'Kappa')
}
{
  // Les positions sont en unités UTF-16 : un emoji hors BMP compte double.
  // C'est ce qui demandait une conversion d'index en Swift.
  const text = '👍 Kappa'
  const r = parseEmoteRanges('25:3-7', text)
  check('décalage après emoji', text.slice(r[0]!.start, r[0]!.end), 'Kappa')
}
{
  check('plage hors bornes ignorée', parseEmoteRanges('25:0-999', 'court').length, 0)
  check('tag vide', parseEmoteRanges('', 'texte').length, 0)
}

console.log('unescapeTag')
check('espaces échappés', unescapeTag('a\\sb\\sc'), 'a b c')
check('point-virgule', unescapeTag('a\\:b'), 'a;b')

console.log('readableChatColor')
{
  // Un pseudo noir doit être éclairci pour rester lisible sur fond sombre.
  const dark = readableChatColor('#000000')
  const lum = (h: string) => {
    const n = Number.parseInt(h.slice(1), 16)
    return 0.299 * ((n >> 16) & 255) + 0.587 * ((n >> 8) & 255) + 0.114 * (n & 255)
  }
  check('noir éclairci au-dessus du seuil', lum(dark) >= 0.45 * 255 - 1, true)
  // Une couleur déjà claire ne doit pas bouger.
  check('blanc inchangé', readableChatColor('#ffffff'), '#ffffff')
  check('couleur invalide → violet Twitch', readableChatColor('zz'), '#9146ff')
}

console.log('buildMessage')
{
  const line =
    '@display-name=Sh;emotes=25:0-4;id=m1;user-id=7;color=#1E90FF ' +
    ':sh!sh@sh.tmi.twitch.tv PRIVMSG #c :Kappa salut @bob https://exemple.fr'
  const msg = buildMessage(parseIRC(line)!, false)!
  check('emote en tête', msg.tokens[0]?.kind, 'emote')
  check(
    'texte, mention et lien reconnus',
    msg.tokens.slice(1).map((t) => t.kind),
    ['text', 'mention', 'link'],
  )
  check('pseudo affiché', msg.displayName, 'Sh')
  check('pas historique', msg.isHistorical, false)
}
{
  // Rejeu : l'heure vient du tag, pas de l'instant présent.
  const line =
    '@display-name=X;id=m2;tmi-sent-ts=1600000000000 :x!x@x.tmi.twitch.tv PRIVMSG #c :salut'
  const msg = buildMessage(parseIRC(line)!, true)!
  check('horodatage repris du tag', msg.timestamp, 1600000000000)
  check('marqué historique', msg.isHistorical, true)
}
{
  // /me : Twitch enrobe le texte de \u0001ACTION … \u0001
  const line = '@display-name=X;id=m3 :x!x@x.tmi.twitch.tv PRIVMSG #c :\u0001ACTION danse\u0001'
  const msg = buildMessage(parseIRC(line)!, false)!
  check('action détectée', msg.isAction, true)
  check('marqueurs retirés', msg.tokens[0], { kind: 'text', value: 'danse' })
}

console.log(failures === 0 ? '\nTout passe.' : `\n${failures} échec(s).`)
process.exit(failures === 0 ? 0 : 1)
