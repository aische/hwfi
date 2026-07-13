-- | The workflow executor (spec §4, §5.3, §8) plus the run/resume orchestration
-- (tasks 4.1, 4.8, 5.3, 5.5, 5.8).
--
-- Runs a fully type-checked workflow: statements execute in source order, each
-- step's argument expressions are evaluated against the current binding
-- environment (with the ambient @ctx@ injected per step, §5.4), and the call is
-- dispatched to a builtin, a sub-workflow, or a user tool. Sub-workflow and tool
-- calls recurse through the same 'runWorkflow', so a workflow can call another
-- workflow as a step (A6) and the callee's trace events nest inside the caller's
-- step (§8.3.3.6).
--
-- Persistence and resume (M5) layer on the 'Hwfi.Runtime.Trace.Tracer' and
-- 'Hwfi.Runtime.RunStore' seams:
--
--   * every emitted event is appended to @trace.jsonl@ (via the persistent
--     tracer);
--   * each completed /cacheable/ step's result is content-addressed by its
--     step-key (§8.1) and written under @steps/@;
--   * on resume, a cacheable step whose step-key already has a persisted result
--     is skipped and emits no new events (§8.2, §8.3.4); non-cacheable steps
--     always re-execute; @ctx.trace@ is reconstructed from the persisted trace
--     so a downstream step sees identical history whether an upstream step was
--     cached or re-executed (§8.3.5, A15).
module Hwfi.Runtime.Executor
  ( RunResult (..),
    performRun,
    performResume,
    runWorkflow,
    projectContentHash,
    defaultParallelism,
  )
where

import Control.Exception (SomeException, displayException)
import Control.Monad (join, void, when)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.Either (lefts, rights)
import Data.IORef (IORef, newIORef, readIORef)
import Data.List (nub, sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime, defaultTimeLocale, diffUTCTime, formatTime, getCurrentTime)
import Hwfi.Ast.Expr (Accessor (..), Expr (..), RefPath (..), StringPart (..))
import Hwfi.Ast.Name (Ident, QName, isBareQName, qnameFromText, qnameSegments, renderQName)
import Hwfi.Ast.Project (Declaration (..))
import Hwfi.Ast.Step
  ( Arg (..),
    Binder (..),
    IfStmt (..),
    LoopKind (..),
    LoopStmt (..),
    ParOnError (..),
    ParOpts (..),
    Statement (..),
    StepStmt (..),
    TryStmt (..),
    WhileBody (..),
    WhileStmt (..),
  )
import Hwfi.Ast.Tool (Tool (..))
import Hwfi.Ast.Workflow (Section, Workflow (..))
import Hwfi.Check.Builtins
  ( Callee (..),
    isAgentBuiltin,
    isBuiltin,
    isOneShotLlmBuiltin,
    llmAgentObjectQName,
    lookupBuiltin,
  )
import Hwfi.Check.Decl (classifyCacheable)
import Hwfi.Check.Graph (builtinFingerprint)
import Hwfi.Project.Manifest (ProjectManifest (..), budgetMaxCostUsd)
import Hwfi.Runtime.Agent
  ( AdvertisedTool (..),
    AgentEnv (..),
    AgentSkillState (..),
    AgentSpec (..),
    SubmitSpec (..),
    advertisedToolDef,
    emptyAgentSkillState,
    runAgent,
    submitToolDef,
  )
import Hwfi.Runtime.Builtins (BuiltinEnv (..), runBuiltin)
import Hwfi.Runtime.Context (RunInfo (..), buildEnvRecord, contextValue)
import Hwfi.Runtime.Error
  ( ErrorKind (..),
    RuntimeError (..),
    StepRef (..),
    atStep,
    evalError,
    internalError,
    isCatchable,
    userError_,
  )
import Hwfi.Runtime.Eval (EvalEnv (..), evalExpr, resolveRefPath)
import Hwfi.Runtime.EvalWorkflow (EvalWorkflowSeam (..))
import Hwfi.Runtime.Gateways (ModelStore, lookupModel, modelCatalogFingerprint, oneShotLlmCtxProjection)
import Hwfi.Runtime.RunStore
  ( RunMeta (..),
    RunPhase (..),
    RunStore,
    cacheStepResult,
    cacheWhileDecision,
    createRunStore,
    isResumable,
    lookupCachedResult,
    lookupWhileDecision,
    openRunStore,
    openTraceAppend,
    phaseText,
    readRunMeta,
    readTraceEvents,
    updateRunPhase,
    withWorkspaceLock,
    writeRunMeta,
  )
import Hwfi.Runtime.RunUsage (emptyRunUsage, runUsageToJson)
import Hwfi.Runtime.StepKey (computeStepKey, computeWhileDecisionKey, sha256Hex)
import Hwfi.Runtime.Trace
  ( EventBody (..),
    RunStatus (..),
    TraceEvent (..),
    Tracer,
    emit,
    newPersistentTracer,
    snapshotEvents,
    snapshotJson,
  )
import Hwfi.Runtime.Usage (UsageSeam (..), newUsageSeam)
import Hwfi.Runtime.Value
  ( RValue (..),
    RefKind (..),
    canonicalJson,
    coerceFromJson,
    redactedJson,
    valueToJson,
  )
import Hwfi.Runtime.Workspace (Workspace, workspaceRoot)
import Hwfi.SkillCatalog (skillPolicyFromManifest)
import Hwfi.Type (Type (..))
import Hwfi.TypedProject
  ( Fingerprint (..),
    ResolvedSignature (..),
    TypedDecl (..),
    TypedProject (..),
    TypedStep (..),
    lookupTyped,
  )
import System.IO (hClose)
import UnliftIO.Async (pooledForConcurrentlyN)
import UnliftIO.Exception (bracket, tryAny)
import Control.Applicative ((<|>))

-- | Everything the executor threads through a run.
data Runtime = Runtime
  { rtProject :: TypedProject,
    rtWorkspace :: Workspace,
    rtModels :: ModelStore,
    rtStore :: RunStore,
    rtTracer :: Tracer,
    rtRunInfo :: RunInfo,
    rtUsage :: UsageSeam,
    -- | Whether this attempt is a resume: only then is the step cache consulted
    -- (§8.2). The cache is /written/ on every attempt so a later resume can use
    -- it.
    rtResume :: Bool
  }

