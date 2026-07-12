module Hwfi.Runtime.ControlFlowSpec (spec) where

import Control.Exception (ErrorCall (ErrorCall), throwIO)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Hwfi.Ast.Name (Ident, QName, qnameFromText)
import Hwfi.Check (checkProject)
import Hwfi.Check.Error (TypeError (..), TypeErrorKind (..))
import Hwfi.Compat (ModelConfig (..))
import Hwfi.Parse.Project (loadProject)
import Hwfi.Runtime.Error (ErrorKind (..), RuntimeError (..), reKind)
import Hwfi.Runtime.Executor (RunResult (..), performResume, performRun)
import Hwfi.Runtime.Gateways (ModelStore)
import Hwfi.Runtime.RunStore (RunPhase (..), openRunStore, updateRunPhase)
import Hwfi.Runtime.Trace (EventBody (..), TraceEvent (..))
import Hwfi.Runtime.Value (RValue (..))
import Hwfi.Runtime.Workspace (newWorkspace, workspaceRoot)
import Hwfi.TypedProject (TypedProject)
import LLM.Core.Types (ChatResponse (..), ContentBlock (..), LLMError (..), LLMGateway (..))
import LLM.Core.Usage (PricingInfo (..), Usage (..))
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

-- Fixtures -------------------------------------------------------------------

mainQ :: QName
mainQ = qnameFromText "workflows/main"

-- | project.json allowlisting @sh@ for @builtin/exec@ (§7.5).
projectJson :: Text
projectJson =
  T.unlines
    [ "{",
      "  \"name\": \"cf\",",
      "  \"version\": \"0.1.0\",",
      "  \"entrypoint\": \"workflows/main\",",
      "  \"env\": [],",
      "  \"exec\": { \"allow\": [\"sh\"], \"env\": [\"PATH\"] }",
      "}"
    ]

-- | Materialise a one-workflow project from a full @main.md@ body.
writeProject :: FilePath -> Text -> IO ()
writeProject dir mainMd = writeProjectWithSub dir mainMd Nothing

-- | Like 'writeProject', optionally adding a @workflows/tick.md@ sub-workflow.
writeProjectWithSub :: FilePath -> Text -> Maybe Text -> IO ()
writeProjectWithSub dir mainMd mSubMd = writeProjectWithSubs dir mainMd (maybe Map.empty (Map.singleton "tick.md") mSubMd)

writeProjectWithSubs :: FilePath -> Text -> Map.Map Text Text -> IO ()
writeProjectWithSubs dir mainMd subs = do
  createDirectoryIfMissing True (dir </> "workflows")
  TIO.writeFile (dir </> "project.json") projectJson
  TIO.writeFile (dir </> "model-catalog.json") "[]\n"
  TIO.writeFile (dir </> "workflows" </> "main.md") mainMd
  mapM_ (\(name, md) -> TIO.writeFile (dir </> "workflows" </> T.unpack name) md) (Map.toList subs)

loadChecked :: FilePath -> IO TypedProject
loadChecked dir = do
  eproj <- loadProject dir
  case eproj of
    Left ds -> error ("fixture parse failed: " <> show ds)
    Right proj -> case checkProject proj of
      Left errs -> error ("fixture check failed: " <> show errs)
      Right tp -> pure tp

checkOnly :: Text -> IO (Either [TypeError] TypedProject)
checkOnly mainMd =
  withSystemTempDirectory "hwfi-cf-check" $ \dir -> do
    writeProject dir mainMd
    eproj <- loadProject dir
    either (\ds -> error ("parse failed: " <> show ds)) (pure . checkProject) eproj

errKinds :: Either [TypeError] TypedProject -> [TypeErrorKind]
errKinds = either (map errKind) (const [])

runProject :: Text -> Map.Map Ident RValue -> (RunResult -> FilePath -> IO a) -> IO a
runProject mainMd = runProjectWithSub mainMd Nothing

runProjectWithSub :: Text -> Maybe Text -> Map.Map Ident RValue -> (RunResult -> FilePath -> IO a) -> IO a
runProjectWithSub mainMd mSubMd = runProjectWithSubs mainMd (maybe Map.empty (Map.singleton "tick.md") mSubMd)

