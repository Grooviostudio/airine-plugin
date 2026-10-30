# Složky pro Znalosti

Plugin hlásí do Airine jen MD soubory a skills ze složek, které si člověk vybere.
Mimo ně nejde do Airine nic, ani karta, a agent nedostane ani radu, co doplnit
do hlavičky. **Dokud nevybereš žádnou složku, plugin nehlásí nic.**

## Jak vybrat

- Lišta se po přihlášení zeptá dialogem Finderu, ze kterých složek brát. V nabídce lišty
  je pak vidět „Airine bere z: …“ a tlačítko „Změnit složky…“ (nový výběr nahradí starý).
- Totéž v terminálu:

```
airine slozky                         vypíše vybrané složky
airine slozky pridej ~/Dokumenty/Firma
airine slozky --zrus ~/Dokumenty/Firma
```

Výběr je nastavení tohohle Macu (`slozky` v `nastaveni.json`). Platí pro hook, hlídání lišty ([hlidani.md](hlidani.md)), místní MCP
(`nahlas_soubor`) i `airine nahraj-obsah`.

## Co se nehlásí ani uvnitř vybraných složek

Tahle pravidla platí natrvalo pro hook, místní MCP, hlídání lišty i `airine nahraj-obsah`.
Z těchto míst nejde do Airine nic, ani karta. Hlídání jejich události zahodí dřív, než
cokoli čte.

| Co | Proč |
|---|---|
| `**/.claude/worktrees/` | Pracovní kopie repozitářů, duplicity souborů, které v katalogu už jsou |
| knihovny: `node_modules`, `vendor`, `bower_components`, `Pods` | README a dokumentace cizích balíčků, ne znalosti firmy. Jen v `node_modules` jich bývají tisíce |
| sestavení: `dist`, `build`, `.next`, `.nuxt`, `out`, `coverage`, `DerivedData` | Vygenerované soubory, zdroj leží jinde |
| prostředí nástrojů: `.git`, `venv`, `.venv`, `__pycache__` | Data nástrojů |
| ostatní skryté složky (`.obsidian`, `.vscode` …) pod vybranou složkou | Nástroje a jejich data, ne znalosti firmy |

Porovnává se po celých složkách pod vybranou složkou: `builds/` ani soubor `build.md`
se nepřeskočí. Vybraná složka sama se nepočítá (výběr `~/Projekty/build` platí).

**Pravidlo pro skills:** skryté složky `.claude/skills`, `.claude/agents`,
`.claude/commands` a `.cursor/rules` se hlásí. Leží v nich skills a pravidla agentů,
kvůli kterým katalog vzniká, a mají v něm zůstat. Platí to jen uvnitř vybraných složek.
Vybraná složka sama může být skrytá (třeba `~/.claude`). Knihovny a sestavení se ani
pod nimi nehlásí.

Seznam knihoven a sestavení je stejný jako u importu složky v prohlížeči. Až ho bude
posílat server, plugin ho převezme odtamtud.

Uvnitř vybraných složek dál platí vynechání obsahu ([vynechani.md](vynechani.md))
i pojistka na tajemství.

## Co výběr nedělá

- Karty, které už v Airine jsou a leží mimo vybrané složky, nearchivuje ani nemaže.
  Jen k nim přestane hlásit změny a dohánět obsah.
- Nic nečte mimo vybrané složky, ani při `nahraj-obsah`.
