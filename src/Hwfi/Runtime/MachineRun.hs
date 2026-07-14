-- | v2 run orchestration: machine snapshots, trace persistence, CLI cutover.
--
-- Replaces cache-as-resume 'performResume' for the default runtime path. See
-- @docs/execution-model.md@ (M4).
module Hwfi.Runtime.MachineRun
  ( RunResult (..),
    performRun,
    performContinue,
    performContinueToEnd,
    performStep,
  )
where

import Control.Exception (SomeException, displayException)
import Control.Monad (join, void, when)
import Data.List (find)
import Data.Maybe (listToMaybe)
import Data.Map.Strict (Map)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (defaultTimeLocale, formatTime, getCurrentTime)
import Hwfi.Ast.Name (Ident, QName, qnameFromText, renderQName)
import Hwfi.Project.Manifest (budgetMaxCostUsd)
import Hwfi.Runtime.Context (RunInfo (..), buildEnvRecord)
import Hwfi.Runtime.Error (ErrorKind (..), RuntimeError (..), internalError)
import Hwfi.Runtime.Gateways (ModelStore)
import Hwfi.Runtime.RunCommon
  ( RunResult (..),
    projectContentHash,
    reconstructInputs,
  )
import Hwfi.Ast.Step (Statement (..), tryId, tryBinder)
import Hwfi.Runtime.Machine
  ( BlockKind (..),
    Current (..),
    Frame (..),
    Machine (..),
    MachineStatus (..),
    PathSegment (..),
    StmtPath (..),
    TryFrame (..),
    TryPhase (..),
    initialMachine,
  )
import Hwfi.Runtime.MachinePar (isParDriving)
import Hwfi.Runtime.MachinePath
  ( StmtContext (..),
    advancePath,
    declStatements,
    enterChildBlock,
    resolveStmtPath,
  )
import Hwfi.Runtime.RunStore
  ( RunMeta (..),
    RunPhase (..),
    RunStore,
    createRunStore,
    hasMachineSnapshot,
    isResumable,
    openRunStore,
    openTraceAppend,
    phaseText,
    readMachineSnapshot,
    readRunMeta,
    readTraceEvents,
    updateRunPhase,
    withWorkspaceLock,
    writeMachineSnapshot,
    writeRunMeta,
  )
import Hwfi.Runtime.RunUsage (emptyRunUsage)
import Hwfi.Runtime.StepDriver
  ( approveConfirm,
    isParWave,
    stepMachine,
    stepParWave,
  )
import Hwfi.Runtime.StepEnv
  ( ConfirmPolicy (..),
    StepEnv (..),
    StepOutcome (..),
    newRunStepEnv,
  )
import Hwfi.Runtime.Trace
  ( EventBody (..),
    RunStatus (..),
    TraceEvent (..),
    Tracer,
    emit,
    newPersistentTracer,
    snapshotEvents,
  )
import Hwfi.Runtime.Usage (newUsageSeam)
import Hwfi.Runtime.Value (RValue (..), redactedJson, valueToJson)
import Hwfi.Runtime.Workspace (Workspace, workspaceRoot)
import Hwfi.TypedProject (TypedProject, lookupTyped, tdDeclaration, tpManifest)
import System.IO (hClose)
import UnliftIO.Exception (bracket, tryAny)

-- | How far to drive the machine before returning.
data DriveMode
  = DriveToEnd
  | DriveOneBatch
  deriving stock (Eq, Show)

-- | Start a fresh v2 run: lock workspace, write metadata, run to completion.
performRun ::
  TypedProject ->
  Workspace ->
  ModelStore ->
  Map Text Text ->
  FilePath ->
  Text ->
  QName ->
  Map Ident RValue ->
  IO (Either Text RunResult)