runProjectWithSubs :: Text -> Map.Map Text Text -> Map.Map Ident RValue -> (RunResult -> FilePath -> IO a) -> IO a
runProjectWithSubs mainMd subs inputs k =
  withSystemTempDirectory "hwfi-cf-proj" $ \proj ->
    withSystemTempDirectory "hwfi-cf-ws" $ \ws -> do
      writeProjectWithSubs proj mainMd subs
      tp <- loadChecked proj
      workspace <- newWorkspace ws
      res <- performRun tp workspace Map.empty Map.empty proj "run-1" mainQ inputs
      case res of
        Left e -> error ("run failed: " <> T.unpack e)
        Right rr -> k rr ws

checkOnlyWithSubs :: Text -> Map.Map Text Text -> IO (Either [TypeError] TypedProject)
checkOnlyWithSubs mainMd subs =
  withSystemTempDirectory "hwfi-cf-check" $ \dir -> do
    writeProjectWithSubs dir mainMd subs
    eproj <- loadProject dir
    either (\ds -> error ("parse failed: " <> show ds)) (pure . checkProject) eproj

runThenResumeWithSubs :: Text -> Map.Map Text Text -> Map.Map Ident RValue -> (RunResult -> RunResult -> FilePath -> IO a) -> IO a
runThenResumeWithSubs mainMd subs inputs = runThenResumeWithSubsModels mainMd subs inputs Map.empty Map.empty

runThenResumeWithSubsModels ::
  Text ->
  Map.Map Text Text ->
  Map.Map Ident RValue ->
  ModelStore ->
  ModelStore ->
  (RunResult -> RunResult -> FilePath -> IO a) ->
  IO a
runThenResumeWithSubsModels mainMd subs inputs models1 models2 k =
  withSystemTempDirectory "hwfi-cf-proj" $ \proj ->
    withSystemTempDirectory "hwfi-cf-ws" $ \ws -> do
      writeProjectWithSubs proj mainMd subs
      tp <- loadChecked proj
      workspace <- newWorkspace ws
      r1 <- expectRun =<< performRun tp workspace models1 Map.empty proj "run-1" mainQ inputs
      Right store <- openRunStore (workspaceRoot workspace) "run-1"
      updateRunPhase store PhaseAborted
      r2 <- expectRun =<< performResume tp workspace models2 Map.empty "run-1"
      k r1 r2 ws
  where
    expectRun = either (\e -> error ("run failed: " <> T.unpack e)) pure

-- | Run to completion, mark the run resumable (aborted), then resume.
runThenResume :: Text -> Map.Map Ident RValue -> (RunResult -> RunResult -> FilePath -> IO a) -> IO a
runThenResume mainMd = runThenResumeWithSub mainMd Nothing

runThenResumeWithSub :: Text -> Maybe Text -> Map.Map Ident RValue -> (RunResult -> RunResult -> FilePath -> IO a) -> IO a
runThenResumeWithSub mainMd mSubMd = runThenResumeWithSubs mainMd (maybe Map.empty (Map.singleton "tick.md") mSubMd)

-- Workflow bodies ------------------------------------------------------------

-- A @foreach@ that, per element, echoes the element to stdout and appends it
-- to a log file. The workflow returns the second iteration's captured stdout,
-- proving map results keep input order.
foreachMd :: Text
foreachMd =
  T.unlines
    [ "---",
      "name: workflows/main",
      "inputs:",
      "  items: List<String>",
      "outputs:",
      "  got: String",
      "imports:",
      "  - builtin/exec",
      "---",
      "",
      "## flow",
      "",
      "```step",
      "rs <- foreach it in ${inputs.items} {",
      "  r <- builtin/exec(program = \"sh\", args = [\"-c\", \"echo ${it} >> log.txt; echo ${it}\"], stdin = \"\", timeout_ms = 0)",
      "} @loop",
      "return { got = ${rs[1].stdout} }",
      "```"
    ]

parMd :: Text
parMd = T.replace "@loop" "@fan" (T.replace "foreach it in" "par(max = 2) it in" foreachMd)

-- A sub-workflow with a cacheable step using identical static arguments on
-- every call — without call-site scope threading (§4.1) a second loop iteration
-- would incorrectly cache-hit the first iteration's internal step.
tickMd :: Text
tickMd =
  T.unlines
    [ "---",
      "name: workflows/tick",
      "inputs: {}",
      "outputs:",
      "  ok: String",
      "imports:",
      "  - builtin/exec",
      "---",
      "",
      "## flow",
      "",
      "```step",
      "_ <- builtin/exec(program = \"sh\", args = [\"-c\", \"echo tick >> log.txt\"], stdin = \"\", timeout_ms = 0) @work",
      "return { ok = \"x\" }",
      "```"
    ]

