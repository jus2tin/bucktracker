-- | Parsing and formatting euro amounts from\/to HTML form fields —
-- shared by every @Api.*@ module instead of each pasting its own copy
-- (DECISIONS.md §12, Architect review S-2). Three parsers because the
-- three things on the page genuinely have different legal ranges: an
-- assignment or a reconciled balance can be negative, a split line or
-- a transfer amount never should be.
module Api.Money
  ( parseSignedEuros
  , parseNonZeroSignedEuros
  , parsePositiveEuros
  , centsToEuroText
  ) where

import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Read as TextRead
import Domain.Types (Cents, cents, centsValue, negateCents, zeroCents)

-- | Parses a decimal euro amount with an optional leading @-@ and
-- either @.@ or @,@ as the decimal separator (@"-25.50"@, @"12,34"@,
-- @"12"@) into whole cents, total and without 'Prelude.read'.
--
-- Bounded to whole-euro amounts @<= 100,000,000,000@ (one hundred
-- billion) specifically so @whole * 100 + frac@ can never overflow
-- 'Data.Int.Int64' (max ~9.22 quintillion) — a real, if practically
-- unreachable, gap in the previous unbounded parser (Architect review
-- S-2: a 10^17-euro input silently overflowed into a wrong, often
-- *positive*, amount after negation).
parseSignedEuros :: Text -> Maybe Cents
parseSignedEuros raw0 = do
  let raw = Text.strip raw0
  (negative, unsigned) <- case Text.uncons raw of
    Just ('-', rest) -> Just (True, rest)
    Just _           -> Just (False, raw)
    Nothing          -> Nothing
  let normalized = Text.map (\c -> if c == ',' then '.' else c) unsigned
  amt <- case Text.splitOn "." normalized of
    [wholePart] -> centsFromParts wholePart "00"
    [wholePart, fracPart]
      | Text.length fracPart == 1 -> centsFromParts wholePart (fracPart <> "0")
      | Text.length fracPart == 2 -> centsFromParts wholePart fracPart
    _ -> Nothing
  Just (if negative then negateCents amt else amt)

-- | Like 'parseSignedEuros', but rejects an amount of exactly zero —
-- for inputs where "didn't change anything" should be a validation
-- error (e.g. a future negative-allowed assignment) rather than a
-- silent, pointless write.
parseNonZeroSignedEuros :: Text -> Maybe Cents
parseNonZeroSignedEuros raw = do
  amt <- parseSignedEuros raw
  if amt == zeroCents then Nothing else Just amt

-- | Like 'parseSignedEuros', but only accepts a strictly positive
-- result — for amounts that are never legitimately zero or negative
-- in v0.1 (a transfer, an inflow, a split line's amount).
parsePositiveEuros :: Text -> Maybe Cents
parsePositiveEuros raw = do
  amt <- parseSignedEuros raw
  if amt > zeroCents then Just amt else Nothing

centsFromParts :: Text -> Text -> Maybe Cents
centsFromParts wholePart fracPart
  | Text.null wholePart = Nothing
  | otherwise = do
      whole <- parseInt64 wholePart
      frac <- parseInt64 fracPart
      if whole > 100000000000 then Nothing else Just (cents (whole * 100 + frac))

parseInt64 :: Text -> Maybe Int64
parseInt64 t = case TextRead.decimal t of
  Right (n, rest) | Text.null rest -> Just n
  _                                -> Nothing

-- | Formats whole cents as a euro string (@"-25.50"@, @"12.00"@).
-- Goes through 'Integer' rather than working on the underlying
-- 'Data.Int.Int64' directly: @abs (minBound :: Int64) == minBound@
-- (two's-complement wraparound) used to make @centsToEuroText (cents
-- minBound)@ print nonsense (double minus signs, a still-negative
-- "absolute value") — 'Integer' has no such bound to wrap around.
centsToEuroText :: Cents -> Text
centsToEuroText amt =
  sign <> Text.pack (show whole) <> "." <> pad2 frac
  where
    raw = toInteger (centsValue amt)
    sign = if raw < 0 then "-" else ""
    absValue = abs raw
    (whole, frac) = absValue `quotRem` 100
    pad2 n =
      let s = Text.pack (show n)
      in if Text.length s < 2 then "0" <> s else s
