-- | Runtime seams for the v2 step driver (M1+).
module Hwfi.Runtime.StepEnv
  ( StepEnv (..),
    newStepEnv,
  )
where

import Data.Aeson (Value (..), object)
import Data.Map.Strict (Map)
import Data.Text (Text)
import Hwfi.Runtime.Context (RunInfo (..), buildEnvRecord)
import Hwfi.Runtime.Gateways (ModelStore)
import Hwfi.Runtime.RunStore (createRunStore)
import Hwfi.Runtime.RunUsage (emptyRunUsage)
import Hwfi.Runtime.Trace (Tracer, newTracer)
import Hwfi.Runtime.Usage (UsageSeam, newUsageSeam)
import Hwfi.Runtime.Workspace (Workspace, workspaceRoot)
import Hwfi.TypedProject (TypedProject)

-- | Effectful dependencies for 'Hwfi.Runtime.StepDriver.stepMachine'.
data StepEnv = StepEnv
  { seProject :: TypedProject,
    seWorkspace :: Workspace,
    seModels :: ModelStore,
    seRunInfo :: RunInfo,
    seTracer :: Tracer,
    seUsage :: UsageSeam
  }

-- | Build a minimal step environment for tests and local stepping.
newStepEnv ::
  TypedProject ->
  Workspace ->
  -- | Whitelisted process environment (for @ctx.env@).
  Map Text Text ->
  -- | Run id.
  Text ->
  -- | Entrypoint qname text.
  Text ->
  IO StepEnv
newStepEnv tp ws envVars runId entrypoint = do
  tracer <- newTracer
  store <- createRunStore (workspaceRoot ws) runId
  usage <- newUsageSeam store Nothing emptyRunUsage
  pure
    StepEnv
      { seProject = tp,
        seWorkspace = ws,
        seModels = mempty,
        seTracer = tracer,
        seUsage = usage,
        seRunInfo =
          RunInfo
            { riRunId = runId,
              riStartedAt = "1970-01-01T00:00:00.000Z",
              riEntrypoint = entrypoint,
              riRootInputs = object [],
              riEnvFields = buildEnvRecord envVars
            }
      }