foreachSubMd :: Text
foreachSubMd =
  T.unlines
    [ "---",
      "name: workflows/main",
      "inputs:",
      "  items: List<String>",
      "outputs:",
      "  got: String",
      "imports:",
      "  - workflows/tick",
      "---",
      "",
      "## flow",
      "",
      "```step",
      "rs <- foreach it in ${inputs.items} {",
      "  r <- workflows/tick() @call",
      "} @loop",
      "return { got = ${rs[1].ok} }",
      "```"
    ]

parSubMd :: Text
parSubMd = T.replace "@loop" "@fan" (T.replace "foreach it in" "par(max = 2) it in" foreachSubMd)

-- An @if@/@else@ that branches on a Bool input; each branch echoes a distinct
-- marker. The workflow returns the taken branch's stdout.
ifMd :: Text
ifMd =
  T.unlines
    [ "---",
      "name: workflows/main",
      "inputs:",
      "  flag: Bool",
      "outputs:",
      "  out: String",
      "imports:",
      "  - builtin/exec",
      "---",
      "",
      "## flow",
      "",
      "```step",
      "x <- if ${inputs.flag} {",
      "  a <- builtin/exec(program = \"sh\", args = [\"-c\", \"echo THEN\"], stdin = \"\", timeout_ms = 0)",
      "} else {",
      "  b <- builtin/exec(program = \"sh\", args = [\"-c\", \"echo ELSE\"], stdin = \"\", timeout_ms = 0)",
      "} @choose",
      "return { out = ${x.stdout} }",
      "```"
    ]

-- @while@ predicate/body sub-workflows (§4.3, M9).
predMd :: Text
predMd =
  T.unlines
    [ "---",
      "name: workflows/pred",
      "inputs:",
      "  stop: Bool",
      "outputs:",
      "  continue: Bool",
      "  reason: String",
      "imports:",
      "  - workflows/go-out",
      "  - workflows/stop-out",
      "---",
      "",
      "## flow",
      "",
      "```step",
      "r <- if ${inputs.stop} {",
      "  x <- workflows/stop-out() @s",
      "} else {",
      "  x <- workflows/go-out() @g",
      "} @pick",
      "return { continue = ${r.continue}, reason = ${r.reason} }",
      "```"
    ]

goOutMd :: Text
goOutMd =
  T.unlines
    [ "---",
      "name: workflows/go-out",
      "inputs: {}",
      "outputs:",
      "  continue: Bool",
      "  reason: String",
      "---",
      "",
      "## flow",
      "",
      "```step",
      "return { continue = true, reason = \"go\" }",
      "```"
    ]

stopOutMd :: Text
stopOutMd =
  T.unlines
    [ "---",
      "name: workflows/stop-out",
      "inputs: {}",
      "outputs:",
      "  continue: Bool",
      "  reason: String",
      "---",
      "",
      "## flow",
      "",
      "```step",
      "return { continue = false, reason = \"finished\" }",
      "```"
    ]

-- | Pred that always stops (zero body iterations).
predStopMd :: Text
predStopMd =
  T.unlines
    [ "---",
      "name: workflows/pred",
      "inputs: {}",
      "outputs:",
      "  continue: Bool",
      "  reason: String",
      "---",
      "",
      "## flow",
      "",
      "```step",
      "return { continue = false, reason = \"done\" }",
      "```"
    ]

bodyMd :: Text
bodyMd =
  T.unlines
    [ "---",
      "name: workflows/body",
      "inputs: {}",
      "outputs:",
      "  ok: String",
      "  stop: Bool",
      "imports:",
      "  - builtin/exec",
      "---",
      "",
      "## flow",
      "",
      "```step",
      "_ <- builtin/exec(program = \"sh\", args = [\"-c\", \"echo body >> log.txt\"], stdin = \"\", timeout_ms = 0) @work",
      "return { ok = \"done\", stop = true }",
      "```"
    ]

foreverPredMd :: Text
foreverPredMd =
  T.unlines
    [ "---",
      "name: workflows/pred",
      "inputs: {}",
      "outputs:",
      "  continue: Bool",
      "  reason: String",
      "---",
      "",
      "## flow",
      "",
      "```step",
      "return { continue = true, reason = \"forever\" }",
      "```"
    ]

whileSubs :: Map.Map Text Text
whileSubs =
  Map.fromList
    [ ("pred.md", predMd),
      ("body.md", bodyMd),
      ("go-out.md", goOutMd),
      ("stop-out.md", stopOutMd)
    ]

