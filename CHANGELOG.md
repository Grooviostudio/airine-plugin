# Changelog

## 29. 10. 2026

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
