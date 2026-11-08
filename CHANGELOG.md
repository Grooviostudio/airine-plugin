# Changelog

## 8. 11. 2026

- **Karty ve Znalostech ukazují `precti_soubor`, ne cestu na disku.** U karty, jejíž
  obsah je uložený v Airine, píše `co_plati` i hook „ve Znalostech, čti precti_soubor
  <id>“ a cestu jen jako původ. Varování „leží jen na jednom počítači“ a „obsah zatím
  není v Airine“ zůstávají jen u karet bez obsahu v Airine. Liší-li se místní verze,
  řekne to. Prvních 40 platných karet je seřazených tak, že karty s popisem jdou nahoru.
- **Víc workspace na jednom Macu (profily).** `airine profil pridej <id> --nazev JMÉNO`
  založí profil s vlastní místní kopií (`profily/<id>/`) a vlastními položkami v Klíčence
  (`token.<id>`, `klic-kopie.<id>`). `airine slozka <cesta> --profil <id>` přiřadí složku.
  Hook, hlášení a místní MCP vyberou profil podle složky sezení, `--profil` ho určí ručně.
  Hlavička doporučení jmenuje workspace. Soubor ze složky jiného workspace se do tohohle
  nenahlásí. Výchozí profil zůstává beze změny jmen; bez `profily.json` se nic nemění.
- **`co_plati` bez argumentů zná složku sezení.** Najde propojený projekt podle složky,
  ve které agent pracuje, místo celého katalogu.
- **Lišta synchronizuje i další profily**, jeden po druhém, a ukáže jejich stav.
- **Hooky, MCP a tichý sync neukážou okno Klíčenky.** Procesy na pozadí čtou bez okna
  (`LAContext.interactionNotAllowed`) a do Klíčenky nepíšou: nezakládají klíč kopie
  a neobnovují token. Zamčená kopie: hook to řekne agentovi, MCP odpoví a zkusí to znovu
  při dalším volání. Dřív se okno ukazovalo při každém sezení a po každé aktualizaci.
- **Projekt bez karet neukáže prázdnou hlavičku.** Má-li propojený projekt 0 platných karet,
  hook i `co_plati` bez argumentů ukážou celý katalog workspace a řeknou proč. Výslovné
  `projekt_id` v `co_plati` dál vrátí jen projekt.
- **`airine propoj --zrus [--slozka CESTA]`** zruší propojení složky s projektem.
- **Propojení složky platí i přes symlink** (~/Desktop/X → ~/Developer/X), stejně jako výběr
  profilu. Dřív se přes odkaz projekt nenašel a ukázal se celý katalog.
- README: víc workspace a jak plugin vypnout.

## 7. 11. 2026

- **Strop v dávce obsahu už neodhlásí.** 403 z `/obsah-davka` se rozlišuje jako u hlášení:
  `strop_souboru` / `nad_stropem` je plný katalog, `bez_prava` karta bez práva, jinak
  nepřihlášen. Dřív byl každý 403 „nepřihlášen“ a plný katalog zastavil celou frontu.
- **Jedno hlášení nezasekne frontu.** Neznámá odpověď serveru (404, 413, nečekané tělo)
  hlášení přeskočí a zbytek fronty i stažení změn proběhne. Po 5 pokusech se hlášení odmítne
  s vysvětlením (`kod: opakovane`), agent i lišta ho uvidí jako odmítnuté.
- **Výpadek se do pokusů nepočítá.** Týden bez sítě hlášení neodmítne.
- **Smazaný soubor nepošle starou cestu.** Čekající hlášení smazaného souboru se zahodí.
  Karta, kterou server ještě nezná, nedostane zmizelé místo (server by ho odmítl a s ním
  celou dávku míst); u známé karty se místo oznámí jako dřív.
- **`co_plati` z čerstvé kopie.** Kopie starší než 5 minut se před odpovědí zkusí
  synchronizovat. Bez spojení odpoví kopie, jaká je.
- **`nahlas_soubor` neříká „Nahlášeno“ u odmítnutého hlášení.** Odmítnuté hlášení vypíše
  chyby a radu opravit hlavičku, čekající ve frontě „Uloženo do fronty“.
- README: testy s Command Line Tools potřebují i `-plugin-path` k makrům Testing.

## 31. 10. 2026

- **Přihlášení přes prohlížeč vypnuté.** Server token z OAuth zatím pouští jen na `/mcp`,
  katalog by ho odmítl. Lišta místo tlačítka radí osobní token, `airine prihlas --prohlizec`
  skončí srozumitelnou chybou. Kód přihlášení zůstává pro chvíli, kdy to server dovolí.
- **Přihlášení bez terminálu.** V liště „Přihlásit se…“ (nebo `airine prihlas --prohlizec`)
  otevře prohlížeč: OAuth s PKCE, který server už má pro MCP. Lišta si zaregistruje
  veřejného klienta „Airine pro Mac“ s návratem na `http://127.0.0.1:<port>/prihlaseni`
  a vymění kód za token. Token platí hodinu a před koncem nebo po 401 se obnoví. Obnova
  je pod zámkem souboru, aby se lišta a hook nepřetahovaly o jeden obnovovací token.
  Zamítnutá obnova (přístup odvolaný v Airine) znamená odhlášení, výpadek nic nemění.
  `airine odhlas` a „Odhlásit“ v liště token smažou. Osobní token z `airine prihlas`
  platí dál a přihlášení z prohlížeče nahradí.
- README: skutečný stav a instalace pro zákazníka.
- **Plugin pro Claude Code z marketplace.** Repo je zároveň marketplace
  (`.claude-plugin/marketplace.json`), instaluje se `/plugin marketplace add Grooviostudio/airine-plugin`
  a `/plugin install airine@airine`. Hooky bez nainstalované aplikace Airine nic nedělají
  a nehlásí chybu. Autor pluginu je Airine.
- **Plný katalog (Solo 2 000, Team 10 000 souborů).** Odpověď `strop_souboru` (u hlášení `kod`,
  v dávce stav `nad_stropem`, s `strop`, `pocet`, `tarif`) hlášení nezahodí ani neodmítne:
  nová karta čeká ve frontě, nová verze existující karty projde. Nové karty se pak 6 hodin
  nezkouší, „Synchronizovat teď“ v liště a `airine sync` je zkusí hned. Lišta ukáže
  „Katalog je plný (2 000 souborů, Solo), navyš tarif. Na Macu čeká N nových souborů, nic se neztratí.“

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