whileStopSubs :: Map.Map Text Text
whileStopSubs = Map.fromList [("pred.md", predStopMd), ("body.md", bodyMd)]

-- | Predicate sub-workflow whose decision comes from @builtin/llm-agent@ (A32).
predAgentMd :: Text
predAgentMd =
  T.unlines
    [ "---",
      "name: workflows/pred",
      "inputs: {}",
      "outputs:",
      "  continue: Bool",
      "  reason: String",
      "imports:",
      "  - builtin/llm-agent",
      "---",
      "",
      "## sys",
      "",
      "Decide whether the loop should continue. Keep your answer brief.",
      "",
      "## flow",
      "",
      "```step",
      "r <- builtin/llm-agent(",
      "  system = @self#sys,",
      "  prompt = \"Return a short reason for continuing.\",",
      "  model = \"fast\",",
      "  tools = [],",
      "  max_rounds = 2",
      ") @decide",
      "return { continue = true, reason = ${r.text} }",
      "```"
    ]

whileAgentSubs :: Map.Map Text Text
whileAgentSubs = Map.fromList [("pred.md", predAgentMd), ("body.md", bodyMd)]

whileAgentMainMd :: Text
whileAgentMainMd =
  T.unlines
    [ "---",
      "name: workflows/main",
      "inputs: {}",
      "outputs:",
      "  got: String",
      "imports:",
      "  - workflows/pred",
      "  - workflows/body",
      "---",
      "",
      "## flow",
      "",
      "```step",
      "rs <- while(",
      "  predicate = workflows/pred,",
      "  predicate_args = {},",
      "  body = workflows/body,",
      "  body_args = {},",
      "  max_iterations = 1",
      ") @loop",
      "return { got = ${rs[0].ok} }",
      "```"
    ]

foreverSubs :: Map.Map Text Text
foreverSubs = Map.fromList [("pred.md", foreverPredMd), ("body.md", bodyMd)]

whileMainMd :: Text
whileMainMd =
  T.unlines
    [ "---",
      "name: workflows/main",
      "inputs: {}",
      "outputs:",
      "  got: String",
      "imports:",
      "  - builtin/exec",
      "  - workflows/pred",
      "  - workflows/body",
      "---",
      "",
      "## flow",
      "",
      "```step",
      "rs <- while(",
      "  predicate = workflows/pred,",
      "  predicate_args = { stop = false },",
      "  body = workflows/body,",
      "  body_args = {},",
      "  max_iterations = 1",
      ") @loop",
      "return { got = ${rs[0].ok} }",
      "```"
    ]

foreverMainMd :: Text
foreverMainMd =
  T.unlines
    [ "---",
      "name: workflows/main",
      "inputs: {}",
      "outputs:",
      "  got: String",
      "imports:",
      "  - workflows/pred",
      "  - workflows/body",
      "---",
      "",
      "## flow",
      "",
      "```step",
      "_ <- while(",
      "  predicate = workflows/pred,",
      "  predicate_args = {},",
      "  body = workflows/body,",
      "  body_args = {},",
      "  max_iterations = 2",
      ") @loop",
      "return { got = \"x\" }",
      "```"
    ]

whileStopMainMd :: Text
whileStopMainMd =
  T.unlines
    [ "---",
      "name: workflows/main",
      "inputs: {}",
      "outputs:",
      "  done: Bool",
      "imports:",
      "  - workflows/pred",
      "  - workflows/body",
      "---",
      "",
      "## flow",
      "",
      "```step",
      "_ <- while(",
      "  predicate = workflows/pred,",
      "  predicate_args = {},",
      "  body = workflows/body,",
      "  body_args = {},",
      "  max_iterations = 10",
      ") @loop",
      "return { done = true }",
      "```"
    ]

items3 :: Map.Map Ident RValue
items3 = Map.fromList [("items", VList [VString "a", VString "b", VString "c"])]

-- Assertions helpers ---------------------------------------------------------

stepStarts :: Ident -> [TraceEvent] -> Int
stepStarts sid evs = length [() | TraceEvent _ _ (StepStart _ s _ _) <- evs, s == sid]

loopIters :: [TraceEvent] -> Int
loopIters evs = length [() | TraceEvent _ _ (LoopIter {}) <- evs]

