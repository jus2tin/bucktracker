module Domain.Transaction
  ( TransactionLine (..)
  , Categorization (..)
  , Transaction (..)
  , transactionAmount
  , mkInflowTransaction
  , mkSpendingTransaction
  , mkTransferPair
  ) where

import Data.List.NonEmpty (NonEmpty, toList)
import Data.Text (Text)
import Data.Time (Day)
import Domain.Error (DomainError (..))
import Domain.Types
  ( AccountId
  , Cents
  , CategoryId
  , ImportHash
  , TransactionId
  , TransactionStatus
  , TransferId
  , negateCents
  )

-- | Eén regel van een (eventueel gesplitste) transactie.
data TransactionLine = TransactionLine
  { tlCategory :: CategoryId
  , tlAmount   :: Cents
  } deriving stock (Eq, Show)

-- | Waar het bedrag van een transactie naartoe gaat. Een gesloten somtype:
-- een transactie is altijd precies één van de drie, nooit "geen van alle"
-- of "allebei" — dat maakt invariant 5 ("elke niet-transfer transactie
-- heeft een categorie, of is een split") een typeniveau-garantie voor de
-- 'Categorized'-tak.
data Categorization
  = -- | Normale uitgave/inkomst, verdeeld over één of meer categorieën.
    -- 'NonEmpty' garandeert minstens één regel: "een split zonder regels"
    -- is onrepresenteerbaar.
    Categorized (NonEmpty TransactionLine)
  | -- | Stroomt direct naar Ready to Assign (inkomen, beginstand). Heeft
    -- bewust geen categorie: dit *is* het geld dat nog verdeeld moet
    -- worden. Zie DECISIONS.md §3 voor waarom dit een bewuste uitzondering
    -- is en geen gat in de invariant.
    Inflow Cents
  | -- | De andere kant van een transfer; raakt geen categorie of Ready to
    -- Assign. Draagt het tegenovergestelde 'AccountId' en het (al
    -- ondertekende) bedrag van déze kant van de transfer.
    TransferLeg TransferId AccountId Cents
  deriving stock (Eq, Show)

data Transaction = Transaction
  { txId             :: TransactionId
  , txAccount        :: AccountId
  , txDate           :: Day
  , txPayee          :: Text
  , txStatus         :: TransactionStatus
  , txCategorization :: Categorization
  , txImportHash     :: Maybe ImportHash
  } deriving stock (Eq, Show)

-- | Het totale, ondertekende effect van deze transactie op het
-- rekeningsaldo. Voor 'Categorized' is dit per definitie de som van de
-- regels — een split kan dus nooit uit de pas lopen met het totaal
-- (invariant 3), want er is geen apart totaal om uit de pas mee te lopen.
transactionAmount :: Transaction -> Cents
transactionAmount tx = case txCategorization tx of
  Categorized ls         -> mconcat (map tlAmount (toList ls))
  Inflow amount          -> amount
  TransferLeg _ _ amount -> amount

mkInflowTransaction
  :: TransactionId
  -> AccountId
  -> Day
  -> Text
  -> TransactionStatus
  -> Cents
  -> Maybe ImportHash
  -> Transaction
mkInflowTransaction tid acc day payee status amount importHash =
  Transaction tid acc day payee status (Inflow amount) importHash

mkSpendingTransaction
  :: TransactionId
  -> AccountId
  -> Day
  -> Text
  -> TransactionStatus
  -> NonEmpty TransactionLine
  -> Maybe ImportHash
  -> Transaction
mkSpendingTransaction tid acc day payee status lines' importHash =
  Transaction tid acc day payee status (Categorized lines') importHash

-- | Maak de twee gekoppelde helften van een transfer. Door constructie
-- sommeren ze altijd tot nul (invariant 2): de ene helft is letterlijk de
-- negatie van de andere, er is geen aparte validatie die dat kan vergeten.
-- De enige mislukkingswijze: beide kanten dezelfde rekening.
mkTransferPair
  :: TransferId
  -> (TransactionId, AccountId) -- ^ (id, rekening) van de kant die het geld *verliest*
  -> (TransactionId, AccountId) -- ^ (id, rekening) van de kant die het geld *ontvangt*
  -> Day
  -> TransactionStatus
  -> Cents -- ^ het overgemaakte bedrag, als positief bedrag
  -> Either DomainError (Transaction, Transaction)
mkTransferPair tid (fromTxId, fromAcc) (toTxId, toAcc) day status amount
  | fromAcc == toAcc = Left TransferRequiresDistinctAccounts
  | otherwise = Right
      ( Transaction fromTxId fromAcc day "Transfer" status
          (TransferLeg tid toAcc (negateCents amount)) Nothing
      , Transaction toTxId toAcc day "Transfer" status
          (TransferLeg tid fromAcc amount) Nothing
      )
