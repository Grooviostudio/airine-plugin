# Hlídání vybraných složek

Od 29. 10. 2026 lišta sama hlídá složky pro Znalosti ([slozky.md](slozky.md)). Změna
MD souboru se do Airine dostane do minuty, ať soubor upravil agent, člověk v editoru,
nebo ho tam někdo nakopíroval.

## Jak to funguje

- Lišta poslouchá události souborového systému (FSEvents) jen nad vybranými složkami.
  Disk neprochází. Po startu a po změně výběru jednou porovná otisky souborů ve vybraných
  složkách s místní kopií (`airine porovnej` dělá totéž z terminálu).
- Události se slévají: po poslední změně lišta počká 5 sekund, pak soubory nahlásí a pošle
  frontu. Editor, který ukládá dvakrát za sebou, tak nevytvoří dvě verze.
- Platí stejná pravidla jako u hooku: jen vybrané složky, bez pracovních kopií a skrytých
  složek (kromě míst se skills), soubory s watermarkem se přeskočí, strop 1 MB, vynechání
  obsahu a pojistka na tajemství.
- Stejná verze (stejný otisk na stejné cestě) se neposílá dvakrát.
- Bez spojení se hlášení řadí do fronty a odejdou, až spojení bude.
- Hlídání do souborů nic nepíše, ani `airine.id`.

## Soubor bez hlavičky

Soubor bez hlavičky Airine (nebo s cizí hlavičkou, třeba jen `description`) dostane kartu
stejně jako u importu složky v prohlížeči:

| Pole | Odkud |
|---|---|
| jméno | z názvu souboru (malá písmena a pomlčky, u `SKILL.md` název složky) |
| typ | z cesty pod vybranou složkou podle stejné tabulky jako import (`brief`, `nabidka`, `postup` …), jinak `poznamky` |
| popis | prázdný, doplní se v Airine v Revizi |

Do souboru se nepíše nic. Karta se k souboru páruje podle cesty a otisku. Když kartu
mezitím někdo upravil v Airine (popis, typ, klient), další verze souboru tyhle údaje
nepřepíše. Agent dostane radu, že karta je bez popisu, hlášení na radě nezávisí.

Soubor s hlavičkou `airine:` se hlásí jako dřív. Jen jméno ve špatném tvaru se nehlásí
a agent dostane návrh.

## Smazaný a přesunutý soubor

- Smazaný soubor se v Airine jen odrazí v místech karty („nikde na disku“). Karta se
  nemaže ani nearchivuje.
- Přesunutý soubor (stejný otisk, stará cesta už neexistuje) zůstává tou kartou, jen
  s novou cestou.
- Zmizelá místa odchází na `POST /api/katalog/mista/zmizela`. Dokud server cestu nemá,
  čekají v místní frontě.

## Karta z importu

Soubor, který už do Airine dostal import z prohlížeče, plugin nezná podle id. Server ho
podle člena, otisku a cesty převezme (`prevzato`) a plugin si id přepíše na existující
kartu, takže nevznikne duplicita.
