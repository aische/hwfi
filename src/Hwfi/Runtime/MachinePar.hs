-- | @par@ pool state and helpers for the v2 machine runtime (M3).
module Hwfi.Runtime.MachinePar
  ( startPar,
    approveParConfirm,
    branchEnv,
    isParDriving,
    spawnBranch,
    absorbBranchDone,
    absorbBranchStep,
    absorbBranchConfirm,
    absorbBranchFailed,
    finishParValues,
    parCollectSuccess,
    parCollectFailure,
    markBranchFailed,
    allSlotsTerminal,
    allBranchesAwaitingConfirm,
    canSpawnBranch,
  )
where

import Control.Monad (void)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Hwfi.Ast.Name (Ident)
import Hwfi.Ast.Step (Binder (..), LoopStmt (..), ParOnError (..), ParOpts (..))
import Hwfi.Ast.Step qualified as Ast
import Hwfi.Runtime.Error (RuntimeError, internalError)
import Hwfi.Runtime.RunCommon (defaultParallelism)
import Hwfi.Runtime.Machine
import Hwfi.Runtime.MachinePath (StmtContext (..), enterChildBlock, resolveStmtPath)
import Hwfi.Runtime.StepEnv (StepEnv (..), StepOutcome (..))
import Hwfi.Runtime.Trace (EventBody (..), emit)
import Hwfi.Runtime.Value (RValue (..))
import Hwfi.TypedProject (TypedProject)

-- | Whether the root machine is actively driving a @par@ pool.
isParDriving :: Machine -> Bool
isParDriving m =
  case (mFrames m, mCurrent m) of
    (FrPar _ : _, CurParPool) -> True
    _ -> False

-- | Step environment for a branch machine (scope + confirm context).
branchEnv :: StepEnv -> Int -> StepEnv
branchEnv env idx = env {seParBranchIndex = Just idx}

-- | Initialise a @par@ loop: push 'FrPar' and switch to 'CurParPool'.
startPar ::
  StepEnv ->
  Machine ->
  StmtContext ->
  LoopStmt ->
  ParOpts ->
  [RValue] ->
  IO (Either RuntimeError StepOutcome)
startPar env machine ctx s opts items = do
  let q = spQName (mPath machine)
  void $
    emit
      (seTracer env)
      (LoopStart q (loopId s) "par" (Just (length items)))
  if null items
    then do
      let v = VList []
      pure . Right . Stepped $
        machine
          { mBindings = bindResult (loopBinder s) v (mBindings machine),
            mLastResult = Just v,
            mPath = advanceParResume ctx machine,
            mCurrent = CurReady
          }
    else do
      let pjs =
            ParJoinState
              { pjsLoopId = loopId s,
                pjsScope = mScope machine,
                pjsBinder = loopBinder s,
                pjsMaxConcurrency = max 1 (fromMaybe defaultParallelism (parMax opts)),
                pjsOnError = parOnError opts,
                pjsItems = items,
                pjsSlots = replicate (length items) ParSlotPending,
                pjsActive = Map.empty,
                pjsNextIndex = 0,
                pjsPhase = ParScheduling,
                pjsConfirmQueue = [],
                pjsLoopPath = mPath machine,
                pjsResumePath = advanceParResume ctx machine,
                pjsParentBindings = mBindings machine
              }
      pure . Right . Stepped $
        machine
          { mFrames = FrPar pjs : mFrames machine,
            mCurrent = CurParPool
          }

advanceParResume :: StmtContext -> Machine -> StmtPath
advanceParResume ctx machine =
  let StmtPath q segs = mPath machine
      idx = scIndex ctx
   in StmtPath q (init segs ++ [PathSegment (idx + 1) Nothing])

canSpawnBranch :: ParJoinState -> Bool
canSpawnBranch pjs =
  pjsPhase pjs == ParScheduling
    && pjsNextIndex pjs < length (pjsItems pjs)
    && Map.size (pjsActive pjs) < pjsMaxConcurrency pjs

