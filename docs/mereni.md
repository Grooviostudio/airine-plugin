# Měření času (krok 5) — plán

**Stav: plán. Měření v kódu zatím není.** Poběží jen po souhlasu v aplikaci a jen
přes Accessibility (žádné nahrávání obrazovky). Do Airine jde jen projekt a minuty,
jako návrh k potvrzení v Časech.

## Anonymní okna prohlížečů (pravidlo od 27. 10. 2026)

Plugin nesmí číst anonymní okna (inkognito, soukromé okno).

- Z anonymního okna se neukládá název okna, adresa ani nic dalšího. Neukládá se ani
  místně, ani v šifrované kopii, ani v logu.
- Čas v tu chvíli se počítá jen jako „prohlížeč“ bez detailu.
- Když se u prohlížeče nedá spolehlivě poznat, že je okno anonymní, plugin z něj
  názvy oken **nečte vůbec** a měří jen čas v aplikaci. Raději méně dat než omyl.
- Adresy (URL) plugin nečte z žádného okna, ani z běžného.

### Prohlížeč → jak se pozná → co měříme

| Prohlížeč | Jak se anonymní okno pozná | Co měříme |
|---|---|---|
| Google Chrome | AppleScript: `mode of front window` vrací `"incognito"` / `"normal"` (vlastnost slovníku Chrome). Potřebuje navíc oprávnění Automatizace pro Chrome. | Název okna jen při `normal`, zjištěno ve stejném vzorku jako název. Jinak jen „prohlížeč“. |
| Microsoft Edge | Chromium, slovník AppleScriptu má mít stejnou vlastnost `mode` jako Chrome (`"incognito"` = InPrivate). **Ověřit testem.** | Dokud test neprojde: jen čas v aplikaci. Pak jako Chrome. |
| Arc | Slovník AppleScriptu má u okna vlastnost `incognito` (boolean). **Ověřit testem**, Arc se už dál nevyvíjí a slovník se může změnit. | Dokud test neprojde: jen čas v aplikaci. Pak název jen při `incognito = false`. |
| Safari | Spolehlivě nijak. AppleScript ani Accessibility nemají vlastnost „soukromé“; soukromé okno se liší jen vzhledem. | **Jen čas v aplikaci**, názvy oken nečteme. |
| Firefox | Spolehlivě nijak. Nemá AppleScript; soukromé okno pozná jen přípona názvu, která je lokalizovaná a dá se změnit. | **Jen čas v aplikaci**, názvy oken nečteme. |
| Ostatní (Brave, Opera, Vivaldi, Dia, Orion, …) | Neověřeno. | **Jen čas v aplikaci.** |

Jak se pozná prohlížeč: plugin nevěří seznamu názvů. Za prohlížeč bere každou
aplikaci, kterou systém hlásí jako obsluhu adres `http`/`https`
(`NSWorkspace.urlsForApplications(toOpen:)`). Názvy oken pak čte jen u prohlížečů ze
seznamu výše, které mají ověřené rozpoznání. Nový nebo neznámý prohlížeč tak spadne
do „jen čas v aplikaci“.

Selhání = nic. Když zjištění režimu selže (vyprší, chybí oprávnění Automatizace,
okno se mezitím změnilo), vzorek se uloží jako „prohlížeč“ bez názvu. Režim a název
se čtou v jednom dotazu, aby se mezi nimi nepřeplo okno.

### Test před prvním spuštěním (u každého prohlížeče)

1. Místní stránka s `<title>AIRINE-ANONYM-<náhodný kód></title>`, otevřená
   v anonymním okně. Počkat aspoň tři vzorky měření.
2. Totéž s jiným kódem v běžném okně (kontrola, že měření vůbec běží).
3. Prohledat dešifrovanou místní kopii, frontu, log a odeslané návrhy.
   Kód z anonymního okna se nesmí objevit nikde. Čas je zapsaný jako „prohlížeč“.
4. U Safari, Firefoxu a ostatních se nesmí objevit ani kód z běžného okna.

Test běží v izolovaném domově (`AIRINE_DOMOV`), ne na pracovním Macu.

## Co plugin při měření čte a co ne

- Čte, která aplikace je vpředu, a jestli je počítač nečinný.
- Čte název okna jen v aplikacích, které nejsou prohlížeč, a v Chromu (později
  Edge, Arc) jen v běžném okně.
- Nečte: anonymní okna, adresy stránek, obsah oken, snímky obrazovky, klávesy.
- Zpracovává místně. Do Airine jde jen projekt a minuty, jako návrh k potvrzení.
