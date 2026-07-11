module Hwfi.Runtime.ExecutorSpec (spec) where

import Control.Exception (ErrorCall (ErrorCall), throwIO)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Hwfi.Ast.Name (Ident, QName, qnameFromText)
import Hwfi.Check (checkProject)
import Hwfi.Compat (ModelConfig (..))
import Hwfi.Parse.Project (loadProject)
import Hwfi.Runtime.Error (ErrorKind (..), RuntimeError (..))
import Hwfi.Runtime.Executor (RunResult (..), performResume, performRun)
import Hwfi.Runtime.Gateways (ModelStore)
import Hwfi.Runtime.RunStore (RunMeta (..), RunPhase (..), RunStore, openRunStore, readRunMeta, rsTracePath, updateRunPhase)
import Hwfi.Runtime.RunUsage (RunUsage (..))
import Hwfi.Runtime.Trace (EventBody (..), FileOp (..), RunStatus (..), TraceEvent (..))
import Hwfi.Runtime.Value (RValue (..))
import Hwfi.Runtime.Workspace (newWorkspace, workspaceRoot)
import Hwfi.TypedProject (TypedProject)
import LLM.Core.Types (ChatResponse (..), ContentBlock (..), LLMError (..), LLMGateway (..))
import LLM.Core.Usage (PricingInfo (..), Usage (..))
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

-- durable-workspace fixture: a mutation + exec step (A25, §8.2) --------------

writeExecProject :: FilePath -> IO ()
writeExecProject dir = do
  createDirectoryIfMissing True (dir </> "workflows")
  TIO.writeFile (dir </> "project.json") projectJson
  TIO.writeFile (dir </> "model-catalog.json") "[]\n"
  TIO.writeFile (dir </> "workflows" </> "main.md") mainMd
  where
    projectJson =
      T.unlines
        [ "{",
          "  \"name\": \"exec-resume\",",
          "  \"version\": \"0.1.0\",",
          "  \"entrypoint\": \"workflows/main\",",
          "  \"env\": [],",
          "  \"exec\": { \"allow\": [\"sh\"], \"env\": [\"PATH\"] }",
          "}"
        ]
    mainMd =
      T.unlines
        [ "---",
          "name: workflows/main",
          "inputs:",
          "  src: FileRef",
          "outputs:",
          "  code: Int",
          "imports:",
          "  - builtin/edit-file",
          "  - builtin/exec",
          "  - builtin/write-file",
          "---",
          "",
          "## flow",
          "",
          "```step",
          "_ <- builtin/edit-file(path = ${inputs.src}, find = \"foo\", replace = \"bar\", expect = 1) @edit",
          "r <- builtin/exec(program = \"sh\", args = [\"-c\", \"echo tick >> counter.txt\"], stdin = \"\", timeout_ms = 0) @exec",
          "_ <- builtin/write-file(path = \"volatile.txt\", text = \"trace: ${ctx.trace}\") @volatile",
          "return { code = ${r.exit_code} }",
          "```"
        ]

writeLlmUsageProject :: FilePath -> Maybe Double -> IO ()
writeLlmUsageProject dir mBudget = do
  createDirectoryIfMissing True (dir </> "workflows")
  TIO.writeFile (dir </> "project.json") (projectJson mBudget)
  TIO.writeFile (dir </> "model-catalog.json") "[]\n"
  TIO.writeFile (dir </> "workflows/main.md") mainMd
  where
    projectJson mBudget' =
      case mBudget' of
        Nothing ->
          "{\n  \"name\": \"llm-usage\",\n  \"version\": \"0.1.0\",\n  \"entrypoint\": \"workflows/main\",\n  \"env\": []\n}\n"
        Just cap ->
          "{\n  \"name\": \"llm-usage\",\n  \"version\": \"0.1.0\",\n  \"entrypoint\": \"workflows/main\",\n  \"env\": [],\n  \"budget\": { \"max_cost_usd\": "
            <> T.pack (show cap)
            <> " }\n}\n"
    mainMd =
      T.unlines
        [ "---",
          "name: workflows/main",
          "inputs: {}",
          "outputs:",
          "  answer: String",
          "imports:",
          "  - builtin/llm-generate",
          "---",
          "",
          "## flow",
          "",
          "```step",
          "g <- builtin/llm-generate(system = \"s\", prompt = \"p\", model = \"fast\") @gen",
          "return { answer = ${g.text} }",
          "```"
        ]

