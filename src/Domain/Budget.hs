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

-- | How much money has been assigned to a category this month. This is
-- a user budget entry, not a transaction.
data Assignment = Assignment
  { asgCategory :: CategoryId
  , asgMonth    :: YearMonth
  , asgAmount   :: Cents
  } deriving stock (Eq, Show)

-- | The full state of one category in one month.
data CategoryMonth = CategoryMonth
  { cmCategory  :: CategoryId
  , cmMonth     :: YearMonth
  , cmAssigned  :: Cents -- ^ assigned this month
  , cmActivity  :: Cents -- ^ sum of transaction lines this month, already signed
  , cmCarriedIn :: Cents -- ^ carried over from the previous month, always >= 0
  } deriving stock (Eq, Show)

-- | Invariant 4: available balance = carried in + assigned + activity.
-- "Activity" here is already signed (expenses negative), so this single
-- addition is equivalent to "... − expenses" with expenses as a
-- positive amount; see DECISIONS.md §5.
available :: CategoryMonth -> Cents
available cm = cmCarriedIn cm <> cmAssigned cm <> cmActivity cm

-- | Result of the month rollover for one category.
data Rollover = Rollover
  { rolloverCarry         :: Cents -- ^ into the next month, always >= 0
  , rolloverRtaAdjustment :: Cents -- ^ impact on Ready to Assign, always <= 0
  } deriving stock (Eq, Show)

-- | The YNAB month rollover: a non-negative balance carries forward, a
-- negative balance (overspending) resets the category to 0 and the
-- whole shortfall is deducted from Ready to Assign. No money is ever
-- lost or created here: @rolloverCarry r \<\> rolloverRtaAdjustment r ==
-- available cm@ holds for every 'CategoryMonth' (hard-tested in
-- @BudgetSpec@).
rolloverCategoryMonth :: CategoryMonth -> Rollover
rolloverCategoryMonth cm
  | avail >= zeroCents = Rollover avail zeroCents
  | otherwise          = Rollover zeroCents avail
  where
    avail = available cm

-- | What the next month gets as 'cmCarriedIn' for this category.
nextCarriedIn :: CategoryMonth -> Cents
nextCarriedIn = rolloverCarry . rolloverCategoryMonth

-- | Sum of the transaction lines for one category, in one month.
categoryActivity :: CategoryId -> YearMonth -> [Transaction] -> Cents
categoryActivity cid month txs = mconcat
  [ tlAmount l
  | tx <- txs
  , dayToYearMonth (txDate tx) == month
  , Categorized ls <- [txCategorization tx]
  , l <- toList ls
  , tlCategory l == cid
  ]

-- | Build the 'CategoryMonth' for one category from the raw ledger
-- (assignments + transactions). @carriedIn@ comes from the previous
-- month ('nextCarriedIn' on the previous 'CategoryMonth'), or is
-- 'zeroCents' for the very first month.
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

-- | Sum of all 'Inflow' transactions on on-budget accounts in a month:
-- this is the money flowing into Ready to Assign this month. Inflows on
-- tracking accounts deliberately don't count (they're not part of the
-- budget) — just like their account balance falls outside
-- 'onBudgetBalanceTotal'.
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

-- | Balance of one account: sum of all transaction amounts on it.
accountBalance :: AccountId -> [Transaction] -> Cents
accountBalance aid txs = mconcat
  [ transactionAmount tx | tx <- txs, txAccount tx == aid ]

-- | Sum of the balances of all on-budget accounts — the left-hand side
-- of invariant 1.
onBudgetBalanceTotal :: [Account] -> [Transaction] -> Cents
onBudgetBalanceTotal accounts txs = mconcat
  [ accountBalance (accId a) txs | a <- accounts, isOnBudget a ]

-- | Total assigned to all categories in a month.
assignedTotal :: YearMonth -> [Assignment] -> Cents
assignedTotal month assignments = mconcat
  [ asgAmount a | a <- assignments, asgMonth a == month ]

-- | Ready to Assign at the end of a month: what came into Ready to
-- Assign this month, plus new inflows, minus everything assigned to
-- categories this month.
readyToAssign
  :: Cents -> [Account] -> YearMonth -> [Assignment] -> [Transaction] -> Cents
readyToAssign rtaCarriedIn accounts month assignments txs =
  rtaCarriedIn <> accountInflows accounts month txs <> negateCents (assignedTotal month assignments)

-- | Invariant 1: the sum of on-budget account balances always equals
-- the sum of all category balances plus Ready to Assign. This holds as
-- long as (a) every 'Categorized' transaction lives on an on-budget
-- account and every category referenced by a line is also present in
-- @categoryMonths@, and (b) every transfer connects two on-budget (or
-- two tracking) accounts, never mixed — see DECISIONS.md §3 for the
-- known v0.1 limitation behind this.
budgetBalancesAccounts
  :: [Account] -> [CategoryMonth] -> Cents -> [Transaction] -> Bool
budgetBalancesAccounts accounts categoryMonths rta txs =
  onBudgetBalanceTotal accounts txs == mconcat (map available categoryMonths) <> rta
