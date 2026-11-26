# Bucktracker — Decisions

Dit document legt de keuzes vast die zijn gemaakt voordat de code is geschreven.
Waar een keuze een subtiliteit bleek te hebben die niet expliciet was besproken,
staat dat als "Implementatienotitie" direct onder de betreffende beslissing — niet
als stille afwijking, maar als iets om straks te bevestigen/herzien.

## 1. Toolchain & repo

- **Resolver:** `lts-24.68` (GHC 9.10.3). Oorspronkelijke CLAUDE.md noemde GHC
  9.14.2 — dat was niet consistent met `stack.yaml` en niet geïnstalleerd; dit is
  gecorrigeerd.
- **Licentie:** MIT (`LICENSE` en `package.yaml` bijgewerkt).
- **`src/Lib.hs`:** verwijderd nu `src/Domain/` er staat.
- **Compiler flags:** `-Wall -Wmissing-export-lists -Wunused-packages` (plus de
  overige standaard `stack new`-warnings). `-Werror` is **CI-only**, niet in
  `package.yaml` zelf (zie §6).

## 2. Technische keuzes

| Onderdeel | Keuze |
|---|---|
| Database | SQLite via `sqlite-simple`, handgeschreven genummerde `.sql`-migraties, expliciete `FromRow`/`ToRow` (geen TemplateHaskell, geen `persistent`/`beam`). |
| Frontend | Servant + Lucid + HTMX, server-rendered, geen npm/JS-buildstap. |
| Auth | Geen in v0.1 (localhost-only). Wel `ReaderT AppEnv Handler` + `hoistServer` zodat handlers testbaar zijn zonder een echte server te starten. |
| Config | Env vars. Defaults: poort `8080`, DB-pad `%APPDATA%\bucktracker\bucktracker.db` op Windows — pad is configureerbaar zodat Linux (`$XDG_DATA_HOME` / `~/.local/share/bucktracker/bucktracker.db`) later triviaal is. |
| ID's | `newtype` rond `Int64`, auto-increment vanuit SQLite (`rowid`). UUID alleen waar straks dedup nodig is (import). |
| Valuta | Alleen EUR, in `Cents` (`Int64`). Geen `Currency`-veld in v0.1. |
| Tests | `hspec` + `QuickCheck` voor `Domain/`, in-memory SQLite voor `Db/` (fase 2), `hspec-wai` voor `Api/` (fase 3). |

## 3. Domeinregels (YNAB-engine)

### Rekeningen
- `AccountType = Checking | Savings | Cash | Tracking`. On-budget = alles behalve
  `Tracking`.
- Beginstand is **geen veld** op `Account`, maar een `Inflow`-transactie op die
  rekening (zie "Transacties" hieronder) — net als in YNAB stroomt dat bedrag
  direct naar Ready to Assign.

### Categorieën & maanden
- Twee niveaus: `CategoryGroup -> Category`.
- Periode is altijd een kalendermaand (`YearMonth`).
- **Maandovergang (cruciaal):** een positief categoriesaldo (`available`) rolt
  ongewijzigd door naar de volgende maand. Een negatief saldo (overbesteding)
  reset de categorie naar 0 en het hele tekort wordt afgetrokken van Ready to
  Assign. Geïmplementeerd in `Domain.Budget.rolloverCategoryMonth`, met als
  kern-invariant dat er bij die overgang geen geld ontstaat of verdwijnt:
  `rolloverCarry <> rolloverRtaAdjustment == available cm` geldt altijd (hard
  getest, zie `BudgetSpec`).

### Transacties & splits
- Bedragen: uitgaven negatief, inkomsten positief, in `Cents`. Een transactie
  heeft **drie** mogelijke "bestemmingen", gemodelleerd als één gesloten
  somtype `Categorization`:
  1. `Categorized (NonEmpty TransactionLine)` — normale uitgave/inkomst,
     verdeeld over één of meer categorieën. `NonEmpty` garandeert op
     typeniveau dat een gecategoriseerde transactie nooit "zonder regels" kan
     bestaan — dit is invariant 5 ("precies één categorie of split")
     afgedwongen door de compiler, geen runtime-check nodig.
  2. `Inflow Cents` — stroomt direct naar Ready to Assign, zonder categorie.
     **Implementatienotitie:** dit is de expliciete uitzondering op "elke
     niet-transfer transactie heeft een categorie" — inkomen en de beginstand
     *zijn* per definitie ongecategoriseerd geld dat nog verdeeld moet worden.
     Dat is precies hoe YNAB "Inflow: Ready to Assign" behandelt, en sluit aan
     bij de beginstand-beslissing hierboven.
  3. `TransferLeg TransferId AccountId Cents` — de andere kant van een
     transfer; raakt geen categorie en geen Ready to Assign.
