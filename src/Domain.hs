-- | Verzamelmodule: importeer @Domain@ in plaats van elke submodule apart.
-- Bedoeld voor consumenten buiten @Domain/@ (straks @Api/@ en @Db/@); binnen
-- @Domain/@ zelf wordt per submodule geïmporteerd om cirkels te vermijden.
module Domain
  ( module Domain.Types
  , module Domain.Error
  , module Domain.Account
  , module Domain.Category
  , module Domain.Transaction
  , module Domain.Budget
  ) where

import Domain.Account
import Domain.Budget
import Domain.Category
import Domain.Error
import Domain.Transaction
import Domain.Types
