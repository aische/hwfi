module Hwfi.Runtime.ExecutorSpec (spec) where

import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text.IO qualified as TIO
import Hwfi.Ast.Name (qnameFromText)
import Hwfi.Check (checkProject)
import Hwfi.Parse.Project (loadProject)
import Hwfi.Runtime.Executor (RunResult (..), runEntrypoint)
import Hwfi.Runtime.Trace (EventBody (..), RunStatus (..), TraceEvent (..))
import Hwfi.Runtime.Value (RValue (..))
import Hwfi.Runtime.Workspace (newWorkspace)
import Hwfi.TypedProject (TypedProject)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

loadChecked :: FilePath -> IO TypedProject
loadChecked dir = do
  eproj <- loadProject dir
  case eproj of
    Left ds -> error ("fixture parse failed: " <> show ds)
    Right proj -> case checkProject proj of
      Left errs -> error ("fixture check failed: " <> show errs)
      Right tp -> pure tp

runFileOnly :: FilePath -> IO (RunResult, FilePath)
runFileOnly ws = do
  tp <- loadChecked "test/fixtures/run/file-only"
  TIO.writeFile (ws </> "input.txt") "the source content"
  workspace <- newWorkspace ws
  result <-
    runEntrypoint
      tp
      workspace
      Map.empty
      Map.empty
      "run-test"
      (qnameFromText "workflows/main")
      (Map.fromList [("src", VFileRef "input.txt"), ("dst", VFileRef "out.txt")])
  pure (result, ws)

spec :: Spec
spec = describe "Executor end-to-end (§4, A3, A6, A9)" $ do
  it "runs a two-step file workflow and returns its outputs" $
    withSystemTempDirectory "hwfi-run" $ \ws -> do
      (result, _) <- runFileOnly ws
      rrOutcome result
        `shouldBe` Right (VRecord (Map.fromList [("content", VString "the source content")]))

  it "writes the destination file (A3)" $
    withSystemTempDirectory "hwfi-run" $ \ws -> do
      _ <- runFileOnly ws
      readFileT (ws </> "out.txt") `shouldReturn` "the source content"

  it "resolves @self#banner at runtime (A9)" $
    withSystemTempDirectory "hwfi-run" $ \ws -> do
      _ <- runFileOnly ws
      readFileT (ws </> "banner.txt") `shouldReturn` "HELLO FROM SELF"

  it "invokes a sub-workflow that writes its own marker (A6)" $
    withSystemTempDirectory "hwfi-run" $ \ws -> do
      _ <- runFileOnly ws
      readFileT (ws </> "inner.txt") `shouldReturn` "the source content"

  it "brackets the trace with run-start and a completed run-end" $
    withSystemTempDirectory "hwfi-run" $ \ws -> do
      (result, _) <- runFileOnly ws
      let bodies = map teBody (rrEvents result)
      firstTag bodies `shouldBe` Just "run-start"
      lastCompleted bodies `shouldBe` True
      seqsAreGapless (rrEvents result) `shouldBe` True

readFileT :: FilePath -> IO Text
readFileT = TIO.readFile

firstTag :: [EventBody] -> Maybe Text
firstTag (RunStart {} : _) = Just "run-start"
firstTag _ = Nothing

lastCompleted :: [EventBody] -> Bool
lastCompleted bodies = case reverse bodies of
  (RunEnd _ Completed : _) -> True
  _ -> False

seqsAreGapless :: [TraceEvent] -> Bool
seqsAreGapless evs = map teSeq evs == [0 .. length evs - 1]
