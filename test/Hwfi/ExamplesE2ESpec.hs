{-# LANGUAGE OverloadedRecordDot #-}

module Hwfi.ExamplesE2ESpec (spec) where

import Control.Exception (SomeException, catch, throwIO, try)
import Control.Monad (unless)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Hwfi.Ast.Name (Ident, QName, qnameFromText)
import Hwfi.Check (checkProject)
import Hwfi.Cli (CheckOpts (..), runCheck)
import Hwfi.Parse.Project (loadProject)
import Hwfi.Runtime.Error (RuntimeError (..))
import Hwfi.Runtime.Executor (RunResult (..), performRun)
import Hwfi.Runtime.Gateways (buildGateways, buildModelStore)
import Hwfi.Runtime.KeyStore (loadKeyStore, lookupKey)
import Hwfi.Runtime.ModelCatalog
  ( loadCatalog,
    renderCatalogError,
    validateProviderKeys,
  )
import Hwfi.Runtime.Provider (ProviderName (DeepSeek))
import Hwfi.Runtime.Value (RValue (..))
import Hwfi.Runtime.Workspace (newWorkspace)
import Hwfi.TypedProject (TypedProject)
import System.Directory (copyFile, doesFileExist)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (readProcessWithExitCode)
import Test.Hspec

summariseDir :: FilePath
summariseDir = "examples/summarise"

codingDir :: FilePath
codingDir = "examples/coding"

brokenShFixture :: FilePath
brokenShFixture = codingDir </> "sample-workspace/broken.sh"

spec :: Spec
spec = do
  describe "tutorial examples (static)" $ do
    it "summarise passes hwfi check" $
      expectCheckOk summariseDir

    it "coding passes hwfi check" $
      expectCheckOk codingDir

  describe "tutorial examples (live E2E)" $ do
    it "summarise reads, summarises, and writes on a clean workspace" $
      withDeepSeekKey summariseDir $ \projectDir -> do
        withSystemTempDirectory "hwfi-e2e-summarise" $ \wsDir -> do
          let article = wsDir </> "article.txt"
          TIO.writeFile
            article
            "The quick brown fox jumps over the lazy dog. This sentence is often used for typing practice."
          outputs <-
            runExample
              projectDir
              (qnameFromText "workflows/main")
              ( Map.fromList
                  [ ("path", VFileRef "article.txt"),
                    ("out", VFileRef "summary.txt")
                  ]
              )
              wsDir
          case outputs of
            VRecord m -> do
              Map.lookup "summary" m `shouldSatisfy` \case
                Just (VString s) -> not (T.null (T.strip s))
                _ -> False
            _ -> expectationFailure "expected output record"
          exists <- doesFileExist (wsDir </> "summary.txt")
          exists `shouldBe` True

    it "coding/fix repairs broken.sh on a clean workspace" $
      withDeepSeekKey codingDir $ \projectDir ->
        retryLive 2 $
          withSystemTempDirectory "hwfi-e2e-coding" $ \wsDir -> do
            copyFile brokenShFixture (wsDir </> "broken.sh")
            outputs <-
              runExample
                projectDir
                (qnameFromText "workflows/fix")
                (Map.singleton "target" (VString "broken.sh"))
                wsDir
            case outputs of
              VRecord m -> do
                Map.lookup "answer" m `shouldSatisfy` \case
                  Just (VString s) -> not (T.null (T.strip s))
                  _ -> False
                Map.lookup "rounds" m `shouldSatisfy` \case
                  Just (VInt n) -> n > 0 && n <= 12
                  _ -> False
              _ -> expectationFailure "expected output record"
            (code, _, _) <- readProcessWithExitCode "sh" ["-n", wsDir </> "broken.sh"] ""
            code `shouldBe` ExitSuccess

-- Helpers --------------------------------------------------------------------

expectCheckOk :: FilePath -> IO ()
expectCheckOk dir = do
  result <- try (runCheck (CheckOpts dir)) :: IO (Either ExitCode ())
  result `shouldBe` Right ()

-- | Skip the example when no DeepSeek key is discoverable for the project.
withDeepSeekKey :: FilePath -> (FilePath -> IO ()) -> IO ()
withDeepSeekKey projectDir action = do
  ks <- loadKeyStore Nothing projectDir
  case lookupKey DeepSeek ks of
    Nothing ->
      pendingWith $
        unlines
          [ "set DEEPSEEK_API_KEY to run live example E2E tests.",
            "Sources (highest precedence first):",
            "  1. export DEEPSEEK_API_KEY=... in your shell",
            "  2. copy " <> projectDir <> "/.env.example to " <> projectDir <> "/.env",
            "  3. $XDG_CONFIG_HOME/hwfi/.env"
          ]
    Just _ -> action projectDir

-- | Retry a flaky live-API action once on failure.
retryLive :: Int -> IO a -> IO a
retryLive 1 action = action
retryLive n action =
  action
    `catch` \(e :: SomeException) ->
      if n <= 1
        then throwIO e
        else retryLive (n - 1) action

loadChecked :: FilePath -> IO TypedProject
loadChecked dir = do
  eproj <- loadProject dir
  case eproj of
    Left ds -> error ("example parse failed: " <> show ds)
    Right proj -> case checkProject proj of
      Left errs -> error ("example check failed: " <> show errs)
      Right tp -> pure tp

runExample ::
  FilePath ->
  QName ->
  Map.Map Ident RValue ->
  FilePath ->
  IO RValue
runExample projectDir entry inputs wsDir = do
  tp <- loadChecked projectDir
  ks <- loadKeyStore Nothing projectDir
  ecat <- loadCatalog projectDir
  cat <-
    case ecat of
      Left ce -> expectationFailure (T.unpack (renderCatalogError ce)) >> error "unreachable"
      Right c -> pure c
  let keyErrs = validateProviderKeys cat ks
  unless (null keyErrs) $
    expectationFailure $
      unlines (map (T.unpack . renderCatalogError) keyErrs)
  store <-
    case buildModelStore (buildGateways ks) cat of
      Left ce -> expectationFailure (T.unpack (renderCatalogError ce)) >> error "unreachable"
      Right s -> pure s
  workspace <- newWorkspace wsDir
  outcome <- performRun tp workspace store Map.empty projectDir "e2e-run" entry inputs
  result <-
    case outcome of
      Left orchErr -> expectationFailure ("run orchestration failed: " <> T.unpack orchErr) >> error "unreachable"
      Right r -> pure r
  case result of
    RunResult {rrOutcome = Left err} ->
      expectationFailure ("workflow failed: " <> T.unpack (reMessage err)) >> error "unreachable"
    RunResult {rrOutcome = Right value} -> pure value