performRun tp ws models envVars projectDir runId entry rootInputs =
  withWorkspaceLock (workspaceRoot ws) $ do
    store <- createRunStore (workspaceRoot ws) runId
    startedAt <- nowIso
    let ph = projectContentHash tp
        budget = budgetMaxCostUsd (tpManifest tp)
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
      usageSeam <- newUsageSeam store budget emptyRunUsage
      let ri = runInfo runId startedAt entry rootInputs envVars
          m0 = initialMachine "" ph entry rootInputs
      _ <- emit tracer (RunStart runId (renderQName entry) (redactedJson (VRecord rootInputs)) ph)
      env <- newRunStepEnv tp ws models envVars store tracer usageSeam ri ConfirmAuto
      writeMachineSnapshot store m0
      guardedFinish env store tracer =<< tryAny (drive env store m0 DriveToEnd)

-- | Continue a v2 run from its persisted machine snapshot.
performContinue ::
  TypedProject ->
  Workspace ->
  ModelStore ->
  Map Text Text ->
  Text ->
  -- | When 'True', approve the active confirm gate before stepping.
  Bool ->
  DriveMode ->
  IO (Either Text RunResult)
performContinue tp ws models envVars runId approve mode =
  fmap join $
    withWorkspaceLock (workspaceRoot ws) $ do
      eStore <- openRunStore (workspaceRoot ws) runId
      case eStore of
        Left e -> pure (Left e)
        Right store -> continueWith tp ws models envVars runId store approve mode

-- | Drive one step-batch until halt, confirm, par wave boundary, or completion.
performStep ::
  TypedProject ->
  Workspace ->
  ModelStore ->
  Map Text Text ->
  Text ->
  Bool ->
  IO (Either Text RunResult)
performStep tp ws models envVars runId approve =
  performContinue tp ws models envVars runId approve DriveOneBatch

-- | Continue a v2 run until completion or workflow error.
performContinueToEnd ::
  TypedProject ->
  Workspace ->
  ModelStore ->
  Map Text Text ->
  Text ->
  Bool ->
  IO (Either Text RunResult)
performContinueToEnd tp ws models envVars runId approve =
  performContinue tp ws models envVars runId approve DriveToEnd

continueWith ::
  TypedProject ->
  Workspace ->
  ModelStore ->
  Map Text Text ->
  Text ->
  RunStore ->
  Bool ->
  DriveMode ->
  IO (Either Text RunResult)
continueWith tp ws models envVars runId store approve mode = do
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
                    <> "' and is not resumable"
                )
            )
      | projectContentHash tp /= rmProjectHash meta ->
          pure
            ( Left
                ( "project hash changed since run started (snapshot "
                    <> rmProjectHash meta
                    <> ", current "
                    <> projectContentHash tp
                    <> "); start a new run"
                )
            )
      | otherwise -> do
          hasSnap <- hasMachineSnapshot store
          if not hasSnap
            then
              pure
                ( Left
                    ( "run '"
                        <> runId
                        <> "' has no machine snapshot; start a new run with `hwfi run`"
                    )
                )
            else resumeMachine tp ws models envVars runId store meta approve mode

resumeMachine ::
  TypedProject ->
  Workspace ->
  ModelStore ->
  Map Text Text ->
  Text ->
  RunStore ->
  RunMeta ->
  Bool ->
  DriveMode ->
  IO (Either Text RunResult)
resumeMachine tp ws models envVars runId store meta approve mode = do
  let entry = qnameFromText (rmEntrypoint meta)
  case reconstructInputs tp entry (rmInputs meta) of
    Left e -> pure (Left e)
    Right rootInputs -> do
      mSnap <- readMachineSnapshot store
      case mSnap of
        Nothing ->
          pure (Left ("could not read machine snapshot for run '" <> runId <> "'"))
        Just machine0 -> do
          priorEvents <- readTraceEvents store
          let lastSeq = case priorEvents of
                [] -> (-1)
                _ -> maximum (map teSeq priorEvents)
          bracket (openTraceAppend store) hClose $ \h -> do
            tracer <- newPersistentTracer h priorEvents (lastSeq + 1)
            updateRunPhase store PhaseRunning
            usageSeam <- newUsageSeam store (budgetMaxCostUsd (tpManifest tp)) (rmUsage meta)
            let ri = runInfo runId (rmStartedAt meta) entry rootInputs envVars
                confirmPolicy =
                  if mode == DriveOneBatch
                    then ConfirmHold
                    else ConfirmAuto
            env <- newRunStepEnv tp ws models envVars store tracer usageSeam ri confirmPolicy
            let (machineR, rewoundTry) = rewindTryIfErroredTrace tp priorEvents machine0 rootInputs
            _ <- emit tracer (Resumed runId lastSeq)
            when rewoundTry $
              case trailingTryError priorEvents of
                Just (tryQ, trySid) -> void $ emit tracer (TryBranch tryQ trySid "try")
                Nothing -> pure ()
            machine <-
              if approve
                then approveConfirm env machineR
                else pure machineR
            exResult <- tryAny (drive env store machine mode)
            Right <$> guardedFinish env store tracer exResult

