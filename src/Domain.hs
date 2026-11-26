-- | Aggregate module: import @Domain@ instead of each submodule
-- separately. Meant for consumers outside @Domain/@ (@Api/@ and @Db/@);
-- within @Domain/@ itself, submodules are imported individually to
-- avoid cycles.
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
