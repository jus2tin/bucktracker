# Project: Bucktracker
Persoonlijke zero-based / envelope budget- en geldtracker (YNAB-alternatief) gebouwd in Haskell met Servant.

Zie `DECISIONS.md` voor de volledige onderbouwing van alle keuzes hieronder,
inclusief bekende v0.1-beperkingen en wat er bewust nog openstaat.

## Tech Stack & Libraries
- **Build tool:** Stack, resolver `lts-24.68` (GHC 9.10.3).
- **Web framework:** Servant (`servant-server`, `warp`).
- **Database:** SQLite via `sqlite-simple` — handgeschreven, genummerde `.sql`-migraties
  en expliciete `FromRow`/`ToRow`-instances. Geen `persistent`/`beam`/`selda`, geen TemplateHaskell.
- **JSON:** `aeson` (gebruik `Generic` + `DerivingVia` of expliciete instances, geen `TemplateHaskell`).
- **Frontend:** Servant + Lucid + HTMX. Server-rendered HTML, geen npm/JS-buildstap.
- **Auth:** Geen auth in v0.1 (draait alleen op localhost). Handlers lopen wel al in
  `ReaderT AppEnv Handler` (via `hoistServer`) zodat ze zonder een draaiende server testbaar zijn.
- **Config:** Env vars. Defaults: poort `8080`, SQLite-pad `%APPDATA%\bucktracker\bucktracker.db`
  op Windows (configureerbaar, zodat Linux later triviaal is).
- **Tekst & Tijd:** Altijd `Data.Text` (strict) en `Data.Time` (`UTCTime` / `Day`). Geen `String` behalve aan de randen voor CLI/config.

## Architectuur & Mappenstructuur
- `app/Main.hs`: Entrypoint, config laden, DB-connectie en Warp-server starten.
- `src/Api/`: Servant API-type definities en route-handlers (dun houden, alleen HTTP-vertaling).
- `src/Domain/`: Pure business logic, domeintypes, validatie en berekeningen (geen `IO` of DB-calls).
- `src/Db/`: Database-queries en schema-definities.
- `test/`: `hspec` + `QuickCheck` tests (focus op domeinlogica en budget-invarianten), via `hspec-discover`.

## Coding Standards (Strikt)
- **Total functions only:** Gebruik NOOIT `head`, `tail`, `fromJust`, `read`, of `error` in productiecode. Gebruik pattern matching, `Maybe`, `Either`, of `NonEmpty`.
- **Type-safety:** Gebruik `newtype` wrappers voor ID's (`AccountId`, `CategoryId`, `CategoryGroupId`, `TransactionId`, `TransferId`) en geldbedragen (`Cents` als `Int64`, NOOIT `Double` of `Float` voor valuta). Maak illegale states onrepresenteerbaar waar mogelijk (bv. `NonEmpty` voor split-regels) in plaats van ze te valideren.
- **Language extensions:** `language: GHC2021` + `default-extensions`: `OverloadedStrings`, `StrictData`, `DeriveGeneric`, `DataKinds`, `TypeOperators`, `DerivingStrategies`, `DerivingVia` (in `package.yaml`).
- **Compiler flags:** `-Wall -Wmissing-export-lists -Wunused-packages` lokaal; `-Werror` alleen in CI (zie `DECISIONS.md` §6 voor waarom dat nu nog niet lokaal aan staat).
- **Error handling:** Gebruik `ExceptT` / `ServantError` alleen in de API-laag; in het domein pure `Either DomainError a` (zie `src/Domain/Error.hs`) of, waar een waarde nooit ongeldig kan zijn, een gewone totale functie.

## Build & Test Commando's
- Build: `stack build --fast`
- Test: `stack test`
- Run: `stack run`
- Linter/Formatter (indien aanwezig): `hlint src/` en `ormolu --mode inplace src/`

## Domeinregels (Bucktracker)
Samenvatting — volledige uitwerking en edge cases staan in `DECISIONS.md` §3-5.

- Alle bedragen worden opgeslagen en berekend in gehele centen (`Int64`), altijd EUR.
- **Rekeningen:** `OnBudget` (Checking/Savings/Cash) vs. `Tracking`. Beginstand = een `Inflow`-transactie naar Ready to Assign, geen apart veld.
- **Categorieën:** twee niveaus (`CategoryGroup -> Category`), periode = kalendermaand.
- **Maandovergang:** positief categoriesaldo rolt door; negatief saldo reset naar 0 en wordt afgetrokken van Ready to Assign van de volgende maand.
- **Transacties:** uitgaven negatief / inkomsten positief. Elke transactie is `Categorized` (één of meer categorieën, via `NonEmpty`), `Inflow` (ongecategoriseerd, naar Ready to Assign) of de helft van een `Transfer` (twee legs, gedeelde `TransferId`, som = 0, geen categorie-impact).
- **Status:** `Uncleared | Cleared | Reconciled`; reconciliatie is een pure vergelijking, geen apart type.
- **Payee:** vrije `Text` op de transactie in v0.1, geen aparte tabel.
- **5 harde invarianten** (QuickCheck in `test/Domain/`): zie `DECISIONS.md` §5.
