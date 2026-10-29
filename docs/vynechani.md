# Vynechání obsahu

Plugin posílá s kartou i obsah souboru (text do 1 MB). Některé složky ale obsah posílat
nemají, přestože karta v Airine být může. Vynechání je trvalé nastavení tohohle Macu
(`vynechatObsah` v `nastaveni.json`) a platí pro hook i pro `airine nahraj-obsah`.

```
airine vynech                         vypíše vynechané vzory
airine vynech "Claude/Code/Aktivita/" "**/.claude/worktrees/"
airine vynech --zrus "Claude/Code/Aktivita/"
airine nahraj-obsah --vynech VZOR     totéž, uloží se trvale
```

- Vzor začínající `/` nebo `~/` sedí na začátek cesty. Jiný vzor sedí na celé složky
  kdekoli v cestě. `**/` na začátku se ignoruje. Porovnává se po celých složkách:
  `Aktivita/` nevynechá `Aktivita-stara/`.
- Z vynechaného souboru odejde jen karta (název, popis, cesta, otisk), obsah nikdy.
- Nezávisle na vynechání neodejde obsah souboru, ve kterém je něco jako klíč, heslo nebo
  token s hodnotou. Tahle pojistka se vypnout nedá.

## Proč se co vynechává

Typické důvody, kvůli kterým tahle volba vznikla (29. 10. 2026):

| Vzor | Proč |
|---|---|
| složka s denními zápisy zadání pro agenty | Soukromý text. O tom, jestli patří do Airine, rozhoduje jeho autor, ne plugin |
| `**/.claude/worktrees/` | Pracovní kopie repozitářů. Jsou to duplicity souborů, které už v katalogu jsou |

Pracovní kopie od 29. 10. 2026 plugin nehlásí vůbec, ani jako kartu
([slozky.md](slozky.md)). Vzor tu zůstává kvůli kartám, které vznikly dřív.