spawnBranch :: StepEnv -> Machine -> ParJoinState -> Either RuntimeError (Machine, ParJoinState, Int, BranchMachine)
spawnBranch env machine pjs =
  resolveLoopStmt (seProject env) pjs >>= \s -> do
    let idx = pjsNextIndex pjs
        item = pjsItems pjs !! idx
        scope' = iterScope (pjsScope pjs) (pjsLoopId pjs) idx
        branch =
          mkBranch $
            Machine
              { mStatus = MsRunning,
                mProjectHash = mProjectHash machine,
                mScope = scope',
                mPath = bodyEntry pjs,
                mCurrent = CurReady,
                mFrames = [],
                mBindings = Map.insert (loopVar s) item (pjsParentBindings pjs),
                mLastResult = Nothing,
                mError = Nothing
              }
        pjs' =
          pjs
            { pjsNextIndex = idx + 1,
              pjsSlots = setSlotRunning (pjsSlots pjs) idx,
              pjsActive = Map.insert idx branch (pjsActive pjs)
            }
    Right (machine, pjs', idx, branch)

absorbBranchDone :: ParJoinState -> Int -> RValue -> ParJoinState
absorbBranchDone pjs idx v =
  pjs
    { pjsSlots = setSlotDone (pjsSlots pjs) idx v,
      pjsActive = Map.delete idx (pjsActive pjs)
    }

absorbBranchStep :: ParJoinState -> Int -> Machine -> ParJoinState
absorbBranchStep pjs idx branch =
  pjs {pjsActive = Map.insert idx (mkBranch branch) (pjsActive pjs)}

absorbBranchConfirm :: ParJoinState -> Int -> Machine -> ConfirmRequest -> ParJoinState
absorbBranchConfirm pjs idx branch c =
  pjs
    { pjsSlots = setSlotConfirm (pjsSlots pjs) idx c,
      pjsActive = Map.insert idx (mkBranch branch) (pjsActive pjs),
      pjsPhase = ParDraining,
      pjsConfirmQueue = pjsConfirmQueue pjs ++ [c]
    }

absorbBranchFailed :: ParJoinState -> Int -> Text -> ParJoinState
absorbBranchFailed = markBranchFailed

markBranchFailed :: ParJoinState -> Int -> Text -> ParJoinState
markBranchFailed pjs idx msg =
  pjs
    { pjsSlots = setSlotFailed (pjsSlots pjs) idx msg,
      pjsActive = Map.delete idx (pjsActive pjs)
    }

finishParValues :: ParOnError -> [ParSlot] -> Either Text [RValue]
finishParValues ParOnErrorFail slots =
  case [msg | ParSlotFailed msg <- slots] of
    (e : _) -> Left e
    _ -> Right [v | ParSlotDone v <- slots]
finishParValues ParOnErrorCollect slots =
  Right
    [ case slot of
        ParSlotDone v -> parCollectSuccess v
        ParSlotFailed msg -> parCollectFailure msg
        ParSlotAwaitingConfirm _ -> parCollectFailure "branch awaiting confirm"
        ParSlotPending -> parCollectFailure "branch pending"
        ParSlotRunning -> parCollectFailure "branch running"
      | slot <- slots
    ]

parCollectSuccess :: RValue -> RValue
parCollectSuccess v =
  VRecord $
    Map.fromList
      [ ("ok", VBool True),
        ("value", v),
        ("error", VString "")
      ]

parCollectFailure :: Text -> RValue
parCollectFailure msg =
  VRecord $
    Map.fromList
      [ ("ok", VBool False),
        ("value", VRecord Map.empty),
        ("error", VString msg)
      ]

-- | Resume after the user approves the head confirm gate.
approveParConfirm :: Machine -> Machine
approveParConfirm machine =
  case mStatus machine of
    MsPaused (PauseAwaitingConfirm c) ->
      case mFrames machine of
        FrPar pjs : rest ->
          let idx = fromMaybe 0 (crBranchIndex c)
              pjs' =
                pjs
                  { pjsPhase = ParScheduling,
                    pjsConfirmQueue = drop 1 (pjsConfirmQueue pjs),
                    pjsSlots = setSlotPending (pjsSlots pjs) idx
                  }
           in machine
                { mStatus = MsRunning,
                  mCurrent = CurParPool,
                  mFrames = FrPar pjs' : rest
                }
        _ -> machine
    _ -> machine

bodyEntry :: ParJoinState -> StmtPath
bodyEntry pjs =
  let StmtPath _ segs = pjsLoopPath pjs
      idx = case reverse segs of
        (PathSegment i _) : _ -> i
        _ -> 0
   in enterChildBlock (pjsLoopPath pjs) idx BkLoopBody

resolveLoopStmt :: TypedProject -> ParJoinState -> Either RuntimeError LoopStmt
resolveLoopStmt tp pjs =
  case resolveStmtPath tp (pjsLoopPath pjs) of
    Left err -> Left (internalError err)
    Right ctx ->
      case scStmt ctx of
        Ast.SLoop s -> Right s
        _ -> Left (internalError "par loop path does not point at a loop statement")

setSlotRunning :: [ParSlot] -> Int -> [ParSlot]
setSlotRunning slots idx = updateSlot idx ParSlotRunning slots

setSlotPending :: [ParSlot] -> Int -> [ParSlot]
setSlotPending slots idx = updateSlot idx ParSlotPending slots

setSlotDone :: [ParSlot] -> Int -> RValue -> [ParSlot]
setSlotDone slots idx v = updateSlot idx (ParSlotDone v) slots

setSlotConfirm :: [ParSlot] -> Int -> ConfirmRequest -> [ParSlot]
setSlotConfirm slots idx c = updateSlot idx (ParSlotAwaitingConfirm c) slots

setSlotFailed :: [ParSlot] -> Int -> Text -> [ParSlot]
setSlotFailed slots idx msg = updateSlot idx (ParSlotFailed msg) slots

updateSlot :: Int -> ParSlot -> [ParSlot] -> [ParSlot]
updateSlot i s = zipWith (\j slot -> if j == i then s else slot) [0 ..]

allSlotsTerminal :: [ParSlot] -> Bool
allSlotsTerminal = all $ \case
  ParSlotDone _ -> True
  ParSlotFailed _ -> True
  ParSlotAwaitingConfirm _ -> True
  _ -> False

allBranchesAwaitingConfirm :: ParJoinState -> Bool
allBranchesAwaitingConfirm pjs =
  not (Map.null (pjsActive pjs))
    && all isAwaitingConfirm (Map.elems (pjsActive pjs))
  where
    isAwaitingConfirm bm =
      case mCurrent (unBranch bm) of
        CurAwaitConfirm _ -> True
        _ -> False

bindResult :: Binder -> RValue -> Map Ident RValue -> Map Ident RValue
bindResult BindDiscard _ bindings = bindings
bindResult (BindName n) v bindings = Map.insert n v bindings

iterScope :: Text -> Ident -> Int -> Text
iterScope scope sid i = scope <> sid <> "#" <> T.pack (show i) <> "/"
