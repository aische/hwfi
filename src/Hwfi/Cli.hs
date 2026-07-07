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
-- In this milestone every command is a stub that reports "not implemented"
-- and exits non-zero. The parser itself is complete so later milestones only
-- fill in the dispatch bodies.
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
  )
where

import Data.Text (Text)
import Data.Text qualified as T
import Options.Applicative
import System.Exit (ExitCode (ExitFailure), exitWith)
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

-- | Dispatch a parsed 'Command'. All bodies are stubs in this milestone.
dispatch :: Command -> IO ()
dispatch = \case
  Check _ -> notImplemented "check"
  Run _ -> notImplemented "run"
  Resume _ -> notImplemented "resume"
  Show _ -> notImplemented "show"

notImplemented :: String -> IO ()
notImplemented name = do
  hPutStrLn stderr ("hwfi " <> name <> ": not implemented yet")
  exitWith (ExitFailure 2)
