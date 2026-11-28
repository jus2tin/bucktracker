# Track C Engineering Specification — ABN AMRO Bank Statement Importer (`CAMT.053` & `.TAB`/`.TXT`)

- **Date:** 2026-11-27
- **Author:** Gemini (Architect), for Claude (Developer) & Justin (Product Owner)
- **Parent Plan:** [`docs/phases/phase-02-hardening-and-forecasting.md`](phase-02-hardening-and-forecasting.md) (Track C: Step 10)
- **Synthetic Golden Fixtures:**
  - [`test/fixtures/abn-amro/abn_amro_sample.camt053.xml`](../../test/fixtures/abn-amro/abn_amro_sample.camt053.xml)
  - [`test/fixtures/abn-amro/abn_amro_sample.tab`](../../test/fixtures/abn-amro/abn_amro_sample.tab)
  - [`test/fixtures/abn-amro/abn_amro_overlap_window2.tab`](../../test/fixtures/abn-amro/abn_amro_overlap_window2.tab)

---

## 1. Domain Context: How ABN AMRO Actually Exports Statements

ABN AMRO retail ("Internet Bankieren" — *Bij- en afschrijvingen downloaden*) and commercial ("Access Online") accounts export up to **18 months** of history per download in two primary machine-readable formats (note: ABN AMRO consumer exports use **headerless tab-separated `.TAB`/`.TXT`** rather than RFC 4180 comma-separated CSV, alongside ISO 20022 **`camt.053.001.02` XML**):

| Format | Typical Filename | Encoding & Line Endings | Key Structural Strengths |
|---|---|---|---|
| **CAMT.053 XML** (`camt.053.001.02`, Dutch Payments Association / Betaalvereniging NL guidelines) | `CAMT053_*.xml` | UTF-8, LF or CRLF | Bank-assigned `<AcctSvcrRef>`, explicit IBANs (`<DbtrAcct>`/`<CdtrAcct>`), structured `<BkTxCd>`, separate `<RltdPties>` name vs. `<RmtInf>` description, batch `<Ntry>` breakdown (`<TxDtls>`). |
| **ABN AMRO `.TAB` / `.TXT`** | `TXT261127153012.TAB` / `.TXT` | UTF-8 or Windows-1252 (`CP1252`), CRLF (`\r\n`), **8 tab-delimited columns, NO header row** | Includes exact **pre-mutation (`Beginsaldo`) and post-mutation (`Eindsaldo`) running balances** on every row, plus `/TRTP/.../IBAN/.../NAME/.../REMI/...` or `BEA, Betaalpas ...` descriptions. |

---

## 2. Exact Deduplication Fingerprint (`ImportHash`) — 100% Idempotent Across Overlapping 18-Month Windows

### 2.1 The Overlapping-Window Problem (Why File-Row Index Alone Fails)

Suppose on `2026-11-15` a user buys **two identical €3.20 coffees** at `"Kiosk Centraal"`.
- If a deduplication hash only hashes `(date, amount, payee)`, the second coffee is **falsely dropped as a duplicate**!
- Conversely, if a deduplication hash appends `occurrenceIndexWithinUploadedFile`, and a later 18-month export starts or ends mid-day (or reverses ascending/descending sort order), the occurrence index can shift!

### 2.2 Two-Format Exact Invariants + Canonical `ImportHash` Formula

Both ABN AMRO formats carry an **immutable, export-window-invariant discriminator** that distinguishes two identical same-day coffees without depending on where the 18-month export window starts or ends:

1. **In `CAMT.053 XML`:** ABN AMRO assigns `<AcctSvcrRef>` per entry/transaction at booking time. Even if two €3.20 coffees happen in the same minute, their `<AcctSvcrRef>` values differ — and never change in future exports!
   - **Rule (CAMT.053 Primary — when `<AcctSvcrRef>` is present and `/= "NOTPROVIDED"`):**
     ```text
     ImportHash = "camt053:v1:" || sha256Hex(
       normalizeAccountId(stmtIban)  || "\n" ||
       txAcctSvcrRefOrEntryRef       || "\n" ||
       show(batchTxDtlsIndex)        || "\n" ||
       isoBookingDate                || "\n" ||
       show(signedAmountCents)
     )
     ```
   - **Rule (CAMT.053 Fallback — if `<AcctSvcrRef>` is absent or `"NOTPROVIDED"`):**
     Sort entries within the same `isoBookingDate` deterministically by `(signedAmountCents, counterpartyIban, canonicalWhitespace(payee), canonicalWhitespace(remittance))` and assign `sameDayOrdinal` (`0, 1, ...`) among identical tuples on that calendar date:
     ```text
     ImportHash = "camt053-fallback:v1:" || sha256Hex(
       normalizeAccountId(stmtIban)        || "\n" ||
       isoBookingDate                      || "\n" ||
       isoValueDate                        || "\n" ||
       show(signedAmountCents)             || "\n" ||
       normalizeAccountId(counterpartyIban)|| "\n" ||
       canonicalWhitespace(payee)          || "\n" ||
       canonicalWhitespace(remittance)     || "\n" ||
       show(sameDayOrdinal)
     )
     ```