writeLlmResumeProject :: FilePath -> IO ()
writeLlmResumeProject dir = writeLlmUsageProject dir Nothing

llmStore :: LLMGateway -> Double -> ModelStore
llmStore gw temp = Map.singleton "fast" (llmConfig gw temp)

llmConfig :: LLMGateway -> Double -> ModelConfig
llmConfig gw temp =
  ModelConfig
    { mcGateway = gw,
      mcModel = "fake",
      mcPricing = PricingInfo 0 0,
      mcMaxTokens = 256,
      mcTemperature = Just temp,
      mcThinking = Nothing,
      mcRequestTimeout = Just 30000,
      mcThrottleDelay = Just 0,
      mcRetryCount = 3,
      mcJitterBackoff = 1000
    }

countingGateway :: IORef Int -> LLMGateway
countingGateway calls =
  LLMGateway
    { gwName = "fake",
      gwGenerateText = \_ _ -> do
        modifyIORef' calls (+ 1)
        pure (Right (ChatResponse "ok" [TextBlock "ok"] (Just usage) Nothing)),
      gwStreamText = \_ _ _ -> pure (Left EmptyResponse),
      gwGenerateObject = \_ _ _ -> pure (Left EmptyResponse)
    }

throwingGateway :: LLMGateway
throwingGateway =
  LLMGateway
    { gwName = "fake",
      gwGenerateText = \_ _ -> throwIO (ErrorCall "synthetic crash"),
      gwStreamText = \_ _ _ -> throwIO (ErrorCall "synthetic crash"),
      gwGenerateObject = \_ _ _ -> throwIO (ErrorCall "synthetic crash")
    }

usage :: Usage
usage = Usage 1 1 0

pricedUsage :: Usage
pricedUsage = Usage 1000 500 0

countingGatewayWithUsage :: IORef Int -> LLMGateway
countingGatewayWithUsage calls =
  LLMGateway
    { gwName = "fake",
      gwGenerateText = \_ _ -> do
        modifyIORef' calls (+ 1)
        pure (Right (ChatResponse "ok" [TextBlock "ok"] (Just pricedUsage) Nothing)),
      gwStreamText = \_ _ _ -> pure (Left EmptyResponse),
      gwGenerateObject = \_ _ _ -> pure (Left EmptyResponse)
    }

llmPricedStore :: LLMGateway -> ModelStore
llmPricedStore gw =
  Map.singleton
    "fast"
    ModelConfig
      { mcGateway = gw,
        mcModel = "fake",
        mcPricing = PricingInfo 3 6,
        mcMaxTokens = 256,
        mcTemperature = Just 0.1,
        mcThinking = Nothing,
        mcRequestTimeout = Just 30000,
        mcThrottleDelay = Just 0,
        mcRetryCount = 3,
        mcJitterBackoff = 1000
      }