-- | The outcome of a run plus the events it produced (for @hwfi show@\/tests).
data RunResult = RunResult
  { rrOutcome :: Either RuntimeError RValue,
    rrEvents :: [TraceEvent]
  }

-- Orchestration --------------------------------------------------------------

-- | Start a fresh run (spec §8): acquire the workspace lock (§12), create the
-- run directory, write @run.json@ (status @running@), open the append-only
-- trace, emit the @run-start@\/@run-end@ bracket, and finalise the status.
-- Returns 'Left' if the workspace is already locked by another run.
performRun ::
  TypedProject ->
  Workspace ->
  ModelStore ->
  -- | Whitelisted environment variables (already validated present, §5.7).
  Map Text Text ->
  -- | The project directory (recorded in @run.json@ for resume).
  FilePath ->
  -- | Run id.
  Text ->
  -- | Entrypoint qname.
  QName ->
  -- | Root inputs, coerced to their declared types.
  Map Ident RValue ->
  IO (Either Text RunResult)
performRun tp ws models envVars projectDir runId entry rootInputs =
  withWorkspaceLock (workspaceRoot ws) $ do
    store <- createRunStore (workspaceRoot ws) runId
    startedAt <- nowIso
    let ph = projectContentHash tp
        budget = budgetMaxCostUsd (tpManifest tp)
    usageSeam <- newUsageSeam store budget emptyRunUsage
    writeRunMeta
      store
      RunMeta
        { rmRunId = runId,
          rmEntrypoint = renderQName entry,
          rmProjectDir = T.pack projectDir,
          rmStartedAt = startedAt,
          rmProjectHash = ph,
          rmInputs = valueToJson (VRecord rootInputs),
          rmPhase = PhaseRunning,
          rmUsage = emptyRunUsage
        }
    bracket (openTraceAppend store) hClose $ \h -> do
      tracer <- newPersistentTracer h [] 0
      let rt = mkRuntime tp ws models store tracer (runInfo runId startedAt entry rootInputs envVars) usageSeam False
      _ <- emit tracer (RunStart runId (renderQName entry) (redactedJson (VRecord rootInputs)) ph)
      guardedFinish rt store entry =<< tryAny (runWorkflow rt "" entry rootInputs)

-- | Resume an interrupted run (spec §8.2): re-acquire the lock, verify the run
-- is resumable, reconstruct the root inputs and the persisted trace, append a
-- @resumed@ marker continuing the @seq@ numbering, and re-execute — skipping
-- cacheable steps that already have a persisted result.
performResume ::
  TypedProject ->
  Workspace ->
  ModelStore ->
  Map Text Text ->
  Text ->
  IO (Either Text RunResult)
performResume tp ws models envVars runId =
  fmap join $
    withWorkspaceLock (workspaceRoot ws) $ do
      eStore <- openRunStore (workspaceRoot ws) runId
      case eStore of
        Left e -> pure (Left e)
        Right store -> resumeWith tp ws models envVars runId store

resumeWith ::
  TypedProject ->
  Workspace ->
  ModelStore ->
  Map Text Text ->
  Text ->
  RunStore ->
  IO (Either Text RunResult)
resumeWith tp ws models envVars runId store = do
  eMeta <- readRunMeta store
  case eMeta of
    Left e -> pure (Left e)
    Right meta
      | not (isResumable (rmPhase meta)) ->
          pure
            ( Left
                ( "run '"
                    <> runId
                    <> "' has status '"
                    <> phaseText (rmPhase meta)
                    <> "' and is not resumable (§8.2)"
                )
            )
      | otherwise ->
          let entry = qnameFromText (rmEntrypoint meta)
           in case reconstructInputs tp entry (rmInputs meta) of
                Left e -> pure (Left e)
                Right rootInputs -> do
                  priorEvents <- readTraceEvents store
                  let lastSeq = case priorEvents of
                        [] -> (-1)
                        _ -> maximum (map teSeq priorEvents)
                  bracket (openTraceAppend store) hClose $ \h -> do
                    tracer <- newPersistentTracer h priorEvents (lastSeq + 1)
                    updateRunPhase store PhaseRunning
                    usageSeam <- newUsageSeam store (budgetMaxCostUsd (tpManifest tp)) (rmUsage meta)
                    let rt = mkRuntime tp ws models store tracer (runInfo runId (rmStartedAt meta) entry rootInputs envVars) usageSeam True
                    _ <- emit tracer (Resumed runId lastSeq)
                    Right <$> (guardedFinish rt store entry =<< tryAny (runWorkflow rt "" entry rootInputs))

-- | Run the workflow body and finalise the run, mapping synchronous exceptions
-- to a deliberate crash path (§8.2, §8.3.2).
guardedFinish ::
  Runtime ->
  RunStore ->
  QName ->
  Either SomeException (Either RuntimeError RValue) ->
  IO RunResult
guardedFinish rt store entry = \case
  Right outcome -> finish rt store outcome
  Left exc -> finishCrash rt store entry exc

-- | Emit @run-end@, finalise @run.json@ status, and package the events.
finish :: Runtime -> RunStore -> Either RuntimeError RValue -> IO RunResult
finish rt store outcome = do
  _ <- emit (rtTracer rt) (RunEnd (riRunId (rtRunInfo rt)) (either (const Aborted) (const Completed) outcome))
  updateRunPhase store (either (const PhaseAborted) (const PhaseCompleted) outcome)
  events <- snapshotEvents (rtTracer rt)
  pure (RunResult outcome events)

-- | Handle an unexpected synchronous exception: record an @internal@ error,
-- emit @run-end@ with @crashed@, set @run.json@ phase, and surface the fault as
-- a typed 'RuntimeError' (§8.2).
finishCrash :: Runtime -> RunStore -> QName -> SomeException -> IO RunResult
finishCrash rt store entry exc = do
  let msg = T.pack (displayException exc)
      runId = riRunId (rtRunInfo rt)
  _ <- emit (rtTracer rt) (ErrorEvent entry "" msg KInternal)
  _ <- emit (rtTracer rt) (RunEnd runId Crashed)
  updateRunPhase store PhaseCrashed
  events <- snapshotEvents (rtTracer rt)
  pure (RunResult (Left (internalError msg)) events)