2. **In ABN AMRO `.TAB` / `.TXT`:** Every row records `Beginsaldo` (balance *before* this row) and `Eindsaldo` (balance *after* this row). Because every real booking has `amountCents /= 0`, Coffee #1 transitions e.g. `125000 -> 124680` and Coffee #2 transitions `124680 -> 124360`. Those two balance pairs are **permanently fixed on the bank's ledger** regardless of what date range the user exports 6 or 17 months later, and regardless of top-down vs. bottom-up row ordering!
   - **Rule (`.TAB` / `.TXT`):**
     ```text
     ImportHash = "abntab:v1:" || sha256Hex(
       normalizeAccountDigits(col0Account) || "\n" ||
       isoBookingDate                      || "\n" ||
       isoValueDate                        || "\n" ||
       show(signedAmountCents)             || "\n" ||
       show(startBalanceCents)             || "\n" ||
       show(endBalanceCents)               || "\n" ||
       canonicalWhitespace(col7Description)
     )
     ```
   - **`normalizeAccountDigits`:** Strip spaces and leading zeros from BBAN/IBAN trailing 10 digits (e.g. both `"NL91ABNA0417164300"` and `"417164300"` normalize to `"417164300"`!).
   - **`canonicalWhitespace`:** `Text.unwords . Text.words` (collapses internal multi-space padding and strips `\r`/`\n`/`\t` edge differences without losing any token).

### 2.3 Cross-Format & Manual-Entry Soft Match Warning (Defense in Depth)

What if a user manually typed an expense (or imported `.TAB` in October) and then imports `CAMT.053` in November covering October?
- **Hard duplicate (`ExactDuplicate`):** `(account_id, import_hash)` already exists in `transactions` → automatically marked **"Already imported (skip)"** (unchecked & disabled by default in preview; enforced at DB level by `UNIQUE (account_id, import_hash) WHERE import_hash IS NOT NULL`).
- **Soft candidate duplicate (`PossibleExistingMatch TransactionId`):** No matching `import_hash`, **but** an existing transaction on `account_id` has `txAmount == signedAmountCents` and `abs (diffDays txDate bookingDate) <= 2` → highlighted in amber in the Import Preview UI (**"Matches existing €X.XX on YYYY-MM-DD — uncheck to skip, or link import hash"**), defaulting to **unchecked (skip)** so switching formats never silently double-counts!

---

## 3. Format Specifications & Parsing Rules (`src/Domain/Import/`)

Keep 100% of parsing and fingerprinting **pure** (`ByteString -> Either ImportParseError ParsedStatement` — zero `IO`, zero `Db`).

### 3.1 Proposed Pure Domain Types (`src/Domain/Import.hs`)

```haskell
data StatementFormat = FormatCamt053 | FormatAbnAmroTab
  deriving stock (Eq, Show, Enum, Bounded)

data DuplicateStatus
  = NewEntry
  | ExactDuplicate
  | PossibleDuplicate TransactionId Day Text -- ^ existing tx id, date, payee
  deriving stock (Eq, Show)

data ImportedRow = ImportedRow
  { irBookingDate      :: Day
  , irValueDate        :: Day
  , irAmount           :: Cents             -- ^ already signed: DBIT < 0, CRDT > 0
  , irSuggestedPayee   :: Text              -- ^ clean merchant / counterparty name
  , irCounterpartyIban :: Maybe Text        -- ^ normalized uppercase IBAN if present
  , irRemittance       :: Text              -- ^ clean human description / reference
  , irBankTxCode       :: Maybe Text        -- ^ e.g. "PMNT-ICDT-ESCT"
  , irImportHash       :: ImportHash
  } deriving stock (Eq, Show)

data ParsedStatement = ParsedStatement
  { psFormat           :: StatementFormat
  , psAccountRef       :: Text              -- ^ IBAN (CAMT.053) or account digits (.TAB)
  , psOpeningBalance   :: Maybe Cents
  , psClosingBalance   :: Maybe Cents
  , psRows             :: [ImportedRow]
  } deriving stock (Eq, Show)
```