drive :: StepEnv -> RunStore -> Machine -> DriveMode -> IO (Either RuntimeError StepOutcome)
drive env store machine mode = loop machine
  where
    loop m
      | isTerminal m = pure (terminalOutcome m)
      | mode == DriveOneBatch, isStepHalt m = pure (Right (StepHalted m))
      | otherwise = do
          outcome <-
            if isParWave m
              then stepParWave env m
              else stepMachine env m
          persistSnapshot store outcome
          case outcome of
            Left err -> pure (Left err)
            Right done -> case done of
              Stepped m' -> loop m'
              finished -> pure (Right finished)

persistSnapshot :: RunStore -> Either RuntimeError StepOutcome -> IO ()
persistSnapshot store outcome =
  case outcome of
    Left _ -> pure ()
    Right (Stepped m) -> writeMachineSnapshot store m
    Right (StepHalted m) -> writeMachineSnapshot store m
    Right (RunCompleted _) -> pure ()

isTerminal :: Machine -> Bool
isTerminal m = case mStatus m of
  MsCompleted -> True
  MsFailed -> True
  _ -> False

terminalOutcome :: Machine -> Either RuntimeError StepOutcome
terminalOutcome m =
  case (mStatus m, mLastResult m) of
    (MsCompleted, Just v) -> Right (RunCompleted v)
    (MsCompleted, Nothing) -> Right (RunCompleted (VRecord mempty))
    (MsFailed, _) -> Left (maybe (internalError "run failed") internalError (mError m))
    _ -> Right (StepHalted m)

isStepHalt :: Machine -> Bool
isStepHalt m =
  case mStatus m of
    MsPaused _ -> True
    MsDraining -> True
    _ ->
      isParDriving m
        && not (isParWave m)
        && case mFrames m of
          FrPar _ : _ -> True
          _ -> False

guardedFinish ::
  StepEnv ->
  RunStore ->
  Tracer ->
  Either SomeException (Either RuntimeError StepOutcome) ->
  IO RunResult
guardedFinish env store tracer = \case
  Right outcome -> finish env store tracer outcome
  Left exc -> finishCrash env store tracer exc

finish ::
  StepEnv ->
  RunStore ->
  Tracer ->
  Either RuntimeError StepOutcome ->
  IO RunResult
finish env store tracer outcome = do
  let runId = riRunId (seRunInfo env)
  case outcome of
    Left err -> do
      _ <- emit tracer (RunEnd runId Aborted)
      updateRunPhase store PhaseAborted
      events <- snapshotEvents tracer
      pure (RunResult (Left err) events False)
    Right (RunCompleted v) -> do
      _ <- emit tracer (RunEnd runId Completed)
      updateRunPhase store PhaseCompleted
      events <- snapshotEvents tracer
      pure (RunResult (Right v) events False)
    Right (StepHalted m) -> do
      writeMachineSnapshot store m
      updateRunPhase store (haltPhase m)
      events <- snapshotEvents tracer
      pure (RunResult (Left (internalError "run halted")) events True)
    Right (Stepped _) -> do
      events <- snapshotEvents tracer
      pure (RunResult (Left (internalError "finish: unexpected Stepped")) events False)

