module Hwfi.Runtime.ControlFlowSpec (spec) where

import Control.Exception (ErrorCall (ErrorCall), throwIO)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Aeson qualified as Aeson
import Data.Maybe (listToMaybe)
import Data.Text.Encoding qualified as TEnc
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
import Hwfi.Runtime.MachineRun (RunResult (..), performContinueToEnd, performRun)
import Hwfi.Runtime.Gateways (ModelStore)
import Hwfi.Runtime.RunStore (RunPhase (..), RunStore, openRunStore, rsTracePath, updateRunPhase)
import Hwfi.Runtime.Trace (EventBody (..), TraceEvent (..), eventFromJson)
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
      TIO.writeFile (ws </> "good.txt") "ok\n"
      tp <- loadChecked proj
      workspace <- newWorkspace ws
      let wsDir = workspaceRoot workspace
      res <- performRun tp workspace Map.empty Map.empty proj "run-1" mainQ inputs
      case res of
        Left e -> error ("run failed: " <> T.unpack e)
        Right rr -> k rr wsDir

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
      let wsDir = workspaceRoot workspace
      r1 <- expectRun_ =<< performRun tp workspace models1 Map.empty proj "run-1" mainQ inputs
      Right store <- openRunStore (workspaceRoot workspace) "run-1"
      updateRunPhase store PhaseAborted
      r2 <- expectRun_ =<< performContinueToEnd tp workspace models2 Map.empty "run-1" False
      k r1 r2 wsDir
  where
    expectRun_ = either (\e -> error ("run failed: " <> T.unpack e)) pure

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

-- Nested @foreach@: outer groups contain inner lists; collects @List<List<exec>>@.
nestedForeachMd :: Text
nestedForeachMd =
  T.unlines
    [ "---",
      "name: workflows/main",
      "inputs:",
      "  groups: List<List<String>>",
      "outputs:",
      "  got: String",
      "imports:",
      "  - builtin/exec",
      "---",
      "",
      "## flow",
      "",
      "```step",
      "rows <- foreach outer in ${inputs.groups} {",
      "  inner <- foreach inner in ${outer} {",
      "    r <- builtin/exec(program = \"sh\", args = [\"-c\", \"echo ${inner} >> log.txt; echo ${inner}\"], stdin = \"\", timeout_ms = 0)",
      "  } @inner",
      "} @outer",
      "return { got = ${rows[1][0].stdout} }",
      "```"
    ]

nestedGroups :: Map.Map Ident RValue
nestedGroups =
  Map.fromList
    [ ( "groups",
        VList
          [ VList [VString "a", VString "b"],
            VList [VString "c"]
          ]
      )
    ]

returnForeachMd :: Text
returnForeachMd =
  T.unlines
    [ "---",
      "name: workflows/main",
      "inputs:",
      "  items: List<String>",
      "outputs:",
      "  got: String",
      "imports: []",
      "---",
      "",
      "## flow",
      "",
      "```step",
      "rows <- foreach it in ${inputs.items} {",
      "  return { out = ${it} }",
      "} @loop",
      "return { got = ${rows[0].out} }",
      "```"
    ]

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

inlineWhileSubs :: Map.Map Text Text
inlineWhileSubs =
  Map.fromList
    [ ("pred.md", predMd),
      ("go-out.md", goOutMd),
      ("stop-out.md", stopOutMd)
    ]

