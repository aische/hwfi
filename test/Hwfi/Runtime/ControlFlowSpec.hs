module Hwfi.Runtime.ControlFlowSpec (spec) where

import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Hwfi.Ast.Name (Ident, QName, qnameFromText)
import Hwfi.Check (checkProject)
import Hwfi.Check.Error (TypeError (..), TypeErrorKind (..))
import Hwfi.Parse.Project (loadProject)
import Hwfi.Runtime.Executor (RunResult (..), performResume, performRun)
import Hwfi.Runtime.RunStore (RunPhase (..), openRunStore, updateRunPhase)
import Hwfi.Runtime.Trace (EventBody (..), TraceEvent (..))
import Hwfi.Runtime.Value (RValue (..))
import Hwfi.Runtime.Workspace (newWorkspace, workspaceRoot)
import Hwfi.TypedProject (TypedProject)
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
writeProject dir mainMd = do
  createDirectoryIfMissing True (dir </> "workflows")
  TIO.writeFile (dir </> "project.json") projectJson
  TIO.writeFile (dir </> "model-catalog.json") "[]\n"
  TIO.writeFile (dir </> "workflows" </> "main.md") mainMd

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
runProject mainMd inputs k =
  withSystemTempDirectory "hwfi-cf-proj" $ \proj ->
    withSystemTempDirectory "hwfi-cf-ws" $ \ws -> do
      writeProject proj mainMd
      tp <- loadChecked proj
      workspace <- newWorkspace ws
      res <- performRun tp workspace Map.empty Map.empty proj "run-1" mainQ inputs
      case res of
        Left e -> error ("run failed: " <> T.unpack e)
        Right rr -> k rr ws

-- | Run to completion, mark the run resumable (aborted), then resume.
runThenResume :: Text -> Map.Map Ident RValue -> (RunResult -> RunResult -> FilePath -> IO a) -> IO a
runThenResume mainMd inputs k =
  withSystemTempDirectory "hwfi-cf-proj" $ \proj ->
    withSystemTempDirectory "hwfi-cf-ws" $ \ws -> do
      writeProject proj mainMd
      tp <- loadChecked proj
      workspace <- newWorkspace ws
      r1 <- expectRun =<< performRun tp workspace Map.empty Map.empty proj "run-1" mainQ inputs
      Right store <- openRunStore (workspaceRoot workspace) "run-1"
      updateRunPhase store PhaseAborted
      r2 <- expectRun =<< performResume tp workspace Map.empty Map.empty "run-1"
      k r1 r2 ws
  where
    expectRun = either (\e -> error ("run failed: " <> T.unpack e)) pure

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

lineCount :: FilePath -> IO Int
lineCount p = length . filter (not . T.null) . T.lines <$> TIO.readFile p

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
        [n | LoopStart _ "loop" "foreach" n <- bodies] `shouldBe` [3]
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

    it "rejects a duplicate step/control-flow id" $ do
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

    it "rejects a return inside a control-flow block" $ do
      let md =
            wrapBody
              ["_ <- foreach it in ${inputs.items} {", "  return { out = \"x\" }", "} @loop", "return { out = \"y\" }"]
              [("items", "List<String>")]
              [("out", "String")]
      errKinds <$> checkOnly md `shouldReturn` [ReturnRule]

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
