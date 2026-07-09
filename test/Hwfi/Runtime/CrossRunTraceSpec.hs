{-# LANGUAGE OverloadedRecordDot #-}

module Hwfi.Runtime.CrossRunTraceSpec (spec) where

import Control.Exception (bracket)
import Data.Aeson (Value (..), object, (.=))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Hwfi.Ast.Name (QName, qnameFromText)
import Hwfi.Check (checkProject)
import Hwfi.Parse.Project (loadProject)
import Hwfi.Runtime.Executor (RunResult (..), performRun)
import Hwfi.Runtime.RunStore
  ( RunMeta (..),
    RunPhase (..),
    RunStore,
    RunSummary (..),
    createRunStore,
    listRuns,
    openTraceAppend,
    readRunTrace,
    writeRunMeta,
  )
import Hwfi.Runtime.RunUsage (emptyRunUsage)
import Hwfi.Runtime.Trace
  ( EventBody (..),
    FileOp (..),
    TraceEvent (..),
    Tracer,
    emit,
    newPersistentTracer,
  )
import Hwfi.Runtime.Value (RValue (..))
import Hwfi.Runtime.Workspace (Workspace, newWorkspace)
import Hwfi.TypedProject (TypedProject)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO (Handle, hClose)
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = describe "cross-run trace reading (§6.5)" $ do
  describe "RunStore helpers" $ do
    it "listRuns returns runs most recent first" $
      withRunsFixture $ \wsRoot -> do
        runs <- listRuns wsRoot 10
        map rsId runs
          `shouldBe` ["run-new", "run-mid", "run-old"]

    it "readRunTrace resolves current against the supplied run id" $
      withRunsFixture $ \wsRoot -> do
        store <- createRunStore wsRoot "run-mid"
        bracketTrace store $ \_ tracer ->
          emit tracer (RunStart "run-mid" "workflows/main" (Object mempty) "abc")
        events <- readRunTrace wsRoot "run-mid" "current"
        fmap length events `shouldBe` Right 1

    it "readRunTrace fails for a missing run" $
      withRunsFixture $ \wsRoot -> do
        readRunTrace wsRoot "run-mid" "nope"
          >>= (`shouldSatisfy` \case
                Left err -> "no run" `T.isInfixOf` err
                _ -> False)

  it "A36: list-runs returns prior workspace runs without leaving .hwfi/runs" $
    withTraceProject $ \tp ws projDir -> do
      seedPriorRuns projDir
      result <-
        performRun
          tp
          ws
          Map.empty
          Map.empty
          projDir
          "run-a36"
          mainQ
          Map.empty
      case result of
        Left msg -> expectationFailure ("run failed: " <> T.unpack msg)
        Right (RunResult (Right (VRecord outs)) _) -> do
          Map.lookup "current" outs `shouldBe` Just (VString "run-a36")
          Map.lookup "newest_prior" outs `shouldBe` Just (VString "run-new")
          Map.lookup "oldest_prior" outs `shouldBe` Just (VString "run-old")
        _ -> expectationFailure "expected successful run"

  it "A37: read-run-trace with missing run_id returns ok=false without aborting" $
    withTraceProject $ \tp ws projDir -> do
      result <-
        performRun
          tp
          ws
          Map.empty
          Map.empty
          projDir
          "run-a37"
          missingQ
          Map.empty
      case result of
        Left msg -> expectationFailure ("run failed: " <> T.unpack msg)
        Right (RunResult (Right (VRecord outs)) _) -> do
          Map.lookup "got_ok" outs `shouldBe` Just (VBool False)
          case Map.lookup "err" outs of
            Just (VString err) -> "no run" `T.isInfixOf` err `shouldBe` True
            _ -> expectationFailure "expected error string"
        _ -> expectationFailure "expected successful run"

  it "read-run-trace with current resolves to the executing run" $
    withTraceProject $ \tp ws projDir -> do
      result <-
        performRun
          tp
          ws
          Map.empty
          Map.empty
          projDir
          "run-current"
          currentQ
          Map.empty
      case result of
        Left msg -> expectationFailure ("run failed: " <> T.unpack msg)
        Right (RunResult (Right (VRecord outs)) evs) -> do
          Map.lookup "got_ok" outs `shouldBe` Just (VBool True)
          length [() | TraceEvent _ _ (FileIo _ _ OpRead p _) <- evs, "run-current" `T.isInfixOf` p]
            `shouldSatisfy` (> 0)
          length [() | TraceEvent _ _ (RunStart rid _ _ _) <- evs, rid == "run-current"] `shouldBe` 1
        _ -> expectationFailure "expected successful run"

-- Fixtures -------------------------------------------------------------------

mainQ :: QName
mainQ = qnameFromText "workflows/list-runs"

missingQ :: QName
missingQ = qnameFromText "workflows/missing-trace"

currentQ :: QName
currentQ = qnameFromText "workflows/current-trace"

withRunsFixture :: (FilePath -> IO a) -> IO a
withRunsFixture k =
  withSystemTempDirectory "hwfi-cross-runs" $ \root -> do
    writeRun root "run-old" "2026-07-01T00:00:00.000Z" PhaseCompleted
    writeRun root "run-mid" "2026-07-02T00:00:00.000Z" PhaseAborted
    writeRun root "run-new" "2026-07-03T00:00:00.000Z" PhaseRunning
    k root

writeRun :: FilePath -> Text -> Text -> RunPhase -> IO ()
writeRun root runId startedAt phase = do
  store <- createRunStore root runId
  writeRunMeta
    store
    RunMeta
      { rmRunId = runId,
        rmEntrypoint = "workflows/main",
        rmProjectDir = "/tmp/proj",
        rmStartedAt = startedAt,
        rmProjectHash = "abc",
        rmInputs = object [],
        rmPhase = phase,
        rmUsage = emptyRunUsage
      }

seedPriorRuns :: FilePath -> IO ()
seedPriorRuns root = do
  writeRun root "run-old" "2026-07-01T00:00:00.000Z" PhaseCompleted
  writeRun root "run-mid" "2026-07-02T00:00:00.000Z" PhaseCompleted
  writeRun root "run-new" "2026-07-03T00:00:00.000Z" PhaseCompleted
  oldStore <- createRunStore root "run-old"
  bracketTrace oldStore $ \h tracer -> do
    _ <- emit tracer (RunStart "run-old" "workflows/main" (Object mempty) "abc")
    pure ()

bracketTrace :: RunStore -> (Handle -> Tracer -> IO a) -> IO a
bracketTrace store k =
  bracket (openTraceAppend store) hClose $ \h -> do
    tracer <- newPersistentTracer h [] 0
    k h tracer

withTraceProject :: (TypedProject -> Workspace -> FilePath -> IO a) -> IO a
withTraceProject k =
  withSystemTempDirectory "hwfi-cross-trace" $ \dir -> do
    writeTraceProject dir
    tp <- loadChecked dir
    ws <- newWorkspace dir
    k tp ws dir

writeTraceProject :: FilePath -> IO ()
writeTraceProject dir = do
  createDirectoryIfMissing True (dir </> "workflows")
  TIO.writeFile (dir </> "project.json") projectJson
  TIO.writeFile (dir </> "model-catalog.json") "[]\n"
  TIO.writeFile (dir </> "workflows" </> "list-runs.md") listRunsMd
  TIO.writeFile (dir </> "workflows" </> "missing-trace.md") missingTraceMd
  TIO.writeFile (dir </> "workflows" </> "current-trace.md") currentTraceMd

loadChecked :: FilePath -> IO TypedProject
loadChecked dir = do
  eproj <- loadProject dir
  case eproj of
    Left ds -> error ("fixture parse failed: " <> show ds)
    Right proj -> case checkProject proj of
      Left errs -> error ("fixture check failed: " <> show errs)
      Right tp -> pure tp

projectJson :: Text
projectJson =
  "{\n  \"name\": \"cross-trace\",\n  \"version\": \"0.1.0\",\n  \"entrypoint\": \"workflows/list-runs\",\n  \"env\": []\n}\n"

listRunsMd :: Text
listRunsMd =
  T.unlines
    [ "---",
      "name: workflows/list-runs",
      "inputs: {}",
      "outputs:",
      "  current: String",
      "  newest_prior: String",
      "  oldest_prior: String",
      "imports:",
      "  - builtin/list-runs",
      "---",
      "",
      "```step",
      "r <- builtin/list-runs(limit = 10)",
      "return {",
      "  current = ${r.runs[0].id},",
      "  newest_prior = ${r.runs[1].id},",
      "  oldest_prior = ${r.runs[3].id}",
      "}",
      "```"
    ]

missingTraceMd :: Text
missingTraceMd =
  T.unlines
    [ "---",
      "name: workflows/missing-trace",
      "inputs: {}",
      "outputs:",
      "  got_ok: Bool",
      "  err: String",
      "imports:",
      "  - builtin/read-run-trace",
      "---",
      "",
      "```step",
      "t <- builtin/read-run-trace(run_id = \"no-such-run\")",
      "return { got_ok = ${t.ok}, err = ${t.error} }",
      "```"
    ]

currentTraceMd :: Text
currentTraceMd =
  T.unlines
    [ "---",
      "name: workflows/current-trace",
      "inputs: {}",
      "outputs:",
      "  got_ok: Bool",
      "imports:",
      "  - builtin/read-run-trace",
      "---",
      "",
      "```step",
      "t <- builtin/read-run-trace(run_id = \"current\")",
      "return { got_ok = ${t.ok} }",
      "```"
    ]