inlineWhileMainMd :: Text
inlineWhileMainMd =
  T.unlines
    [ "---",
      "name: workflows/main",
      "inputs: {}",
      "outputs:",
      "  got: String",
      "imports:",
      "  - builtin/exec",
      "  - workflows/pred",
      "---",
      "",
      "## flow",
      "",
      "```step",
      "rs <- while(",
      "  predicate = workflows/pred,",
      "  predicate_args = { stop = false },",
      "  body = {",
      "    r <- builtin/exec(program = \"sh\", args = [\"-c\", \"echo done >> log.txt; echo done\"], stdin = \"\", timeout_ms = 0) @work",
      "  },",
      "  max_iterations = 1",
      ") @loop",
      "return { got = ${rs[0].stdout} }",
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

-- try/catch fixtures (§4.4, 9.9) ---------------------------------------------

tryOkMd :: Text
tryOkMd =
  wrapBody
    [ "x <- try {",
      "  a <- builtin/exec(program = \"sh\", args = [\"-c\", \"echo OK\"], stdin = \"\", timeout_ms = 0) @work",
      "} catch {",
      "  b <- builtin/exec(program = \"sh\", args = [\"-c\", \"echo CATCH\"], stdin = \"\", timeout_ms = 0) @recover",
      "} @safe",
      "return { out = ${x.stdout} }"
    ]
    []
    [("out", "String")]

tryFailMd :: Text
tryFailMd =
  wrapBody
    [ "x <- try {",
      "  a <- builtin/read-file(path = \"missing.txt\") @fail",
      "} catch {",
      "  b <- builtin/read-file(path = \"good.txt\") @recover",
      "} @safe",
      "return { out = ${x.text} }"
    ]
    []
    [("out", "String")]

tryCatchFailMd :: Text
tryCatchFailMd =
  wrapBody
    [ "_ <- try {",
      "  a <- builtin/read-file(path = \"missing1.txt\") @fail",
      "} catch {",
      "  c1 <- builtin/exec(program = \"sh\", args = [\"-c\", \"echo catch1 >> log.txt\"], stdin = \"\", timeout_ms = 0) @rc1",
      "  c2 <- builtin/read-file(path = \"missing2.txt\") @rc2",
      "} @safe",
      "return { ok = true }"
    ]
    []
    [("ok", "Bool")]

tryPartialMd :: Text
tryPartialMd =
  wrapBody
    [ "x <- try {",
      "  _ <- builtin/exec(program = \"sh\", args = [\"-c\", \"echo partial >> log.txt\"], stdin = \"\", timeout_ms = 0) @prep",
      "  a <- builtin/read-file(path = \"missing.txt\") @fail",
      "} catch {",
      "  b <- builtin/read-file(path = \"good.txt\") @recover",
      "} @safe",
      "return { out = ${x.text} }"
    ]
    []
    [("out", "String")]

parCollectMd :: Text
parCollectMd =
  wrapBody
    [ "rs <- par(on_error = \"collect\") path in ${inputs.paths} {",
      "  r <- builtin/read-file(path = ${path}) @read",
      "} @fan",
      "return { ok0 = ${rs[0].ok}, ok1 = ${rs[1].ok}, ok2 = ${rs[2].ok} }"
    ]
    [("paths", "List<String>")]
    [("ok0", "Bool"), ("ok1", "Bool"), ("ok2", "Bool")]

parPaths3 :: Map.Map Ident RValue
parPaths3 =
  Map.fromList
    [ ("paths", VList [VString "good.txt", VString "bad.txt", VString "good.txt"])
    ]

-- Assertions helpers ---------------------------------------------------------

stepStarts :: Ident -> [TraceEvent] -> Int
stepStarts sid evs = length [() | TraceEvent _ _ (StepStart _ s _ _ _) <- evs, s == sid]

loopIters :: [TraceEvent] -> Int
loopIters evs = length [() | TraceEvent _ _ (LoopIter {}) <- evs]

-- | Step-starts for @sid@ that occur /after/ the resume marker, i.e. steps
-- that actually re-executed on resume (the resumed trace also carries the
-- prior attempt's events).
resumedStepStarts :: Ident -> [TraceEvent] -> Int
resumedStepStarts sid evs = stepStarts sid afterResume_
  where
    afterResume_ = drop 1 (dropWhile (not . isResumed) evs)
    isResumed (TraceEvent _ _ (Resumed {})) = True
    isResumed _ = False

llmCalls :: [TraceEvent] -> Int
llmCalls evs = length [() | TraceEvent _ _ (LlmCall {}) <- evs]

lineCount :: FilePath -> IO Int
lineCount p = length . filter (not . T.null) . T.lines <$> TIO.readFile p

tryBranches :: Ident -> [TraceEvent] -> [Text]
tryBranches tid evs =
  [b | TraceEvent _ _ (TryBranch _ tid' b) <- evs, tid' == tid]

afterResume :: [TraceEvent] -> [TraceEvent]
afterResume evs =
  case dropWhile (not . isResumed) evs of
    (_ : rest) -> rest
    [] -> evs
  where
    isResumed (TraceEvent _ _ (Resumed {})) = True
    isResumed _ = False

errorEvents :: Ident -> [TraceEvent] -> Int
errorEvents sid evs =
  length [() | TraceEvent _ _ (ErrorEvent _ s _ _) <- evs, s == sid]

-- | Drop trace lines after the first @error@ for @sid@, simulating a kill
-- before the catch arm starts (§4.4.6 T5).
truncateTraceAfterError :: RunStore -> Ident -> IO ()
truncateTraceAfterError store sid = do
  contents <- TIO.readFile (rsTracePath store)
  let lines' = filter (not . T.null) (T.lines contents)
  case findErrorLine sid lines' of
    Nothing -> pure ()
    Just ix -> TIO.writeFile (rsTracePath store) (T.unlines (take (ix + 1) lines'))
  where
    findErrorLine s ls =
      listToMaybe
        [ i
          | (i, l) <- zip [0 ..] ls,
            Just ev <- [parseTraceLine l],
            ErrorEvent _ s' _ _ <- [teBody ev],
            s' == s
        ]

-- | Drop trace lines after @step-end@ for @sid@, simulating a kill mid-catch
-- (§4.4.6 T6).
truncateTraceAfterStepEnd :: RunStore -> Ident -> IO ()
truncateTraceAfterStepEnd store sid = do
  contents <- TIO.readFile (rsTracePath store)
  let lines' = filter (not . T.null) (T.lines contents)
  case findStepEndLine sid lines' of
    Nothing -> pure ()
    Just ix -> TIO.writeFile (rsTracePath store) (T.unlines (take (ix + 1) lines'))
  where
    findStepEndLine s ls =
      listToMaybe
        [ i
          | (i, l) <- zip [0 ..] ls,
            Just ev <- [parseTraceLine l],
            StepEnd _ s' _ _ _ <- [teBody ev],
            s' == s
        ]

parseTraceLine :: Text -> Maybe TraceEvent
parseTraceLine line = eventFromJson =<< Aeson.decodeStrict (TEnc.encodeUtf8 line)

runAbortAfter ::
  Text ->
  Map.Map Ident RValue ->
  (RunStore -> IO ()) ->
  (RunResult -> RunResult -> IO a) ->
  IO a
runAbortAfter mainMd inputs truncate_ k = do
  withSystemTempDirectory "hwfi-try-proj" $ \proj ->
    withSystemTempDirectory "hwfi-try-ws" $ \ws -> do
      writeProject proj mainMd
      TIO.writeFile (ws </> "good.txt") "ok\n"
      tp <- loadChecked proj
      workspace <- newWorkspace ws
      r1 <- expectRun =<< performRun tp workspace Map.empty Map.empty proj "run-1" mainQ inputs
      Right store <- openRunStore (workspaceRoot workspace) "run-1"
      truncate_ store
      updateRunPhase store PhaseAborted
      r2 <- expectRun =<< performContinueToEnd tp workspace Map.empty Map.empty "run-1" False
      k r1 r2

expectRun :: Either Text RunResult -> IO RunResult
expectRun = either (\e -> error ("run failed: " <> T.unpack e)) pure

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

    it "runs nested foreach loops and preserves two-dimensional order" $
      runProject nestedForeachMd nestedGroups $ \rr ws -> do
        rrOutcome rr `shouldBe` Right (VRecord (Map.fromList [("got", VString "c\n")]))
        lineCount (ws </> "log.txt") `shouldReturn` 3
        loopIters (rrEvents rr) `shouldBe` 5

    it "type-checks nested foreach" $
      errKinds <$> checkOnly nestedForeachMd `shouldReturn` []

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

    it "accepts return inside a foreach body as the iteration value" $ do
      let md =
            wrapBody
              [ "rows <- foreach it in ${inputs.items} {",
                "  return { out = ${it} }",
                "} @loop",
                "return { got = ${rows[0].out} }"
              ]
              [("items", "List<String>")]
              [("got", "String")]
      errKinds <$> checkOnly md `shouldReturn` []

    it "runs foreach with return in the body and collects record results" $
      runProject returnForeachMd items3 $ \rr _ -> do
        rrOutcome rr
          `shouldBe` Right (VRecord (Map.fromList [("got", VString "a")]))

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

    it "runs an inline body block and collects List<U> results (§4.3.7)" $
      runProjectWithSubs inlineWhileMainMd inlineWhileSubs Map.empty $ \rr ws -> do
        case rrOutcome rr of
          Left err -> reKind err `shouldBe` KUser
          Right _ -> expectationFailure "expected max_iterations user error"
        lineCount (ws </> "log.txt") `shouldReturn` 1
        loopIters (rrEvents rr) `shouldBe` 2

    it "accepts carry inside an inline while body when the body type is known (§4.3.7)" $ do
      let md =
            wrapBodyWithImports
              ["workflows/pred"]
              [ "rs <- while(",
                "  predicate = workflows/pred,",
                "  predicate_args = { stop = false },",
                "  body = {",
                "    r <- builtin/exec(program = \"sh\", args = [\"-c\", \"echo hi\"], stdin = \"\", timeout_ms = 0) @work",
                "    t <- builtin/exec(program = \"sh\", args = [\"-c\", \"echo ${carry.stdout}\"], stdin = \"\", timeout_ms = 0) @carry",
                "  },",
                "  max_iterations = 2",
                ") @loop",
                "return { got = \"x\" }"
              ]
              []
              [("got", "String")]
      errKinds <$> checkOnlyWithSubs md inlineWhileSubs `shouldReturn` []

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

  describe "try/catch (§4.4, 9.9)" $ do
    it "T1: try succeeds and catch never runs" $
      runProject tryOkMd Map.empty $ \rr _ -> do
        rrOutcome rr `shouldBe` Right (VRecord (Map.fromList [("out", VString "OK\n")]))
        tryBranches "safe" (rrEvents rr) `shouldBe` ["try"]
        stepStarts "recover" (rrEvents rr) `shouldBe` 0

    it "T2: try step fails, emits error, and catch runs" $
      runProject tryFailMd Map.empty $ \rr _ -> do
        rrOutcome rr `shouldBe` Right (VRecord (Map.fromList [("out", VString "ok\n")]))
        tryBranches "safe" (rrEvents rr) `shouldBe` ["try", "catch"]
        errorEvents "fail" (rrEvents rr) `shouldBe` 1
        stepStarts "recover" (rrEvents rr) `shouldBe` 1

    it "T3: catch failure aborts the run (not caught by the same try)" $
      runProject tryCatchFailMd Map.empty $ \rr _ -> do
        case rrOutcome rr of
          Left err -> reKind err `shouldSatisfy` (/= KInternal)
          Right _ -> expectationFailure "expected catch arm failure"
        tryBranches "safe" (rrEvents rr) `shouldBe` ["try", "catch"]
        errorEvents "fail" (rrEvents rr) `shouldBe` 1
        errorEvents "rc2" (rrEvents rr) `shouldBe` 1

    it "T4: try partial mutation is retained when catch runs" $
      runProject tryPartialMd Map.empty $ \rr ws -> do
        rrOutcome rr `shouldBe` Right (VRecord (Map.fromList [("out", VString "ok\n")]))
        lineCount (ws </> "log.txt") `shouldReturn` 1
        TIO.readFile (ws </> "log.txt") >>= (`shouldSatisfy` T.isInfixOf "partial")

    it "T5: resume after try failure before catch re-runs try, not catch" $
      runAbortAfter tryFailMd Map.empty (`truncateTraceAfterError` "fail") $ \_r1 r2 -> do
        "try" `elem` tryBranches "safe" (afterResume (rrEvents r2)) `shouldBe` True
        resumedStepStarts "fail" (rrEvents r2) `shouldBe` 1

    it "T6: resume mid-catch continues catch only" $
      runAbortAfter tryCatchFailMd Map.empty (`truncateTraceAfterStepEnd` "rc1") $ \_r1 r2 -> do
        resumedStepStarts "fail" (rrEvents r2) `shouldBe` 0
        resumedStepStarts "prep" (rrEvents r2) `shouldBe` 0
        resumedStepStarts "rc1" (rrEvents r2) `shouldBe` 0
        resumedStepStarts "rc2" (rrEvents r2) `shouldBe` 1

    it "T7: resume after full success does not re-execute" $
      runThenResume tryOkMd Map.empty $ \_ r2 _ -> do
        resumedStepStarts "work" (rrEvents r2) `shouldBe` 0
        resumedStepStarts "recover" (rrEvents r2) `shouldBe` 0

  describe "par(on_error = collect) (§4.1.1, 9.9)" $ do
    it "runs all iterations and wraps failures in envelope records" $
      withSystemTempDirectory "hwfi-par-collect" $ \ws ->
        withSystemTempDirectory "hwfi-par-collect-proj" $ \proj -> do
          writeProject proj parCollectMd
          TIO.writeFile (ws </> "good.txt") "ok\n"
          tp <- loadChecked proj
          workspace <- newWorkspace ws
          rr <- expectRun =<< performRun tp workspace Map.empty Map.empty proj "run-1" mainQ parPaths3
          rrOutcome rr
            `shouldBe` Right
              ( VRecord
                  ( Map.fromList
                      [ ("ok0", VBool True),
                        ("ok1", VBool False),
                        ("ok2", VBool True)
                      ]
                  )
              )
          loopIters (rrEvents rr) `shouldBe` 3
          errorEvents "read" (rrEvents rr) `shouldBe` 1

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
