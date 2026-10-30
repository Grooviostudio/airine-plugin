# Changelog

## 30. 10. 2026

- **Knihovny a sestavení se nehlásí nikdy.** `node_modules`, `vendor`, `bower_components`,
  `dist`, `build`, `.next`, `.nuxt`, `out`, `coverage`, `Pods`, `DerivedData`, `.git`, `venv`,
  `.venv`, `__pycache__`. Platí pro hook, hlídání (události se zahodí hned), místní MCP
  a `nahraj-obsah` ([docs/slozky.md](docs/slozky.md)).
- **Klíčenka jednou za proces.** Token a klíč místní kopie se drží v paměti procesu. Lišta
  token přečte znovu jen po 401. macOS se tak u ad hoc podepsané lišty neptá každou minutu.
- Na 503 s `Retry-After` (přetížené úložiště) plugin počká, nejdéle 30 s, a zkusí to až
  dvakrát znovu. Pak hlášení zůstane ve frontě do příští synchronizace.
- **Přeskakované složky ze serveru.** Seznam knihoven a sestavení a povolená skrytá
  místa plugin bere z GET /api/katalog/import (jednou za 6 hodin, uloží do kopie).
  Bez spojení nebo se starým serverem platí vestavěný seznam.
- **Obsah po dávkách.** Fronta posílá soubory s obsahem po 50 (do 3,5 MB) jedním požadavkem
  `POST /api/katalog/obsah-davka`. Přetížené soubory pošle znovu po `retry_after`, odmítnuté
  (`neplatne`), se stavem `chyba` nebo neznámým stavem ještě jednou po jednom. Server bez dávek nebo 413: po jednom jako dřív.

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
