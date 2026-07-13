-- | On-disk run artifacts and the workspace lock (spec §8, §12).
--
-- Every run lives under @\<workspace>/.hwfi/runs/\<run-id>/@:
--
-- @
-- run.json          -- run metadata: project hash, entrypoint, inputs, status
-- steps/
--   \<step-key>.json -- one file per completed cacheable step (§8.1)
-- trace.jsonl       -- append-only event log (§8.3)
-- @
--
-- This module owns those paths, the @run.json@ schema, the content-addressed
-- step cache, reading @trace.jsonl@ back into events on resume, and the
-- exclusive @\<workspace>/.hwfi/lock@ that serialises runs sharing a workspace
-- (§12). It performs no policy: the executor decides /when/ to read or write.
--
-- @run.json.inputs@ stores the /actual/ root-input values (not the redacted
-- trace form) because resume must re-evaluate the workflow with the original
-- inputs; the file lives inside the user's workspace under @.hwfi/@.
module Hwfi.Runtime.RunStore
  ( RunStore,
    rsRunDir,
    rsTracePath,
    rsMetaPath,
    runsRoot,
    RunPhase (..),
    phaseText,
    phaseFromText,
    isResumable,
    RunMeta (..),
    RunSummary (..),
    createRunStore,
    openRunStore,
    writeRunMeta,
    readRunMeta,
    updateRunPhase,
    cacheStepResult,
    lookupCachedResult,
    deleteCachedResult,
    clearRunStepCache,
    registerAgentSubCache,
    purgeAgentSubCaches,
    deleteCachedResults,
    cacheWhileDecision,
    lookupWhileDecision,
    readTraceEvents,
    listRuns,
    readRunTrace,
    openTraceAppend,
    withWorkspaceLock,
    writeMachineSnapshot,
    readMachineSnapshot,
    hasMachineSnapshot,
  )
where

import Control.Exception (IOException)
import Control.Monad (when)
import Data.Aeson (Value (..), eitherDecodeFileStrict', object, (.:), (.:?), (.=))
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseMaybe, withObject)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as BSL
import Data.Functor ((<&>))
import Data.List (isSuffixOf, nub, sortOn)
import Data.Maybe (catMaybes, fromMaybe)
import Data.Ord (Down (..))
import Data.Vector qualified as V
import Data.Text (Text)
import Data.Text qualified as T
import GHC.IO.Handle.Lock (LockMode (ExclusiveLock), hTryLock)
import Hwfi.Runtime.Machine (Machine)
import Hwfi.Runtime.MachineSnapshot (decodeMachine, encodeMachine)
import Hwfi.Runtime.RunUsage (RunUsage (..), emptyRunUsage, runUsageFromJson, runUsageToJson)
import Hwfi.Runtime.StepKey (sha256Hex)
import Hwfi.Runtime.Trace (TraceEvent, eventFromJson)
import System.Directory
  ( createDirectoryIfMissing,
    doesDirectoryExist,
    doesFileExist,
    listDirectory,
    removeFile,
    renameFile,
  )
import System.FilePath ((</>))
import System.IO
  ( BufferMode (LineBuffering),
    Handle,
    IOMode (AppendMode, ReadWriteMode, WriteMode),
    hClose,
    hSetBuffering,
    openFile,
    withFile,
  )
import UnliftIO.Exception (finally, try)

-- | The resolved paths of one run's artifacts.
data RunStore = RunStore
  { rsRunDir :: FilePath,
    rsStepsDir :: FilePath,
    rsTracePath :: FilePath,
    rsMetaPath :: FilePath
  }
  deriving stock (Eq, Show)

-- | The lifecycle status recorded in @run.json@ (spec §8.2). A run is
-- resumable unless it has cleanly completed.
data RunPhase
  = -- | In progress (also the state left behind by a crash: the process died
    -- before it could write a terminal phase).
    PhaseRunning
  | -- | Finished successfully; not resumable.
    PhaseCompleted
  | -- | Finished with a workflow error; resumable (fix and re-run the failed
    -- step, reusing cached upstream results).
    PhaseAborted
  | -- | Explicitly marked as crashed; resumable.
    PhaseCrashed
  deriving stock (Eq, Show)

phaseText :: RunPhase -> Text
phaseText = \case
  PhaseRunning -> "running"
  PhaseCompleted -> "completed"
  PhaseAborted -> "aborted"
  PhaseCrashed -> "crashed"

