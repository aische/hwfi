-- | v2 runtime transition driver (cursor + frames).
--
-- Executes one machine transition per 'stepMachine' call. The legacy executor
-- remains the default until M4 cutover (see @docs/execution-model.md@).
module Hwfi.Runtime.StepDriver
  ( StepOutcome (..),
    stepMachine,
    pauseMachine,
  )
where

import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Hwfi.Ast.Step (Statement (..))
import Hwfi.Runtime.Error (RuntimeError, internalError)
import Hwfi.Runtime.Machine
import Hwfi.Runtime.MachinePath (StmtContext (..), resolveStmtPath)
import Hwfi.Runtime.Value (RValue (..))
import Hwfi.TypedProject (TypedProject (..))

-- | Result of a single machine transition.
data StepOutcome
  = -- | Machine advanced; may still be 'MsRunning'.
    Stepped Machine
  | -- | Entry workflow finished.
    RunCompleted RValue
  | -- | Machine is paused or failed; no transition applied.
    StepHalted Machine
  deriving stock (Eq, Show)

-- | Execute one transition when status is 'MsRunning' or finish draining.
stepMachine :: TypedProject -> Machine -> IO (Either RuntimeError StepOutcome)
stepMachine tp machine = case mStatus machine of
  MsRunning -> stepRunning tp machine
  MsDraining -> stepDraining machine
  MsPaused _ -> pure (Right (StepHalted machine))
  MsCompleted -> pure (Right (StepHalted machine))
  MsFailed -> pure (Right (StepHalted machine))

-- | Mark the machine explicitly paused after the last completed transition.
pauseMachine :: Machine -> Machine
pauseMachine m =
  m
    { mStatus = case mStatus m of
        MsRunning -> MsPaused PauseExplicit
        MsDraining -> MsPaused PauseExplicit
        s -> s
    }

stepRunning :: TypedProject -> Machine -> IO (Either RuntimeError StepOutcome)
stepRunning tp machine =
  case mCurrent machine of
    CurReady -> stepFromReady tp machine
    CurDispatch _ -> pure (Left (internalStub "dispatch not implemented (M1)"))
    CurAgent _ -> pure (Left (internalStub "agent transitions not implemented (M2)"))
    CurAwaitConfirm c ->
      pure (Right (StepHalted machine {mStatus = MsPaused (PauseAwaitingConfirm c)}))

stepDraining :: Machine -> IO (Either RuntimeError StepOutcome)
stepDraining machine =
  -- M3: finish in-flight par branches, then move to paused confirm.
  pure (Right (StepHalted machine))

stepFromReady :: TypedProject -> Machine -> IO (Either RuntimeError StepOutcome)
stepFromReady tp machine =
  case resolveStmtPath tp (mPath machine) of
    Left "statement index out of range" -> completeWorkflow machine
    Left err -> pure (Left (internalStub err))
    Right ctx -> case scStmt ctx of
      SReturn _ _ -> completeWorkflow machine
      SStep step -> pure (Right (Stepped machine {mCurrent = CurDispatch step}))
      SIf {} -> pure (Left (internalStub "if not implemented (M1)"))
      SLoop {} -> pure (Left (internalStub "loop not implemented (M1)"))
      SWhile {} -> pure (Left (internalStub "while not implemented (M1)"))
      STry {} -> pure (Left (internalStub "try not implemented (M1)"))

completeWorkflow :: Machine -> IO (Either RuntimeError StepOutcome)
completeWorkflow machine =
  pure . Right . RunCompleted $
    fromMaybe (VRecord mempty) (mLastResult machine)

internalStub :: Text -> RuntimeError
internalStub msg = internalError ("step driver: " <> msg)
