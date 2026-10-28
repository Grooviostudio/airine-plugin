# Podpis aplikace a Klíčenka — návrh

**Stav: návrh. V kódu ani ve vydání zatím nic z toho není.**

## Proč se Klíčenka ptá znovu a znovu

- `Airine.app` je podepsaná ad-hoc (`Signature=adhoc`, bez Team ID). Každý build má
  jiný otisk a položka v Klíčence si pamatuje otisk binárky, která ji založila.
  Po aktualizaci ji macOS nepozná a ptá se znovu.
- V aplikaci jsou dvě binárky: lišta (`AirineLista`) a příkazová řádka (`airine`).
  Položky `token` a `klic-kopie` založila vždy jedna z nich, druhá se musí ptát.
- Klíčenka se čte při každém volání:
  - lišta čte `token` při každé synchronizaci, tedy každou minutu (`App.swift`, `token()`);
  - `airine mcp` čte `token` a `klic-kopie` u každého nástroje (`otevri()`, `token()`).
    Běží jeden proces na session, takže jich bývá několik najednou;
  - hook `airine nahlas` je krátký proces, čte jednou za spuštění.

Dotaz se tedy vrací každou minutu a po každé aktualizaci od začátku.

## Varianty podpisu

| | A. Vlastní stálý certifikát | B. Developer ID (Apple) | C. Požadavek jen podle identifikátoru |
|---|---|---|---|
| Cena | zdarma | 99 USD ročně (Apple Developer Program) | zdarma |
| Co je potřeba od majitele Macu | jednou založit certifikát pro podpis kódu v Klíčence (Klíčenka → Asistent certifikátů → typ „Podpis kódu“) a povolit jeho použití, jednou „Povolit vždy“ po přechodu | registrace do programu: jako firma s číslem D-U-N-S (zdarma, vyřízení trvá dny až týdny), nebo jako fyzická osoba (rychlejší, u aplikace se pak ukazuje jméno osoby). Pak certifikát „Developer ID Application“ a heslo pro notarizaci | nic |
| Klíčenka po aktualizaci | neptá se (stejný certifikát = stejný požadavek) | neptá se | neptá se |
| Sdílení mezi binárkami | ano, přes seznam důvěryhodných aplikací u položky (obě binárky) | ano a nejčistěji: společná skupina přístupu `<TeamID>.eu.airine.plugin`, Klíčenka se neptá vůbec | ano |
| Gatekeeper u zákazníka | nepomůže, aplikace z internetu se neotevře bez obcházení | podepsaná a notarizovaná, otevře se normálně | nepomůže |
| Automatické aktualizace | jen na tomhle Macu | ano (aktualizace musí být podepsaná stejným Team ID) | jen na tomhle Macu |
| Bezpečnost | dobrá, klíč certifikátu je jen na tomhle Macu | nejlepší | **slabá**: token by přečetl kterýkoli program, který se ad-hoc podepíše stejným identifikátorem |

**C nedoporučuju.** Token Airine by byl chráněný jen názvem, který si může dát kdokoli.

## Doporučení

1. **Hned, bez ceny: A + úprava kódu níž.** Odstraní dotaz na vývojovém Macu. Po
   přechodu se Klíčenka zeptá naposledy, aplikace položky přečte a založí je znovu
   se správným přístupem.
2. **Před první instalací u zákazníka: B.** Bez Developer ID a notarizace se aplikace
   stažená z internetu neotevře a automatické aktualizace nemají čím ověřit původ.
   Číslo D-U-N-S je dobré zažádat hned, protože vyřízení trvá nejdéle.

## Úprava kódu (patří k A i B)

1. **Obě binárky smí číst obě položky.**
   - U A: položka se zakládá s přístupem (`SecAccess`), který jmenovitě povoluje obě
     binárky z `Airine.app`. Při přechodu ji binárka, která ji smí číst, přečte, smaže
     a založí znovu s tímto přístupem.
   - U B: položky se přesunou do Klíčenky s ochranou dat (`kSecUseDataProtectionKeychain`)
     se skupinou přístupu `<TeamID>.eu.airine.plugin`. Obě binárky ji dostanou
     v entitlementu `keychain-access-groups`. Dotaz pak nevzniká vůbec.
2. **Klíčenka se čte jednou za proces.**
   - `Tajemstvi` dostane paměťovou mezipaměť: první `cti` jde do Klíčenky, další
     vrací uloženou hodnotu. `zapis` a `smaz` ji aktualizují.
   - Lišta si token drží v paměti a znovu ho čte, jen když server vrátí 401 nebo
     když se token v nastavení změní.
   - `airine mcp` přečte `token` a `klic-kopie` při startu, ne u každého nástroje.
   - Hook zůstává na jednom čtení za spuštění.
3. **Test:** mezipaměť se dá ověřit s `AIRINE_KLICE=soubor` (počet čtení úložiště za
   proces = 1 na položku). Chování Klíčenky se ověří ručně na Macu po přepodepsání.
