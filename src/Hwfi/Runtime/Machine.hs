-- | Serializable execution machine (v2 runtime).
--
-- Replaces content-addressed skip-as-resume with an explicit cursor + frame
-- stack. See @docs/execution-model.md@.
module Hwfi.Runtime.Machine
  ( -- * Lifecycle
    MachineStatus (..),
    PauseReason (..),
    ConfirmRequest (..),
    -- * Position
    StmtPath (..),
    PathSegment (..),
    BlockKind (..),
    StepRef (..),
    -- * Reducible state
    Current (..),
    AgentState (..),
    PendingAgent (..),
    ToolRound (..),
    -- * Continuations
    Frame (..),
    ParJoinState (..),
    ParSlot (..),
    ParPoolPhase (..),
    WhileFrame (..),
    TryFrame (..),
    TryPhase (..),
    -- * Machine
    Machine (..),
    BranchMachine (..),
    unBranch,
    mkBranch,
    Bindings,
    initialMachine,
  )
where

import Data.Aeson (Value)
import Data.Map.Strict (Map)
import Data.Text (Text)
import Hwfi.Ast.Name (Ident, QName)
import Hwfi.Ast.Step (Binder, ParOnError, StepStmt)
import Hwfi.Runtime.Value (RValue)
import LLM.Core.Types (ToolCall, ToolResult, Turn)

-- | Top-level run status for the v2 machine.
data MachineStatus
  = -- | Actively scheduling / executing transitions.
    MsRunning
  | -- | Finishing in-flight transitions before a pause (confirm gate).
    MsDraining
  | -- | Explicit or confirm pause; no new transitions until continue.
    MsPaused PauseReason
  | -- | Entry workflow finished successfully.
    MsCompleted
  | -- | Unrecoverable failure recorded in 'mError'.
    MsFailed
  deriving stock (Eq, Show)

-- | Why a run is paused.
data PauseReason
  = -- | Operator/API requested pause after the last transition.
    PauseExplicit
  | -- | A step awaits user confirmation (may queue several; head is active).
    PauseAwaitingConfirm ConfirmRequest
  | -- | Loaded from crash with no explicit pause flag.
    PauseCrashRecovery
  deriving stock (Eq, Show)

-- | Human approval gate attached to a step (e.g. @builtin/exec@).
data ConfirmRequest = ConfirmRequest
  { crBranchIndex :: Maybe Int,
    crQName :: QName,
    crStepId :: Ident,
    crTitle :: Text,
    crDetail :: Value
  }
  deriving stock (Eq, Show)

-- | Address of the next statement to execute within a workflow body.
data StmtPath = StmtPath
  { spQName :: QName,
    spSegments :: [PathSegment]
  }
  deriving stock (Eq, Show)

-- | One level of navigation into nested control-flow blocks.
data PathSegment = PathSegment
  { psStmtIndex :: Int,
    psBlock :: Maybe BlockKind
  }
  deriving stock (Eq, Show)

-- | Which child block of a control-flow statement we are inside.
data BlockKind
  = BkIfThen
  | BkIfElse
  | BkLoopBody
  | BkTryTry
  | BkTryCatch
  | BkWhileInline
  deriving stock (Eq, Show)

-- | Correlates trace events with a workflow step.
data StepRef = StepRef
  { srQName :: QName,
    srStepId :: Ident
  }
  deriving stock (Eq, Show)

type Bindings = Map Ident RValue

-- | What the machine is reducing right now.
data Current
  = -- | At 'mPath'; next action is to begin the statement there.
    CurReady
  | -- | Evaluating arguments and dispatching a step call.
    CurDispatch StepStmt
  | -- | Inside an agent loop (model rounds and tool calls).
    CurAgent AgentState
  | -- | Blocked on user confirmation before proceeding.
    CurAwaitConfirm ConfirmRequest
  deriving stock (Eq, Show)

-- | Agent loop reducible state (mirrors @llm-workflow@ @Pending@ + round index).
data AgentState = AgentState
  { agStepRef :: StepRef,
    agPending :: PendingAgent,
    agRound :: Int,
    agSubmitRequired :: Bool
  }
  deriving stock (Eq, Show)