phaseFromText :: Text -> RunPhase
phaseFromText = \case
  "completed" -> PhaseCompleted
  "aborted" -> PhaseAborted
  "crashed" -> PhaseCrashed
  _ -> PhaseRunning

-- | Whether a run in this phase may be resumed (spec §8.2).
isResumable :: RunPhase -> Bool
isResumable = \case
  PhaseCompleted -> False
  _ -> True

-- | The @run.json@ contents.
data RunMeta = RunMeta
  { rmRunId :: Text,
    rmEntrypoint :: Text,
    -- | The project directory this run was launched from, so @hwfi resume@ can
    -- re-parse and re-check the project (a code edit invalidates dependent step
    -- keys, A13) without the user re-supplying the path.
    rmProjectDir :: Text,
    rmStartedAt :: Text,
    rmProjectHash :: Text,
    -- | Actual (non-redacted) root inputs, as a JSON record, for resume.
    rmInputs :: Value,
    rmPhase :: RunPhase,
    -- | Accumulated LLM spend for the logical run (§8.4.4).
    rmUsage :: RunUsage
  }
  deriving stock (Eq, Show)

-- | A run directory summary for @builtin/list-runs@ (§6.5.1).
data RunSummary = RunSummary
  { rsId :: Text,
    rsStartedAt :: Text,
    rsEntrypoint :: Text,
    rsStatus :: Text
  }
  deriving stock (Eq, Show)

-- Paths ----------------------------------------------------------------------

runsRoot :: FilePath -> FilePath
runsRoot wsRoot = wsRoot </> ".hwfi" </> "runs"

storeFor :: FilePath -> Text -> RunStore
storeFor wsRoot runId =
  RunStore
    { rsRunDir = dir,
      rsStepsDir = dir </> "steps",
      rsTracePath = dir </> "trace.jsonl",
      rsMetaPath = dir </> "run.json"
    }
  where
    dir = runsRoot wsRoot </> T.unpack runId

-- | Create the run directory tree for a fresh run under the given workspace
-- root (already canonicalised by 'Hwfi.Runtime.Workspace').
createRunStore :: FilePath -> Text -> IO RunStore
createRunStore wsRoot runId = do
  let store = storeFor wsRoot runId
  createDirectoryIfMissing True (rsStepsDir store)
  pure store

-- | Locate an existing run directory for resume. Fails if it is absent.
openRunStore :: FilePath -> Text -> IO (Either Text RunStore)
openRunStore wsRoot runId = do
  let store = storeFor wsRoot runId
  exists <- doesDirectoryExist (rsRunDir store)
  pure $
    if exists
      then Right store
      else Left ("no run '" <> runId <> "' under " <> T.pack (runsRoot wsRoot))

-- run.json -------------------------------------------------------------------

metaToJson :: RunMeta -> Value
metaToJson m =
  object
    [ "run_id" .= rmRunId m,
      "entrypoint" .= rmEntrypoint m,
      "project_dir" .= rmProjectDir m,
      "started_at" .= rmStartedAt m,
      "project_hash" .= rmProjectHash m,
      "inputs" .= rmInputs m,
      "status" .= phaseText (rmPhase m),
      "usage" .= runUsageToJson (rmUsage m)
    ]

metaFromJson :: Value -> Maybe RunMeta
metaFromJson = parseMaybe (withObject "RunMeta" parseMeta)
  where
    parseMeta o = do
      runId <- o .: "run_id"
      entry <- o .: "entrypoint"
      projectDir <- o .: "project_dir"
      startedAt <- o .: "started_at"
      projectHash <- o .: "project_hash"
      inputs <- o .: "inputs"
      phase <- phaseFromText <$> o .: "status"
      mUsage <- o .:? "usage"
      let usage = maybe emptyRunUsage (fromMaybe emptyRunUsage . runUsageFromJson) mUsage
      pure
        RunMeta
          { rmRunId = runId,
            rmEntrypoint = entry,
            rmProjectDir = projectDir,
            rmStartedAt = startedAt,
            rmProjectHash = projectHash,
            rmInputs = inputs,
            rmPhase = phase,
            rmUsage = usage
          }

-- | Write (or overwrite) @run.json@ atomically.
writeRunMeta :: RunStore -> RunMeta -> IO ()
writeRunMeta store meta = atomicWrite (rsMetaPath store) (Aeson.encode (metaToJson meta))