- **Splits sommeren per constructie exact tot het totaal**
  (`transactionAmount` leidt het totaal af uit de regels in plaats van het
  apart op te slaan en te valideren) — invariant 3 is daardoor onmogelijk te
  schenden, niet alleen "getest".
- **Transfers:** twee gekoppelde `Transaction`-legs met een gedeelde
  `TransferId`. De ene leg is letterlijk `negateCents` van de andere
  (`mkTransferPair`), dus invariant 2 (som = 0) is ook een
  constructie-garantie. Enige validatie: de twee rekeningen moeten verschillen
  (`TransferRequiresDistinctAccounts`).
  - **Implementatienotitie / bekende beperking v0.1:** de invariant "som van
    on-budget rekeningsaldi = categorieën + Ready to Assign" klopt alleen
    zolang (a) `Categorized`-transacties uitsluitend op on-budget rekeningen
    staan, en (b) een transfer nooit een on-budget met een tracking-rekening
    verbindt (anders verdwijnt er geld uit de on-budget-kant zonder dat de
    budgetkant het ziet, of omgekeerd). Beide regels zijn in v0.1 **nog niet**
    als runtime-`DomainError` afgedwongen, omdat `Transaction`/`mkTransferPair`
    op zichzelf niet weet of een `AccountId` on-budget is (dat is
    aggregaat-kennis). Dit wordt een validatie in de assembly/service-laag
    zodra `Db`/`Api` er zijn (fase 2/3) — tot die tijd is het een
    gedocumenteerde aanname, en de property tests genereren bewust alleen
    "geldige werelden" (zie `Domain.Gen.genWorld`) om dit aan te tonen.
- **Import-dedup:** elke `Transaction` heeft een optioneel
  `txImportHash :: Maybe ImportHash` (nog ongebruikt in v0.1, voor CSV/CAMT.053
  import in een latere fase).

### Status & payees
- `TransactionStatus = Uncleared | Cleared | Reconciled`.
- Reconciliatie is een pure vergelijking (`clearedBalance == bankStatementBalance`),
  geen apart domeintype — de aanroeper (straks `Api`) beslist wat er met een
  mismatch gebeurt.
- Payee is in v0.1 gewoon `Text` op de transactie, geen aparte tabel/entiteit.

## 4. Scope v0.1 (MVP)

**Binnen scope:** rekeningen (on-budget & tracking), categoriegroepen +
categorieën, handmatige transacties (incl. splits & transfers), maandbudget met
doorrollen/overspending-reset, reconciliatie, Lucid+HTMX UI.

**Buiten scope (later):** creditcard-potjeslogica, targets/doelen, recurring
transactions, CSV/CAMT.053-import (hash-kolom staat al klaar), rapportages.

## 5. Invarianten (hard getest met QuickCheck in Fase 1)

1. Som van alle on-budget rekeningsaldi = som van alle categoriesaldi +
   Ready to Assign. → `Domain.Budget.budgetBalancesAccounts`,
   `BudgetSpec`, binnen de in §3 genoemde v0.1-beperking (geen gemengde
   on-budget/tracking-transfers, categorisatie alleen op on-budget rekeningen).
2. Elke transfer sommeert naar 0 over de twee legs. → constructie-garantie in
   `mkTransferPair`, getest in `TransactionSpec`.
3. Split-regels sommeren exact naar het transactietotaal. → constructie-garantie
   (`transactionAmount` leidt af, valideert niet), getest in `TransactionSpec`.
4. Per maand: beschikbaar = toegewezen + doorgerold vorige maand + activiteit
   (activiteit is al *ondertekend*: uitgaven negatief — dit is equivalent aan
   "... − uitgaven" met uitgaven als positief bedrag, maar in code consequent
   als één signed `Cents`-optelling geschreven om een apart
   plus/min-onderscheid te vermijden). → `Domain.Budget.available`, en de
   bijbehorende behoudswet bij de maandovergang
   (`rolloverCarry <> rolloverRtaAdjustment == available cm`) in `BudgetSpec`.
