# Airine plugin

Plugin pro Claude Code a Cursor a malá aplikace v liště macOS. Na začátku práce
agentovi řekne, které podklady a skills k projektu v Airine platí, a MD soubory
a skills po změně nahlásí do katalogu Airine. Funguje i bez spojení.

**Stav: kostra, netestováno na skutečném účtu.** Neinstaluj mimo vývoj.

## Co dělá a co ne

- Čte jen soubory, které agent právě upravil (`.md`, `.mdc`, do 1 MB), a jejich hlavičku.
- Do Airine posílá hlavičku souboru (front matter: název, popis, typ, fakta), cestu na tomhle
  počítači, otisk (SHA-256), počet řádků a velikost, a název počítače. Tělo souboru neposílá.
- Místní kopie katalogu je v `~/Library/Application Support/Airine`, každý řádek
  šifrovaný (AES-GCM). Klíč i osobní token jsou v Klíčence.
- Když soubor nemá v hlavičce `airine.id`, plugin ho doplní (u `SKILL.md` do `metadata.airine-id`).
  Jinak soubor nemění.
- Nic neměří a nedělá snímky obrazovky.

## Části

| Cesta | Co to je |
|---|---|
| `Sources/AirineCore` | Místní kopie (SQLite), fronta hlášení, synchronizace, hlavičky, doporučení, místní MCP |
| `Sources/airine` | Příkaz `airine`: hooky, `sync`, `stav`, `propoj`, `vyres`, `mcp` |
| `Sources/AirineLista` | Aplikace v liště (SwiftUI `MenuBarExtra`) |
| `claude-plugin` | Plugin pro Claude Code: hooky SessionStart a PostToolUse, MCP server `airine mcp` |

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
zařízení `x-airine-zarizeni`. Hlášení se páruje podle (id, otisk), takže opakované
odeslání téže verze nic nezdvojí. Souběžná změna ze dvou zařízení skončí jako rozpor,
nic se tiše nepřepíše.

## Licence

MIT, viz `LICENSE`.