-- | Read @run.json@; 'Left' on missing or malformed metadata.
readRunMeta :: RunStore -> IO (Either Text RunMeta)
readRunMeta store = do
  result <- eitherDecodeFileStrict' (rsMetaPath store)
  pure $ case result of
    Left e -> Left ("could not read run.json: " <> T.pack e)
    Right v -> case metaFromJson v of
      Just m -> Right m
      Nothing -> Left "run.json is missing required fields"

-- | Update just the lifecycle phase in @run.json@, leaving the rest intact.
updateRunPhase :: RunStore -> RunPhase -> IO ()
updateRunPhase store phase = do
  existing <- readRunMeta store
  case existing of
    Right meta -> writeRunMeta store meta {rmPhase = phase}
    Left _ -> pure ()

-- Step result cache ----------------------------------------------------------

stepPath :: RunStore -> Text -> FilePath
stepPath store key = rsStepsDir store </> T.unpack key <> ".json"

-- | Persist a completed cacheable step's result (§8.1). The value is the
-- actual (non-redacted) result JSON; the file name is the content-addressed
-- step-key.
cacheStepResult :: RunStore -> Text -> Value -> IO ()
cacheStepResult store key value = atomicWrite (stepPath store key) (Aeson.encode value)

-- | Look up a cached step result by key; 'Nothing' if there is no persisted
-- result (a never-run or crashed-before-completion step, §8.2).
lookupCachedResult :: RunStore -> Text -> IO (Maybe Value)
lookupCachedResult store key = do
  let path = stepPath store key
  exists <- doesFileExist path
  if not exists
    then pure Nothing
    else do
      result <- eitherDecodeFileStrict' path
      pure (either (const Nothing) Just result)

-- | Remove a cached step result, if present. Used when a checkpoint makes
-- earlier intra-step sub-keys obsolete on resume (§8.2.1 optional 8.g).
deleteCachedResult :: RunStore -> Text -> IO ()
deleteCachedResult store key = do
  let path = stepPath store key
  exists <- doesFileExist path
  when exists (removeFile path)

-- | Remove every persisted step result (and pinned @while@ decisions) for a
-- run. Trace and @run.json@ are left intact so @hwfi resume@ re-executes
-- cacheable steps (§13.1.4 subset).
clearRunStepCache :: RunStore -> IO Int
clearRunStepCache store = do
  let dir = rsStepsDir store
  exists <- doesDirectoryExist dir
  if not exists
    then pure 0
    else do
      files <- filter (".json" `isSuffixOf`) <$> listDirectory dir
      mapM_ (removeFile . (dir </>)) files
      pure (length files)

-- | Record an intra-step agent sub-key under its enclosing agent step-key
-- (§8.2.1, §13.1.4). Used by @hwfi cache invalidate@ to purge nested caches.
registerAgentSubCache :: RunStore -> Text -> Text -> IO ()
registerAgentSubCache store agentKey subKey = do
  reg <- readAgentRegistry store
  let updated =
        KM.insertWith
          mergeKeys
          (K.fromText agentKey)
          (subKey : fromMaybe [] (KM.lookup (K.fromText agentKey) reg))
          reg
  writeAgentRegistry store updated
  where
    mergeKeys old new = nub (new <> old)

-- | Delete every registered intra-step cache entry for an agent step-key,
-- including its optional checkpoint (§8.2.1).
purgeAgentSubCaches :: RunStore -> Text -> IO Int
purgeAgentSubCaches store agentKey = do
  reg <- readAgentRegistry store
  let keys = fromMaybe [] (KM.lookup (K.fromText agentKey) reg)
      allKeys = nub (agentCheckpointKey agentKey : keys)
  n <- deleteCachedResults store allKeys
  writeAgentRegistry store (KM.delete (K.fromText agentKey) reg)
  pure n

-- | Delete a list of cached step results; returns how many files were removed.
deleteCachedResults :: RunStore -> [Text] -> IO Int
deleteCachedResults store keys = do
  deleted <- mapM (deleteIfPresent store) (nub keys)
  pure (length (filter id deleted))
  where
    deleteIfPresent s key = do
      let path = stepPath s key
      exists <- doesFileExist path
      when exists (removeFile path)
      pure exists

agentCheckpointKey :: Text -> Text
agentCheckpointKey stepKey = sha256Hex ("agent-checkpoint:" <> stepKey)