mkRuntime :: TypedProject -> Workspace -> ModelStore -> RunStore -> Tracer -> RunInfo -> UsageSeam -> Bool -> Runtime
mkRuntime tp ws models store tracer ri usage resume =
  Runtime
    { rtProject = tp,
      rtWorkspace = ws,
      rtModels = models,
      rtStore = store,
      rtTracer = tracer,
      rtRunInfo = ri,
      rtUsage = usage,
      rtResume = resume
    }

runInfo :: Text -> Text -> QName -> Map Ident RValue -> Map Text Text -> RunInfo
runInfo runId startedAt entry rootInputs envVars =
  RunInfo
    { riRunId = runId,
      riStartedAt = startedAt,
      riEntrypoint = renderQName entry,
      riRootInputs = redactedJson (VRecord rootInputs),
      riEnvFields = buildEnvRecord envVars
    }

-- | Reconstruct typed root inputs from the JSON persisted in @run.json@ using
-- the entrypoint's declared input types (spec §8.2).
reconstructInputs :: TypedProject -> QName -> Value -> Either Text (Map Ident RValue)
reconstructInputs tp entry v = case v of
  Object o -> case lookupTyped entry tp of
    Nothing -> Left ("entrypoint '" <> renderQName entry <> "' not found on resume")
    Just td -> Map.fromList <$> traverse (field o) (rsigInputs (tdSignature td))
  _ -> Left "run.json 'inputs' is not an object"
  where
    field o (n, ty) = case KM.lookup (K.fromText n) o of
      Just fv -> (,) n <$> tagInput n (coerceFromJson ty fv)
      Nothing -> Left ("missing persisted input '" <> n <> "'")
    tagInput n = either (\m -> Left ("input '" <> n <> "': " <> m)) Right

-- Workflow execution ---------------------------------------------------------

-- | Run a workflow or tool by qname with the supplied inputs record. The
-- @scope@ prefix is the caller's control-flow scope (§4.1): top-level entry
-- uses @""@; a sub-workflow invoked from a loop iteration or branch inherits
-- the call-site prefix so its internal step-keys stay distinct per call site.
runWorkflow :: Runtime -> Text -> QName -> Map Ident RValue -> IO (Either RuntimeError RValue)
runWorkflow rt scope q inputs =
  case lookupTyped q (rtProject rt) of
    Nothing -> pure (Left (internalError ("no such declaration: " <> renderQName q)))
    Just td -> case declBody (tdDeclaration td) of
      Nothing -> pure (Left (internalError (renderQName q <> " is not executable")))
      Just (stmts, sections) ->
        let typedSteps = Map.fromList [(stepId (tsStmt ts), ts) | ts <- tdSteps td]
         in execStatements rt typedSteps q sections scope (Map.singleton "inputs" (VRecord inputs)) Nothing stmts

-- | The default @par@ concurrency bound when @par(max = N)@ is not given
-- (§13, M8).
defaultParallelism :: Int
defaultParallelism = 4

execStatements ::
  Runtime ->
  Map Ident TypedStep ->
  QName ->
  [Section] ->
  -- | The current step-key scope prefix (§8.1): empty at a body's top level,
  -- extended per control-flow branch\/iteration so nested step-keys stay
  -- distinct across branches and loop iterations (§13, M8).
  Text ->
  Map Ident RValue ->
  Maybe RValue ->
  [Statement] ->
  IO (Either RuntimeError RValue)