5. Geen transactie zonder rekening; elke niet-transfer transactie heeft precies
   één categorie (of is een split). → `txAccount` is een verplicht veld
   (typeniveau), `Categorized` gebruikt `NonEmpty` (typeniveau); de expliciete
   `Inflow`-uitzondering staat hierboven beschreven.

## 6. Open punten uit Fase 1 — nu beslist in §7, of bewust later

- **`-Werror` in CI:** zodra `Db/`/`Api/` de in `package.yaml` opgenomen
  dependencies (`sqlite-simple`, `servant*`, `warp`, `lucid`, …) daadwerkelijk
  gebruiken, verdwijnen de huidige `-Wunused-packages`-warnings op de
  `library`-component. Schakel `-Werror` in CI pas in nadat dat is gebeurd (of
  voeg per-fase dependencies toe in plaats van alles nu al), anders faalt elke
  CI-run op fase 1. (Nu sowieso niet relevant: CI zelf is uitgesteld tot na de
  MVP, zie §7.)
- **On-budget/tracking-transfervalidatie** (zie §3): beslist in §7 — nu, in
  Fase 2.
- **CI-pipeline:** beslist in §7 — bewust *niet* nu, pas na de MVP (zie §4 voor
  de scope-afbakening van die MVP).
- **Backup-strategie** voor het SQLite-bestand: beslist in §7.

## 7. Fase 2-beslissingen (Db-laag)

Geïnterviewd voorafgaand aan Fase 2. Per punt de keuze en de reden.

| Onderdeel | Keuze | Reden |
|---|---|---|
| Migratie-levering | Cabal `data-files` + `Paths_bucktracker` (`getDataFileName`) | Blijven losse, reviewbare `.sql`-bestanden; geen TemplateHaskell; cabal/stack installeert ze automatisch mee. |
| Migratie-runner | Auto-apply bij opstarten, bijgehouden in een `schema_migrations`-tabel | Simpel voor een single-user app; geen apart commando om te onthouden of te vergeten. |
| DB-connectiebeheer | Een echte connection pool (`resource-pool`) | Bewuste keuze tegen het "één connectie + lock"-advies in — zie toelichting onder de tabel. |
| SQLite-pragmas | `journal_mode=WAL`, `foreign_keys=ON`, `busy_timeout` | Betere concurrency (relevant nu er een pool is), FK's worden echt afgedwongen, geen directe "database is locked"-fouten. |
| `YearMonth`-opslag | Twee kolommen `year INTEGER, month INTEGER` | Geen parse-stap, triviaal te sorteren/filteren, 1-op-1 met `ymYear`/`ymMonth`. |
| Verwijderen van rekeningen/categorieën | Soft-delete (`archived_at`/`closed`-kolom) | Historische transacties blijven kloppend; geen cascade-delete-gedoe. |
| Transfer-validatie (on-budget/tracking) | Wordt nu een echte `DomainError`, in Fase 2 | De Db/repository-laag kan rekeningen opzoeken bij het opslaan van een transfer; voorkomt dat een inconsistente boekhouding ooit wordt opgeslagen. |
| Config laden | Een config-library (`envparse`) | Gestructureerde validatie/foutmeldingen voor env vars, in plaats van handmatig `lookupEnv`. |
| Db-teststrategie | Verse `:memory:`-connectie per test, migraties er telkens overheen | Volledige test-isolatie; iets meer overhead per test, maar geen kans dat tests elkaar beïnvloeden. |
| CI-pipeline | **Niet nu** — pas opzetten na de MVP (zie §4) | Eerst de MVP afbouwen; CI komt erbij zodra er een stabiel geheel is om te bewaken. (Besluit herzien tijdens het Fase 2-interview: oorspronkelijk "nu", gewijzigd naar "na MVP".) |
| Backup-strategie | SQLite's online backup API, vanuit de app zelf | Robuuster dan een losse bestandskopie, ook consistent tijdens gebruik; iets meer code dan een `.bak`-kopie. |

**Implementatienotitie — DB-connectiebeheer:** een pool heeft op een
single-user SQLite-db weinig voordeel voor *schrijven* (SQLite is sowieso
single-writer), maar helpt wel bij gelijktijdige *lezers* (bv. meerdere
open browsertabs/HTMX-requests) zonder dat elke request op een schrijvende
transactie hoeft te wachten — vooral met WAL-mode, die lezers niet laat
blokkeren door een actieve schrijver. `resource-pool` met een klein maximum
(bv. 4-8 connecties) is de te gebruiken library in Fase 2.
