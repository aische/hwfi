-- | v2 runtime transition driver (cursor + frames).
--
-- Executes one machine transition per 'stepMachine' call. The legacy executor
-- remains the default until M4 cutover (see @docs/execution-model.md@).
module Hwfi.Runtime.StepDriver
  ( StepOutcome (..),
    stepMachine,
    pauseMachine,
    runMachine,
  )
where

import Control.Monad (void)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.Key qualified as K
import Data.IORef (readIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Hwfi.Ast.Expr (Expr (..), RefPath (..))
import Hwfi.Ast.Name (Ident, QName, isBareQName, qnameSegments, renderQName)
import Hwfi.Ast.Project (Declaration (..))
import Hwfi.Ast.Step
  ( Arg (..),
    Binder (..),
    IfStmt (..),
    LoopKind (..),
    LoopStmt (..),
    Statement (..),
    StepStmt (..),
    TryStmt (..),
    WhileBody (..),
    WhileStmt (..),
  )
import Hwfi.Ast.Tool (Tool (..))
import Hwfi.Ast.Workflow (Section, Workflow (..))
import Hwfi.Check.Builtins (isAgentBuiltin, isBuiltin)
import Hwfi.Project.Manifest (ProjectManifest (..))
import Hwfi.Runtime.Builtins (BuiltinEnv (..), runBuiltin)
import Hwfi.Runtime.Context (RunInfo (..), contextValue)
import Hwfi.Runtime.Error
  ( RuntimeError (..),
    atStep,
    evalError,
    internalError,
    isCatchable,
    userError_,
  )
import Hwfi.Runtime.Error qualified as Err
import Hwfi.Runtime.Eval (EvalEnv (..), evalExpr)
import Hwfi.Runtime.EvalWorkflow (EvalWorkflowSeam (..))
import Hwfi.Runtime.Executor (projectContentHash)
import Hwfi.Runtime.Machine
import Hwfi.Runtime.MachineAgent (initAgentState, stepAgent)
import Hwfi.Runtime.MachinePath
  ( StmtContext (..),
    advancePath,
    enterChildBlock,
    initialStmtPath,
    resolveStmtPath,
  )
import Hwfi.Runtime.RunUsage (runUsageToJson)
import Hwfi.Runtime.StepEnv (RunWorkflowSeam, StepEnv (..))
import Hwfi.Runtime.Trace (EventBody (..), emit, snapshotEvents, snapshotJson)
import Hwfi.Runtime.Usage (usRef)
import Hwfi.Runtime.Value (RValue (..), RefKind (..), redactedJson)
import Hwfi.Runtime.Workspace (workspaceRoot)
import Hwfi.TypedProject (TypedDecl (..), TypedProject (..), TypedStep (..), lookupTyped, tpManifest, tpSkillCatalog)

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
stepMachine :: StepEnv -> Machine -> IO (Either RuntimeError StepOutcome)
stepMachine env machine = case mStatus machine of
  MsRunning -> stepRunning (wireWorkflowSeam env) machine
  MsDraining -> stepDraining machine
  MsPaused _ -> pure (Right (StepHalted machine))
  MsCompleted -> pure (Right (StepHalted machine))
  MsFailed -> pure (Right (StepHalted machine))

wireWorkflowSeam :: StepEnv -> StepEnv
wireWorkflowSeam env =
  case seRunWorkflow env of
    Just _ -> env
    Nothing -> env {seRunWorkflow = Just (runWorkflowSeam env)}

runWorkflowSeam :: StepEnv -> RunWorkflowSeam
runWorkflowSeam env q scope inputs = do
  let m0 = initialMachine scope (projectContentHash (seProject env)) q inputs
  runMachine (wireWorkflowSeam env) m0 >>= \case
    Left err -> pure (Left err)
    Right (RunCompleted v) -> pure (Right v)
    Right _ -> pure (Left (internalError "nested workflow did not complete"))

-- | Run until 'RunCompleted', 'StepHalted', or an error.
runMachine :: StepEnv -> Machine -> IO (Either RuntimeError StepOutcome)
runMachine env machine = loop machine
  where
    loop m = stepMachine env m >>= \case
      Left err -> pure (Left err)
      Right (Stepped m') -> loop m'
      Right done -> pure (Right done)

-- | Mark the machine explicitly paused after the last completed transition.
pauseMachine :: Machine -> Machine
pauseMachine m =
  m
    { mStatus = case mStatus m of
        MsRunning -> MsPaused PauseExplicit
        MsDraining -> MsPaused PauseExplicit
        s -> s
    }

stepDraining :: Machine -> IO (Either RuntimeError StepOutcome)
stepDraining machine =
  -- M3: finish in-flight par branches, then move to paused confirm.
  pure (Right (StepHalted machine))

stepRunning :: StepEnv -> Machine -> IO (Either RuntimeError StepOutcome)
stepRunning env machine =
  case mCurrent machine of
    CurReady -> stepFromReady env machine
    CurDispatch step -> stepDispatch env machine step
    CurAgent ag -> stepAgentTransition env machine ag
    CurAwaitConfirm c ->
      pure (Right (StepHalted machine {mStatus = MsPaused (PauseAwaitingConfirm c)}))

stepFromReady :: StepEnv -> Machine -> IO (Either RuntimeError StepOutcome)
stepFromReady env machine =
  case resolveStmtPath (seProject env) (mPath machine) of
    Left "statement index out of range" -> endOfBlock env machine (fromMaybe (VRecord mempty) (mLastResult machine))
    Left err -> pure (Left (internalStub err))
    Right ctx -> case scStmt ctx of
      SReturn args _ -> finishReturn env machine args
      SStep step -> pure (Right (Stepped machine {mCurrent = CurDispatch step}))
      SIf s -> startIf env machine ctx s
      SLoop s -> startLoop env machine ctx s
      SWhile s -> startWhile env machine ctx s
      STry s -> startTry machine ctx s

stepDispatch :: StepEnv -> Machine -> StepStmt -> IO (Either RuntimeError StepOutcome)
stepDispatch env machine step = do
  let q = spQName (mPath machine)
  (sections, _) <- requireWorkflowDecl env q
  let sid = stepId step
      stepRef = Err.StepRef q sid
      target = stepTarget step
  ctxR <- buildCtx env q sid
  let envEval = mkEvalEnv env sections (Map.insert "ctx" ctxR (mBindings machine))
  case evalArgs envEval (stepArgs step) of
    Left e -> pure (Left (atStep stepRef e))
    Right argPairs -> do
      let argMap = Map.fromList argPairs
      if isAgentBuiltin target
        then enterAgent env machine stepRef target (stepBinder step) argMap
        else dispatchCall env machine stepRef argMap target (stepBinder step)

enterAgent ::
  StepEnv ->
  Machine ->
  Err.StepRef ->
  QName ->
  Binder ->
  Map Ident RValue ->
  IO (Either RuntimeError StepOutcome)
enterAgent env machine stepRef target binder argMap =
  let mRef = StepRef (Err.srQName stepRef) (Err.srStepId stepRef)
   in case initAgentState env mRef binder target argMap of
    Left e -> pure (Left (atStep stepRef e))
    Right ag -> do
      void $
        emit
          (seTracer env)
          ( StepStart
              (Err.srQName stepRef)
              (Err.srStepId stepRef)
              (redactedJson (VRecord argMap))
              False
              Nothing
          )
      pure . Right . Stepped $
        machine {mCurrent = CurAgent ag}

stepAgentTransition :: StepEnv -> Machine -> AgentState -> IO (Either RuntimeError StepOutcome)
stepAgentTransition env machine ag =
  stepAgent env machine ag >>= \case
    Left e -> pure (Left e)
    Right (Just result, m') -> do
      void $
        emit
          (seTracer env)
          ( StepEnd
              (srQName (agStepRef ag))
              (srStepId (agStepRef ag))
              (redactedJson result)
              0
              Nothing
          )
      completeStep m' (agBinder ag) result
    Right (Nothing, m') -> pure (Right (Stepped m'))

dispatchCall ::
  StepEnv ->
  Machine ->
  Err.StepRef ->
  Map Ident RValue ->
  QName ->
  Binder ->
  IO (Either RuntimeError StepOutcome)
dispatchCall env machine stepRef argMap target binder =
  case resolveDispatchTarget machine target of
    Left e -> pure (Left (atStep stepRef e))
    Right realTarget
      | isBuiltin realTarget -> do
          r <- runBuiltin (builtinEnv env stepRef (mBindings machine) (mScope machine)) realTarget argMap
          case r of
            Left e -> handleStepError env machine (atStep stepRef e)
            Right result -> completeStep machine binder result
      | otherwise ->
          case lookupTyped realTarget (seProject env) of
            Nothing -> pure (Left (atStep stepRef (internalError ("cannot dispatch to " <> renderQName realTarget))))
            Just td
              | not (isExecutable (tdDeclaration td)) ->
                  pure (Left (atStep stepRef (internalError (renderQName realTarget <> " is not executable"))))
              | otherwise -> enterSubWorkflow env machine binder realTarget argMap

resolveDispatchTarget :: Machine -> QName -> Either RuntimeError QName
resolveDispatchTarget machine target
  | isBareQName target =
      case Map.lookup (bareIdent target) (mBindings machine) of
        Just (VRef _ realQ) -> Right realQ
        Just _ -> Left (evalError ("'" <> renderQName target <> "' is not a callable ref value"))
        Nothing -> Left (evalError ("call target '" <> renderQName target <> "' is not bound"))
  | otherwise = Right target

enterSubWorkflow ::
  StepEnv ->
  Machine ->
  Binder ->
  QName ->
  Map Ident RValue ->
  IO (Either RuntimeError StepOutcome)
enterSubWorkflow env machine binder callee inputs =
  case initialStmtPath (seProject env) callee of
    Left err -> pure (Left (internalError err))
    Right entryPath ->
      pure . Right . Stepped $
        machine
          { mFrames =
              FrSeq
                { fsScope = mScope machine,
                  fsResumePath = advancePath (mPath machine),
                  fsBinder = Just binder,
                  fsBindings = mBindings machine
                }
                : mFrames machine,
            mPath = entryPath,
            mBindings = Map.singleton "inputs" (VRecord inputs),
            mCurrent = CurReady
          }

completeStep :: Machine -> Binder -> RValue -> IO (Either RuntimeError StepOutcome)
completeStep machine binder result =
  pure . Right . Stepped $
    machine
      { mBindings = bindResult binder result (mBindings machine),
        mLastResult = Just result,
        mPath = advancePath (mPath machine),
        mCurrent = CurReady
      }

finishReturn :: StepEnv -> Machine -> [Arg] -> IO (Either RuntimeError StepOutcome)
finishReturn env machine args = do
  let q = spQName (mPath machine)
  sections <- workflowSections env q
  ctxR <- buildCtx env q "return"
  let envEval = mkEvalEnv env sections (Map.insert "ctx" ctxR (mBindings machine))
  case evalArgs envEval args of
    Left e -> pure (Left e)
    Right fields -> endOfBlock env machine (VRecord (Map.fromList fields))

endOfBlock :: StepEnv -> Machine -> RValue -> IO (Either RuntimeError StepOutcome)
endOfBlock env machine result =
  case mFrames machine of
    [] -> pure (Right (RunCompleted result))
    FrSeq {fsResumePath = resume} : FrWhile wf : rest
      | resume == wfWhilePath wf ->
          continueWhile env machine wf rest result
    FrSeq {fsScope = scope, fsResumePath = resumePath, fsBinder = binder, fsBindings = saved} : rest ->
      pure . Right . Stepped $
        machine
          { mFrames = rest,
            mScope = scope,
            mPath = resumePath,
            mBindings = case binder of
              Nothing -> saved
              Just b -> bindResult b result saved,
            mLastResult = Just result,
            mCurrent = CurReady
          }
    FrForeach ff : rest -> continueForeach machine ff rest result
    FrWhile wf : rest -> continueWhile env machine wf rest result
    FrTry tf : rest -> continueTry machine tf rest result
    FrPar _ : _ -> pure (Left (internalStub "par frame completion not implemented (M3)"))

continueForeach :: Machine -> ForeachFrame -> [Frame] -> RValue -> IO (Either RuntimeError StepOutcome)
continueForeach machine ff rest result = do
  let acc' = result : ffAcc ff
      idx' = ffIndex ff + 1
      items = ffItems ff
  if idx' < length items
    then
      pure . Right . Stepped $
        machine
          { mFrames = FrForeach (ff {ffIndex = idx', ffAcc = acc'}) : rest,
            mScope = iterScope (ffScope ff) (ffLoopId ff) idx',
            mPath = ffBodyEntry ff,
            mBindings = Map.insert (ffVar ff) (items !! idx') (mBindings machine),
            mLastResult = Just result,
            mCurrent = CurReady
          }
    else
      let v = VList (reverse acc')
       in pure . Right . Stepped $
            machine
              { mFrames = rest,
                mScope = ffScope ff,
                mPath = ffResumePath ff,
                mBindings = bindResult (ffBinder ff) v (mBindings machine),
                mLastResult = Just v,
                mCurrent = CurReady
              }

continueWhile :: StepEnv -> Machine -> WhileFrame -> [Frame] -> RValue -> IO (Either RuntimeError StepOutcome)
continueWhile env machine wf rest bodyResult =
  case wfPhase wf of
    WhileRunPred -> do
      case extractPredDecision bodyResult of
        Left e -> pure (Left e)
        Right (cont, _)
          | not cont -> finishWhile machine wf rest
          | wfIteration wf >= wfMaxIterations wf ->
              pure $
                Left
                  ( userError_
                      ( "while loop reached max_iterations ("
                          <> T.pack (show (wfMaxIterations wf))
                          <> ") without predicate returning continue = false (§4.3)"
                      )
                  )
          | otherwise -> startWhileBody env machine wf rest bodyResult
    WhileRunBody ->
      startWhilePred env machine (wf {wfIteration = wfIteration wf + 1, wfAcc = bodyResult : wfAcc wf, wfCarry = Just bodyResult, wfPhase = WhileRunPred}) rest

finishWhile :: Machine -> WhileFrame -> [Frame] -> IO (Either RuntimeError StepOutcome)
finishWhile machine wf rest =
  let v = VList (reverse (wfAcc wf))
   in pure . Right . Stepped $
        machine
          { mFrames = rest,
            mScope = wfScope wf,
            mPath = wfResumePath wf,
            mBindings = bindResult (wfBinder wf) v (mBindings machine),
            mLastResult = Just v,
            mCurrent = CurReady
          }

continueTry :: Machine -> TryFrame -> [Frame] -> RValue -> IO (Either RuntimeError StepOutcome)
continueTry machine tf rest result =
  pure . Right . Stepped $
    machine
      { mFrames = rest,
        mScope = tfScope tf,
        mPath = tfResumePath tf,
        mBindings = bindResult (tfBinder tf) result (mBindings machine),
        mLastResult = Just result,
        mCurrent = CurReady
      }

startIf :: StepEnv -> Machine -> StmtContext -> IfStmt -> IO (Either RuntimeError StepOutcome)
startIf env machine ctx s = do
  let q = spQName (mPath machine)
  sections <- workflowSections env q
  ctxR <- buildCtx env q (ifId s)
  let envEval = mkEvalEnv env sections (Map.insert "ctx" ctxR (mBindings machine))
  case evalExpr envEval (ifCond s) of
    Left e -> pure (Left e)
    Right (VBool True) -> enterIfBranch machine ctx s BkIfThen
    Right (VBool False) ->
      case ifElse s of
        Just _ -> enterIfBranch machine ctx s BkIfElse
        Nothing ->
          let v = VRecord mempty
           in pure . Right . Stepped $
                machine
                  { mBindings = bindResult (ifBinder s) v (mBindings machine),
                    mLastResult = Just v,
                    mPath = advancePath (mPath machine),
                    mCurrent = CurReady
                  }
    Right _ -> pure (Left (evalError "'if' condition did not evaluate to a Bool"))

enterIfBranch :: Machine -> StmtContext -> IfStmt -> BlockKind -> IO (Either RuntimeError StepOutcome)
enterIfBranch machine ctx s bk = do
  let idx = scIndex ctx
      branch = case bk of
        BkIfThen -> "then"
        BkIfElse -> "else"
        _ -> "branch"
      scope' = ifScope (mScope machine) (ifId s) branch
      bodyEntry = enterChildBlock (mPath machine) idx bk
  pure . Right . Stepped $
    machine
      { mFrames =
          FrSeq
            { fsScope = mScope machine,
              fsResumePath = advancePath (mPath machine),
              fsBinder = Just (ifBinder s),
              fsBindings = mBindings machine
            }
            : mFrames machine,
        mScope = scope',
        mPath = bodyEntry,
        mCurrent = CurReady
      }

startLoop :: StepEnv -> Machine -> StmtContext -> LoopStmt -> IO (Either RuntimeError StepOutcome)
startLoop env machine ctx s =
  case loopKind s of
    LoopPar _ -> pure (Left (internalStub "par not implemented (M3)"))
    LoopSeq -> do
      let q = spQName (mPath machine)
      sections <- workflowSections env q
      ctxR <- buildCtx env q (loopId s)
      let envEval = mkEvalEnv env sections (Map.insert "ctx" ctxR (mBindings machine))
      case evalExpr envEval (loopList s) of
        Left e -> pure (Left e)
        Right (VList xs) -> startForeach machine ctx s xs
        Right _ -> pure (Left (evalError "'foreach' expected a list to iterate over"))

startForeach :: Machine -> StmtContext -> LoopStmt -> [RValue] -> IO (Either RuntimeError StepOutcome)
startForeach machine ctx s items =
  if null items
    then do
      let v = VList []
      pure . Right . Stepped $
        machine
          { mBindings = bindResult (loopBinder s) v (mBindings machine),
            mLastResult = Just v,
            mPath = advancePath (mPath machine),
            mCurrent = CurReady
          }
    else do
      let idx = scIndex ctx
          scope' = iterScope (mScope machine) (loopId s) 0
          bodyEntry = enterChildBlock (mPath machine) idx BkLoopBody
          ff =
            ForeachFrame
              { ffLoopId = loopId s,
                ffScope = mScope machine,
                ffBinder = loopBinder s,
                ffVar = loopVar s,
                ffItems = items,
                ffIndex = 0,
                ffAcc = [],
                ffResumePath = advancePath (mPath machine),
                ffBodyEntry = bodyEntry
              }
      pure . Right . Stepped $
        machine
          { mFrames = FrForeach ff : mFrames machine,
            mScope = scope',
            mPath = bodyEntry,
            mBindings = Map.insert (loopVar s) (head items) (mBindings machine),
            mCurrent = CurReady
          }

startWhile :: StepEnv -> Machine -> StmtContext -> WhileStmt -> IO (Either RuntimeError StepOutcome)
startWhile env machine _ctx s = do
  let q = spQName (mPath machine)
  sections <- workflowSections env q
  ctxR <- buildCtx env q (whileId s)
  let envEval = mkEvalEnv env sections (Map.insert "ctx" ctxR (mBindings machine))
  case evalExpr envEval (whileMaxIterations s) of
    Left e -> pure (Left e)
    Right (VInt n)
      | n >= 1 ->
          let wf =
                WhileFrame
                  { wfLoopId = whileId s,
                    wfScope = mScope machine,
                    wfBinder = whileBinder s,
                    wfIteration = 0,
                    wfMaxIterations = fromInteger n,
                    wfAcc = [],
                    wfCarry = Nothing,
                    wfResumePath = advancePath (mPath machine),
                    wfWhilePath = mPath machine,
                    wfPhase = WhileRunPred
                  }
           in startWhilePred env machine wf (mFrames machine)
    Right _ -> pure (Left (evalError "while max_iterations must evaluate to an Int >= 1 (§4.3)"))

startWhilePred :: StepEnv -> Machine -> WhileFrame -> [Frame] -> IO (Either RuntimeError StepOutcome)
startWhilePred env machine wf rest = do
  case resolveStmtPath (seProject env) (wfWhilePath wf) of
    Left err -> pure (Left (internalStub err))
    Right ctx ->
      case scStmt ctx of
        SWhile s ->
          invokeWhileCallee env machine wf rest (whilePredScope (wfScope wf) (wfLoopId wf) (wfIteration wf)) (whilePredicate s) (whilePredicateArgs s) (wfCarry wf)
        _ -> pure (Left (internalError "while path does not point at a while statement"))

startWhileBody :: StepEnv -> Machine -> WhileFrame -> [Frame] -> RValue -> IO (Either RuntimeError StepOutcome)
startWhileBody env machine wf rest _predResult = do
  case resolveStmtPath (seProject env) (wfWhilePath wf) of
    Left err -> pure (Left (internalStub err))
    Right ctx ->
      case scStmt ctx of
        SWhile s ->
          case whileBody s of
            WhileBodyCallee calleeExpr args ->
              invokeWhileCallee env machine (wf {wfPhase = WhileRunBody}) rest (whileBodyScope (wfScope wf) (wfLoopId wf) (wfIteration wf)) calleeExpr args (wfCarry wf)
            WhileBodyInline _ ->
              let scope' = whileBodyScope (wfScope wf) (wfLoopId wf) (wfIteration wf)
                  bodyEntry = enterChildBlock (wfWhilePath wf) (scIndex ctx) BkWhileInline
               in pure . Right . Stepped $
                    machine
                      { mFrames = FrWhile (wf {wfPhase = WhileRunBody}) : rest,
                        mScope = scope',
                        mPath = bodyEntry,
                        mBindings = maybe id (Map.insert "carry") (wfCarry wf) (mBindings machine),
                        mCurrent = CurReady
                      }
        _ -> pure (Left (internalError "while path does not point at a while statement"))

invokeWhileCallee ::
  StepEnv ->
  Machine ->
  WhileFrame ->
  [Frame] ->
  Text ->
  Expr ->
  [Arg] ->
  Maybe RValue ->
  IO (Either RuntimeError StepOutcome)
invokeWhileCallee env machine wf rest scope calleeExpr args mCarry = do
  let q = spQName (mPath machine)
  sections <- workflowSections env q
  ctxR <- buildCtx env q (wfLoopId wf)
  let baseEnv = mkEvalEnv env sections (Map.insert "ctx" ctxR (mBindings machine))
  case resolveWhileCallee baseEnv calleeExpr of
    Left e -> pure (Left e)
    Right target ->
      case evalWhileArgs baseEnv mCarry args of
        Left e -> pure (Left e)
        Right argMap ->
          case initialStmtPath (seProject env) target of
            Left err -> pure (Left (internalError err))
            Right entryPath ->
              pure . Right . Stepped $
                machine
                  { mFrames = FrWhile wf : FrSeq {fsScope = wfScope wf, fsResumePath = wfWhilePath wf, fsBinder = Nothing, fsBindings = mBindings machine} : rest,
                    mScope = scope,
                    mPath = entryPath,
                    mBindings = Map.singleton "inputs" (VRecord argMap),
                    mCurrent = CurReady
                  }

startTry :: Machine -> StmtContext -> TryStmt -> IO (Either RuntimeError StepOutcome)
startTry machine ctx s = do
  let idx = scIndex ctx
      scope' = tryScope (mScope machine) (tryId s) "try"
      bodyEntry = enterChildBlock (mPath machine) idx BkTryTry
      tf =
        TryFrame
          { tfLoopId = tryId s,
            tfScope = mScope machine,
            tfBinder = tryBinder s,
            tfPhase = TryInTry,
            tfResumePath = advancePath (mPath machine),
            tfTryPath = mPath machine
          }
  pure . Right . Stepped $
    machine
      { mFrames = FrTry tf : mFrames machine,
        mScope = scope',
        mPath = bodyEntry,
        mCurrent = CurReady
      }

handleStepError :: StepEnv -> Machine -> RuntimeError -> IO (Either RuntimeError StepOutcome)
handleStepError env machine err =
  case (mFrames machine, isCatchable (reKind err)) of
    (FrTry tf : rest, True)
      | tfPhase tf == TryInTry -> do
          case resolveStmtPath (seProject env) (tfTryPath tf) of
            Left e -> pure (Left (internalStub e))
            Right ctx ->
              case scStmt ctx of
                STry s -> do
                  let idx = scIndex ctx
                      scope' = tryScope (tfScope tf) (tryId s) "catch"
                      bodyEntry = enterChildBlock (tfTryPath tf) idx BkTryCatch
                  pure . Right . Stepped $
                    machine
                      { mFrames = FrTry (tf {tfPhase = TryInCatch}) : rest,
                        mScope = scope',
                        mPath = bodyEntry,
                        mCurrent = CurReady,
                        mError = Just (reMessage err)
                      }
                _ -> pure (Left (internalError "try path does not point at a try statement"))
    _ -> pure (Left err)

-- Environment ----------------------------------------------------------------

requireWorkflowDecl :: StepEnv -> QName -> IO ([Section], Map Ident TypedStep)
requireWorkflowDecl env q =
  case lookupTyped q (seProject env) of
    Nothing -> fail ("StepDriver: unknown declaration: " <> T.unpack (renderQName q))
    Just td -> case declBody (tdDeclaration td) of
      Nothing -> fail ("StepDriver: not executable: " <> T.unpack (renderQName q))
      Just (_, sections) -> pure (sections, typedStepsFor td)

workflowSections :: StepEnv -> QName -> IO [Section]
workflowSections env q = fst <$> requireWorkflowDecl env q

typedStepsFor :: TypedDecl -> Map Ident TypedStep
typedStepsFor td = Map.fromList [(stepId (tsStmt ts), ts) | ts <- tdSteps td]

mkEvalEnv :: StepEnv -> [Section] -> Map Ident RValue -> EvalEnv
mkEvalEnv env sections bindings =
  EvalEnv
    { eeBindings = bindings,
      eeSections = sections,
      eeRefKind = refKind env
    }

refKind :: StepEnv -> QName -> Maybe RefKind
refKind env q
  | isBuiltin q = Just RTool
  | otherwise = case lookupTyped q (seProject env) of
      Just td -> case tdDeclaration td of
        DeclTool _ -> Just RTool
        DeclWorkflow _ -> Just RWorkflow
        _ -> Nothing
      Nothing -> Nothing

buildCtx :: StepEnv -> QName -> Ident -> IO RValue
buildCtx env q sid = do
  events <- snapshotEvents (seTracer env)
  usage <- readIORef (usRef (seUsage env))
  pure (contextValue (seRunInfo env) usage q sid events)

builtinEnv :: StepEnv -> Err.StepRef -> Map Ident RValue -> Text -> BuiltinEnv
builtinEnv env stepRef bindings scope =
  BuiltinEnv
    { beWorkspace = seWorkspace env,
      beModels = seModels env,
      beTracer = seTracer env,
      beStep = stepRef,
      beExecPolicy = execPolicy (tpManifest (seProject env)),
      beUsage = seUsage env,
      beIntrospect = introspectDump env stepRef bindings,
      beEvalWorkflow = Just (evalWorkflowSeam env scope),
      beRunId = riRunId (seRunInfo env),
      beSkillCatalog = tpSkillCatalog (seProject env)
    }

evalWorkflowSeam :: StepEnv -> Text -> EvalWorkflowSeam
evalWorkflowSeam env scope =
  EvalWorkflowSeam
    { ewsProject = seProject env,
      ewsScope = scope,
      ewsExecute = \tp sc q inputs -> do
        let env' = env {seProject = tp}
            m0 = initialMachine sc (projectContentHash tp) q inputs
        runMachine env' m0 >>= \case
          Left err -> pure (Left err)
          Right (RunCompleted v) -> pure (Right v)
          Right _ -> pure (Left (internalError "eval-workflow did not complete"))
    }

introspectDump :: StepEnv -> Err.StepRef -> Map Ident RValue -> IO Value
introspectDump env stepRef bindings = do
  events <- snapshotJson (seTracer env)
  usage <- readIORef (usRef (seUsage env))
  let ri = seRunInfo env
  pure $
    object
      [ "run"
          .= object
            [ "id" .= riRunId ri,
              "started_at" .= riStartedAt ri,
              "entrypoint" .= riEntrypoint ri,
              "usage" .= runUsageToJson usage
            ],
        "self"
          .= object
            [ "qname" .= renderQName (Err.srQName stepRef),
              "step_id" .= Err.srStepId stepRef
            ],
        "workspace" .= T.pack (workspaceRoot (seWorkspace env)),
        "inputs" .= riRootInputs ri,
        "bindings" .= object [K.fromText k .= redactedJson v | (k, v) <- Map.toList bindings],
        "trace" .= events
      ]

-- Scope prefixes (§8.1) ------------------------------------------------------

ifScope :: Text -> Ident -> Text -> Text
ifScope scope sid branch = scope <> sid <> "?" <> branch <> "/"

iterScope :: Text -> Ident -> Int -> Text
iterScope scope sid i = scope <> sid <> "#" <> T.pack (show i) <> "/"

tryScope :: Text -> Ident -> Text -> Text
tryScope scope sid arm = scope <> sid <> "?" <> arm <> "/"

whilePredScope :: Text -> Ident -> Int -> Text
whilePredScope scope sid i = iterScope scope sid i <> "p/"

whileBodyScope :: Text -> Ident -> Int -> Text
whileBodyScope scope sid i = iterScope scope sid i <> "b/"

-- Helpers --------------------------------------------------------------------

evalArgs :: EvalEnv -> [Arg] -> Either RuntimeError [(Ident, RValue)]
evalArgs env = traverse (\a -> (,) (argName a) <$> evalExpr env (argValue a))

bindResult :: Binder -> RValue -> Map Ident RValue -> Map Ident RValue
bindResult BindDiscard _ bindings = bindings
bindResult (BindName n) v bindings = Map.insert n v bindings

declBody :: Declaration -> Maybe ([Statement], [Section])
declBody = \case
  DeclWorkflow w -> Just (wfStatements w, wfSections w)
  DeclTool t -> Just (toolStatements t, toolSections t)
  _ -> Nothing

isExecutable :: Declaration -> Bool
isExecutable d = case declBody d of
  Just _ -> True
  Nothing -> False

bareIdent :: QName -> Ident
bareIdent q = case qnameSegments q of
  (seg : _) -> seg
  [] -> ""

resolveWhileCallee :: EvalEnv -> Expr -> Either RuntimeError QName
resolveWhileCallee env = \case
  EQName q -> Right q
  ERef (RefPath root []) ->
    case Map.lookup root (eeBindings env) of
      Just (VRef _ q) -> Right q
      _ -> Left (evalError "while callee ref is not a ToolRef/WorkflowRef value")
  _ -> Left (evalError "while callee must be a static qname or a bound ref value")

evalWhileArgs :: EvalEnv -> Maybe RValue -> [Arg] -> Either RuntimeError (Map Ident RValue)
evalWhileArgs env mCarry args = do
  let env' =
        case mCarry of
          Nothing -> env
          Just v -> env {eeBindings = Map.insert "carry" v (eeBindings env)}
  pairs <- evalArgs env' args
  pure (Map.fromList pairs)

extractPredDecision :: RValue -> Either RuntimeError (Bool, Text)
extractPredDecision (VRecord m) = do
  cont <- case Map.lookup "continue" m of
    Just (VBool b) -> Right b
    _ -> Left (evalError "while predicate output missing continue: Bool (§4.3.2)")
  reason <- case Map.lookup "reason" m of
    Just (VString t) -> Right t
    Just (VFileRef t) -> Right t
    _ -> Left (evalError "while predicate output missing reason: String (§4.3.2)")
  pure (cont, reason)
extractPredDecision _ = Left (evalError "while predicate output is not a record (§4.3.2)")

internalStub :: Text -> RuntimeError
internalStub msg = internalError ("step driver: " <> msg)
