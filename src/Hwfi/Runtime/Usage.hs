-- | Run-scoped LLM usage and dollar-cost accounting (spec §8.4).
--
-- Maintains a monotonic running total across resume attempts, computes per-call
-- cost from provider metadata or catalog pricing, enforces an optional budget,
-- and persists the total in @run.json@.
module Hwfi.Runtime.Usage
  ( UsageSeam (..),
    newUsageSeam,
    callCostUsd,
    checkBudgetSeam,
    recordBilledCall,
  )
where

import Control.Monad (when)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Hwfi.Compat (ModelConfig (..), Usage (..), estimateCost)
import Hwfi.Runtime.Error (RuntimeError, llmError)
import Hwfi.Runtime.RunStore (RunMeta (..), RunStore, readRunMeta, rsMetaPath, writeRunMeta)
import Hwfi.Runtime.RunUsage (RunUsage (..), formatCostUsd)
import System.Directory (doesFileExist)

-- | Mutable usage state plus persistence and optional budget enforcement.
data UsageSeam = UsageSeam
  { usRef :: IORef RunUsage,
    usStore :: RunStore,
    usBudget :: Maybe Double
  }

-- | Create a fresh usage seam for a run attempt.
newUsageSeam :: RunStore -> Maybe Double -> RunUsage -> IO UsageSeam
newUsageSeam store budget initial = do
  ref <- newIORef initial
  pure UsageSeam {usRef = ref, usStore = store, usBudget = budget}

-- | Compute dollar cost for one billed provider call (spec §8.4.3).
callCostUsd :: ModelConfig -> Usage -> Double
callCostUsd mc usage
  | usage.usageTotalCost /= 0 = usage.usageTotalCost
  | otherwise = estimateCost mc.mcPricing usage

-- | Abort before a live provider call when the running total is already at or
-- above the budget ceiling (spec §8.4.6).
checkBudgetSeam :: UsageSeam -> IO (Either RuntimeError ())
checkBudgetSeam seam = do
  ru <- readIORef (usRef seam)
  pure (checkBudget (usBudget seam) ru)

checkBudget :: Maybe Double -> RunUsage -> Either RuntimeError ()
checkBudget (Just maxCost) ru
  | ruCostUsd ru >= maxCost =
      Left
        ( llmError $
            "LLM budget exceeded: running cost $"
              <> formatCostUsd (ruCostUsd ru)
              <> " is at or above ceiling $"
              <> formatCostUsd maxCost
        )
  | otherwise = Right ()
checkBudget Nothing _ = Right ()

-- | Add one billed call to the running total and persist it to @run.json@.
-- Returns the per-call @cost_usd@ for the trace event (spec §8.4.5).
recordBilledCall :: UsageSeam -> ModelConfig -> Usage -> IO Double
recordBilledCall seam mc usage = do
  let cost = callCostUsd mc usage
  newUsage <-
    atomicModifyIORef' (usRef seam) $ \ru ->
      let nu = addCall ru usage cost
       in (nu, nu)
  persistRunUsage seam newUsage
  pure cost

addCall :: RunUsage -> Usage -> Double -> RunUsage
addCall ru usage cost =
  RunUsage
    { ruTokensIn = ruTokensIn ru + usage.usageInputTokens,
      ruTokensOut = ruTokensOut ru + usage.usageOutputTokens,
      ruCostUsd = ruCostUsd ru + cost
    }

persistRunUsage :: UsageSeam -> RunUsage -> IO ()
persistRunUsage seam ru = do
  let store = usStore seam
  exists <- doesFileExist (rsMetaPath store)
  when exists $ do
    eMeta <- readRunMeta store
    case eMeta of
      Right meta -> writeRunMeta store meta {rmUsage = ru}
      Left _ -> pure ()
