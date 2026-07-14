-- | Command-line interface. See spec §9.
--
-- v1 surface:
--
-- @
-- hwfi check   \<project-dir>
-- hwfi run      \<project-dir> --workspace \<dir> ...
-- hwfi resume   \<workspace-dir> \<run-id> [--approve]
-- hwfi step     \<workspace-dir> \<run-id> [--approve]
-- hwfi show    \<workspace-dir> \<run-id>
-- @
--
-- @hwfi check@ parses and type-checks the project (spec §9, §7.3, A1/A2).
-- @run@, @resume@, @step@, and @show@ are fully implemented.
module Hwfi.Cli
  ( Command (..),
    CheckOpts (..),
    RunOpts (..),
    ResumeOpts (..),
    StepOpts (..),
    ShowOpts (..),
    InputArg (..),
    commandParserInfo,
    parseInputArg,
    defaultMain,
    dispatch,
    runCheck,
  )
where

import Control.Exception (IOException, try)
import Control.Monad (unless)
import Data.Aeson (Value (..), eitherDecodeFileStrict', encode)
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as BSL
import Data.Either (fromRight)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Data.Time (defaultTimeLocale, formatTime, getCurrentTime)
import Hwfi.Ast.Name (Ident, QName, qnameFromText, renderQName)
import Hwfi.Check (checkProject, checkProjectWithMeta, renderCheckErrors, renderCheckWarnings)
import Hwfi.Check.Error (CheckWarning)
import Hwfi.Parse.Project (loadProject)
import Hwfi.Project.Manifest (ProjectManifest (..), validateEnvPresence)
import Hwfi.Runtime.Error (renderRuntimeError)
import Hwfi.Runtime.MachineRun
  ( RunResult (..),
    performContinueToEnd,
    performRun,
    performStep,
  )
import Hwfi.Runtime.Gateways (buildGateways, buildModelStore)
import Hwfi.Runtime.KeyStore (loadKeyStore)
import Hwfi.Runtime.ModelCatalog
  ( ModelCatalogMap,
    loadCatalog,
    renderCatalogError,
    validateProviderKeys,
  )
import Hwfi.Runtime.RunStore
  ( RunMeta (..),
    openRunStore,
    phaseText,
    readRunMeta,
    readTraceEvents,
  )
import Hwfi.Runtime.RunUsage (renderUsageSummary)
import Hwfi.Runtime.Trace (renderEvent)
import Hwfi.Runtime.Value (RValue, coerceFromJson, coerceFromString, redactedJson)
import Hwfi.Runtime.Workspace (Workspace, newWorkspace, workspaceRoot)
import Hwfi.Source (Diagnostic (..), renderDiagnostic)
import Hwfi.Type (Type)
import Hwfi.TypedProject
  ( ResolvedSignature (..),
    TypedDecl (..),
    TypedProject (..),
    lookupTyped,
  )
import Options.Applicative
import System.Exit (ExitCode (ExitFailure), exitWith)
import System.FilePath ((</>))
import System.IO (stderr)
import System.Random (randomRIO)

-- | A parsed CLI invocation.
data Command
  = Check CheckOpts
  | Run RunOpts
  | Resume ResumeOpts
  | Step StepOpts
  | Show ShowOpts
  deriving stock (Eq, Show)

-- | @hwfi check \<project-dir>@.
newtype CheckOpts = CheckOpts
  { projectDir :: FilePath
  }
  deriving stock (Eq, Show)

-- | @hwfi run \<project-dir> --workspace \<dir> ...@.
data RunOpts = RunOpts
  { projectDir :: FilePath,
    workspace :: FilePath,
    envFile :: Maybe FilePath,
    inputs :: [InputArg],
    inputJson :: Maybe FilePath,
    entry :: Maybe Text
  }
  deriving stock (Eq, Show)

-- | @hwfi resume \<workspace-dir> \<run-id>@ (v2 runtime).
data ResumeOpts = ResumeOpts
  { resumeWorkspace :: FilePath,
    resumeRunId :: Text,
    resumeApprove :: Bool
  }
  deriving stock (Eq, Show)

-- | @hwfi step \<workspace-dir> \<run-id>@ — one step-batch (v2 runtime).
newtype StepOpts = StepOpts
  { stepResume :: ResumeOpts
  }
  deriving stock (Eq, Show)

-- | @hwfi show \<workspace-dir> \<run-id>@.
data ShowOpts = ShowOpts
  { workspaceDir :: FilePath,
    runId :: Text
  }
  deriving stock (Eq, Show)

-- | A single @--input@ argument. @k=v@ binds a string; @k=@file.json@ reads
-- a JSON value from a file (spec §9).
data InputArg
  = InputString Text Text
  | InputFile Text FilePath
  deriving stock (Eq, Show)

-- | Parse an @--input@ value of the form @k=v@ or @k=@file.json@.
parseInputArg :: String -> Either String InputArg
parseInputArg raw =
  case break (== '=') raw of
    (_, "") -> Left "expected key=value or key=@file.json"
    (key, '=' : rest)
      | null key -> Left "empty input key"
      | otherwise -> case rest of
          '@' : path
            | null path -> Left "empty file path after '@'"
            | otherwise -> Right (InputFile (T.pack key) path)
          val -> Right (InputString (T.pack key) (T.pack val))
    _ -> Left "expected key=value or key=@file.json"

-- | Top-level parser with subcommands and @--help@ metadata.
commandParserInfo :: ParserInfo Command
commandParserInfo =
  info
    (commandParser <**> helper)
    ( fullDesc
        <> progDesc "Type-check and run markdown-defined workflows"
        <> header "hwfi - a markdown workflow execution engine"
    )

commandParser :: Parser Command
commandParser =
  hsubparser
    ( command "check" (info (Check <$> checkOpts) (progDesc "Parse and type-check a project"))
        <> command "run" (info (Run <$> runOpts) (progDesc "Run a workflow project"))
        <> command "resume" (info (Resume <$> resumeOpts) (progDesc "Resume a v2 run from its machine snapshot"))
        <> command "step" (info (Step <$> stepOpts) (progDesc "Advance a v2 run until the next halt point"))
        <> command "show" (info (Show <$> showOpts) (progDesc "Pretty-print a run's trace"))
    )

checkOpts :: Parser CheckOpts
checkOpts =
  CheckOpts
    <$> strArgument (metavar "PROJECT-DIR" <> help "Path to the workflow project directory")

runOpts :: Parser RunOpts
runOpts =
  RunOpts
    <$> strArgument (metavar "PROJECT-DIR" <> help "Path to the workflow project directory")
    <*> strOption (long "workspace" <> metavar "DIR" <> help "Workspace directory for file I/O")
    <*> optional (strOption (long "env-file" <> metavar "PATH" <> help "Extra .env file for provider API keys"))
    <*> many
      ( option
          (eitherReader parseInputArg)
          (long "input" <> metavar "K=V|K=@FILE" <> help "Bind an input value (repeatable)")
      )
    <*> optional (strOption (long "input-json" <> metavar "FILE" <> help "Supply the whole inputs record as JSON"))
    <*> optional (fmap T.pack (strOption (long "entry" <> metavar "QNAME" <> help "Override project.json entrypoint")))

resumeOpts :: Parser ResumeOpts
resumeOpts =
  ResumeOpts
    <$> strArgument (metavar "WORKSPACE-DIR" <> help "Workspace directory of the run")
    <*> fmap T.pack (strArgument (metavar "RUN-ID" <> help "Run id to resume"))
    <*> switch (long "approve" <> help "Approve the active exec confirm gate before stepping")

stepOpts :: Parser StepOpts
stepOpts = StepOpts <$> resumeOpts

showOpts :: Parser ShowOpts
showOpts =
  ShowOpts
    <$> strArgument (metavar "WORKSPACE-DIR" <> help "Workspace directory of the run")
    <*> fmap T.pack (strArgument (metavar "RUN-ID" <> help "Run id to display"))

-- | Parse @argv@ and dispatch. Entry point for the executable.
defaultMain :: IO ()
defaultMain =
  customExecParser (prefs showHelpOnEmpty) commandParserInfo >>= dispatch

-- | Dispatch a parsed 'Command'.
dispatch :: Command -> IO ()
dispatch = \case
  Check opts -> runCheck opts
  Run opts -> runRun opts
  Resume opts -> runResume opts
  Step opts -> runStep opts
  Show opts -> runShow opts

-- | Run @hwfi check@ (spec §9): parse the project, require a parseable
-- @model-catalog.json@ (§7.3), and type-check. Prints nothing and exits 0 on
-- success (A1); prints §9.1 diagnostics to stderr and exits non-zero on any
-- error (A2).
runCheck :: CheckOpts -> IO ()
runCheck opts = do
  let dir = opts.projectDir
  eproj <- loadProject dir
  case eproj of
    Left ds -> reportAndFail dir ds []
    Right proj -> do
      ecat <- loadCatalog dir
      let catMsgs = either (\e -> [renderCatalogError e]) (const []) ecat
      let (checkErrs, checkWarns, mtp) = checkProjectWithMeta proj
      case mtp of
        Nothing -> do
          unless (null checkWarns) $ printCheckWarnings dir checkWarns
          reportAndFail dir (renderCheckErrors checkErrs) catMsgs
        Just _tp
          | null catMsgs && null checkWarns -> pure ()
          | null catMsgs ->
              printCheckWarnings dir checkWarns
          | otherwise -> reportAndFail dir [] catMsgs

-- | Print check warnings to stderr (spec §6.1.6 phase 2).
printCheckWarnings :: FilePath -> [CheckWarning] -> IO ()
printCheckWarnings projectDir warns = do
  rendered <- mapM (renderOne projectDir) (renderCheckWarnings warns)
  TIO.hPutStr stderr (T.intercalate "\n\n" rendered <> "\n")

-- | Render diagnostics against their source files and any plain messages to
-- stderr, then exit with a failure code.
reportAndFail :: FilePath -> [Diagnostic] -> [Text] -> IO ()
reportAndFail projectDir diags msgs = do
  rendered <- mapM (renderOne projectDir) diags
  let blocks = rendered <> msgs
  TIO.hPutStr stderr (T.intercalate "\n\n" blocks <> "\n")
  exitWith (ExitFailure 1)

-- | Render one diagnostic, quoting the offending source line when the file is
-- readable (spec §9.1).
renderOne :: FilePath -> Diagnostic -> IO Text
renderOne projectDir d = do
  src <- readFileOrEmpty (projectDir </> diagPath d)
  pure (renderDiagnostic src d)

readFileOrEmpty :: FilePath -> IO Text
readFileOrEmpty path = do
  result <- try (TIO.readFile path) :: IO (Either IOException Text)
  pure (fromRight "" result)

-- | Run @hwfi run@ (spec §7, §9): parse, type-check, validate provider keys
-- (A12) and the @env@ whitelist (A14), build gateways and the model store
-- (§7.2\/§7.3), then execute the entrypoint over the workspace. Prints the
-- workflow's output record as JSON on success and exits 0; prints a runtime
-- error and exits non-zero otherwise.
runRun :: RunOpts -> IO ()
runRun opts = do
  let dir = opts.projectDir
  eproj <- loadProject dir
  case eproj of
    Left ds -> reportAndFail dir ds []
    Right proj -> do
      ecat <- loadCatalog dir
      case (checkProject proj, ecat) of
        (Left errs, _) -> reportAndFail dir (renderCheckErrors errs) (catMsgs ecat)
        (Right _, Left ce) -> failMsgs [renderCatalogError ce]
        (Right tp, Right catalog) -> runChecked opts dir tp catalog
  where
    catMsgs = either (\e -> [renderCatalogError e]) (const [])

-- | Everything after parse\/check\/catalog-load has succeeded.
runChecked :: RunOpts -> FilePath -> TypedProject -> ModelCatalogMap -> IO ()
runChecked opts dir tp catalog = do
  keyStore <- loadKeyStore opts.envFile dir
  let keyErrs = validateProviderKeys catalog keyStore
  case keyErrs of
    (_ : _) -> failMsgs (map renderCatalogError keyErrs)
    [] -> do
      envResult <- validateEnvPresence tp.tpManifest
      case envResult of
        Left missing -> failMsgs (map missingEnvMsg missing)
        Right envVars -> case buildModelStore (buildGateways keyStore) catalog of
          Left ce -> failMsgs [renderCatalogError ce]
          Right models -> do
            let entry = maybe (qnameFromText tp.tpManifest.entrypoint) qnameFromText opts.entry
            case entrypointInputs entry tp of
              Nothing -> failMsgs ["error: entrypoint '" <> renderQName entry <> "' is not a declared workflow"]
              Just declaredInputs -> do
                collected <- collectInputs opts
                case collected >>= resolveInputs declaredInputs of
                  Left msg -> failMsgs [msg]
                  Right rootInputs -> do
                    workspace <- newWorkspace opts.workspace
                    runId <- genRunId
                    TIO.hPutStrLn stderr ("run-id: " <> runId)
                    outcome <- performRun tp workspace models envVars dir runId entry rootInputs
                    finishRun outcome

-- | Look up the declared inputs of the entrypoint (in signature order).
entrypointInputs :: QName -> TypedProject -> Maybe [(Ident, Type)]
entrypointInputs entry tp = rsigInputs . tdSignature <$> lookupTyped entry tp

-- | Print the outcome of a run/resume and exit. Orchestration failures (lock
-- busy, non-resumable, etc.) and workflow errors both exit non-zero.
finishRun :: Either Text RunResult -> IO ()
finishRun = \case
  Left orchErr -> failMsgs ["error: " <> orchErr]
  Right result
    | rrHalted result ->
        TIO.putStrLn ("run halted (status: " <> haltStatus result <> ")")
    | otherwise ->
        case rrOutcome result of
          Left err -> failMsgs [renderRuntimeError err]
          Right outputs -> TIO.putStrLn (jsonText (redactedJson outputs))
  where
    haltStatus r = case rrOutcome r of
      Left _ -> "paused"
      Right _ -> "completed"

-- | Run @hwfi resume@ (v2 runtime): reload machine snapshot and drive.
runResume :: ResumeOpts -> IO ()
runResume opts =
  runResumeMode opts False

-- | Run @hwfi step@ — one step-batch until halt.
runStep :: StepOpts -> IO ()
runStep opts =
  runResumeMode opts.stepResume True

runResumeMode :: ResumeOpts -> Bool -> IO ()
runResumeMode opts stepBatch = do
  workspace <- newWorkspace opts.resumeWorkspace
  eStore <- openRunStore (workspaceRoot workspace) opts.resumeRunId
  case eStore of
    Left e -> failMsgs ["error: " <> e]
    Right store -> do
      eMeta <- readRunMeta store
      case eMeta of
        Left e -> failMsgs ["error: " <> e]
        Right meta -> resumeChecked workspace meta opts.resumeApprove stepBatch

resumeChecked :: Workspace -> RunMeta -> Bool -> Bool -> IO ()
resumeChecked workspace meta approve stepBatch = do
  let dir = T.unpack meta.rmProjectDir
  eproj <- loadProject dir
  case eproj of
    Left ds -> reportAndFail dir ds []
    Right proj -> do
      ecat <- loadCatalog dir
      case (checkProject proj, ecat) of
        (Left errs, _) -> reportAndFail dir (renderCheckErrors errs) (catMsgsOf ecat)
        (Right _, Left ce) -> failMsgs [renderCatalogError ce]
        (Right tp, Right catalog) -> do
          keyStore <- loadKeyStore Nothing dir
          case validateProviderKeys catalog keyStore of
            errs@(_ : _) -> failMsgs (map renderCatalogError errs)
            [] -> do
              envResult <- validateEnvPresence tp.tpManifest
              case envResult of
                Left missing -> failMsgs (map missingEnvMsg missing)
                Right envVars -> case buildModelStore (buildGateways keyStore) catalog of
                  Left ce -> failMsgs [renderCatalogError ce]
                  Right models -> do
                    outcome <-
                      if stepBatch
                        then performStep tp workspace models envVars meta.rmRunId approve
                        else performContinueToEnd tp workspace models envVars meta.rmRunId approve
                    finishRun outcome
  where
    catMsgsOf = either (\e -> [renderCatalogError e]) (const [])

-- | Run @hwfi show@ (spec §9): pretty-print a persisted run's metadata and its
-- @trace.jsonl@ events, one per line.
runShow :: ShowOpts -> IO ()
runShow opts = do
  workspace <- newWorkspace opts.workspaceDir
  eStore <- openRunStore (workspaceRoot workspace) opts.runId
  case eStore of
    Left e -> failMsgs ["error: " <> e]
    Right store -> do
      eMeta <- readRunMeta store
      events <- readTraceEvents store
      let metaLines = case eMeta of
            Right m ->
              [ "run:        " <> m.rmRunId,
                "entrypoint: " <> m.rmEntrypoint,
                "started_at: " <> m.rmStartedAt,
                "status:     " <> phaseText m.rmPhase,
                ""
              ]
            Left _ -> []
          summary =
            case eMeta of
              Right m -> [renderUsageSummary m.rmUsage, ""]
              Left _ -> []
      TIO.putStr (T.unlines (metaLines <> map renderEvent events <> summary))

-- Input assembly (§9) --------------------------------------------------------

-- | The three sources of input values, kept separate so precedence can be
-- applied per declared field (spec §9): JSON from @--input-json@, JSON from
-- @--input k=@file.json@, and raw strings from @--input k=v@. @--input@ entries
-- override @--input-json@.
data InputSources = InputSources
  { isBaseJson :: Map Ident Value,
    isFileJson :: Map Ident Value,
    isStrings :: Map Ident Text
  }

collectInputs :: RunOpts -> IO (Either Text InputSources)
collectInputs opts = do
  eBase <- case opts.inputJson of
    Nothing -> pure (Right Map.empty)
    Just path -> fmap asObjectMap <$> readJsonFile path
  eFiles <- mapM readFileArg [(k, p) | InputFile k p <- opts.inputs]
  pure $ do
    base <- eBase
    fileEntries <- sequence eFiles
    pure
      InputSources
        { isBaseJson = base,
          isFileJson = Map.fromList fileEntries,
          isStrings = Map.fromList [(k, v) | InputString k v <- opts.inputs]
        }
  where
    readFileArg (k, p) = fmap (k,) <$> readJsonFile p

-- | Resolve each declared input to a typed 'RValue', applying source
-- precedence and coercing to the declared type.
resolveInputs :: [(Ident, Type)] -> InputSources -> Either Text (Map Ident RValue)
resolveInputs declared srcs =
  Map.fromList <$> traverse resolveOne declared
  where
    resolveOne (name, ty)
      | Just raw <- Map.lookup name (isStrings srcs) =
          (,) name <$> tag name (coerceFromString ty raw)
      | Just v <- Map.lookup name (isFileJson srcs) =
          (,) name <$> tag name (coerceFromJson ty v)
      | Just v <- Map.lookup name (isBaseJson srcs) =
          (,) name <$> tag name (coerceFromJson ty v)
      | otherwise = Left ("error: missing required input '" <> name <> "'")
    tag name = either (\m -> Left ("error: input '" <> name <> "': " <> m)) Right

-- Small IO\/JSON helpers ------------------------------------------------------

readJsonFile :: FilePath -> IO (Either Text Value)
readJsonFile path = do
  result <- eitherDecodeFileStrict' path
  pure (either (\e -> Left ("error: could not read JSON from " <> T.pack path <> ": " <> T.pack e)) Right result)

asObjectMap :: Value -> Map Ident Value
asObjectMap = \case
  Object o -> Map.fromList [(K.toText k, v) | (k, v) <- KM.toList o]
  _ -> Map.empty

jsonText :: Value -> Text
jsonText = TE.decodeUtf8 . BSL.toStrict . encode

missingEnvMsg :: Text -> Text
missingEnvMsg var =
  "error: whitelisted env variable '" <> var <> "' is not set in the environment (§5.7)"

-- | Generate a run id. A ULID is planned for M5; for now a sortable timestamp
-- plus a small random suffix suffices to name a run directory uniquely enough.
genRunId :: IO Text
genRunId = do
  now <- getCurrentTime
  suffix <- randomRIO (0, 0xffffff :: Int)
  let stamp = formatTime defaultTimeLocale "%Y%m%dT%H%M%S" now
  pure ("run-" <> T.pack stamp <> "-" <> T.pack (padHex suffix))
  where
    padHex n = let h = showHex' n in replicate (6 - length h) '0' <> h
    showHex' n
      | n < 16 = [hexDigit n]
      | otherwise = showHex' (n `div` 16) <> [hexDigit (n `mod` 16)]
    hexDigit d = "0123456789abcdef" !! d

-- | Print plain error messages to stderr and exit non-zero.
failMsgs :: [Text] -> IO ()
failMsgs msgs = do
  TIO.hPutStr stderr (T.intercalate "\n\n" msgs <> "\n")
  exitWith (ExitFailure 1)
