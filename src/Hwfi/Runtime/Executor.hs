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
  )
where

import Control.Monad (join)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.List (nub, sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime, defaultTimeLocale, diffUTCTime, formatTime, getCurrentTime)
import Hwfi.Ast.Expr (Accessor (..), Expr (..), RefPath (..), StringPart (..))
import Hwfi.Ast.Name (Ident, QName, isBareQName, qnameFromText, qnameSegments, renderQName)
import Hwfi.Ast.Project (Declaration (..))
import Hwfi.Ast.Step (Arg (..), Binder (..), Statement (..), StepStmt (..))
import Hwfi.Ast.Tool (Tool (..))
import Hwfi.Ast.Workflow (Section, Workflow (..))
import Hwfi.Check.Builtins (isBuiltin)
import Hwfi.Check.Decl (classifyCacheable)
import Hwfi.Check.Graph (builtinFingerprint)
import Hwfi.Runtime.Builtins (BuiltinEnv (..), runBuiltin)
import Hwfi.Runtime.Context (RunInfo (..), buildEnvRecord, contextValue)
import Hwfi.Runtime.Error
  ( RuntimeError (..),
    StepRef (..),
    atStep,
    evalError,
    internalError,
  )
import Hwfi.Runtime.Eval (EvalEnv (..), evalExpr, resolveRefPath)
import Hwfi.Runtime.Gateways (ModelStore)
import Hwfi.Runtime.RunStore
  ( RunMeta (..),
    RunPhase (..),
    RunStore,
    cacheStepResult,
    createRunStore,
    isResumable,
    lookupCachedResult,
    openRunStore,
    openTraceAppend,
    phaseText,
    readRunMeta,
    readTraceEvents,
    updateRunPhase,
    withWorkspaceLock,
    writeRunMeta,
  )
import Hwfi.Runtime.StepKey (computeStepKey, sha256Hex)
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
import Hwfi.Runtime.Value
  ( RValue (..),
    RefKind (..),
    canonicalJson,
    coerceFromJson,
    redactedJson,
    valueToJson,
  )
import Hwfi.Runtime.Workspace (Workspace, workspaceRoot)
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
import UnliftIO.Exception (bracket)

