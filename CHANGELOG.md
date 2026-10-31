# Changelog

## 31. 10. 2026

- **Plugin pro Claude Code z marketplace.** Repo je zároveň marketplace
  (`.claude-plugin/marketplace.json`), instaluje se `/plugin marketplace add Grooviostudio/airine-plugin`
  a `/plugin install airine@airine`. Hooky bez nainstalované aplikace Airine nic nedělají
  a nehlásí chybu. Autor pluginu je Airine.
- **Plný katalog (Solo 2 000, Team 10 000 souborů).** Odpověď `strop_souboru` (u hlášení `kod`,
  v dávce stav `nad_stropem`, s `strop`, `pocet`, `tarif`) hlášení nezahodí ani neodmítne:
  nová karta čeká ve frontě, nová verze existující karty projde. Nové karty se pak 6 hodin
  nezkouší, „Synchronizovat teď“ v liště a `airine sync` je zkusí hned. Lišta ukáže
  „Katalog je plný (2 000 souborů, Solo). Na Macu čeká N nových souborů, nic se neztratí.“

## 30. 10. 2026

- **Knihovny a sestavení se nehlásí nikdy.** `node_modules`, `vendor`, `bower_components`,
  `dist`, `build`, `.next`, `.nuxt`, `out`, `coverage`, `Pods`, `DerivedData`, `.git`, `venv`,
  `.venv`, `__pycache__`. Platí pro hook, hlídání (události se zahodí hned), místní MCP
  a `nahraj-obsah` ([docs/slozky.md](docs/slozky.md)).
- **Klíčenka jednou za proces.** Token a klíč místní kopie se drží v paměti procesu. Lišta
  token přečte znovu jen po 401. macOS se tak u ad hoc podepsané lišty neptá každou minutu.
- Na 503 s `Retry-After` (přetížené úložiště) plugin počká, nejdéle 30 s, a zkusí to až
  dvakrát znovu. Pak hlášení zůstane ve frontě do příští synchronizace.
- **`airine nahraj-obsah` po dávkách.** Stejná cesta jako fronta (`obsah-davka`), stejné
  zacházení se stavy; `--pauza` je teď mezi dávkami. Stropy dávky (`obsah_davka`,
  `obsah_davka_bajtu`) plugin bere z GET /api/katalog/import spolu s přeskakovanými
  složkami, výchozí 50 souborů a 3,5 MB.
- **Přeskakované složky ze serveru.** Seznam knihoven a sestavení a povolená skrytá
  místa plugin bere z GET /api/katalog/import (jednou za 6 hodin, uloží do kopie).
  Bez spojení nebo se starým serverem platí vestavěný seznam.
- **Obsah po dávkách.** Fronta posílá soubory s obsahem po 50 (do 3,5 MB) jedním požadavkem
  `POST /api/katalog/obsah-davka`. Přetížené soubory pošle znovu po `retry_after`, odmítnuté
  (`neplatne`), se stavem `chyba` nebo neznámým stavem ještě jednou po jednom. Na 413 dávku půlí, dokud
  neprojde; samotný soubor pak jde po jednom. Server bez dávek: po jednom jako dřív.

## 29. 10. 2026

- **Lišta hlídá vybrané složky.** Změna MD souboru je v Airine do minuty, ať ji udělal
  kdokoli (FSEvents, slévání 5 s, žádné procházení disku; po startu jedno porovnání otisků).
  Smazaný nebo přesunutý soubor se odrazí jen v místech karty, karta zůstává. Bez spojení
  fronta. `airine porovnej [--zkouska]` ([docs/hlidani.md](docs/hlidani.md)).
- **Soubor bez hlavičky se hlásí.** Jméno z názvu souboru, typ z cesty jako u importu
  z prohlížeče, popis prázdný. Do souboru se nepíše, ani `airine.id`; karta se páruje podle
  cesty a otisku. Popis a vazby doplněné v Airine další verze souboru nepřepíše.
- **Složky pro Znalosti.** Plugin hlásí jen soubory ze složek, které si člověk vybere
  (`airine slozky`, dialog v liště). Výchozí seznam je prázdný: dokud nic nevybereš,
  plugin nehlásí nic. Pracovní kopie (`.claude/worktrees`) a skryté složky kromě míst se
  skills nehlásí nikdy. Dřívější karty mimo vybrané složky zůstávají ([docs/slozky.md](docs/slozky.md)).
- **Obsah souborů do Airine.** S kartou odejde i text souboru (do 1 MB), když sedí s otiskem
  karty. Vypínač `airine obsah ne` a v liště. Soubor s klíčem, heslem nebo tokenem odejde
  jen jako karta.
- `airine vynech` trvale vynechá obsah celých složek ([docs/vynechani.md](docs/vynechani.md)).
- `airine nahraj-obsah` dožene obsah karet z dřívějška. Mezi soubory dělá pauzu (`--pauza`,
  výchozí 500 ms), protože úložiště serveru při rychlé dávce odmítalo požadavky.
- Archivované karty z Airine zůstávají v místní kopii a nedoporučují se, `airine vrat` je vrátí.