-- | Run the durable-workspace fixture to completion, abort it, then resume.
runExecThenResume :: FilePath -> FilePath -> IO (RunResult, RunResult, FilePath)
runExecThenResume proj ws = do
  writeExecProject proj
  TIO.writeFile (ws </> "input.txt") "foo"
  workspace <- newWorkspace ws
  tp1 <- loadChecked proj
  r1 <- expectRun =<< performRun tp1 workspace Map.empty Map.empty proj "run-1" mainQ resumeInputs
  Right store <- openRunStore (workspaceRoot workspace) "run-1"
  updateRunPhase store PhaseAborted
  tp2 <- loadChecked proj
  r2 <- expectRun =<< performResume tp2 workspace Map.empty Map.empty "run-1"
  pure (r1, r2, ws)

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
          >>= \t -> T.null t `shouldBe` False

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

  describe "Durable-workspace resume (§8.2, A25)" $ do
    it "runs a mutation + exec workflow and returns the exit code" $
      withResumeDirs $ \proj ws -> do
        (r1, _, _) <- runExecThenResume proj ws
        rrOutcome r1
          `shouldBe` Right (VRecord (Map.fromList [("code", VInt 0)]))

    it "applies the edit and the exec side effect exactly once across resume" $
      withResumeDirs $ \proj ws -> do
        (_, _, _) <- runExecThenResume proj ws
        -- The edit ran once (foo -> bar); it is not re-applied on resume, which
        -- would fail (no 'foo' left) if the durable-workspace invariant broke.
        readFileT (ws </> "input.txt") `shouldReturn` "bar"
        -- The exec appended one line; a re-run on resume would append a second.
        readFileT (ws </> "counter.txt") `shouldReturn` "tick\n"

    it "serves cached mutation and exec steps from cache on resume (§8.2)" $
      withResumeDirs $ \proj ws -> do
        (_, r2, _) <- runExecThenResume proj ws
        let evs = rrEvents r2
        stepStarts "edit" evs `shouldBe` 1
        stepStarts "exec" evs `shouldBe` 1
        -- The volatile step reads ctx.trace, so it re-runs on resume.
        stepStarts "volatile" evs `shouldBe` 2

    it "records the exec exactly once in the resumed trace (no re-emit)" $
      withResumeDirs $ \proj ws -> do
        (_, r2, _) <- runExecThenResume proj ws
        length [() | TraceEvent _ _ (Exec {}) <- rrEvents r2] `shouldBe` 1

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

  describe "Crash handling (§8.2, H1.5)" $ do
    it "emits internal error + run-end crashed and sets run.json phase on unexpected exception" $
      withResumeDirs $ \proj ws -> do
        writeLlmResumeProject proj
        workspace <- newWorkspace ws
        tp <- loadChecked proj
        result <-
          expectRun
            =<< performRun tp workspace (llmStore throwingGateway 0.1) Map.empty proj "run-1" mainQ Map.empty
        case rrOutcome result of
          Left err -> reKind err `shouldBe` KInternal
          Right _ -> expectationFailure "expected crash to surface as internal RuntimeError"
        lastRunEnd (map teBody (rrEvents result)) `shouldBe` Just Crashed
        hasInternalError (map teBody (rrEvents result)) `shouldBe` True
        Right store <- openRunStore (workspaceRoot workspace) "run-1"
        Right meta <- readRunMeta store
        rmPhase meta `shouldBe` PhaseCrashed

    it "can resume a crashed run to completion" $
      withResumeDirs $ \proj ws -> do
        writeLlmResumeProject proj
        workspace <- newWorkspace ws
        tp <- loadChecked proj
        calls <- newIORef (0 :: Int)
        _ <-
          expectRun
            =<< performRun tp workspace (llmStore throwingGateway 0.1) Map.empty proj "run-1" mainQ Map.empty
        r2 <-
          expectRun
            =<< performResume tp workspace (llmStore (countingGateway calls) 0.1) Map.empty "run-1"
        readIORef calls `shouldReturn` 1
        lastRunEnd (map teBody (rrEvents r2)) `shouldBe` Just Completed

  describe "Model-catalog invalidation (§8.1, H1.3)" $
    it "recomputes a cached one-shot LLM step when the catalog fingerprint changes" $
      withResumeDirs $ \proj ws -> do
        calls <- newIORef (0 :: Int)
        let gw = countingGateway calls
            store1 = llmStore gw 0.1
            store2 = llmStore gw 0.9
        writeLlmResumeProject proj
        workspace <- newWorkspace ws
        tp <- loadChecked proj
        _ <- expectRun =<< performRun tp workspace store1 Map.empty proj "run-1" mainQ Map.empty
        readIORef calls `shouldReturn` 1
        Right store <- openRunStore (workspaceRoot workspace) "run-1"
        updateRunPhase store PhaseAborted
        r2 <- expectRun =<< performResume tp workspace store2 Map.empty "run-1"
        readIORef calls `shouldReturn` 2
        stepStarts "gen" (rrEvents r2) `shouldBe` 2
  describe "Usage accounting (§8.4, A27-A29)" $ do
    it "increments run.json usage on a live llm-generate call (A27)" $
      withResumeDirs $ \proj ws -> do
        writeLlmUsageProject proj Nothing
        calls <- newIORef (0 :: Int)
        let models = llmPricedStore (countingGatewayWithUsage calls)
        workspace <- newWorkspace ws
        tp <- loadChecked proj
        result <- expectRun =<< performRun tp workspace models Map.empty proj "run-1" mainQ Map.empty
        readIORef calls `shouldReturn` 1
        Right runStore <- openRunStore (workspaceRoot workspace) "run-1"
        Right meta <- readRunMeta runStore
        rmUsage meta `shouldBe` RunUsage 1000 500 0.006
        llmCallCosts (rrEvents result) `shouldBe` [0.006]

    it "does not bill a cache hit on resume (A27)" $
      withResumeDirs $ \proj ws -> do
        calls <- newIORef (0 :: Int)
        let models = llmPricedStore (countingGatewayWithUsage calls)
        writeLlmUsageProject proj Nothing
        workspace <- newWorkspace ws
        tp <- loadChecked proj
        _ <- expectRun =<< performRun tp workspace models Map.empty proj "run-1" mainQ Map.empty
        readIORef calls `shouldReturn` 1
        Right runStore <- openRunStore (workspaceRoot workspace) "run-1"
        Right meta1 <- readRunMeta runStore
        updateRunPhase runStore PhaseAborted
        r2 <- expectRun =<< performResume tp workspace models Map.empty "run-1"
        readIORef calls `shouldReturn` 1
        Right meta2 <- readRunMeta runStore
        rmUsage meta2 `shouldBe` rmUsage meta1
        llmCallCosts (rrEvents r2) `shouldBe` [0.006]

    it "aborts before a provider call when the budget is already met (A29)" $
      withResumeDirs $ \proj ws -> do
        writeLlmUsageProject proj (Just 0.0)
        calls <- newIORef (0 :: Int)
        let models = llmPricedStore (countingGatewayWithUsage calls)
        workspace <- newWorkspace ws
        tp <- loadChecked proj
        result <- expectRun =<< performRun tp workspace models Map.empty proj "run-1" mainQ Map.empty
        readIORef calls `shouldReturn` 0
        case rrOutcome result of
          Left err -> reKind err `shouldBe` KLlm
          Right _ -> expectationFailure "expected budget rejection"
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

llmCallCosts :: [TraceEvent] -> [Double]
llmCallCosts evs =
  [cost | TraceEvent _ _ (LlmCall _ _ _ _ _ _ _ _ cost) <- evs]

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
lastCompleted bodies = lastRunEnd bodies == Just Completed

lastRunEnd :: [EventBody] -> Maybe RunStatus
lastRunEnd bodies =
  case [s | RunEnd _ s <- bodies] of
    [] -> Nothing
    xs -> Just (last xs)

hasInternalError :: [EventBody] -> Bool
hasInternalError = any (\case ErrorEvent _ _ _ KInternal -> True; _ -> False)

seqsAreGapless :: [TraceEvent] -> Bool
seqsAreGapless evs = map teSeq evs == [0 .. length evs - 1]
