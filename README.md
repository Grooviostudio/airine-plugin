# Airine plugin

Plugin pro Claude Code a Cursor a malá aplikace v liště macOS. Na začátku práce
agentovi řekne, které podklady a skills k projektu v Airine platí, a MD soubory
a skills po změně nahlásí do katalogu Airine. Funguje i bez spojení.

**Stav: beta.** Běží denně na jednom Macu se skutečným katalogem. Podepsaná aplikace ke stažení
zatím není; do prvního vydání jde jen sestavení ze zdrojů (níž).

## Instalace

1. Stáhni `Airine.dmg` z [Releases](https://github.com/Grooviostudio/airine-plugin/releases)
   a přetáhni Airine do Aplikací. *(Připravujeme, první vydání ještě není.)*
2. Spusť Airine. V liště nahoře se objeví ikona knih.
3. V Airine si vytvoř osobní token (Nastavení → Účet → API tokeny) a předej ho v terminálu:
   `pbpaste | /Applications/Airine.app/Contents/MacOS/airine prihlas`. Token se uloží do Klíčenky.
   Přihlášení přes prohlížeč připravujeme.
4. Lišta se zeptá, **ze kterých složek** má Airine brát MD dokumenty a skills. Mimo ně neodejde nic.
5. Plugin pro Claude Code (doporučení na začátku práce a hlášení po změně souboru):

   ```
   /plugin marketplace add Grooviostudio/airine-plugin
   /plugin install airine@airine
   ```

   Plugin volá aplikaci v `/Applications/Airine.app`. Bez ní nic nedělá a nehlásí chybu.

Odhlášení je `airine odhlas`. Přístup jde odvolat i v Airine v Nastavení mezi tokeny.

Když je katalog plný (Solo 2 000, Team 10 000 souborů), lišta napíše „Katalog je plný, navyš tarif“. Nové soubory počkají
na Macu ve frontě, nic se neztratí; nové verze souborů, které už v Airine jsou, projdou dál.

## Co dělá a co ne

- Hlásí jen soubory ve složkách, které si vybereš (dialog v liště nebo `airine slozky pridej
  CESTA`). Dokud žádnou nevybereš, nehlásí nic. Pracovní kopie repozitářů (`.claude/worktrees`)
  a skryté složky nehlásí nikdy, kromě míst se skills a pravidly agentů
  ([docs/slozky.md](docs/slozky.md)).
- Čte jen soubory, které agent právě upravil (`.md`, `.mdc`, do 1 MB), a jejich hlavičku.
- Do Airine posílá hlavičku souboru (front matter: název, popis, typ, fakta), cestu na tomhle
  počítači, otisk (SHA-256), počet řádků a velikost, a název počítače.
- S kartou posílá i obsah souboru (text do 1 MB: `.md`, `.mdc`, `.txt`, `.csv`, `.json`, `.yaml`),
  aby ho v Airine četli i kolegové bez souboru. Jen když bajty na disku sedí s otiskem karty;
  jinak jde karta bez obsahu. Vypíná se v liště nebo `airine obsah ne`. Obsah jde do úložiště
  přes jednorázovou adresu od serveru, token Airine úložiště nedostane.
- Soubor, ve kterém je něco jako klíč, heslo nebo token s hodnotou (`sk-…`, `api_key: …`,
  `Bearer …`, soukromý klíč, JWT, dlouhé base64), odejde jen jako karta, obsah nikdy.
- `airine vynech VZOR…` trvale vynechá obsah celých složek, odejde z nich jen karta
  ([docs/vynechani.md](docs/vynechani.md)).
- `airine nahraj-obsah [--koren CESTA]… [--vynech VZOR]… [--pauza MS] [--zkouska] [--vypis]` dožene obsah karet, které ho
  v Airine ještě nemají (třeba z dřívějšího importu). Posílá jen soubory, jejichž otisk sedí
  s kartou, popis ani vazby karty nemění. Relativní cesty z importu hledá pod `--koren` a z něj
  nevyjde. Posílá po dávkách do stropu serveru (`--pauza` je mezi dávkami, výchozí 500 ms);
  server bez dávek nebo soubor, který není UTF-8, jde po jednom. Vypíše rozpad podle
  přípony, soubory s tajemstvím a s `--vypis` i seznam souborů.
- Místní kopie katalogu je v `~/Library/Application Support/Airine`, každý řádek
  šifrovaný (AES-GCM). Klíč i osobní token jsou v Klíčence.
- Lišta sama hlídá vybrané složky (FSEvents, žádné procházení disku): změna souboru je
  v Airine do minuty, ať ji udělal kdokoli. Smazaný soubor se odrazí jen v místech karty,
  karta zůstává ([docs/hlidani.md](docs/hlidani.md)). `airine porovnej [--zkouska]`
  porovná vybrané složky s místní kopií z terminálu.
- Soubor bez hlavičky se hlásí taky, jako u importu složky: jméno z názvu souboru, typ
  z cesty, popis prázdný. Do souboru se nepíše nic, karta se páruje podle cesty a otisku.
- Soubor s hlavičkou `airine:`: v bloku mají `name` a `popis` přednost před `name`
  a `description` nahoře, typ je `airine.typ`. U skillu (`SKILL.md` nebo `metadata.airine-id`)
  platí `name` a `description` nahoře a typ je `skill`. Jméno ve špatném tvaru se nehlásí
  a agent dostane návrh.
- Soubor, který má na prvním řádku watermark (`<!-- airine vlastnik=… -->`), plugin přeskočí:
  nehlásí ho, nic do něj nepíše a agentovi nic neradí. Takové dokumenty mají vlastníka
  a historii v gitu.
- Když hlavička `airine:` nemá `airine.id`, hook ho doplní (u `SKILL.md` do `metadata.airine-id`).
  Hlídání lišty do souborů nepíše nikdy.
- Nic neměří a nedělá snímky obrazovky.

## Části

| Cesta | Co to je |
|---|---|
| `Sources/AirineCore` | Místní kopie (SQLite), fronta hlášení, synchronizace, hlavičky, doporučení, místní MCP |
| `Sources/airine` | Příkaz `airine`: hooky, `prihlas`, `odhlas`, `sync`, `stav`, `propoj`, `vyres`, `slozky`, `porovnej`, `obsah`, `vynech`, `nahraj-obsah`, `mcp` |
| `Sources/AirineLista` | Aplikace v liště (SwiftUI `MenuBarExtra`) |
| `claude-plugin` | Plugin pro Claude Code: hooky SessionStart a PostToolUse, MCP server `airine mcp` |
| `.claude-plugin/marketplace.json` | Repo jako marketplace Claude Code (`/plugin marketplace add`) |

## Sestavení a testy

Stačí Command Line Tools (Swift 6), Xcode není potřeba.

```bash
swift build
```

Testy s Command Line Tools potřebují cestu k frameworku Testing:

```bash
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
L=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
AIRINE_KLICE=soubor swift test -Xswiftc -F$F -Xlinker -F$F -Xlinker -rpath -Xlinker $F -Xlinker -rpath -Xlinker $L
```

`AIRINE_KLICE=soubor` drží klíče v souborech místo Klíčenky (jen pro testy),
`AIRINE_DOMOV` přesměruje místní data jinam.

## Rozhraní serveru

Plugin mluví s Airine přes `/api/katalog/*` s osobním tokenem (`x-api-key`) a hlavičkou
zařízení `x-airine-zarizeni`. Token je osobní token z Airine předaný `airine prihlas`
na stdin. Přihlášení v prohlížeči (OAuth s PKCE, návrat na `http://127.0.0.1:<port>/prihlaseni`)
je v kódu hotové, ale vypnuté: server token z OAuth zatím pouští jen na `/mcp`. Hlášení se páruje podle (id, otisk), takže opakované
odeslání téže verze nic nezdvojí. Souběžná změna ze dvou zařízení skončí jako rozpor,
nic se tiše nepřepíše.

## Licence

MIT, viz `LICENSE`.
