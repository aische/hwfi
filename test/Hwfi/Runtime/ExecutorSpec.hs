module Hwfi.Runtime.ExecutorSpec (spec) where

import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Hwfi.Ast.Name (Ident, QName, qnameFromText)
import Hwfi.Check (checkProject)
import Hwfi.Parse.Project (loadProject)
import Hwfi.Runtime.Executor (RunResult (..), performResume, performRun)
import Hwfi.Runtime.RunStore (RunPhase (..), RunStore, openRunStore, rsTracePath, updateRunPhase)
import Hwfi.Runtime.Trace (EventBody (..), FileOp (..), RunStatus (..), TraceEvent (..))
import Hwfi.Runtime.Value (RValue (..))
import Hwfi.Runtime.Workspace (newWorkspace, workspaceRoot)
import Hwfi.TypedProject (TypedProject)
import System.Directory (createDirectoryIfMissing)
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

mainQ :: QName
mainQ = qnameFromText "workflows/main"

resumeInputs :: Map.Map Ident RValue
resumeInputs = Map.fromList [("src", VFileRef "input.txt")]

expectRun :: Either Text RunResult -> IO RunResult
expectRun = either (\e -> error ("run failed: " <> T.unpack e)) pure

-- file-only fixture (A3/A6/A9) ----------------------------------------------

runFileOnly :: FilePath -> IO (RunResult, FilePath)
runFileOnly ws = do
  tp <- loadChecked "test/fixtures/run/file-only"
  TIO.writeFile (ws </> "input.txt") "the source content"
  workspace <- newWorkspace ws
  result <-
    expectRun
      =<< performRun
        tp
        workspace
        Map.empty
        Map.empty
        "test/fixtures/run/file-only"
        "run-test"
        mainQ
        (Map.fromList [("src", VFileRef "input.txt"), ("dst", VFileRef "out.txt")])
  pure (result, ws)

-- resume fixture, materialised so A13 can edit the sub-workflow --------------

writeResumeProject :: FilePath -> Text -> IO ()
writeResumeProject dir subWriteExpr = do
  createDirectoryIfMissing True (dir </> "workflows")
  TIO.writeFile (dir </> "project.json") projectJson
  TIO.writeFile (dir </> "model-catalog.json") "[]\n"
  TIO.writeFile (dir </> "workflows" </> "main.md") mainMd
  TIO.writeFile (dir </> "workflows" </> "sub.md") (subMd subWriteExpr)
  where
    projectJson =
      "{\n  \"name\": \"resume\",\n  \"version\": \"0.1.0\",\n  \"entrypoint\": \"workflows/main\",\n  \"env\": []\n}\n"
    mainMd =
      T.unlines
        [ "---",
          "name: workflows/main",
          "inputs:",
          "  src: FileRef",
          "outputs:",
          "  content: String",
          "imports:",
          "  - builtin/read-file",
          "  - builtin/write-file",
          "  - workflows/sub",
          "---",
          "",
          "## flow",
          "",
          "```step",
          "c <- builtin/read-file(path = ${inputs.src})",
          "s <- workflows/sub(note = ${c.text}) @sub",
          "_ <- builtin/write-file(path = \"cached.txt\", text = ${s.marker}) @cached",
          "_ <- builtin/write-file(path = \"volatile.txt\", text = \"trace: ${ctx.trace}\") @volatile",
          "return { content = ${c.text} }",
          "```"
        ]
    subMd expr =
      T.unlines
        [ "---",
          "name: workflows/sub",
          "inputs:",
          "  note: String",
          "outputs:",
          "  marker: String",
          "imports:",
          "  - builtin/write-file",
          "---",
          "",
          "## flow",
          "",
          "```step",
          "_ <- builtin/write-file(path = \"sub-marker.txt\", text = " <> expr <> ") @w",
          "return { marker = \"SUB:${inputs.note}\" }",
          "```"
        ]

-- | Run the resume fixture to completion, mark it resumable (aborted), then
-- resume — optionally after editing the sub-workflow's write expression.
runThenResume ::
  FilePath -> FilePath -> Text -> Text -> IO (RunResult, RunResult, FilePath)
runThenResume proj ws subExpr1 subExpr2 = do
  writeResumeProject proj subExpr1
  TIO.writeFile (ws </> "input.txt") "SEED"
  workspace <- newWorkspace ws
  tp1 <- loadChecked proj
  r1 <- expectRun =<< performRun tp1 workspace Map.empty Map.empty proj "run-1" mainQ resumeInputs
  Right store <- openRunStore (workspaceRoot workspace) "run-1"
  updateRunPhase store PhaseAborted
  writeResumeProject proj subExpr2
  tp2 <- loadChecked proj
  r2 <- expectRun =<< performResume tp2 workspace Map.empty Map.empty "run-1"
  pure (r1, r2, ws)