haltPhase :: Machine -> RunPhase
haltPhase m = case mStatus m of
  MsFailed -> PhaseAborted
  _ -> PhaseRunning

finishCrash ::
  StepEnv ->
  RunStore ->
  Tracer ->
  SomeException ->
  IO RunResult
finishCrash env store tracer exc = do
  let msg = T.pack (displayException exc)
      runId = riRunId (seRunInfo env)
  _ <- emit tracer (ErrorEvent (qnameFromText (riEntrypoint (seRunInfo env))) "" msg KInternal)
  _ <- emit tracer (RunEnd runId Crashed)
  updateRunPhase store PhaseCrashed
  events <- snapshotEvents tracer
  pure (RunResult (Left (internalError msg)) events False)

runInfo :: Text -> Text -> QName -> Map Ident RValue -> Map Text Text -> RunInfo
runInfo runId startedAt entry rootInputs envVars =
  RunInfo
    { riRunId = runId,
      riStartedAt = startedAt,
      riEntrypoint = renderQName entry,
      riRootInputs = redactedJson (VRecord rootInputs),
      riEnvFields = buildEnvRecord envVars
    }

nowIso :: IO Text
nowIso = do
  T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S%3QZ" <$> getCurrentTime

-- | When a run was aborted with a trace ending at a catchable error inside a
-- @try@ (but before a @catch@ branch was recorded), rewind the machine so
-- resume re-enters the @try@ arm (§4.4.6 T5).
rewindTryIfErroredTrace ::
  TypedProject ->
  [TraceEvent] ->
  Machine ->
  Map Ident RValue ->
  (Machine, Bool)
rewindTryIfErroredTrace tp evs m bindings =
  case trailingTryError evs of
    Nothing -> (m, False)
    Just (tryQ, trySid) ->
      case findTryStmtPath tp tryQ trySid of
        Nothing -> (m, False)
        Just tryPath ->
          case resolveStmtPath tp tryPath of
            Left _ -> (m, False)
            Right ctx ->
              case scStmt ctx of
                STry s ->
                  let idx = scIndex ctx
                      scope' = tryArmScope (mScope m) (tryId s) "try"
                      bodyEntry = enterChildBlock tryPath idx BkTryTry
                      tf =
                        TryFrame
                          { tfLoopId = tryId s,
                            tfScope = mScope m,
                            tfBinder = tryBinder s,
                            tfPhase = TryInTry,
                            tfResumePath = advancePath tryPath,
                            tfTryPath = tryPath
                          }
                   in
                    ( m
                        { mStatus = MsRunning,
                          mFrames = [FrTry tf],
                          mScope = scope',
                          mPath = bodyEntry,
                          mBindings = bindings,
                          mCurrent = CurReady,
                          mLastResult = Nothing,
                          mError = Nothing
                        },
                      True
                    )
                _ -> (m, False)

trailingTryError :: [TraceEvent] -> Maybe (QName, Ident)
trailingTryError evs =
  case reverse evs of
    (TraceEvent _ _ (ErrorEvent {})) : _
      | not (any isCatchBranch evs) ->
          listToMaybe collectTryBranches
    _ -> Nothing
  where
    isCatchBranch (TraceEvent _ _ (TryBranch _ _ "catch")) = True
    isCatchBranch _ = False
    collectTryBranches =
      reverse
        [ (q, sid)
          | TraceEvent _ _ (TryBranch q sid "try") <- evs
        ]

findTryStmtPath :: TypedProject -> QName -> Ident -> Maybe StmtPath
findTryStmtPath tp q sid = do
  td <- lookupTyped q tp
  let stmts = declStatements (tdDeclaration td)
  (i, STry _s) <-
    find
      ( \(_, st) -> case st of
          STry s' -> tryId s' == sid
          _ -> False
      )
      (zip [0 ..] stmts)
  pure (StmtPath q [PathSegment i Nothing])

tryArmScope :: Text -> Ident -> Text -> Text
tryArmScope scope sid arm = scope <> sid <> "?" <> arm <> "/"
