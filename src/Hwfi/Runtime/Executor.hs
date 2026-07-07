-- | The workflow executor (spec §4, §5.3, tasks 4.1, 4.8).
--
-- Runs a fully type-checked workflow: statements execute in source order,
-- each step's argument expressions are evaluated against the current binding
-- environment (with the ambient @ctx@ injected per step, §5.4), and the call
-- is dispatched to a builtin, a sub-workflow, or a user tool. Sub-workflow and
-- tool calls recurse through the same 'runWorkflow', so a workflow can call
-- another workflow as a step (A6) and the callee's trace events nest inside the
-- caller's step (§8.3.3.6).
--
-- Persistence, step-key caching, and resume are deferred to M5; this module
-- accumulates the trace in memory via the 'Tracer' seam, which M5 will extend
-- to append to @trace.jsonl@.
module Hwfi.Runtime.Executor
  ( RunResult (..),
    runEntrypoint,
    runWorkflow,
  )
where

import Data.Aeson (Value, object, (.=))
import Data.Aeson.Key qualified as K
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime, defaultTimeLocale, diffUTCTime, formatTime, getCurrentTime)
import Hwfi.Ast.Name (Ident, QName, isBareQName, qnameSegments, renderQName)
import Hwfi.Ast.Project (Declaration (..))
import Hwfi.Ast.Step (Arg (..), Binder (..), Statement (..), StepStmt (..))
import Hwfi.Ast.Tool (Tool (..))
import Hwfi.Ast.Workflow (Section, Workflow (..))
import Hwfi.Check.Builtins (isBuiltin)
import Hwfi.Check.Decl (classifyCacheable)
import Hwfi.Runtime.Builtins (BuiltinEnv (..), runBuiltin)
import Hwfi.Runtime.Context (RunInfo (..), buildEnvRecord, contextValue)
import Hwfi.Runtime.Error
  ( RuntimeError (..),
    StepRef (..),
    atStep,
    evalError,
    internalError,
  )
import Hwfi.Runtime.Eval (EvalEnv (..), evalExpr)
import Hwfi.Runtime.Gateways (ModelStore)
import Hwfi.Runtime.Trace
  ( EventBody (..),
    RunStatus (..),
    TraceEvent,
    Tracer,
    emit,
    newTracer,
    snapshotEvents,
    snapshotJson,
  )
import Hwfi.Runtime.Value (RValue (..), RefKind (..), redactedJson)
import Hwfi.Runtime.Workspace (Workspace, workspaceRoot)
import Hwfi.TypedProject (Fingerprint (..), TypedDecl (..), TypedProject, lookupTyped)

-- | Everything the executor threads through a run.
data Runtime = Runtime
  { rtProject :: TypedProject,
    rtWorkspace :: Workspace,
    rtModels :: ModelStore,
    rtTracer :: Tracer,
    rtRunInfo :: RunInfo
  }

-- | The outcome of a run plus the events it produced (for @hwfi show@\/tests).
data RunResult = RunResult
  { rrOutcome :: Either RuntimeError RValue,
    rrEvents :: [TraceEvent]
  }

-- | Run the entrypoint workflow with the given root inputs and environment
-- (spec §5.2, §5.7). Emits the @run-start@\/@run-end@ bracket and returns the
-- workflow's output record (or the first error) together with the trace.
runEntrypoint ::
  TypedProject ->
  Workspace ->
  ModelStore ->
  -- | Whitelisted environment variables (already validated present, §5.7).
  Map Text Text ->
  -- | Run id (ULID\/timestamp; formalised in M5).
  Text ->
  -- | Entrypoint qname.
  QName ->
  -- | Root inputs, coerced to their declared types.
  Map Ident RValue ->
  IO RunResult
runEntrypoint tp ws models envVars runId entry rootInputs = do
  tracer <- newTracer
  startedAt <- nowIso
  let rootInputsJson = redactedJson (VRecord rootInputs)
      runInfo =
        RunInfo
          { riRunId = runId,
            riStartedAt = startedAt,
            riEntrypoint = renderQName entry,
            riRootInputs = rootInputsJson,
            riEnvFields = buildEnvRecord envVars
          }
      rt = Runtime tp ws models tracer runInfo
  _ <- emit tracer (RunStart runId (renderQName entry) rootInputsJson (projectHash tp entry))
  outcome <- runWorkflow rt entry rootInputs
  _ <- emit tracer (RunEnd runId (either (const Aborted) (const Completed) outcome))
  events <- snapshotEvents tracer
  pure (RunResult outcome events)

