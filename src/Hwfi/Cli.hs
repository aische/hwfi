-- | Command-line interface. See spec §9.
--
-- v1 surface:
--
-- @
-- hwfi check   \<project-dir>
-- hwfi run     \<project-dir> --workspace \<dir>
--              [--env-file \<path>]
--              [--input \<k>=\<v>]... [--input \<k>=@\<file.json>]...
--              [--input-json \<file.json>]
--              [--entry \<qname>]
-- hwfi resume  \<workspace-dir> \<run-id>
-- hwfi show    \<workspace-dir> \<run-id>
-- @
--
-- @hwfi check@ is implemented end-to-end (parse + model-catalog presence +
-- type-check, spec §9, §7.3, A1/A2). The remaining commands are stubs that
-- report "not implemented" and exit non-zero until their milestones land.
module Hwfi.Cli
  ( Command (..),
    CheckOpts (..),
    RunOpts (..),
    ResumeOpts (..),
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
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Hwfi.Check (checkProject, renderCheckErrors)
import Hwfi.Parse.Project (loadProject)
import Hwfi.Runtime.ModelCatalog (loadCatalog, renderCatalogError)
import Hwfi.Source (Diagnostic (..), renderDiagnostic)
import Options.Applicative
import System.Exit (ExitCode (ExitFailure), exitWith)
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)

-- | A parsed CLI invocation.
data Command
  = Check CheckOpts
  | Run RunOpts
  | Resume ResumeOpts
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

-- | @hwfi resume \<workspace-dir> \<run-id>@.
data ResumeOpts = ResumeOpts
  { workspaceDir :: FilePath,
    runId :: Text
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
        <> command "resume" (info (Resume <$> resumeOpts) (progDesc "Resume an interrupted run"))
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

showOpts :: Parser ShowOpts
showOpts =
  ShowOpts
    <$> strArgument (metavar "WORKSPACE-DIR" <> help "Workspace directory of the run")
    <*> fmap T.pack (strArgument (metavar "RUN-ID" <> help "Run id to display"))

-- | Parse @argv@ and dispatch. Entry point for the executable.
defaultMain :: IO ()
defaultMain = execParser commandParserInfo >>= dispatch

-- | Dispatch a parsed 'Command'.
dispatch :: Command -> IO ()
dispatch = \case
  Check opts -> runCheck opts
  Run _ -> notImplemented "run"
  Resume _ -> notImplemented "resume"
  Show _ -> notImplemented "show"

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
      case checkProject proj of
        Left errs -> reportAndFail dir (renderCheckErrors errs) catMsgs
        Right _
          | null catMsgs -> pure ()
          | otherwise -> reportAndFail dir [] catMsgs

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
  pure (either (const "") id result)

notImplemented :: String -> IO ()
notImplemented name = do
  hPutStrLn stderr ("hwfi " <> name <> ": not implemented yet")
  exitWith (ExitFailure 2)