spec :: Spec
spec = do
  describe "Executor end-to-end (§4, A3, A6, A9)" $ do
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

    it "creates the persisted run directory (A3)" $
      withSystemTempDirectory "hwfi-run" $ \ws -> do
        _ <- runFileOnly ws
        readFileT (ws </> ".hwfi" </> "runs" </> "run-test" </> "trace.jsonl")
          >>= \t -> (T.null t) `shouldBe` False

  describe "Resume and step caching (§8.2, A4, A7, A15)" $ do
    it "skips cacheable steps and re-executes volatile ones on resume" $
      withResumeDirs $ \proj ws -> do
        (_, r2, _) <- runThenResume proj ws base base
        let evs = rrEvents r2
        -- cacheable steps ran once (fresh) and were skipped on resume:
        stepStarts "c" evs `shouldBe` 1
        stepStarts "sub" evs `shouldBe` 1
        stepStarts "cached" evs `shouldBe` 1
        -- the volatile step (reads ctx.trace) re-executed on resume:
        stepStarts "volatile" evs `shouldBe` 2

    it "does not re-write a cached step's file on resume (A4)" $
      withResumeDirs $ \proj ws -> do
        (_, r2, _) <- runThenResume proj ws base base
        fileWrites "cached.txt" (rrEvents r2) `shouldBe` 1
        fileWrites "volatile.txt" (rrEvents r2) `shouldBe` 2

    it "appends exactly one resumed marker and continues seq gap-free" $
      withResumeDirs $ \proj ws -> do
        (_, r2, _) <- runThenResume proj ws base base
        length [() | TraceEvent _ _ (Resumed {}) <- rrEvents r2] `shouldBe` 1
        seqsAreGapless (rrEvents r2) `shouldBe` True

    it "resumes a crashed run (running phase, no run-end) without double-writing (A4)" $
      withResumeDirs $ \proj ws -> do
        writeResumeProject proj base
        TIO.writeFile (ws </> "input.txt") "SEED"
        workspace <- newWorkspace ws
        tp <- loadChecked proj
        _ <- expectRun =<< performRun tp workspace Map.empty Map.empty proj "run-1" mainQ resumeInputs
        Right store <- openRunStore (workspaceRoot workspace) "run-1"
        -- Simulate a mid-run kill: drop the terminal run-end line and leave the
        -- run in the 'running' phase (§8.2, §8.3.3).
        dropLastTraceLine store
        updateRunPhase store PhaseRunning
        r2 <- expectRun =<< performResume tp workspace Map.empty Map.empty "run-1"
        lastCompleted (map teBody (rrEvents r2)) `shouldBe` True
        fileWrites "cached.txt" (rrEvents r2) `shouldBe` 1

    it "shows cached upstream events in a resumed step's ctx.trace (A15)" $
      withResumeDirs $ \proj ws -> do
        (_, _, _) <- runThenResume proj ws base base
        -- The volatile step re-ran on resume and wrote its ctx.trace, which must
        -- still contain the cached steps' original detailed events.
        traceDump <- readFileT (ws </> "volatile.txt")
        traceDump `shouldSatisfy` T.isInfixOf "step-end"
        traceDump `shouldSatisfy` T.isInfixOf "cached.txt"

  describe "Code-edit invalidation (§8.1, A13)" $
    it "recomputes a step whose callee fingerprint changed" $
      withResumeDirs $ \proj ws -> do
        (_, r2, _) <- runThenResume proj ws base edited
        -- Editing sub-workflow's body changes fingerprint(sub), hence the
        -- caller's step-key: the 'sub' step recomputes on resume.
        stepStarts "sub" (rrEvents r2) `shouldBe` 2
        -- Its result (marker) is unchanged, so the downstream 'cached' step's
        -- key is unchanged and it stays served from cache.
        stepStarts "cached" (rrEvents r2) `shouldBe` 1
        readFileT (ws </> "sub-marker.txt") `shouldReturn` "EDIT SEED"
  where
    base = "${inputs.note}"
    edited = "\"EDIT ${inputs.note}\""

withResumeDirs :: (FilePath -> FilePath -> IO a) -> IO a
withResumeDirs k =
  withSystemTempDirectory "hwfi-proj" $ \proj ->
    withSystemTempDirectory "hwfi-ws" $ \ws -> k proj ws

-- | Drop the final non-empty line of the persisted trace, mimicking a process
-- killed before it could append (and flush) the @run-end@ event.
dropLastTraceLine :: RunStore -> IO ()
dropLastTraceLine store = do
  contents <- TIO.readFile (rsTracePath store)
  let kept = reverse (drop 1 (reverse (filter (not . T.null) (T.lines contents))))
  TIO.writeFile (rsTracePath store) (T.unlines kept)

readFileT :: FilePath -> IO Text
readFileT = TIO.readFile

stepStarts :: Ident -> [TraceEvent] -> Int
stepStarts sid evs = length [() | TraceEvent _ _ (StepStart _ s _ _) <- evs, s == sid]

fileWrites :: Text -> [TraceEvent] -> Int
fileWrites path evs =
  length [() | TraceEvent _ _ (FileIo _ _ OpWrite p _) <- evs, p == path]

firstTag :: [EventBody] -> Maybe Text
firstTag (RunStart {} : _) = Just "run-start"
firstTag _ = Nothing

lastCompleted :: [EventBody] -> Bool
lastCompleted bodies = case reverse bodies of
  (RunEnd _ Completed : _) -> True
  _ -> False

seqsAreGapless :: [TraceEvent] -> Bool
seqsAreGapless evs = map teSeq evs == [0 .. length evs - 1]