agentRegistryPath :: RunStore -> FilePath
agentRegistryPath store = rsStepsDir store </> ".agent-subkeys.json"

readAgentRegistry :: RunStore -> IO (KM.KeyMap [Text])
readAgentRegistry store = do
  let path = agentRegistryPath store
  exists <- doesFileExist path
  if not exists
    then pure KM.empty
    else do
      result <- eitherDecodeFileStrict' path
      pure (either (const KM.empty) registryFromJson result)

writeAgentRegistry :: RunStore -> KM.KeyMap [Text] -> IO ()
writeAgentRegistry store reg =
  if KM.null reg
    then do
      let path = agentRegistryPath store
      exists <- doesFileExist path
      when exists (removeFile path)
    else atomicWrite (agentRegistryPath store) (Aeson.encode (registryToJson reg))

registryToJson :: KM.KeyMap [Text] -> Value
registryToJson reg =
  Object (KM.map (Array . V.fromList . map String) reg)

registryFromJson :: Value -> KM.KeyMap [Text]
registryFromJson = \case
  Object o ->
    KM.mapMaybe parseList o
  _ -> KM.empty
  where
    parseList = \case
      Array a -> Just [t | String t <- V.toList a]
      _ -> Nothing

-- | Persist a pinned @while@ predicate decision (§4.3.5). Stored under the
-- same @steps/@ tree as step results, keyed by 'computeWhileDecisionKey'.
cacheWhileDecision :: RunStore -> Text -> Bool -> Text -> IO ()
cacheWhileDecision store key continue reason =
  cacheStepResult store key (object ["continue" .= continue, "reason" .= reason])

-- | Look up a pinned @while@ predicate decision; 'Nothing' if absent.
lookupWhileDecision :: RunStore -> Text -> IO (Maybe (Bool, Text))
lookupWhileDecision store key = do
  mJson <- lookupCachedResult store key
  pure (mJson >>= parseDecision)
  where
    parseDecision = parseMaybe (withObject "WhileDecision" parseBody)
    parseBody o = (,) <$> o .: "continue" <*> o .: "reason"

-- trace.jsonl ----------------------------------------------------------------

-- | Parse the persisted @trace.jsonl@ into events in file order (spec §8.3.5).
-- Blank lines and any unparseable trailing line (e.g. a torn write from a
-- crash) are skipped.
readTraceEvents :: RunStore -> IO [TraceEvent]
readTraceEvents store = do
  exists <- doesFileExist (rsTracePath store)
  if not exists
    then pure []
    else do
      -- Read strictly: a lazy read would hold the handle open and clash with
      -- the append handle opened for the resumed attempt (GHC single-writer).
      raw <- BS.readFile (rsTracePath store)
      let lns = filter (not . BS.null) (BS8.lines raw)
      pure [ev | ln <- lns, Just v <- [Aeson.decodeStrict ln], Just ev <- [eventFromJson v]]

-- | List persisted runs under @\<workspace>/.hwfi/runs/@, most recent first
-- (§6.5.1). @limit@ is clamped to @[1, 100]@. Entries without a readable
-- @run.json@ are skipped.
listRuns :: FilePath -> Int -> IO [RunSummary]
listRuns wsRoot limit = do
  let root = runsRoot wsRoot
      cap = max 1 (min 100 limit)
  exists <- doesDirectoryExist root
  if not exists
    then pure []
    else do
      dirs <- listDirectory root
      summaries <-
        mapM
          ( \name -> do
              let dir = root </> name
              isDir <- doesDirectoryExist dir
              if not isDir
                then pure Nothing
                else do
                  let store = storeFor wsRoot (T.pack name)
                  mMeta <- readRunMeta store
                  pure (metaSummary <$> eitherToMaybe mMeta)
          )
          dirs
      pure $
        take cap $
          sortByStartedAtDesc $
            catMaybes summaries
  where
    metaSummary m =
      RunSummary
        { rsId = rmRunId m,
          rsStartedAt = rmStartedAt m,
          rsEntrypoint = rmEntrypoint m,
          rsStatus = phaseText (rmPhase m)
        }
    sortByStartedAtDesc = sortOn (Down . rsStartedAt)
    eitherToMaybe = \case
      Right m -> Just m
      Left _ -> Nothing

