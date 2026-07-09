{-# LANGUAGE OverloadedRecordDot #-}

module Hwfi.Runtime.SkillSpec (spec) where

import Control.Exception (bracket)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Hwfi.Ast.Name (QName, qnameFromText, renderQName)
import Hwfi.Check (checkProject)
import Hwfi.Parse.Project (loadProject)
import Hwfi.Runtime.Builtins (BuiltinEnv (..), runBuiltin)
import Hwfi.Runtime.Error (StepRef (..))
import Hwfi.Runtime.Executor (RunResult (..), performRun)
import Hwfi.Runtime.RunStore
  ( RunMeta (..),
    RunPhase (..),
    RunStore,
    createRunStore,
    openTraceAppend,
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
    newTracer,
    sliceTrace,
  )
import Hwfi.Runtime.Usage (UsageSeam (..), newUsageSeam)
import Hwfi.Runtime.Value (RValue (..))
import Hwfi.Runtime.Workspace (Workspace, newWorkspace)
import Hwfi.TypedProject (TypedProject)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO (Handle, hClose)
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = describe "skills and trace-slice (§6.6)" $ do
  describe "sliceTrace" $ do
    it "include_nested=false keeps agent events but drops nested sub-workflow events" $ do
      let sliced = sliceTrace agentTrace wfQ "agent" False
          tags = map eventTag sliced
      tags
        `shouldBe`
          [ "step-start",
            "agent-round-start",
            "agent-tool-call",
            "agent-tool-result",
            "agent-round-end",
            "step-end"
          ]

    it "include_nested=true includes nested sub-workflow events under the agent step" $ do
      let sliced = sliceTrace agentTrace wfQ "agent" True
          tags = map eventTag sliced
      tags
        `shouldSatisfy` \ts ->
          "step-start" `elem` ts
            && "agent-tool-call" `elem` ts
            && "agent-tool-result" `elem` ts
            && any (== "tools/helper") (mapMaybe eventQname sliced)

  it "A38: builtin/trace-slice with include_nested=true includes agent-tool-call/result" $
    withSystemTempDirectory "hwfi-a38" $ \root -> do
      ws <- newWorkspace root
      seedAgentTrace root "run-a38"
      store <- createRunStore root "run-slice"
      tracer <- newTracer
      usageSeam <- newUsageSeam store Nothing emptyRunUsage
      let benv =
            BuiltinEnv
              { beWorkspace = ws,
                beModels = Map.empty,
                beTracer = tracer,
                beStep = StepRef wfQ "slice",
                beExecPolicy = Nothing,
                beUsage = usageSeam,
                beIntrospect = pure Null,
                beEvalWorkflow = Nothing,
                beRunId = "run-slice"
              }
          args =
            Map.fromList
              [ ("run_id", VString "run-a38"),
                ("qname", VString "workflows/fix"),
                ("step_id", VString "agent"),
                ("include_nested", VBool True)
              ]
      result <- runBuiltin benv (qnameFromText "builtin/trace-slice") args
      case result of
        Left err -> expectationFailure ("builtin failed: " <> show err)
        Right (VRecord m) -> do
          Map.lookup "ok" m `shouldBe` Just (VBool True)
          case Map.lookup "events" m of
            Just (VList evs) -> do
              let tags = mapMaybe jsonTag evs
              "agent-tool-call" `elem` tags `shouldBe` True
              "agent-tool-result" `elem` tags `shouldBe` True
              any (== "tools/helper") (mapMaybe jsonQname evs) `shouldBe` True
            _ -> expectationFailure "expected events list"

  it "A39: a declaration under skills/ type-checks and is callable like tools/" $
    withSkillsProject $ \tp ws projDir -> do
      result <-
        performRun
          tp
          ws
          Map.empty
          Map.empty
          projDir
          "run-a39"
          mainQ
          (Map.singleton "name" (VString "Ada"))
      case result of
        Left msg -> expectationFailure ("run failed: " <> T.unpack msg)
        Right (RunResult (Right (VRecord outs)) _) ->
          Map.lookup "greeting" outs `shouldBe` Just (VString "Hi Ada")
        _ -> expectationFailure "expected successful run"

-- Fixtures -------------------------------------------------------------------

wfQ :: QName
wfQ = qnameFromText "workflows/fix"

helperQ :: QName
helperQ = qnameFromText "tools/helper"

agentTrace :: [TraceEvent]
agentTrace =
  [ ev 0 (RunStart "run-a38" "workflows/fix" (object []) "abc"),
    ev 1 (StepStart wfQ "agent" (object []) False),
    ev 2 (AgentRoundStart wfQ "agent" 0),
    ev 3 (AgentToolCall wfQ "agent" 0 0 "tools/read-file" (object ["path" .= ("x.txt" :: String)])),
    ev 4 (StepStart helperQ "call" (object []) True),
    ev 5 (FileIo helperQ "call" OpRead "x.txt" 3),
    ev 6 (StepEnd helperQ "call" (object []) 1),
    ev 7 (AgentToolResult wfQ "agent" 0 0 "tools/read-file" (object ["text" .= ("hi" :: String)]) False),
    ev 8 (AgentRoundEnd wfQ "agent" 0 True),
    ev 9 (StepEnd wfQ "agent" (object []) 42)
  ]
  where
    ev n = TraceEvent n "2026-07-09T10:00:00.000Z"

eventTag :: TraceEvent -> Text
eventTag (TraceEvent _ _ body) = case body of
  StepStart {} -> "step-start"
  StepEnd {} -> "step-end"
  AgentRoundStart {} -> "agent-round-start"
  AgentToolCall {} -> "agent-tool-call"
  AgentToolResult {} -> "agent-tool-result"
  AgentRoundEnd {} -> "agent-round-end"
  FileIo {} -> "file-io"
  RunStart {} -> "run-start"
  _ -> "other"

eventQname :: TraceEvent -> Maybe Text
eventQname (TraceEvent _ _ body) = renderQName <$> eventStepQname body

eventStepQname :: EventBody -> Maybe QName
eventStepQname = \case
  StepStart q _ _ _ -> Just q
  StepEnd q _ _ _ -> Just q
  FileIo q _ _ _ _ -> Just q
  _ -> Nothing

jsonTag :: RValue -> Maybe Text
jsonTag (VJson (Object o)) = case KM.lookup (Key.fromString "tag") o of
  Just (String t) -> Just t
  _ -> Nothing
jsonTag _ = Nothing

jsonQname :: RValue -> Maybe Text
jsonQname (VJson (Object o)) = case KM.lookup (Key.fromString "qname") o of
  Just (String t) -> Just t
  _ -> Nothing
jsonQname _ = Nothing

mainQ :: QName
mainQ = qnameFromText "workflows/main"

seedAgentTrace :: FilePath -> Text -> IO ()
seedAgentTrace root runId = do
  store <- createRunStore root runId
  writeRunMeta
    store
    RunMeta
      { rmRunId = runId,
        rmEntrypoint = "workflows/fix",
        rmProjectDir = "/tmp/proj",
        rmStartedAt = "2026-07-09T10:00:00.000Z",
        rmProjectHash = "abc",
        rmInputs = object [],
        rmPhase = PhaseCompleted,
        rmUsage = emptyRunUsage
      }
  bracketTrace store $ \_ tracer ->
    mapM_ (emit tracer . (.teBody)) agentTrace

bracketTrace :: RunStore -> (Handle -> Tracer -> IO a) -> IO a
bracketTrace store k =
  bracket (openTraceAppend store) hClose $ \h -> do
    tracer <- newPersistentTracer h [] 0
    k h tracer

withSkillsProject :: (TypedProject -> Workspace -> FilePath -> IO a) -> IO a
withSkillsProject k =
  withSystemTempDirectory "hwfi-skills" $ \dir -> do
    writeSkillsProject dir
    tp <- loadChecked dir
    ws <- newWorkspace dir
    k tp ws dir

loadChecked :: FilePath -> IO TypedProject
loadChecked dir = do
  eproj <- loadProject dir
  case eproj of
    Left ds -> error ("fixture parse failed: " <> show ds)
    Right proj -> case checkProject proj of
      Left errs -> error ("fixture check failed: " <> show errs)
      Right tp -> pure tp

writeSkillsProject :: FilePath -> IO ()
writeSkillsProject dir = do
  createDirectoryIfMissing True (dir </> "workflows")
  createDirectoryIfMissing True (dir </> "skills")
  TIO.writeFile (dir </> "project.json") skillsProjectJson
  TIO.writeFile (dir </> "model-catalog.json") "[]\n"
  TIO.writeFile (dir </> "skills" </> "greet.md") skillsGreetMd
  TIO.writeFile (dir </> "workflows" </> "main.md") skillsMainMd

skillsProjectJson :: Text
skillsProjectJson =
  "{\n  \"name\": \"skills-ok\",\n  \"version\": \"0.1.0\",\n  \"entrypoint\": \"workflows/main\",\n  \"env\": []\n}\n"

skillsGreetMd :: Text
skillsGreetMd =
  T.unlines
    [ "---",
      "name: skills/greet",
      "inputs:",
      "  name: String",
      "outputs:",
      "  greeting: String",
      "---",
      "",
      "```step",
      "return { greeting = \"Hi ${inputs.name}\" }",
      "```"
    ]

skillsMainMd :: Text
skillsMainMd =
  T.unlines
    [ "---",
      "name: workflows/main",
      "inputs:",
      "  name: String",
      "outputs:",
      "  greeting: String",
      "imports:",
      "  - skills/greet",
      "---",
      "",
      "```step",
      "g <- skills/greet(name = ${inputs.name})",
      "return { greeting = ${g.greeting} }",
      "```"
    ]