data PendingAgent = PendingAgent
  { paSystem :: Text,
    paPrompt :: Text,
    paHistory :: [Turn],
    paToolRounds :: [Turn],
    paActiveToolIds :: [Text],
    paLoadedInstructionIds :: [Text]
  }
  deriving stock (Eq, Show)

-- | In-progress tool round inside an agent step.
data ToolRound = ToolRound
  { trAssistant :: Turn,
    trPending :: [ToolCall],
    trCompleted :: [ToolResult],
    trActive :: Maybe ToolCall
  }
  deriving stock (Eq, Show)

-- | Defunctionalized continuation frames.
data Frame
  = -- | Return to the next statement after completing a block or step.
    FrSeq
      { fsScope :: Text,
        fsResumePath :: StmtPath,
        fsBinder :: Maybe Binder
      }
  | -- | Join parallel loop branches (real concurrency).
    FrPar ParJoinState
  | -- | @while@ loop continuation.
    FrWhile WhileFrame
  | -- | @try@/@catch@ boundary.
    FrTry TryFrame
  deriving stock (Eq, Show)

-- | State for an active @par@ pool (see @docs/execution-model.md@).
data ParJoinState = ParJoinState
  { pjsLoopId :: Ident,
    pjsScope :: Text,
    pjsBinder :: Binder,
    pjsMaxConcurrency :: Int,
    pjsOnError :: ParOnError,
    pjsItems :: [RValue],
    pjsSlots :: [ParSlot],
    pjsActive :: Map Int BranchMachine,
    pjsNextIndex :: Int,
    pjsPhase :: ParPoolPhase,
    pjsConfirmQueue :: [ConfirmRequest]
  }
  deriving stock (Eq, Show)

-- | Per-index branch status inside @par@.
data ParSlot
  = ParSlotPending
  | ParSlotRunning
  | ParSlotDone RValue
  | ParSlotFailed Text
  | ParSlotAwaitingConfirm ConfirmRequest
  deriving stock (Eq, Show)

-- | Scheduler phase for a @par@ pool.
data ParPoolPhase
  = ParScheduling
  | ParDraining
  | ParPausedConfirm
  deriving stock (Eq, Show)

data WhileFrame = WhileFrame
  { wfLoopId :: Ident,
    wfScope :: Text,
    wfBinder :: Binder,
    wfIteration :: Int,
    wfMaxIterations :: Int,
    wfAcc :: [RValue],
    wfCarry :: Maybe RValue
  }
  deriving stock (Eq, Show)

data TryFrame = TryFrame
  { tfLoopId :: Ident,
    tfScope :: Text,
    tfBinder :: Binder,
    tfPhase :: TryPhase
  }
  deriving stock (Eq, Show)

data TryPhase
  = TryInTry
  | TryInCatch
  deriving stock (Eq, Show)

-- | Full machine snapshot (persisted on each transition / pause).
data Machine = Machine
  { mStatus :: MachineStatus,
    mProjectHash :: Text,
    mScope :: Text,
    mPath :: StmtPath,
    mCurrent :: Current,
    mFrames :: [Frame],
    mBindings :: Bindings,
    mLastResult :: Maybe RValue,
    mError :: Maybe Text
  }
  deriving stock (Eq, Show)

-- | A branch inside @par@ is a full nested machine sharing the same shape.
newtype BranchMachine = BranchMachine {bmMachine :: Machine}
  deriving stock (Eq, Show)

unBranch :: BranchMachine -> Machine
unBranch = (.bmMachine)

mkBranch :: Machine -> BranchMachine
mkBranch = BranchMachine

-- | Build an initial machine at a workflow entrypoint (top of body, index 0).
initialMachine ::
  Text ->
  -- | Project content hash.
  Text ->
  QName ->
  Bindings ->
  Machine
initialMachine scope projectHash q inputs =
  Machine
    { mStatus = MsRunning,
      mProjectHash = projectHash,
      mScope = scope,
      mPath = StmtPath q [PathSegment 0 Nothing],
      mCurrent = CurReady,
      mFrames = [],
      mBindings = inputs,
      mLastResult = Nothing,
      mError = Nothing
    }