-- | Step-starts for @sid@ that occur /after/ the resume marker, i.e. steps
-- that actually re-executed on resume (the resumed trace also carries the
-- prior attempt's events).
resumedStepStarts :: Ident -> [TraceEvent] -> Int
resumedStepStarts sid evs = stepStarts sid afterResume
  where
    afterResume = drop 1 (dropWhile (not . isResumed) evs)
    isResumed (TraceEvent _ _ (Resumed {})) = True
    isResumed _ = False

llmCalls :: [TraceEvent] -> Int
llmCalls evs = length [() | TraceEvent _ _ (LlmCall {}) <- evs]

lineCount :: FilePath -> IO Int
lineCount p = length . filter (not . T.null) . T.lines <$> TIO.readFile p

-- Fake LLM gateways (A32) ----------------------------------------------------

llmUsage :: Usage
llmUsage = Usage 1 1 0

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
        pure (Right (ChatResponse "go" [TextBlock "go"] (Just llmUsage) Nothing)),
      gwStreamText = \_ _ _ -> pure (Left EmptyResponse),
      gwGenerateObject = \_ _ _ -> pure (Left EmptyResponse)
    }

explodingGateway :: LLMGateway
explodingGateway =
  LLMGateway
    { gwName = "fake",
      gwGenerateText = \_ _ -> throwIO (ErrorCall "llm invoked during a pinned while-pred resume"),
      gwStreamText = \_ _ _ -> throwIO (ErrorCall "llm invoked during a pinned while-pred resume"),
      gwGenerateObject = \_ _ _ -> throwIO (ErrorCall "llm invoked during a pinned while-pred resume")
    }