-- | Run a workflow or tool by qname with the supplied inputs record.
runWorkflow :: Runtime -> QName -> Map Ident RValue -> IO (Either RuntimeError RValue)
runWorkflow rt q inputs =
  case lookupTyped q (rtProject rt) of
    Nothing -> pure (Left (internalError ("no such declaration: " <> renderQName q)))
    Just td -> case declBody (tdDeclaration td) of
      Nothing -> pure (Left (internalError (renderQName q <> " is not executable")))
      Just (stmts, sections) ->
        execStatements rt q sections (Map.singleton "inputs" (VRecord inputs)) Nothing stmts

-- Statement execution --------------------------------------------------------

execStatements ::
  Runtime ->
  QName ->
  [Section] ->
  Map Ident RValue ->
  Maybe RValue ->
  [Statement] ->
  IO (Either RuntimeError RValue)
execStatements rt q sections bindings lastResult = \case
  [] -> pure (Right (maybe (VRecord Map.empty) id lastResult))
  (SReturn args _ : _) -> do
    ctx <- buildCtx rt q "return"
    let env = mkEvalEnv rt sections (Map.insert "ctx" ctx bindings)
    case evalArgs env args of
      Left e -> failStep rt (StepRef q "return") e
      Right fields -> pure (Right (VRecord (Map.fromList fields)))
  (SStep s : rest) -> do
    r <- execStep rt q sections bindings s
    case r of
      Left e -> pure (Left e)
      Right (bindings', result) ->
        execStatements rt q sections bindings' (Just result) rest

-- | Execute a single step: evaluate arguments, emit @step-start@, dispatch,
-- emit @step-end@, and bind the result. Any failure emits an @error@ event
-- tagged with this step and short-circuits.
execStep ::
  Runtime ->
  QName ->
  [Section] ->
  Map Ident RValue ->
  StepStmt ->
  IO (Either RuntimeError (Map Ident RValue, RValue))
execStep rt q sections bindings s = do
  let sid = stepId s
      stepRef = StepRef q sid
      target = stepTarget s
  ctx <- buildCtx rt q sid
  let env = mkEvalEnv rt sections (Map.insert "ctx" ctx bindings)
  case evalArgs env (stepArgs s) of
    Left e -> Left <$> failWith rt stepRef e
    Right argPairs -> do
      let argMap = Map.fromList argPairs
          cacheable = classifyCacheable target (stepArgs s)
      _ <- emit (rtTracer rt) (StepStart q sid (redactedJson (VRecord argMap)) cacheable)
      start <- getCurrentTime
      dr <- dispatch rt stepRef bindings target argMap
      case dr of
        Left e -> Left <$> failWith rt stepRef e
        Right result -> do
          end <- getCurrentTime
          _ <- emit (rtTracer rt) (StepEnd q sid (redactedJson result) (durationMs start end))
          pure (Right (bindResult (stepBinder s) result bindings, result))

-- Call dispatch --------------------------------------------------------------

-- | Resolve a step target and invoke it. A bare target is a first-class ref
-- value bound in scope (§3.2); a multi-segment target is a builtin,
-- sub-workflow, or user tool.
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

-- | Assemble the @builtin/introspect@ dump (spec §6): a JSON view of
-- everything the runtime knows about the current run, secrets redacted.
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

-- Error handling -------------------------------------------------------------

-- | Tag an error with the current step, emit its @error@ event, and return it.
failWith :: Runtime -> StepRef -> RuntimeError -> IO RuntimeError
failWith rt stepRef e = do
  let e' = atStep stepRef e
  _ <- emit (rtTracer rt) (ErrorEvent (srQName stepRef) (srStepId stepRef) (reMessage e') (reKind e'))
  pure e'

-- | Variant used at the workflow level (return blocks), yielding a
-- fully-formed @Left@.
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
  (s : _) -> s
  [] -> ""

durationMs :: UTCTime -> UTCTime -> Int
durationMs start end = round (realToFrac (diffUTCTime end start) * (1000 :: Double))

-- | The current time in the trace's ISO-8601 millisecond form (§8.3.1).
nowIso :: IO Text
nowIso = T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S%3QZ" <$> getCurrentTime

-- | A project content hash for @run-start@ (spec §8.3.2). M5 replaces this
-- with a hash of the whole project directory; for now the entrypoint's Merkle
-- fingerprint (which transitively covers everything it calls, §8.1) stands in.
projectHash :: TypedProject -> QName -> Text
projectHash tp entry = maybe "" (unFingerprint . tdFingerprint) (lookupTyped entry tp)
  where
    unFingerprint (Fingerprint t) = t