-- | Read a prior run's @trace.jsonl@ (§6.5.1). @requestedRunId@ may be
-- @\"current\"@, resolved against @currentRunId@. Returns 'Left' with a
-- human-readable message when the run directory is missing, @run_id@ is
-- invalid, or @trace.jsonl@ cannot be read.
readRunTrace :: FilePath -> Text -> Text -> IO (Either Text [TraceEvent])
readRunTrace wsRoot currentRunId requestedRunId = do
  let resolved =
        if requestedRunId == "current"
          then currentRunId
          else requestedRunId
  case validateRunId resolved of
    Left err -> pure (Left err)
    Right runId -> do
      store <- openRunStore wsRoot runId
      case store of
        Left err -> pure (Left err)
        Right s -> do
          exists <- doesFileExist (rsTracePath s)
          if not exists
            then pure (Left ("no trace.jsonl for run '" <> runId <> "'"))
            else readTraceEvents s <&> Right

-- | Reject @run_id@ values that could escape @.hwfi/runs/@ (§6.5.1).
validateRunId :: Text -> Either Text Text
validateRunId rid
  | T.null rid = Left "run_id must not be empty"
  | T.any (`elem` ['/', '\\']) rid = Left "run_id must not contain path separators"
  | ".." `T.isInfixOf` rid = Left "run_id must not contain '..'"
  | otherwise = Right rid

-- | Open @trace.jsonl@ for line-buffered appending (fresh run or resume).
openTraceAppend :: RunStore -> IO Handle
openTraceAppend store = do
  h <- openFile (rsTracePath store) AppendMode
  hSetBuffering h LineBuffering
  pure h

-- Machine snapshot (v2 runtime) ----------------------------------------------

machineSnapshotPath :: RunStore -> FilePath
machineSnapshotPath store = rsRunDir store </> "machine.json"

-- | Whether a v2 machine snapshot exists for this run.
hasMachineSnapshot :: RunStore -> IO Bool
hasMachineSnapshot store = doesFileExist (machineSnapshotPath store)

-- | Persist the authoritative machine snapshot for resume (v2 runtime).
writeMachineSnapshot :: RunStore -> Machine -> IO ()
writeMachineSnapshot store machine =
  atomicWrite (machineSnapshotPath store) (Aeson.encode (encodeMachine machine))

-- | Load the persisted machine snapshot; 'Nothing' when absent or malformed.
readMachineSnapshot :: RunStore -> IO (Maybe Machine)
readMachineSnapshot store = do
  exists <- doesFileExist (machineSnapshotPath store)
  if not exists
    then pure Nothing
    else do
      result <- eitherDecodeFileStrict' (machineSnapshotPath store)
      pure $
        case result of
          Left _ -> Nothing
          Right v -> either (const Nothing) Just (decodeMachine v)

-- Workspace lock -------------------------------------------------------------

-- | Run @action@ while holding the exclusive @\<workspace>/.hwfi/lock@ (spec
-- §12). A second concurrent run fails fast with 'Left'. The lock is an
-- advisory OS file lock, released when the action finishes (or throws).
withWorkspaceLock :: FilePath -> IO a -> IO (Either Text a)
withWorkspaceLock wsRoot action = do
  createDirectoryIfMissing True (wsRoot </> ".hwfi")
  let lockPath = wsRoot </> ".hwfi" </> "lock"
      busy = Left ("workspace is locked by another run: " <> T.pack lockPath)
  -- Opening the lock file can itself fail if another run in /this/ process
  -- already holds it (GHC's per-handle single-writer lock); a separate process
  -- opens successfully and is then excluded by the advisory 'hTryLock' below.
  eh <- try (openFile lockPath ReadWriteMode) :: IO (Either IOException Handle)
  case eh of
    Left _ -> pure busy
    Right h ->
      flip finally (hClose h) $ do
        locked <- try (hTryLock h ExclusiveLock) :: IO (Either IOException Bool)
        case locked of
          Right True -> Right <$> action
          _ -> pure busy

-- Helpers --------------------------------------------------------------------

-- | Write bytes atomically: to a sibling @.tmp@ file, then rename over the
-- target (atomic on POSIX), so a crash never leaves a half-written artifact.
atomicWrite :: FilePath -> BSL.ByteString -> IO ()
atomicWrite path bytes = do
  let tmp = path <> ".tmp"
  withFile tmp WriteMode (`BSL.hPut` bytes)
  renameFile tmp path