### 3.2 `CAMT.053` (`camt.053.001.02`) Field Extraction (`src/Domain/Import/Camt053.hs`)

Use a pure XML parser from `lts-24.68` (`xml-conduit`'s `Text.XML.parseLBS` — pure, total `Either SomeException Document`, no TemplateHaskell; match element `nameLocalName` ignoring namespace prefix differences so both `urn:iso:std:iso:20022:tech:xsd:camt.053.001.02` and `.08` work seamlessly!):

1. **Account & Currency (`BkToCstmrStmt/Stmt/Acct`):**
   - Extract `Id/IBAN` (fallback `Id/Othr/Id`).
   - Check `Ccy` (and every `<Amt Ccy="...">`) equals `"EUR"`; return `Left (UnsupportedCurrency ccy)` otherwise.
2. **Balances (`Stmt/Bal`):**
   - `Tp/CdOrPrtry/Cd` in `["OPBD", "PRCD"]` → `psOpeningBalance` (negate `<Amt>` when `<CdtDbtInd> == "DBIT"`!).
   - `Tp/CdOrPrtry/Cd == "CLBD"` → `psClosingBalance` (negate `<Amt>` when `<CdtDbtInd> == "DBIT"`!).
3. **Entries (`Stmt/Ntry`):**
   - Filter `<Sts>` == `"BOOK"` (ignore `"PDNG"` / `"INFO"`).
   - `irBookingDate`: `BookgDt/Dt` (or prefix `YYYY-MM-DD` of `BookgDt/DtTm`).
   - `irValueDate`: `ValDt/Dt` (fallback `irBookingDate`).
   - `irBankTxCode`: join `BkTxCd/Domn/Cd`, `BkTxCd/Domn/Fmly/Cd`, `BkTxCd/Domn/Fmly/SubFmlyCd` with `"-"` (e.g. `"PMNT-IDDT-ESDD"`).
   - **Single vs. Batch `<NtryDtls>/<TxDtls>`:**
     - If `<NtryDtls>/<TxDtls>` has **0** elements: emit 1 `ImportedRow` using `<Ntry>/<Amt>`, `<Ntry>/<CdtDbtInd>`, `<Ntry>/<AcctSvcrRef>`, and `<Ntry>/<AddtlNtryInf>`.
     - If `<NtryDtls>/<TxDtls>` has **1..K** elements: emit 1 `ImportedRow` per `<TxDtls>` (index `0..K-1`):
       - **Amount:** `<TxDtls>/<AmtDtls>/<TxAmt>/<Amt>` (fallback `<Ntry>/<Amt>` when `K == 1`).
       - **Sign (`DBIT` = negative, `CRDT` = positive):** `<TxDtls>/<CdtDbtInd>` (fallback `<Ntry>/<CdtDbtInd>`). Reject `0.00` rows or handle cleanly.
       - **Reference for `ImportHash`:** `<TxDtls>/<Refs>/<AcctSvcrRef>` → fallback `<Ntry>/<AcctSvcrRef>` → fallback `<Ntry>/<NtryRef>`.
       - **Counterparty (`RltdPties` — direction-sensitive!):**
         - When `DBIT` (outgoing): Payee = `Cdtr/Nm` → fallback `UltmtCdtr/Nm`; IBAN = `CdtrAcct/Id/IBAN`.
         - When `CRDT` (incoming/refund): Payee = `Dbtr/Nm` → fallback `UltmtDbtr/Nm`; IBAN = `DbtrAcct/Id/IBAN`.
       - **Remittance (`RmtInf`):** Join all `RmtInf/Ustrd` lines with `" — "`, and if `RmtInf/Strd/CdtrRefInf/Ref` exists, append `"Ref: " <> ref`. Fallback to `<Ntry>/<AddtlNtryInf>`.
       - **POS Card Merchant Fallback:** For `PMNT-CCRD-POSD` (`BEA` / Apple Pay / contactless) where `<Cdtr>/<Nm>` is absent, extract the merchant name from `<AddtlNtryInf>` / `<Ustrd>` (see §3.3 `parseAbnDescription` — ABN AMRO uses the same `BEA, Betaalpas ...` string in `<AddtlNtryInf>`!).

### 3.3 ABN AMRO `.TAB` / `.TXT` Field Extraction (`src/Domain/Import/AbnTab.hs`)

1. **Byte Decoding (UTF-8 with Windows-1252 Fallback):**
   - Try `Data.Text.Encoding.decodeUtf8' bytes`.
   - On `Left _`, decode total byte-by-byte via Windows-1252 (`0x80 -> '€'`, `0x82..0x9F` standard CP1252 table, `0xA0..0xFF -> Char.chr (fromIntegral b)`). Never throw!
2. **Line & Column Splitting:**
   - Strip trailing `\r`, ignore completely blank trailing lines.
   - Split each non-empty line on `'\t'`. Must have **exactly 8 fields** (`[colAcct, colCcy, colTxDate, colStartBal, colEndBal, colValDate, colAmt, colDesc]`), else return `Left (InvalidTabColumnCount lineNum (length cols))`.
   - Verify `colCcy == "EUR"`.
   - Parse `colTxDate` and `colValDate` as `YYYYMMDD` (`fromGregorianValid`).
   - Parse `colStartBal`, `colEndBal`, and `colAmt` via `Api.Money.parseSignedEuros` (which already accepts signed comma decimals like `"-34,40"` and `"1250,00"`!).
   - **Balance-math sanity check:** Assert `startBalCents <> amtCents == endBalCents` (if violated, return `Left (InconsistentRowBalances lineNum)` — catches corrupted/truncated files immediately!).
3. **Structured Description Extraction (`parseAbnDescription :: Text -> (Text, Maybe Text, Text)` → `(suggestedPayee, maybeCounterpartyIban, cleanRemittance)`):**
   - **Pattern A — Slash-tagged SEPA (`Text.isPrefixOf "/TRTP/" desc`):**
     ABN AMRO encodes key-value pairs `/KEY/VALUE/...` with known keys `TRTP`, `IBAN`, `BIC`, `NAME`, `REMI`, `EREF`, `MARF`, `CSID`, `ORDP`, `ULTP`:
     - `suggestedPayee` = value of `NAME` (trimmed).
     - `maybeCounterpartyIban` = value of `IBAN` (trimmed).
     - `cleanRemittance` = non-empty parts of `[REMI, "Ref: " <> EREF (if /= "NOTPROVIDED"), "Mandate: " <> MARF]` joined with `" — "` (fallback `TRTP`).
   - **Pattern B — Card Terminal (`"BEA"` or `"GEA"` prefix, e.g. `"BEA, Betaalpas               Albert Heijn 1492,PAS123          NR:8492A1, 15.11.26/14:32       AMSTERDAM"`):**
     - Split fixed/multi-space segments (`splitOnMultiSpace` — runs of 2+ spaces): segment 1 (`"Albert Heijn 1492,PAS123"`), strip `",PAS" <> digits` suffix → `suggestedPayee = "Albert Heijn 1492"`, `cleanRemittance = canonicalWhitespace desc`.
   - **Pattern C — Legacy `SEPA Overboeking` / `SEPA Incasso` / `SEPA iDEAL` multi-space blocks or free text:**
     - Extract `IBAN: NL...` and `Naam: ...` / `Omschrijving: ...` if present; otherwise `suggestedPayee = take 60 (canonicalWhitespace desc)`.

---

## 4. Database Schema Addition & Import Preview Workflow

### 4.1 Migration `0002_account_iban_and_import_index.sql`

Adding an optional `iban TEXT` to `accounts` unlocks two killer UX features: (1) auto-matching an uploaded statement's `<IBAN>` / account number to the right Bucktracker account (preventing importing Savings into Checking by mistake!), and (2) **auto-detecting internal transfers** when `irCounterpartyIban` matches another Bucktracker account's `iban`!

```sql
ALTER TABLE accounts ADD COLUMN iban TEXT;

-- Enforces per-account idempotency at the database level while allowing
-- manual transactions (import_hash IS NULL) freely.
CREATE UNIQUE INDEX idx_transactions_account_import_hash
    ON transactions (account_id, import_hash)
    WHERE import_hash IS NOT NULL;

CREATE INDEX idx_assignments_year_month ON assignments (year, month);
```

### 4.2 Two-Step Import Preview → Commit UI (`src/Api/Import.hs`, `/import`)

Because Invariant 5 requires every non-transfer, non-inflow transaction on an on-budget account to have a `CategoryId`, importing is a clean two-step HTMX + Alpine flow:

1. **`GET /import`:** Upload `<form enctype="multipart/form-data" method="post" action="/import/preview">` selecting Target Account + File (`.xml`, `.tab`, `.txt`). Auto-detect format (`<Document` XML prefix → `FormatCamt053`, else `FormatAbnAmroTab`).
2. **`POST /import/preview`:**
   - Parses the file purely (`Domain.Import`). If the statement's IBAN/account digits conflict with the selected `Account`'s `accIban` (when set), reject immediately with an `errorBanner`!
   - Queries `Db.Import.classifyDuplicates conn accountId rows` (`ExactDuplicate` vs `PossibleDuplicate` vs `NewEntry`).
   - Renders the **Import Preview Table**:
     - `ExactDuplicate` rows: collapsed/dimmed badge *"Already imported — skipped"*.
     - `NewEntry` (and user-toggled `PossibleDuplicate`) rows:
       - If `irCounterpartyIban` matches another active `Account` (`sameBudgetStatus`): pre-select action **`Transfer -> <Account Name>`**!
       - Else if `irAmount > 0`: default to **`Inflow (Ready to Assign)`**, with option to pick a `Category` instead (e.g., for store refunds like the Zalando fixture!).
       - Else (`irAmount < 0` on an on-budget account): require picking an active `Category` (with an Alpine `applyToSamePayee` helper so assigning `"Albert Heijn 1492" -> Groceries` fills all other `"Albert Heijn 1492"` rows in one click!).
       - On a `Tracking` account: all selected rows commit directly as signed `Inflow` balance mutations.
3. **`POST /import/commit`:**
   - Runs inside a single `withImmediateTransaction`: inserts all checked rows with `TransactionStatus = Cleared` and `Just irImportHash` (for transfers: links `import_hash` on the source leg and pairs with the counterpart account, checking if the counterpart leg was already imported from the other account's statement so internal transfers between Checking and Savings don't double-book when *both* accounts' statements are imported!!).

> **CRITICAL Internal-Transfer Deduplication Rule:** When importing an internal transfer on Checking (`-€300` to Savings on `2026-11-20`), check if Savings *already* has an imported/unlinked transfer leg of `+€300` from Checking within `±1 day` (or attach deterministic transfer dedup): if Checking already created both legs via `insertTransfer`, then later importing Savings' own statement must detect the existing `TransferLeg` (`account_id = savingsId, counterpart_account_id = checkingId, date = 2026-11-20, amount = +30000`) as a `PossibleDuplicate` (defaulting to **skip / attach `import_hash` to existing leg** rather than creating a second transfer pair)!

---

## 5. Golden Test Fixtures Verification Matrix (`test/Domain/ImportSpec.hs`)

The three synthetic fixtures in `test/fixtures/abn-amro/` are pre-built to test every edge case on Day 1:

| Case # | Scenario Tested | In `abn_amro_sample.camt053.xml` | In `abn_amro_sample.tab` | In `abn_amro_overlap_window2.tab` |
|---:|---|---|---|---|
| 1 | Salary incoming SEPA Credit Transfer (`+€3,250.00`) | `NTRY-2026-0001` (`PMNT-ICDT-ESCT`) | Row 1 (`/TRTP/SEPA Overboeking/...`) | — (before overlap window) |
| 2 | SEPA Direct Debit utility bill with Mandate ID (`-€145.80`) | `NTRY-2026-0002` (`PMNT-IDDT-ESDD`, multi-line `<Ustrd>`) | Row 2 (`/TRTP/SEPA Incasso algemeen doorlopend/...`) | — (before overlap window) |
| 3 | iDEAL payment with structured `<CdtrRefInf>` (`-€59.95`) | `NTRY-2026-0003` (`PMNT-IRCT-ESCT`) | Row 3 (`/TRTP/iDEAL/...`) | Overlap Row 1 (**must skip on re-import!**) |
| 4 | **Same-day identical POS coffee #1** at Café De Bruin (`-€3.40`, UTF-8 `é`) | `NTRY-2026-0004` (`BEA`, `10:04`) | Row 4 (`Beginsaldo 4104,25 -> 4100,85`) | Overlap Row 2 (**must skip!**) |
| 5 | **Same-day identical POS coffee #2** at Café De Bruin (`-€3.40`, same day!) | `NTRY-2026-0005` (`BEA`, `15:18` — **must NOT collide with #4!**) | Row 5 (`Beginsaldo 4100,85 -> 4097,45` — **must NOT collide with #4!**) | Overlap Row 3 (**must skip!**) |
| 6 | Internal transfer Checking `NL91ABNA0417164300` → Savings `NL37ABNA0417164399` (`-€500.00`) | `NTRY-2026-0006` | Row 6 | Overlap Row 4 (**must skip!**) |
| 7 | Merchant category refund (`+€29.99`, multi-line remittance) | `NTRY-2026-0007` (`CRDT`) | Row 7 (`+29,99`) | — (new rows 5 & 6 test post-overlap imports: `-€67.20` Albert Heijn + `+€29.99` refund!) |