-- | Everything the executor threads through a run.
data Runtime = Runtime
  { rtProject :: TypedProject,
    rtWorkspace :: Workspace,
    rtModels :: ModelStore,
    rtStore :: RunStore,
    rtTracer :: Tracer,
    rtRunInfo :: RunInfo,
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
    writeRunMeta
      store
      RunMeta
        { rmRunId = runId,
          rmEntrypoint = renderQName entry,
          rmProjectDir = T.pack projectDir,
          rmStartedAt = startedAt,
          rmProjectHash = ph,
          rmInputs = valueToJson (VRecord rootInputs),
          rmPhase = PhaseRunning
        }
    bracket (openTraceAppend store) hClose $ \h -> do
      tracer <- newPersistentTracer h [] 0
      let rt = mkRuntime tp ws models store tracer (runInfo runId startedAt entry rootInputs envVars) False
      _ <- emit tracer (RunStart runId (renderQName entry) (redactedJson (VRecord rootInputs)) ph)
      finish rt store =<< runWorkflow rt entry rootInputs

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
                    let rt = mkRuntime tp ws models store tracer (runInfo runId (rmStartedAt meta) entry rootInputs envVars) True
                    _ <- emit tracer (Resumed runId lastSeq)
                    Right <$> (finish rt store =<< runWorkflow rt entry rootInputs)

-- | Emit @run-end@, finalise @run.json@ status, and package the events.
finish :: Runtime -> RunStore -> Either RuntimeError RValue -> IO RunResult
finish rt store outcome = do
  _ <- emit (rtTracer rt) (RunEnd (riRunId (rtRunInfo rt)) (either (const Aborted) (const Completed) outcome))
  updateRunPhase store (either (const PhaseAborted) (const PhaseCompleted) outcome)
  events <- snapshotEvents (rtTracer rt)
  pure (RunResult outcome events)

mkRuntime :: TypedProject -> Workspace -> ModelStore -> RunStore -> Tracer -> RunInfo -> Bool -> Runtime
mkRuntime tp ws models store tracer ri resume =
  Runtime
    { rtProject = tp,
      rtWorkspace = ws,
      rtModels = models,
      rtStore = store,
      rtTracer = tracer,
      rtRunInfo = ri,
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

-- | Run a workflow or tool by qname with the supplied inputs record.
runWorkflow :: Runtime -> QName -> Map Ident RValue -> IO (Either RuntimeError RValue)
runWorkflow rt q inputs =
  case lookupTyped q (rtProject rt) of
    Nothing -> pure (Left (internalError ("no such declaration: " <> renderQName q)))
    Just td -> case declBody (tdDeclaration td) of
      Nothing -> pure (Left (internalError (renderQName q <> " is not executable")))
      Just (stmts, sections) ->
        let typedSteps = Map.fromList [(stepId (tsStmt ts), ts) | ts <- tdSteps td]
         in execStatements rt typedSteps q sections (Map.singleton "inputs" (VRecord inputs)) Nothing stmts

execStatements ::
  Runtime ->
  Map Ident TypedStep ->
  QName ->
  [Section] ->
  Map Ident RValue ->
  Maybe RValue ->
  [Statement] ->
  IO (Either RuntimeError RValue)
execStatements rt typedSteps q sections bindings lastResult = \case
  [] -> pure (Right (maybe (VRecord Map.empty) id lastResult))
  (SReturn args _ : _) -> do
    ctx <- buildCtx rt q "return"
    let env = mkEvalEnv rt sections (Map.insert "ctx" ctx bindings)
    case evalArgs env args of
      Left e -> failStep rt (StepRef q "return") e
      Right fields -> pure (Right (VRecord (Map.fromList fields)))
  (SStep s : rest) -> do
    r <- execStep rt typedSteps q sections bindings s
    case r of
      Left e -> pure (Left e)
      Right (bindings', result) ->
        execStatements rt typedSteps q sections bindings' (Just result) rest

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
  Map Ident RValue ->
  StepStmt ->
  IO (Either RuntimeError (Map Ident RValue, RValue))
execStep rt typedSteps q sections bindings s = do
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
              then Just (stepKeyFor rt env bindings mts q sid target argMap s)
              else Nothing
      hit <- cacheHit rt resultTy mKey
      case hit of
        Just result -> pure (Right (bindResult (stepBinder s) result bindings, result))
        Nothing -> do
          _ <- emit (rtTracer rt) (StepStart q sid (redactedJson (VRecord argMap)) cacheable)
          start <- getCurrentTime
          dr <- dispatch rt stepRef bindings target argMap
          case dr of
            Left e -> Left <$> failWith rt stepRef e
            Right result -> do
              end <- getCurrentTime
              _ <- emit (rtTracer rt) (StepEnd q sid (redactedJson result) (durationMs start end))
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
  EvalEnv ->
  Map Ident RValue ->
  Maybe TypedStep ->
  QName ->
  Ident ->
  QName ->
  Map Ident RValue ->
  StepStmt ->
  Text
stepKeyFor rt env bindings mts q sid target argMap s =
  computeStepKey refFp q sid argMap ctxProj calleeFp
  where
    tp = rtProject rt
    refFp qn = fpText <$> fingerprintOfQName tp qn
    ctxProj =
      [ (renderRefPath rp, canonicalJson (valueToJson v))
      | rp <- stableCtxPaths s,
        Right v <- [resolveRefPath env rp]
      ]
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
  QName ->
  Map Ident RValue ->
  IO (Either RuntimeError RValue)
dispatch rt stepRef bindings target argMap
  | isBareQName target =
      case Map.lookup (bareIdent target) bindings of
        Just (VRef _ realQ) -> dispatchResolved rt stepRef bindings realQ argMap
        Just _ ->
          pure (Left (evalError ("'" <> renderQName target <> "' is not a callable ref value")))
        Nothing ->
          pure (Left (evalError ("call target '" <> renderQName target <> "' is not bound")))
  | otherwise = dispatchResolved rt stepRef bindings target argMap

dispatchResolved ::
  Runtime ->
  StepRef ->
  Map Ident RValue ->
  QName ->
  Map Ident RValue ->
  IO (Either RuntimeError RValue)
dispatchResolved rt stepRef bindings target argMap
  | isBuiltin target =
      runBuiltin (builtinEnv rt stepRef bindings) target argMap
  | otherwise = case lookupTyped target (rtProject rt) of
      Just td
        | isExecutable (tdDeclaration td) -> runWorkflow rt target argMap
      _ -> pure (Left (internalError ("cannot dispatch to " <> renderQName target)))

builtinEnv :: Runtime -> StepRef -> Map Ident RValue -> BuiltinEnv
builtinEnv rt stepRef bindings =
  BuiltinEnv
    { beWorkspace = rtWorkspace rt,
      beModels = rtModels rt,
      beTracer = rtTracer rt,
      beStep = stepRef,
      beIntrospect = introspectDump rt stepRef bindings
    }

-- | Assemble the @builtin/introspect@ dump (spec §6): a JSON view of everything
-- the runtime knows about the current run, secrets redacted.
introspectDump :: Runtime -> StepRef -> Map Ident RValue -> IO Value
introspectDump rt stepRef bindings = do
  events <- snapshotJson (rtTracer rt)
  let ri = rtRunInfo rt
  pure $
    object
      [ "run"
          .= object
            [ "id" .= riRunId ri,
              "started_at" .= riStartedAt ri,
              "entrypoint" .= riEntrypoint ri
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
  pure (contextValue (rtRunInfo rt) q sid events)

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
    volatile _ = False
isStableCtx _ = False

exprRefPaths :: Expr -> [RefPath]
exprRefPaths = \case
  EString parts -> [rp | SInterp rp <- parts]
  ERef rp -> [rp]
  EList es -> concatMap exprRefPaths es
  ERecord fs -> concatMap (exprRefPaths . snd) fs
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