spec :: Spec
spec = do
  describe "foreach (§13, M8)" $ do
    it "runs the body once per element, in order, collecting a list result" $
      runProject foreachMd items3 $ \rr ws -> do
        rrOutcome rr `shouldBe` Right (VRecord (Map.fromList [("got", VString "b\n")]))
        lineCount (ws </> "log.txt") `shouldReturn` 3
        loopIters (rrEvents rr) `shouldBe` 3
        stepStarts "r" (rrEvents rr) `shouldBe` 3

    it "brackets iterations with loop-start/loop-end carrying the count" $
      runProject foreachMd items3 $ \rr _ -> do
        let bodies = map teBody (rrEvents rr)
        [n | LoopStart _ "loop" "foreach" n <- bodies] `shouldBe` [Just 3]
        [n | LoopEnd _ "loop" n <- bodies] `shouldBe` [3]

    it "does not re-apply per-iteration side effects on resume (§8.2)" $
      runThenResume foreachMd items3 $ \_ r2 ws -> do
        -- All three iterations were cached; none re-run on resume, so the log
        -- keeps exactly three lines (a re-run would double it).
        lineCount (ws </> "log.txt") `shouldReturn` 3
        resumedStepStarts "r" (rrEvents r2) `shouldBe` 0

  describe "par (§13, M8)" $ do
    it "returns results in input order despite concurrency" $
      runProject parMd items3 $ \rr ws -> do
        rrOutcome rr `shouldBe` Right (VRecord (Map.fromList [("got", VString "b\n")]))
        lineCount (ws </> "log.txt") `shouldReturn` 3
        loopIters (rrEvents rr) `shouldBe` 3

    it "does not re-apply per-iteration side effects on resume (§8.2)" $
      runThenResume parMd items3 $ \_ r2 ws -> do
        lineCount (ws </> "log.txt") `shouldReturn` 3
        resumedStepStarts "r" (rrEvents r2) `shouldBe` 0

  describe "sub-workflow scope threading (§4.1, H1.4)" $ do
    it "runs a cacheable sub-workflow once per foreach iteration (identical args)" $
      runProjectWithSub foreachSubMd (Just tickMd) items3 $ \rr ws -> do
        rrOutcome rr `shouldBe` Right (VRecord (Map.fromList [("got", VString "x")]))
        lineCount (ws </> "log.txt") `shouldReturn` 3
        stepStarts "work" (rrEvents rr) `shouldBe` 3

    it "does not re-apply sub-workflow side effects on foreach resume (§8.2)" $
      runThenResumeWithSub foreachSubMd (Just tickMd) items3 $ \_ r2 ws -> do
        lineCount (ws </> "log.txt") `shouldReturn` 3
        resumedStepStarts "work" (rrEvents r2) `shouldBe` 0

    it "runs a cacheable sub-workflow once per par iteration (identical args)" $
      runProjectWithSub parSubMd (Just tickMd) items3 $ \rr ws -> do
        lineCount (ws </> "log.txt") `shouldReturn` 3
        stepStarts "work" (rrEvents rr) `shouldBe` 3

    it "does not re-apply sub-workflow side effects on par resume (§8.2)" $
      runThenResumeWithSub parSubMd (Just tickMd) items3 $ \_ r2 ws -> do
        lineCount (ws </> "log.txt") `shouldReturn` 3
        resumedStepStarts "work" (rrEvents r2) `shouldBe` 0

  describe "if/else (§13, M8)" $ do
    it "takes the then branch and yields its value" $
      runProject ifMd (Map.fromList [("flag", VBool True)]) $ \rr _ -> do
        rrOutcome rr `shouldBe` Right (VRecord (Map.fromList [("out", VString "THEN\n")]))
        [b | IfBranch _ "choose" b <- map teBody (rrEvents rr)] `shouldBe` ["then"]
        stepStarts "a" (rrEvents rr) `shouldBe` 1
        stepStarts "b" (rrEvents rr) `shouldBe` 0

    it "takes the else branch and yields its value" $
      runProject ifMd (Map.fromList [("flag", VBool False)]) $ \rr _ -> do
        rrOutcome rr `shouldBe` Right (VRecord (Map.fromList [("out", VString "ELSE\n")]))
        [b | IfBranch _ "choose" b <- map teBody (rrEvents rr)] `shouldBe` ["else"]
        stepStarts "a" (rrEvents rr) `shouldBe` 0
        stepStarts "b" (rrEvents rr) `shouldBe` 1

  describe "control-flow type checking (§13, M8)" $ do
    it "accepts a well-formed foreach and if" $ do
      r1 <- checkOnly foreachMd
      errKinds r1 `shouldBe` []
      r2 <- checkOnly ifMd
      errKinds r2 `shouldBe` []

    it "rejects a value-binding if without an else branch" $ do
      let md =
            wrapBody
              ["x <- if ${inputs.flag} {", "  a <- builtin/exec(program = \"sh\", args = [\"-c\", \"echo hi\"], stdin = \"\", timeout_ms = 0)", "} @c", "return { out = ${x.stdout} }"]
              [("flag", "Bool")]
              [("out", "String")]
      ks <- errKinds <$> checkOnly md
      ks `shouldContain` [ReturnRule]

    it "rejects if branches with different result types" $ do
      let md =
            wrapBody
              [ "x <- if ${inputs.flag} {",
                "  a <- builtin/exec(program = \"sh\", args = [\"-c\", \"echo hi\"], stdin = \"\", timeout_ms = 0)",
                "} else {",
                "  b <- builtin/read-file(path = \"f.txt\")",
                "} @c",
                "return { out = ${x.stdout} }"
              ]
              [("flag", "Bool")]
              [("out", "String")]
      ks <- errKinds <$> checkOnly md
      ks `shouldContain` [TypeMismatch]

    it "rejects foreach over a non-list expression" $ do
      let md =
            wrapBody
              ["rs <- foreach it in ${inputs.flag} {", "  a <- builtin/exec(program = \"sh\", args = [\"-c\", \"echo ${it}\"], stdin = \"\", timeout_ms = 0)", "} @loop", "return { out = \"x\" }"]
              [("flag", "Bool")]
              [("out", "String")]
      ks <- errKinds <$> checkOnly md
      ks `shouldContain` [TypeMismatch]

    it "rejects a loop variable that shadows an existing binding" $ do
      let md =
            wrapBody
              [ "it <- builtin/read-file(path = \"f.txt\")",
                "rs <- foreach it in ${inputs.items} {",
                "  a <- builtin/exec(program = \"sh\", args = [\"-c\", \"echo hi\"], stdin = \"\", timeout_ms = 0)",
                "} @loop",
                "return { out = \"x\" }"
              ]
              [("items", "List<String>")]
              [("out", "String")]
      errKinds <$> checkOnly md `shouldReturn` [DuplicateBind]

    it "rejects a duplicate step/control-flow id in the same block" $ do
      let md =
            wrapBody
              [ "_ <- foreach it in ${inputs.items} {",
                "  a <- builtin/exec(program = \"sh\", args = [\"-c\", \"echo hi\"], stdin = \"\", timeout_ms = 0)",
                "} @dup",
                "_ <- foreach it in ${inputs.items} {",
                "  b <- builtin/exec(program = \"sh\", args = [\"-c\", \"echo bye\"], stdin = \"\", timeout_ms = 0)",
                "} @dup",
                "return { out = \"x\" }"
              ]
              [("items", "List<String>")]
              [("out", "String")]
      errKinds <$> checkOnly md `shouldReturn` [DuplicateBind]

    it "allows the same step id in sibling if branches (§4.2)" $ do
      let md =
            wrapBody
              [ "x <- if ${inputs.flag} {",
                "  msg <- builtin/exec(program = \"sh\", args = [\"-c\", \"echo THEN\"], stdin = \"\", timeout_ms = 0) @notify",
                "} else {",
                "  msg <- builtin/exec(program = \"sh\", args = [\"-c\", \"echo ELSE\"], stdin = \"\", timeout_ms = 0) @notify",
                "} @choose",
                "return { out = ${x.stdout} }"
              ]
              [("flag", "Bool")]
              [("out", "String")]
      errKinds <$> checkOnly md `shouldReturn` []

    it "allows the same step id in sibling loop bodies (§4.2)" $ do
      let md =
            wrapBody
              [ "_ <- foreach it in ${inputs.items} {",
                "  a <- builtin/exec(program = \"sh\", args = [\"-c\", \"echo hi\"], stdin = \"\", timeout_ms = 0) @work",
                "} @loop1",
                "_ <- foreach it in ${inputs.items} {",
                "  b <- builtin/exec(program = \"sh\", args = [\"-c\", \"echo bye\"], stdin = \"\", timeout_ms = 0) @work",
                "} @loop2",
                "return { out = \"x\" }"
              ]
              [("items", "List<String>")]
              [("out", "String")]
      errKinds <$> checkOnly md `shouldReturn` []

    it "rejects a duplicate step id within a single block" $ do
      let md =
            wrapBody
              [ "_ <- foreach it in ${inputs.items} {",
                "  a <- builtin/exec(program = \"sh\", args = [\"-c\", \"echo hi\"], stdin = \"\", timeout_ms = 0) @dup",
                "  b <- builtin/exec(program = \"sh\", args = [\"-c\", \"echo bye\"], stdin = \"\", timeout_ms = 0) @dup",
                "} @loop",
                "return { out = \"x\" }"
              ]
              [("items", "List<String>")]
              [("out", "String")]
      errKinds <$> checkOnly md `shouldReturn` [DuplicateBind]

    it "rejects a return inside a control-flow block" $ do
      let md =
            wrapBody
              ["_ <- foreach it in ${inputs.items} {", "  return { out = \"x\" }", "} @loop", "return { out = \"y\" }"]
              [("items", "List<String>")]
              [("out", "String")]
      errKinds <$> checkOnly md `shouldReturn` [ReturnRule]

  describe "while (§4.3, M9)" $ do
    it "runs predicate then body until max_iterations when predicate never stops (A30)" $
      runProjectWithSubs whileMainMd whileSubs Map.empty $ \rr ws -> do
        case rrOutcome rr of
          Left err -> reKind err `shouldBe` KUser
          Right _ -> expectationFailure "expected max_iterations user error"
        lineCount (ws </> "log.txt") `shouldReturn` 1
        length [() | TraceEvent _ _ (WhilePred {}) <- rrEvents rr] `shouldBe` 2
        loopIters (rrEvents rr) `shouldBe` 2

    it "produces an empty list when the predicate immediately returns continue = false (A30)" $
      runProjectWithSubs whileStopMainMd whileStopSubs Map.empty $ \rr _ -> do
        rrOutcome rr `shouldBe` Right (VRecord (Map.fromList [("done", VBool True)]))
        length [() | TraceEvent _ _ (WhilePred {}) <- rrEvents rr] `shouldBe` 1

    it "aborts with kind user when max_iterations is reached (A30)" $
      runProjectWithSubs foreverMainMd foreverSubs Map.empty $ \rr _ -> do
        case rrOutcome rr of
          Left err -> reKind err `shouldBe` KUser
          Right _ -> expectationFailure "expected max_iterations user error"

    it "emits loop-start without count for while" $
      runProjectWithSubs whileMainMd whileSubs Map.empty $ \rr _ -> do
        let bodies = map teBody (rrEvents rr)
        [k | LoopStart _ "loop" "while" k <- bodies] `shouldBe` [Nothing]

    it "does not re-apply completed body iterations or re-run pinned predicates on resume (A31)" $
      runThenResumeWithSubs whileMainMd whileSubs Map.empty $ \r1 r2 ws -> do
        lineCount (ws </> "log.txt") `shouldReturn` 1
        resumedStepStarts "work" (rrEvents r2) `shouldBe` 0
        length [() | TraceEvent _ _ (WhilePred {}) <- drop (length (rrEvents r1)) (rrEvents r2)] `shouldBe` 0

    it "replays pinned agent predicate decisions on resume without re-invoking llm-agent (A32)" $ do
      calls <- newIORef (0 :: Int)
      let store1 = llmStore (countingGateway calls) 0.1
          store2 = llmStore explodingGateway 0.1
      runThenResumeWithSubsModels whileAgentMainMd whileAgentSubs Map.empty store1 store2 $ \r1 r2 ws -> do
        readIORef calls `shouldReturn` 2
        case rrOutcome r1 of
          Left err -> reKind err `shouldBe` KUser
          Right _ -> expectationFailure "expected max_iterations user error"
        case rrOutcome r2 of
          Left err -> reKind err `shouldBe` KUser
          Right _ -> expectationFailure "expected max_iterations user error on resume"
        lineCount (ws </> "log.txt") `shouldReturn` 1
        resumedStepStarts "work" (rrEvents r2) `shouldBe` 0
        llmCalls (rrEvents r1) `shouldBe` 2
        llmCalls (drop (length (rrEvents r1)) (rrEvents r2)) `shouldBe` 0
        length [() | TraceEvent _ _ (WhilePred {}) <- drop (length (rrEvents r1)) (rrEvents r2)] `shouldBe` 0

    it "rejects carry outside while predicate_args/body_args at check time (A33)" $ do
      let bodyNoteMd = T.replace "inputs: {}" "inputs:\n  note: String" bodyMd
          md =
            wrapBodyWithImports
              ["workflows/pred", "workflows/body"]
              [ "rs <- while(",
                "  predicate = workflows/pred,",
                "  predicate_args = { stop = false },",
                "  body = workflows/body,",
                "  body_args = {},",
                "  max_iterations = 3",
                ") @loop",
                "x <- workflows/body(note = ${carry.ok}) @bad",
                "return { got = \"x\" }"
              ]
              []
              [("got", "String")]
      ks <- errKinds <$> checkOnlyWithSubs md (Map.insert "body.md" bodyNoteMd whileSubs)
      ks `shouldContain` [UndeclaredRef]

    it "accepts carry in while body_args when the body output type is known" $ do
      let bodyCarryMd = T.replace "inputs: {}" "inputs:\n  note: String" bodyMd
          subs = Map.insert "body.md" bodyCarryMd whileSubs
          md =
            wrapBodyWithImports
              ["workflows/pred", "workflows/body"]
              [ "rs <- while(",
                "  predicate = workflows/pred,",
                "  predicate_args = { stop = false },",
                "  body = workflows/body,",
                "  body_args = { note = ${carry.ok} },",
                "  max_iterations = 3",
                ") @loop",
                "return { got = \"x\" }"
              ]
              []
              [("got", "String")]
      errKinds <$> checkOnlyWithSubs md subs `shouldReturn` []

    it "accepts foreach i in range(n) as List<Int> (§13.1.3)" $ do
      let md =
            wrapBody
              [ "_ <- foreach i in range(3) {",
                "} @loop",
                "return { got = \"ok\" }"
              ]
              []
              [("got", "String")]
      errKinds <$> checkOnly md `shouldReturn` []

