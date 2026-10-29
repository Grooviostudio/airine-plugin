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

| Co | Proč |
|---|---|
| `**/.claude/worktrees/` | Pracovní kopie repozitářů, duplicity souborů, které v katalogu už jsou |
| skryté složky (`.git`, `.obsidian`, `.vscode` …) pod vybranou složkou | Nástroje a jejich data, ne znalosti firmy |

Výjimka ze skrytých složek: `.claude/skills`, `.claude/agents`, `.claude/commands`
a `.cursor/rules`. Tam leží skills a pravidla agentů, kvůli kterým katalog vzniká.
Vybraná složka sama může být skrytá (třeba `~/.claude`).

Uvnitř vybraných složek dál platí vynechání obsahu ([vynechani.md](vynechani.md))
i pojistka na tajemství.

## Co výběr nedělá

- Karty, které už v Airine jsou a leží mimo vybrané složky, nearchivuje ani nemaže.
  Jen k nim přestane hlásit změny a dohánět obsah.
- Nic nečte mimo vybrané složky, ani při `nahraj-obsah`.