execStatements rt typedSteps q sections scope bindings lastResult = \case
  [] -> pure (Right (fromMaybe (VRecord Map.empty) lastResult))
  (SReturn args _ : _) -> do
    ctx <- buildCtx rt q "return"
    let env = mkEvalEnv rt sections (Map.insert "ctx" ctx bindings)
    case evalArgs env args of
      Left e -> failStep rt (StepRef q "return") e
      Right fields -> pure (Right (VRecord (Map.fromList fields)))
  (stmt : rest) -> do
    r <- execStmt rt typedSteps q sections scope bindings stmt
    case r of
      Left e -> pure (Left e)
      Right (bindings', result) ->
        execStatements rt typedSteps q sections scope bindings' (Just result) rest

-- | Execute one statement, returning the updated bindings and its result value.
-- @return@ is handled by 'execStatements' (it terminates the sequence) and so
-- never reaches here.
execStmt ::
  Runtime ->
  Map Ident TypedStep ->
  QName ->
  [Section] ->
  Text ->
  Map Ident RValue ->
  Statement ->
  IO (Either RuntimeError (Map Ident RValue, RValue))
execStmt rt typedSteps q sections scope bindings = \case
  SStep s -> execStep rt typedSteps q sections scope bindings s
  SIf s -> execIf rt typedSteps q sections scope bindings s
  SLoop s -> execLoop rt typedSteps q sections scope bindings s
  SWhile s -> execWhile rt typedSteps q sections scope bindings s
  STry s -> execTry rt typedSteps q sections scope bindings s
  SReturn _ _ -> pure (Left (internalError "unexpected 'return' in statement position"))

-- | Run a control-flow block (an @if@ branch or a loop body) in a child
-- binding scope: it sees the enclosing bindings but its own binds do not
-- escape (only the construct's value is returned to the caller). The block's
-- value is its final statement's result (§5.6.5, §13).
runBlock ::
  Runtime ->
  Map Ident TypedStep ->
  QName ->
  [Section] ->
  Text ->
  Map Ident RValue ->
  [Statement] ->
  IO (Either RuntimeError RValue)
runBlock rt typedSteps q sections scope childBindings =
  execStatements rt typedSteps q sections scope childBindings Nothing

-- Control flow (§13, M8) -----------------------------------------------------

-- | Execute an @if@\/@else@ statement (§13). The condition is evaluated with
-- the ambient @ctx@; the taken branch runs in a child scope whose step-key
-- prefix records the branch, so its steps never collide with the other
-- branch's on resume (§8.1). The statement's value is the taken branch's value
-- (an empty record when a discarding @if@ takes an absent @else@).
execIf ::
  Runtime ->
  Map Ident TypedStep ->
  QName ->
  [Section] ->
  Text ->
  Map Ident RValue ->
  IfStmt ->
  IO (Either RuntimeError (Map Ident RValue, RValue))
execIf rt typedSteps q sections scope bindings s = do
  ctx <- buildCtx rt q (ifId s)
  let stepRef = StepRef q (ifId s)
      env = mkEvalEnv rt sections (Map.insert "ctx" ctx bindings)
  case evalExpr env (ifCond s) of
    Left e -> Left <$> failWith rt stepRef e
    Right (VBool True) -> do
      _ <- emit (rtTracer rt) (IfBranch q (ifId s) "then")
      runBranch "then" (ifThen s)
    Right (VBool False) -> case ifElse s of
      Just blk -> do
        _ <- emit (rtTracer rt) (IfBranch q (ifId s) "else")
        runBranch "else" blk
      Nothing -> do
        _ <- emit (rtTracer rt) (IfBranch q (ifId s) "none")
        let v = VRecord Map.empty
        pure (Right (bindResult (ifBinder s) v bindings, v))
    Right _ -> Left <$> failWith rt stepRef (evalError "'if' condition did not evaluate to a Bool")
  where
    runBranch branch blk = do
      r <- runBlock rt typedSteps q sections (ifScope scope (ifId s) branch) bindings blk
      pure (fmap (\v -> (bindResult (ifBinder s) v bindings, v)) r)

-- | Execute a @try@\/@catch@ statement (§4.4). Catchable errors in the try arm
-- trigger the catch arm; @internal@ errors propagate. Resume uses prior
-- @try-branch@ events to decide whether to re-run the try arm or continue the
-- catch arm (§4.4.6).
execTry ::
  Runtime ->
  Map Ident TypedStep ->
  QName ->
  [Section] ->
  Text ->
  Map Ident RValue ->
  TryStmt ->
  IO (Either RuntimeError (Map Ident RValue, RValue))
execTry rt typedSteps q sections scope bindings s = do
  resumePhase <-
    if rtResume rt
      then do
        events <- snapshotEvents (rtTracer rt)
        pure (lookupTryResumePhase q (tryId s) events)
      else pure TryFresh
  case resumePhase of
    TryContinueCatch -> runCatchArm False
    TryFresh -> do
      _ <- emit (rtTracer rt) (TryBranch q (tryId s) "try")
      r <- runBlock rt typedSteps q sections (tryScope scope (tryId s) "try") bindings (tryTry s)
      case r of
        Right v -> pure (Right (bindResult (tryBinder s) v bindings, v))
        Left e
          | isCatchable (reKind e) -> runCatchArm True
          | otherwise -> pure (Left e)
  where
    runCatchArm emitCatch = do
      when emitCatch $
        void (emit (rtTracer rt) (TryBranch q (tryId s) "catch"))
      r <- runBlock rt typedSteps q sections (tryScope scope (tryId s) "catch") bindings (tryCatch s)
      case r of
        Left e -> pure (Left e)
        Right v -> pure (Right (bindResult (tryBinder s) v bindings, v))

data TryResumePhase = TryFresh | TryContinueCatch

lookupTryResumePhase :: QName -> Ident -> [TraceEvent] -> TryResumePhase
lookupTryResumePhase q tid events =
  case [b | TraceEvent _ _ (TryBranch q' tid' b) <- events, q' == q, tid' == tid] of
    bs | "catch" `elem` bs -> TryContinueCatch
    _ -> TryFresh

-- | Execute a @foreach@\/@par@ loop (§13). The scrutinee list is evaluated
-- once; each element runs the body in a child scope binding the loop variable,
-- with a per-iteration step-key prefix (so a resumed run distinguishes and
-- does not re-apply already-completed iterations, §8.2). The value is the list
-- of per-iteration body values (map semantics), always in input order. @par@
-- runs iterations with bounded concurrency but still returns results in input
-- order and aborts with the lowest-index error, so it is deterministic.
execLoop ::
  Runtime ->
  Map Ident TypedStep ->
  QName ->
  [Section] ->
  Text ->
  Map Ident RValue ->
  LoopStmt ->
  IO (Either RuntimeError (Map Ident RValue, RValue))
execLoop rt typedSteps q sections scope bindings s = do
  ctx <- buildCtx rt q (loopId s)
  let stepRef = StepRef q (loopId s)
      env = mkEvalEnv rt sections (Map.insert "ctx" ctx bindings)
  case evalExpr env (loopList s) of
    Left e -> Left <$> failWith rt stepRef e
    Right (VList xs) -> do
      _ <- emit (rtTracer rt) (LoopStart q (loopId s) kindLabel (Just (length xs)))
      res <- case loopKind s of
        LoopSeq -> runSeq xs
        LoopPar opts -> runPar opts xs
      case res of
        Left e -> pure (Left e)
        Right vs -> do
          _ <- emit (rtTracer rt) (LoopEnd q (loopId s) (length xs))
          let v = VList vs
          pure (Right (bindResult (loopBinder s) v bindings, v))
    Right _ ->
      Left <$> failWith rt stepRef (evalError ("'" <> kindLabel <> "' expected a list to iterate over"))
  where
    kindLabel = case loopKind s of
      LoopSeq -> "foreach"
      LoopPar _ -> "par"

    runIter :: Int -> RValue -> IO (Either RuntimeError RValue)
    runIter i x = do
      _ <- emit (rtTracer rt) (LoopIter q (loopId s) i)
      let childBindings = Map.insert (loopVar s) x bindings
      runBlock rt typedSteps q sections (iterScope scope (loopId s) i) childBindings (loopBody s)

    runSeq = go 0 []
      where
        go _ acc [] = pure (Right (reverse acc))
        go i acc (x : rest) = do
          r <- runIter i x
          case r of
            Left e -> pure (Left e)
            Right v -> go (i + 1) (v : acc) rest

    runPar opts xs = case parOnError opts of
      ParOnErrorFail -> runParFail opts xs
      ParOnErrorCollect -> runParCollect opts xs

    runParFail ParOpts {parMax = mMax} xs = do
      let n = max 1 (fromMaybe defaultParallelism mMax)
      results <- pooledForConcurrentlyN n (zip [0 ..] xs) (uncurry runIter)
      case lefts results of
        (e : _) -> pure (Left e)
        [] -> pure (Right (rights results))

    runParCollect ParOpts {parMax = mMax} xs = do
      let n = max 1 (fromMaybe defaultParallelism mMax)
      results <- pooledForConcurrentlyN n (zip [0 ..] xs) (uncurry runIterCollect)
      case lefts results of
        (e : _) -> pure (Left e)
        [] -> pure (Right (rights results))

    runIterCollect i x =
      runIter i x >>= \case
        Right v -> pure (Right (parCollectSuccess v))
        Left e
          | isCatchable (reKind e) -> pure (Right (parCollectFailure (reMessage e)))
          | otherwise -> pure (Left e)

-- | The step-key scope prefix for a @try@ arm (§4.4.5).
tryScope :: Text -> Ident -> Text -> Text
tryScope scope sid arm = scope <> sid <> "?" <> arm <> "/"

-- | The step-key scope prefix for a taken @if@ branch (§8.1, §13).
ifScope :: Text -> Ident -> Text -> Text
ifScope scope sid branch = scope <> sid <> "?" <> branch <> "/"

-- | The step-key scope prefix for a loop iteration (§8.1, §13).
iterScope :: Text -> Ident -> Int -> Text
iterScope scope sid i = scope <> sid <> "#" <> T.pack (show i) <> "/"

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

-- | The step-key scope prefix for a @while@ predicate/body invocation (§4.3.5).
whilePredScope :: Text -> Ident -> Int -> Text
whilePredScope scope sid i = iterScope scope sid i <> "p/"

whileBodyScope :: Text -> Ident -> Int -> Text
whileBodyScope scope sid i = iterScope scope sid i <> "b/"

-- | Execute a @while@ loop (§4.3, M9).
execWhile ::
  Runtime ->
  Map Ident TypedStep ->
  QName ->
  [Section] ->
  Text ->
  Map Ident RValue ->
  WhileStmt ->
  IO (Either RuntimeError (Map Ident RValue, RValue))
execWhile rt typedSteps q sections scope bindings s = do
  let stepRef = StepRef q (whileId s)
  ctx <- buildCtx rt q (whileId s)
  let baseEnv = mkEvalEnv rt sections (Map.insert "ctx" ctx bindings)
  case evalExpr baseEnv (whileMaxIterations s) of
    Left e -> failStep rt stepRef e
    Right (VInt n) | n >= 1 -> do
      let maxIter = fromInteger n
      _ <- emit (rtTracer rt) (LoopStart q (whileId s) "while" Nothing)
      go stepRef 0 [] Nothing baseEnv maxIter
    Right _ -> failStep rt stepRef (evalError "while max_iterations must evaluate to an Int >= 1 (§4.3)")
  where
    go stepRef i acc mCarry env maxIter = do
      _ <- emit (rtTracer rt) (LoopIter q (whileId s) i)
      let decisionKey = computeWhileDecisionKey q scope (whileId s) i
      decisionRes <-
        ( if rtResume rt
            then
              lookupWhileDecision (rtStore rt) decisionKey >>= \case
                Just pinned -> pure (Right pinned)
                Nothing -> runPredicate i env mCarry decisionKey
            else runPredicate i env mCarry decisionKey
          )
      case decisionRes of
        Left e -> pure (Left e)
        Right (cont, _reason)
          | not cont -> do
              _ <- emit (rtTracer rt) (LoopEnd q (whileId s) (i + 1))
              let v = VList (reverse acc)
              pure (Right (bindResult (whileBinder s) v bindings, v))
          | i >= maxIter ->
              failStep
                rt
                stepRef
                ( userError_
                    ( "while loop reached max_iterations ("
                        <> T.pack (show maxIter)
                        <> ") without predicate returning continue = false (§4.3)"
                    )
                )
          | otherwise -> do
              bodyRes <-
                runWhileBody
                  rt
                  typedSteps
                  q
                  sections
                  (whileBodyScope scope (whileId s) i)
                  env
                  bindings
                  (whileBody s)
                  mCarry
              case bodyRes of
                Left e -> pure (Left e)
                Right bv -> go stepRef (i + 1) (bv : acc) (Just bv) env maxIter

    runPredicate i env mCarry decisionKey = do
      predRes <-
        runWhileCallee
          rt
          (whilePredScope scope (whileId s) i)
          env
          (whilePredicate s)
          (whilePredicateArgs s)
          mCarry
      case predRes of
        Left e -> pure (Left e)
        Right pv -> case extractPredDecision pv of
          Left e -> pure (Left e)
          Right decision@(cont, rsn) -> do
            _ <- emit (rtTracer rt) (WhilePred q (whileId s) i cont rsn (Just decisionKey))
            cacheWhileDecision (rtStore rt) decisionKey cont rsn
            pure (Right decision)

runWhileBody ::
  Runtime ->
  Map Ident TypedStep ->
  QName ->
  [Section] ->
  Text ->
  EvalEnv ->
  Map Ident RValue ->
  WhileBody ->
  Maybe RValue ->
  IO (Either RuntimeError RValue)
runWhileBody rt typedSteps q sections scope env bindings wb mCarry =
  case wb of
    WhileBodyCallee calleeExpr args ->
      runWhileCallee rt scope env calleeExpr args mCarry
    WhileBodyInline stmts -> do
      let childBindings =
            maybe bindings (\v -> Map.insert "carry" v bindings) mCarry
      runBlock rt typedSteps q sections scope childBindings stmts

runWhileCallee ::
  Runtime ->
  Text ->
  EvalEnv ->
  Expr ->
  [Arg] ->
  Maybe RValue ->
  IO (Either RuntimeError RValue)
runWhileCallee rt scope env calleeExpr args mCarry =
  case resolveWhileCallee env calleeExpr of
    Left e -> pure (Left e)
    Right target -> case evalWhileArgs env mCarry args of
      Left e -> pure (Left e)
      Right argMap -> runWorkflow rt scope target argMap

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

-- | Execute a single step, honouring the step cache (§8.1, §8.2):
--
--   1. evaluate arguments (with the ambient @ctx@ injected);
--   2. if cacheable, compute the step-key and — when resuming — try the cache;
--      a hit binds the reconstructed result and emits /no/ events (§8.3.4);
--   3. otherwise emit @step-start@, dispatch, emit @step-end@, and (if
--      cacheable) persist the result under its step-key.
execStep ::
  Runtime ->
  Map Ident TypedStep ->
  QName ->
  [Section] ->
  Text ->
  Map Ident RValue ->
  StepStmt ->
  IO (Either RuntimeError (Map Ident RValue, RValue))
execStep rt typedSteps q sections scope bindings s = do
  let sid = stepId s
      stepRef = StepRef q sid
      target = stepTarget s
      mts = Map.lookup sid typedSteps
      cacheable = maybe (classifyCacheable target (stepArgs s)) tsCacheable mts
      resultTy = maybe TyJson tsResultType mts
  ctx <- buildCtx rt q sid
  let env = mkEvalEnv rt sections (Map.insert "ctx" ctx bindings)
  case evalArgs env (stepArgs s) of
    Left e -> Left <$> failWith rt stepRef e
    Right argPairs -> do
      let argMap = Map.fromList argPairs
          mKey =
            if cacheable
              then Just (stepKeyFor rt scope env bindings mts q sid target argMap s)
              else Nothing
          mAgentKey =
            if isAgentBuiltin target
              then Just (stepKeyFor rt scope env bindings mts q sid target argMap s)
              else Nothing
          mTraceKey =
            mKey <|> mAgentKey
      hit <- cacheHit rt resultTy mKey
      case hit of
        Just result -> pure (Right (bindResult (stepBinder s) result bindings, result))
        Nothing -> do
          _ <- emit (rtTracer rt) (StepStart q sid (redactedJson (VRecord argMap)) cacheable mTraceKey)
          start <- getCurrentTime
          dr <-
            if isAgentBuiltin target
              then case mAgentKey of
                Just agentKey ->
                  runAgentStep rt bindings stepRef scope target argMap agentKey
                Nothing ->
                  failStep rt stepRef (internalError "agent step-key missing")
              else dispatch rt stepRef bindings scope target argMap
          case dr of
            Left e -> Left <$> failWith rt stepRef e
            Right result -> do
              end <- getCurrentTime
              _ <- emit (rtTracer rt) (StepEnd q sid (redactedJson result) (durationMs start end) mKey)
              case mKey of
                Just key -> cacheStepResult (rtStore rt) key (valueToJson result)
                Nothing -> pure ()
              pure (Right (bindResult (stepBinder s) result bindings, result))

-- | Consult the step cache: only on resume, only for a cacheable step with a
-- key, and only when the persisted JSON reconstructs to a value of the step's
-- static result type (a mismatch is treated as a miss and re-executed).
cacheHit :: Runtime -> Type -> Maybe Text -> IO (Maybe RValue)
cacheHit rt resultTy mKey
  | not (rtResume rt) = pure Nothing
  | otherwise = case mKey of
      Nothing -> pure Nothing
      Just key -> do
        mJson <- lookupCachedResult (rtStore rt) key
        pure (mJson >>= either (const Nothing) Just . coerceFromJson resultTy)

-- | Compute a step's step-key (§8.1) from its resolved args, stable @ctx@
-- projection, and callee fingerprint.
stepKeyFor ::
  Runtime ->
  -- | The control-flow scope prefix (§13, M8), folded into the step id so a
  -- step's key is distinct per branch\/iteration. Empty at a body's top level,
  -- keeping top-level keys identical to the pre-control-flow engine.
  Text ->
  EvalEnv ->
  Map Ident RValue ->
  Maybe TypedStep ->
  QName ->
  Ident ->
  QName ->
  Map Ident RValue ->
  StepStmt ->
  Text
stepKeyFor rt scope env bindings mts q sid target argMap s =
  computeStepKey refFp q (scope <> sid) argMap ctxProj calleeFp
  where
    tp = rtProject rt
    refFp qn = fpText <$> fingerprintOfQName tp qn
    ctxProj = baseCtxProj <> modelCatalogProj
    baseCtxProj =
      [ (renderRefPath rp, canonicalJson (valueToJson v))
        | rp <- stableCtxPaths s,
          Right v <- [resolveRefPath env rp]
      ]
    modelCatalogProj
      | isOneShotLlmBuiltin target = oneShotLlmCtxProjection argMap (rtModels rt)
      | otherwise = []
    calleeFp = case tsCalleeFingerprint =<< mts of
      Just fp -> fpText fp
      Nothing -> case (isBareQName target, Map.lookup (bareIdent target) bindings) of
        (True, Just (VRef _ realQ)) -> maybe "" fpText (fingerprintOfQName tp realQ)
        _ -> ""

-- Call dispatch --------------------------------------------------------------

dispatch ::
  Runtime ->
  StepRef ->
  Map Ident RValue ->
  Text ->
  QName ->
  Map Ident RValue ->
  IO (Either RuntimeError RValue)
dispatch rt stepRef bindings scope target argMap
  | isBareQName target =
      case Map.lookup (bareIdent target) bindings of
        Just (VRef _ realQ) -> dispatchResolved rt stepRef bindings scope realQ argMap
        Just _ ->
          pure (Left (evalError ("'" <> renderQName target <> "' is not a callable ref value")))
        Nothing ->
          pure (Left (evalError ("call target '" <> renderQName target <> "' is not bound")))
  | otherwise = dispatchResolved rt stepRef bindings scope target argMap

dispatchResolved ::
  Runtime ->
  StepRef ->
  Map Ident RValue ->
  Text ->
  QName ->
  Map Ident RValue ->
  IO (Either RuntimeError RValue)
dispatchResolved rt stepRef bindings scope target argMap
  | isBuiltin target =
      runBuiltin (builtinEnv rt stepRef bindings scope) target argMap
  | otherwise = case lookupTyped target (rtProject rt) of
      Just td
        | isExecutable (tdDeclaration td) -> runWorkflow rt scope target argMap
      _ -> pure (Left (internalError ("cannot dispatch to " <> renderQName target)))

-- Agent step (§6.1) ----------------------------------------------------------

-- | Run a @builtin/llm-agent@\/@builtin/llm-agent-object@ step (spec §6.1). The
-- loop lives in 'Hwfi.Runtime.Agent'; the executor supplies the effectful seams
-- — the tracer, the intra-step cache store, and a dispatcher that runs a
-- model-chosen ref as a nested step (so its effects go through the sandboxed
-- workspace and its events nest under the agent step, §6.1.2, §8.3.3.7).
runAgentStep ::
  Runtime ->
  Map Ident RValue ->
  StepRef ->
  Text ->
  QName ->
  Map Ident RValue ->
  -- | The enclosing agent step-key namespacing every sub-key (§8.2.1).
  Text ->
  IO (Either RuntimeError RValue)
runAgentStep rt bindings stepRef scope target argMap agentKey =
  case buildAgentSpec rt target argMap of
    Left e -> pure (Left e)
    Right spec -> do
      skillState <- newIORef emptyAgentSkillState
      runAgent (mkAgentEnv rt bindings stepRef scope agentKey skillState) spec

mkAgentEnv :: Runtime -> Map Ident RValue -> StepRef -> Text -> Text -> IORef AgentSkillState -> AgentEnv
mkAgentEnv rt bindings stepRef scope agentKey skillState =
  AgentEnv
    { aeTracer = rtTracer rt,
      aeStore = rtStore rt,
      aeResume = rtResume rt,
      aeUsage = rtUsage rt,
      aeQName = srQName stepRef,
      aeStepId = srStepId stepRef,
      aeStepKey = agentKey,
      aeDispatch = \tq tsid targs -> dispatchResolved rt (StepRef tq tsid) bindings scope tq targs,
      aeSkillPolicy = skillPolicyFromManifest (tpManifest (rtProject rt)),
      aeSkillCatalog = tpSkillCatalog (rtProject rt),
      aeSkillState = skillState,
      aeBuildTool = buildAdvertisedTool rt
    }

buildAdvertisedTool :: Runtime -> QName -> Maybe AdvertisedTool
buildAdvertisedTool rt q =
  case refKind rt q of
    Nothing -> Nothing
    Just rk ->
      case buildTool rt (VRef rk q) of
        Right t -> Just t
        Left _ -> Nothing

-- | Assemble the 'AgentSpec' from the resolved step arguments (spec §6.1). The
-- checker (§5.6.9) has already validated the shape, so a mismatch here is an
-- internal error.
buildAgentSpec :: Runtime -> QName -> Map Ident RValue -> Either RuntimeError AgentSpec
buildAgentSpec rt target argMap = do
  system <- reqText "system"
  prompt <- reqText "prompt"
  modelName <- reqText "model"
  model <- lookupModel modelName (rtModels rt)
  maxRounds <- reqInt "max_rounds"
  tools <- traverse (buildTool rt) =<< reqList "tools"
  submit <-
    if target == llmAgentObjectQName
      then Just . mkSubmit . valueToJson <$> reqValue "schema"
      else Right Nothing
  Right
    AgentSpec
      { asSystem = system,
        asPrompt = prompt,
        asModelName = modelName,
        asModel = model,
        asModelFingerprint = modelCatalogFingerprint modelName (rtModels rt),
        asTools = tools,
        asMaxRounds = maxRounds,
        asSubmit = submit
      }
  where
    reqValue name = case Map.lookup name argMap of
      Just v -> Right v
      Nothing -> Left (internalError ("agent argument '" <> name <> "' is missing at runtime"))
    reqText name =
      reqValue name >>= \case
        VString t -> Right t
        VFileRef t -> Right t
        _ -> Left (internalError ("agent argument '" <> name <> "' is not text"))
    reqInt name =
      reqValue name >>= \case
        VInt n -> Right (fromInteger n)
        _ -> Left (internalError ("agent argument '" <> name <> "' is not an integer"))
    reqList name =
      reqValue name >>= \case
        VList xs -> Right xs
        _ -> Left (internalError ("agent argument '" <> name <> "' is not a list"))
    mkSubmit schema = SubmitSpec {ssSchema = schema, ssToolDef = submitToolDef schema}

-- | Build one 'AdvertisedTool' from a first-class ref value: its declared input
-- types drive the JSON-Schema tool parameters (§6.1.1) and its fingerprint
-- namespaces that tool's intra-step cache (§8.2.1).
buildTool :: Runtime -> RValue -> Either RuntimeError AdvertisedTool
buildTool rt = \case
  VRef _ q -> do
    ins <- calleeInputTypes rt q
    outs <- calleeOutputTypes rt q
    Right
      AdvertisedTool
        { atQName = q,
          atToolDef = advertisedToolDef q ins,
          atInputs = ins,
          atOutputs = outs,
          atFingerprint = maybe "" fpText (fingerprintOfQName (rtProject rt) q)
        }
  _ -> Left (internalError "agent 'tools' element is not a ref value")

-- | The declared input types of an advertised callee (a builtin or a project
-- declaration).
calleeInputTypes :: Runtime -> QName -> Either RuntimeError [(Ident, Type)]
calleeInputTypes rt q
  | isBuiltin q = case lookupBuiltin q of
      Just c -> Right (calleeInputs c)
      Nothing -> Left (internalError ("no such builtin: " <> renderQName q))
  | otherwise = case lookupTyped q (rtProject rt) of
      Just td -> Right (rsigInputs (tdSignature td))
      Nothing -> Left (internalError ("advertised tool not found: " <> renderQName q))

calleeOutputTypes :: Runtime -> QName -> Either RuntimeError [(Ident, Type)]
calleeOutputTypes rt q
  | isBuiltin q = case lookupBuiltin q of
      Just c -> Right (calleeOutputs c)
      Nothing -> Left (internalError ("no such builtin: " <> renderQName q))
  | otherwise = case lookupTyped q (rtProject rt) of
      Just td -> Right (rsigOutputs (tdSignature td))
      Nothing -> Left (internalError ("advertised tool not found: " <> renderQName q))

builtinEnv :: Runtime -> StepRef -> Map Ident RValue -> Text -> BuiltinEnv
builtinEnv rt stepRef bindings scope =
  BuiltinEnv
    { beWorkspace = rtWorkspace rt,
      beModels = rtModels rt,
      beTracer = rtTracer rt,
      beStep = stepRef,
      beExecPolicy = (tpManifest (rtProject rt)).execPolicy,
      beUsage = rtUsage rt,
      beIntrospect = introspectDump rt stepRef bindings,
      beEvalWorkflow = Just (evalWorkflowSeam rt scope),
      beRunId = riRunId (rtRunInfo rt),
      beSkillCatalog = tpSkillCatalog (rtProject rt)
    }

evalWorkflowSeam :: Runtime -> Text -> EvalWorkflowSeam
evalWorkflowSeam rt scope =
  EvalWorkflowSeam
    { ewsProject = rtProject rt,
      ewsScope = scope,
      ewsExecute = \tp sc q inputs -> runWorkflow (rt {rtProject = tp}) sc q inputs
    }

-- | Assemble the @builtin/introspect@ dump (spec §6): a JSON view of everything
-- the runtime knows about the current run, secrets redacted.
introspectDump :: Runtime -> StepRef -> Map Ident RValue -> IO Value
introspectDump rt stepRef bindings = do
  events <- snapshotJson (rtTracer rt)
  usage <- readIORef (usRef (rtUsage rt))
  let ri = rtRunInfo rt
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
            [ "qname" .= renderQName (srQName stepRef),
              "step_id" .= srStepId stepRef
            ],
        "workspace" .= T.pack (workspaceRoot (rtWorkspace rt)),
        "inputs" .= riRootInputs ri,
        "bindings" .= object [K.fromText k .= redactedJson v | (k, v) <- Map.toList bindings],
        "trace" .= events
      ]

-- Environment and context ----------------------------------------------------

mkEvalEnv :: Runtime -> [Section] -> Map Ident RValue -> EvalEnv
mkEvalEnv rt sections bindings =
  EvalEnv
    { eeBindings = bindings,
      eeSections = sections,
      eeRefKind = refKind rt
    }

refKind :: Runtime -> QName -> Maybe RefKind
refKind rt q
  | isBuiltin q = Just RTool
  | otherwise = case lookupTyped q (rtProject rt) of
      Just td -> case tdDeclaration td of
        DeclTool _ -> Just RTool
        DeclWorkflow _ -> Just RWorkflow
        _ -> Nothing
      Nothing -> Nothing

buildCtx :: Runtime -> QName -> Ident -> IO RValue
buildCtx rt q sid = do
  events <- snapshotEvents (rtTracer rt)
  usage <- readIORef (usRef (rtUsage rt))
  pure (contextValue (rtRunInfo rt) usage q sid events)

-- Step-key helpers -----------------------------------------------------------

-- | Resolve any qname to its fingerprint at runtime (§8.1): declared decls use
-- their Merkle fingerprint; builtins their fixed engine-derived one.
fingerprintOfQName :: TypedProject -> QName -> Maybe Fingerprint
fingerprintOfQName tp q
  | isBuiltin q = Just (builtinFingerprint q)
  | otherwise = tdFingerprint <$> lookupTyped q tp

fpText :: Fingerprint -> Text
fpText (Fingerprint t) = t

-- | The distinct /stable/ @ctx.*@ reference paths a step's arguments read
-- (§8.1). Volatile paths never appear on a cacheable step, but are filtered
-- defensively.
stableCtxPaths :: StepStmt -> [RefPath]
stableCtxPaths s = nub [rp | a <- stepArgs s, rp <- exprRefPaths (argValue a), isStableCtx rp]

isStableCtx :: RefPath -> Bool
isStableCtx (RefPath "ctx" accs) = not (volatile accs)
  where
    volatile (AField "trace" : _) = True
    volatile (AField "run" : AField "started_at" : _) = True
    volatile (AField "run" : AField "usage" : _) = True
    volatile _ = False
isStableCtx _ = False

exprRefPaths :: Expr -> [RefPath]
exprRefPaths = \case
  EString parts -> [rp | SInterp rp <- parts]
  ERef rp -> [rp]
  EList es -> concatMap exprRefPaths es
  ERecord fs -> concatMap (exprRefPaths . snd) fs
  ERange e -> exprRefPaths e
  _ -> []

renderRefPath :: RefPath -> Text
renderRefPath (RefPath root accs) = root <> T.concat (map renderAccessor accs)
  where
    renderAccessor (AField f) = "." <> f
    renderAccessor (AIndex i) = "[" <> T.pack (show i) <> "]"

-- | A content hash of the checked project (spec §8.3.2, replacing M4's
-- entrypoint-fingerprint stand-in): a hash over every declaration's qname and
-- Merkle fingerprint. Any edit to any declaration changes it.
projectContentHash :: TypedProject -> Text
projectContentHash tp =
  sha256Hex (T.intercalate ";" (sort entries))
  where
    entries = [renderQName q <> ":" <> fpText (tdFingerprint d) | (q, d) <- Map.toList (tpDecls tp)]

-- Error handling -------------------------------------------------------------

failWith :: Runtime -> StepRef -> RuntimeError -> IO RuntimeError
failWith rt stepRef e = do
  let e' = atStep stepRef e
  _ <- emit (rtTracer rt) (ErrorEvent (srQName stepRef) (srStepId stepRef) (reMessage e') (reKind e'))
  pure e'

failStep :: Runtime -> StepRef -> RuntimeError -> IO (Either RuntimeError a)
failStep rt stepRef e = Left <$> failWith rt stepRef e

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

durationMs :: UTCTime -> UTCTime -> Int
durationMs start end = round (realToFrac (diffUTCTime end start) * (1000 :: Double))

-- | The current time in the trace's ISO-8601 millisecond form (§8.3.1).
nowIso :: IO Text
nowIso = T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S%3QZ" <$> getCurrentTime