-- | Assemble a @main.md@ with extra import lines and body lines.
wrapBodyWithImports :: [Text] -> [Text] -> [(Text, Text)] -> [(Text, Text)] -> Text
wrapBodyWithImports extraImports bodyLines ins outs =
  T.unlines $
    ["---", "name: workflows/main", "inputs:"]
      <> ["  " <> n <> ": " <> t | (n, t) <- ins]
      <> ["outputs:"]
      <> ["  " <> n <> ": " <> t | (n, t) <- outs]
      <> [ "imports:",
           "  - builtin/exec",
           "  - builtin/read-file"
         ]
      <> map ("  - " <>) extraImports
      <> ["---", "", "## flow", "", "```step"]
      <> bodyLines
      <> ["```"]

-- | Assemble a @main.md@ from body lines and simple scalar/list field specs.
wrapBody :: [Text] -> [(Text, Text)] -> [(Text, Text)] -> Text
wrapBody bodyLines ins outs =
  T.unlines $
    ["---", "name: workflows/main", "inputs:"]
      <> ["  " <> n <> ": " <> t | (n, t) <- ins]
      <> ["outputs:"]
      <> ["  " <> n <> ": " <> t | (n, t) <- outs]
      <> [ "imports:",
           "  - builtin/exec",
           "  - builtin/read-file",
           "---",
           "",
           "## flow",
           "",
           "```step"
         ]
      <> bodyLines
      <> ["```"]
