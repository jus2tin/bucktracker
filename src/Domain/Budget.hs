module Domain.Budget
  ( Assignment (..)
  , CategoryMonth (..)
  , available
  , Rollover (..)
  , rolloverCategoryMonth
  , nextCarriedIn
  , categoryActivity
  , buildCategoryMonth
  , accountInflows
  , accountBalance
  , onBudgetBalanceTotal
  , assignedTotal
  , readyToAssign
  , budgetBalancesAccounts
  ) where

import Data.List.NonEmpty (toList)
import Domain.Account (Account (..), isOnBudget)
import Domain.Transaction
  ( Categorization (..)
  , Transaction (..)
  , TransactionLine (..)
  , transactionAmount
  )
import Domain.Types
  ( AccountId
  , Cents
  , CategoryId
  , YearMonth
  , dayToYearMonth
  , negateCents
  , zeroCents
  )

-- | Hoeveel geld deze maand aan een categorie is toegewezen. Dit is een
-- budget-invoer van de gebruiker, geen transactie.
data Assignment = Assignment
  { asgCategory :: CategoryId
  , asgMonth    :: YearMonth
  , asgAmount   :: Cents
  } deriving stock (Eq, Show)

-- | De volledige staat van één categorie in één maand.
data CategoryMonth = CategoryMonth
  { cmCategory  :: CategoryId
  , cmMonth     :: YearMonth
  , cmAssigned  :: Cents -- ^ deze maand toegewezen
  , cmActivity  :: Cents -- ^ som van transactieregels deze maand, al ondertekend
  , cmCarriedIn :: Cents -- ^ meegebracht vanuit de vorige maand, altijd >= 0
  } deriving stock (Eq, Show)

-- | Invariant 4: beschikbaar saldo = meegebracht + toegewezen + activiteit.
-- "Activiteit" is hier al ondertekend (uitgaven negatief), dus deze ene
-- optelling is equivalent aan "... − uitgaven" met uitgaven als positief
-- bedrag; zie DECISIONS.md §5.
available :: CategoryMonth -> Cents
available cm = cmCarriedIn cm <> cmAssigned cm <> cmActivity cm

-- | Resultaat van de maandovergang voor één categorie.
data Rollover = Rollover
  { rolloverCarry         :: Cents -- ^ naar volgende maand, altijd >= 0
  , rolloverRtaAdjustment :: Cents -- ^ impact op Ready to Assign, altijd <= 0
  } deriving stock (Eq, Show)

-- | De YNAB-maandovergang: een niet-negatief saldo rolt door, een negatief
-- saldo (overbesteding) reset de categorie naar 0 en het hele tekort wordt
-- afgetrokken van Ready to Assign. Geld gaat hierbij nooit verloren of
-- wordt gecreëerd: @rolloverCarry r \<\> rolloverRtaAdjustment r ==
-- available cm@ geldt voor elke 'CategoryMonth' (hard getest in
-- @BudgetSpec@).
rolloverCategoryMonth :: CategoryMonth -> Rollover
rolloverCategoryMonth cm
  | avail >= zeroCents = Rollover avail zeroCents
  | otherwise          = Rollover zeroCents avail
  where
    avail = available cm

-- | Wat de volgende maand als 'cmCarriedIn' voor deze categorie meekrijgt.
nextCarriedIn :: CategoryMonth -> Cents
nextCarriedIn = rolloverCarry . rolloverCategoryMonth

-- | Som van de transactieregels voor één categorie, in één maand.
categoryActivity :: CategoryId -> YearMonth -> [Transaction] -> Cents
categoryActivity cid month txs = mconcat
  [ tlAmount l
  | tx <- txs
  , dayToYearMonth (txDate tx) == month
  , Categorized ls <- [txCategorization tx]
  , l <- toList ls
  , tlCategory l == cid
  ]

-- | Bouw de 'CategoryMonth' voor één categorie uit de ruwe boekhouding
-- (toewijzingen + transacties). @carriedIn@ komt van de vorige maand
-- ('nextCarriedIn' op de vorige 'CategoryMonth'), of is 'zeroCents' voor de
-- allereerste maand.
buildCategoryMonth
  :: CategoryId -> YearMonth -> Cents -> [Assignment] -> [Transaction] -> CategoryMonth
buildCategoryMonth cid month carriedIn assignments txs = CategoryMonth
  { cmCategory  = cid
  , cmMonth     = month
  , cmAssigned  = mconcat
      [ asgAmount a | a <- assignments, asgCategory a == cid, asgMonth a == month ]
  , cmActivity  = categoryActivity cid month txs
  , cmCarriedIn = carriedIn
  }

-- | Som van alle 'Inflow'-transacties op on-budget rekeningen in een
-- maand: dit is het geld dat deze maand instroomt in Ready to Assign.
-- Inflows op tracking-rekeningen tellen bewust niet mee (ze horen niet bij
-- het budget) — net als hun rekeningsaldo buiten 'onBudgetBalanceTotal'
-- valt.
accountInflows :: [Account] -> YearMonth -> [Transaction] -> Cents
accountInflows accounts month txs = mconcat
  [ amount
  | tx <- txs
  , dayToYearMonth (txDate tx) == month
  , Inflow amount <- [txCategorization tx]
  , isOnBudgetAccount (txAccount tx)
  ]
  where
    isOnBudgetAccount aid = any (\a -> accId a == aid && isOnBudget a) accounts

-- | Saldo van één rekening: som van alle transactiebedragen erop.
accountBalance :: AccountId -> [Transaction] -> Cents
accountBalance aid txs = mconcat
  [ transactionAmount tx | tx <- txs, txAccount tx == aid ]

-- | Som van de saldi van alle on-budget rekeningen — de linkerkant van
-- invariant 1.
onBudgetBalanceTotal :: [Account] -> [Transaction] -> Cents
onBudgetBalanceTotal accounts txs = mconcat
  [ accountBalance (accId a) txs | a <- accounts, isOnBudget a ]

-- | Totaal toegewezen aan alle categorieën in een maand.
assignedTotal :: YearMonth -> [Assignment] -> Cents
assignedTotal month assignments = mconcat
  [ asgAmount a | a <- assignments, asgMonth a == month ]

-- | Ready to Assign aan het einde van een maand: wat er aan Ready to
-- Assign de maand binnenkwam, plus nieuwe inflows, minus alles wat deze
-- maand aan categorieën is toegewezen.
readyToAssign
  :: Cents -> [Account] -> YearMonth -> [Assignment] -> [Transaction] -> Cents
readyToAssign rtaCarriedIn accounts month assignments txs =
  rtaCarriedIn <> accountInflows accounts month txs <> negateCents (assignedTotal month assignments)

-- | Invariant 1: de som van de on-budget rekeningsaldi is altijd gelijk aan
-- de som van alle categoriesaldi plus Ready to Assign. Dit klopt zodra (a)
-- elke 'Categorized' transactie op een on-budget rekening staat en elke
-- categorie die in een regel voorkomt ook in @categoryMonths@ zit, en (b)
-- elke transfer twee on-budget (of twee tracking) rekeningen verbindt, nooit
-- gemengd — zie DECISIONS.md §3 voor de bekende v0.1-beperking hierachter.
budgetBalancesAccounts
  :: [Account] -> [CategoryMonth] -> Cents -> [Transaction] -> Bool
budgetBalancesAccounts accounts categoryMonths rta txs =
  onBudgetBalanceTotal accounts txs == mconcat (map available categoryMonths) <> rta
