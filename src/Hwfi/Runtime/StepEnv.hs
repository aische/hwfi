-- | Runtime seams for the v2 step driver (M1+).
module Hwfi.Runtime.StepEnv
  ( StepEnv (..),
    RunWorkflowSeam,
    ConfirmPolicy (..),
    StepOutcome (..),
    newStepEnv,
  )
where

import Data.Aeson (Value (..), object)
import Data.IORef (IORef, newIORef)
import Data.Map.Strict (Map)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Hwfi.Ast.Name (Ident, QName)
import Hwfi.Runtime.Context (RunInfo (..), buildEnvRecord)
import Hwfi.Runtime.Error (RuntimeError)
import Hwfi.Runtime.Gateways (ModelStore)
import Hwfi.Runtime.Machine (Machine)
import Hwfi.Runtime.RunStore (createRunStore)
import Hwfi.Runtime.RunUsage (emptyRunUsage)
import Hwfi.Runtime.Trace (Tracer, newTracer)
import Hwfi.Runtime.Usage (UsageSeam, newUsageSeam)
import Hwfi.Runtime.Value (RValue)
import Hwfi.Runtime.Workspace (Workspace, workspaceRoot)
import Hwfi.TypedProject (TypedProject)

-- | Result of a single machine transition.
data StepOutcome
  = -- | Machine advanced; may still be 'MsRunning'.
    Stepped Machine
  | -- | Entry workflow finished.
    RunCompleted RValue
  | -- | Machine is paused or failed; no transition applied.
    StepHalted Machine
  deriving stock (Eq, Show)

-- | How user-confirm gates behave inside @par@ branches.
data ConfirmPolicy
  = -- | Pause at confirm gates (operator must approve).
    ConfirmHold
  | -- | Approve confirm gates automatically (tests and trusted runs).
    ConfirmAuto
  deriving stock (Eq, Show)

-- | Run a nested workflow to completion (agent tool dispatch, eval-workflow).
type RunWorkflowSeam =
  QName -> Text -> Map Ident RValue -> IO (Either RuntimeError RValue)

-- | Effectful dependencies for 'Hwfi.Runtime.StepDriver.stepMachine'.
data StepEnv = StepEnv
  { seProject :: TypedProject,
    seWorkspace :: Workspace,
    seModels :: ModelStore,
    seRunInfo :: RunInfo,
    seTracer :: Tracer,
    seUsage :: UsageSeam,
    seRunWorkflow :: Maybe RunWorkflowSeam,
    -- | When 'Just', the machine being stepped is a @par@ branch at this index.
    seParBranchIndex :: Maybe Int,
    -- | Exec steps in @par@ branches require user confirm when 'ConfirmHold'.
    seConfirmPolicy :: ConfirmPolicy,
    -- | Confirm gates already approved this run (branch index, step id).
    seConfirmApprovals :: IORef (Set (Int, Ident))
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
  approvals <- newIORef Set.empty
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
            },
        seRunWorkflow = Nothing,
        seParBranchIndex = Nothing,
        seConfirmPolicy = ConfirmAuto,
        seConfirmApprovals = approvals
      }
