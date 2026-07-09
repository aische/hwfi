{-# LANGUAGE OverloadedRecordDot #-}

module Hwfi.Runtime.EvalWorkflowSpec (spec) where

import Data.Aeson (Value (..), object, (.=))
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Hwfi.Ast.Name (Ident, QName, qnameFromText)
import Hwfi.Check (checkProject)
import Hwfi.Compat (ModelConfig (..))
import Hwfi.Parse.Project (loadProject)
import Hwfi.Runtime.Agent
  ( AdvertisedTool (..),
    AgentEnv (..),
    AgentSpec (..),
    advertisedToolDef,
    runAgent,
    sanitizeToolName,
  )
import Hwfi.Runtime.Builtins (BuiltinEnv (..), runBuiltin)
import Hwfi.Runtime.Error (RuntimeError (..), StepRef (..))
import Hwfi.Runtime.EvalWorkflow (EvalWorkflowSeam (..), runEvalWorkflow)
import Hwfi.Runtime.Executor (RunResult (..), performRun)
import Hwfi.Runtime.RunStore (RunStore, createRunStore)
import Hwfi.Runtime.RunUsage (emptyRunUsage)
import Hwfi.Runtime.Trace (Tracer, newTracer)
import Hwfi.Runtime.Usage (UsageSeam (..), newUsageSeam)
import Hwfi.Runtime.Value (RValue (..))
import Hwfi.Runtime.Workspace (Workspace, newWorkspace)
import Hwfi.Type (Type (..))
import Hwfi.TypedProject (TypedProject)
import LLM.Core.Types
  ( ChatRequest (..),
    ChatResponse (..),
    ContentBlock (..),
    LLMError (..),
    LLMGateway (..),
    Turn (..),
    mkToolCall,
  )
import LLM.Core.Usage (PricingInfo (..), Usage (..))
import LLM.Generate.ModelConfig (ModelConfig (..), ModelWithFallbacks (..))
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = describe "builtin/eval-workflow (§6.4)" $ do
  it "returns ok=false for ill-typed source without calling execute (A34 core)" $
    withCheckedProject $ \tp -> do
      let seam =
            EvalWorkflowSeam
              { ewsProject = tp,
                ewsScope = "eval@",
                ewsExecute = \_ _ _ _ -> error "execute must not run for ill-typed source"
              }
      res <- runEvalWorkflow seam illTypedWorkflowSource (Object mempty)
      case res of
        Left err -> expectationFailure ("expected recoverable result, got fatal: " <> show err)
        Right (VRecord m) -> do
          Map.lookup "ok" m `shouldBe` Just (VBool False)
          case Map.lookup "errors" m of
            Just (VList errs) -> errs `shouldSatisfy` not . null
            _ -> expectationFailure "expected errors list"

  it "A34: enclosing run completes when eval-workflow gets ill-typed source" $
    withRunProject $ \tp ws projDir -> do
      result <-
        performRun
          tp
          ws
          Map.empty
          Map.empty
          projDir
          "run-a34"
          mainQ
          (Map.fromList [("src", VString illTypedWorkflowSource)])
      case result of
        Left msg -> expectationFailure ("run failed: " <> T.unpack msg)
        Right (RunResult (Right (VRecord outs)) _) ->
          Map.lookup "got_ok" outs `shouldBe` Just (VBool False)
        _ -> expectationFailure "expected successful run"

  it "runs valid dynamic source and returns ok=true with outputs" $
    withRunProjectGood $ \tp ws projDir -> do
      result <-
        performRun
          tp
          ws
          Map.empty
          Map.empty
          projDir
          "run-ok"
          mainQ
          (Map.fromList [("src", VString goodWorkflowSource)])
      case result of
        Left msg -> expectationFailure ("run failed: " <> T.unpack msg)
        Right (RunResult (Right (VRecord outs)) _) ->
          Map.lookup "succeeded" outs `shouldBe` Just (VBool True)
        _ -> expectationFailure "expected successful run"

  it "A35: agent loop continues after eval-workflow returns ok=false" $
    withAgentHarness $ \store tracer usageSeam ws tp -> do
      calls <- newIORef (0 :: Int)
      let seam =
            EvalWorkflowSeam
              { ewsProject = tp,
                ewsScope = "agent@t0@",
                ewsExecute = \_ _ _ _ -> pure (Right (VRecord mempty))
              }
          benv =
            BuiltinEnv
              { beWorkspace = ws,
                beModels = Map.empty,
                beTracer = tracer,
                beStep = StepRef mainQ "agent",
                beExecPolicy = Nothing,
                beUsage = usageSeam,
                beIntrospect = pure Null,
                beEvalWorkflow = Just seam,
                beRunId = "run-agent"
              }
          dispatch q _sid args = do
            modifyIORef' calls (+ 1)
            runBuiltin benv q args
          evalToolName = sanitizeToolName evalQ
          gw =
            scriptedGateway
              [ toolResp
                  "c1"
                  evalToolName
                  ( object
                      [ "source" .= illTypedWorkflowSource,
                        "inputs" .= (object [] :: Value)
                      ]
                  ),
                textResp "done"
              ]
          agentSpec =
            AgentSpec
              { asSystem = "test",
                asPrompt = "test",
                asModelName = "test-model",
                asModel = ModelWithFallbacks (config gw) [],
                asModelFingerprint = "fp",
                asTools =
                  [ AdvertisedTool
                      { atQName = evalQ,
                        atToolDef = advertisedToolDef evalQ [("source", TyString), ("inputs", TyJson)],
                        atInputs = [("source", TyString), ("inputs", TyJson)],
                        atFingerprint = "eval-fp"
                      }
                    ],
                asMaxRounds = 3,
                asSubmit = Nothing
              }
      res <- runAgent (agentEnv store tracer usageSeam False dispatch) agentSpec
      res `shouldBe` Right (record [("text", VString "done"), ("rounds", VInt 2)])
      nCalls <- readIORef calls
      nCalls `shouldBe` 1

-- Fixtures -------------------------------------------------------------------

mainQ :: QName
mainQ = qnameFromText "workflows/main"

evalQ :: QName
evalQ = qnameFromText "builtin/eval-workflow"

illTypedWorkflowSource :: Text
illTypedWorkflowSource =
  T.unlines
    [ "---",
      "name: workflows/dynamic",
      "inputs:",
      "  x: String",
      "outputs:",
      "  y: Int",
      "imports:",
      "  - builtin/read-file",
      "---",
      "",
      "```step",
      "c <- builtin/read-file(path = ${inputs.x})",
      "return { y = ${c.text} }",
      "```"
    ]

goodWorkflowSource :: Text
goodWorkflowSource =
  T.unlines
    [ "---",
      "name: workflows/dynamic",
      "inputs: {}",
      "outputs:",
      "  done: Bool",
      "---",
      "",
      "```step",
      "return { done = true }",
      "```"
    ]

withCheckedProject :: (TypedProject -> IO a) -> IO a
withCheckedProject k =
  withSystemTempDirectory "hwfi-eval-check" $ \dir -> do
    writeEvalProject dir evalMainMd
    k =<< loadChecked dir

withRunProject :: (TypedProject -> Workspace -> FilePath -> IO a) -> IO a
withRunProject k =
  withSystemTempDirectory "hwfi-eval-run" $ \dir -> do
    writeEvalProject dir evalMainMd
    tp <- loadChecked dir
    ws <- newWorkspace dir
    k tp ws dir

withRunProjectGood :: (TypedProject -> Workspace -> FilePath -> IO a) -> IO a
withRunProjectGood k =
  withSystemTempDirectory "hwfi-eval-run-ok" $ \dir -> do
    writeEvalProject dir evalMainMdGood
    tp <- loadChecked dir
    ws <- newWorkspace dir
    k tp ws dir

withAgentHarness :: (RunStore -> Tracer -> UsageSeam -> Workspace -> TypedProject -> IO a) -> IO a
withAgentHarness k =
  withSystemTempDirectory "hwfi-eval-agent" $ \dir -> do
    writeEvalProject dir evalMainMd
    tp <- loadChecked dir
    ws <- newWorkspace dir
    store <- createRunStore dir "run-agent"
    tracer <- newTracer
    usageSeam <- newUsageSeam store Nothing emptyRunUsage
    k store tracer usageSeam ws tp

writeEvalProject :: FilePath -> Text -> IO ()
writeEvalProject dir mainMd = do
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

projectJson :: Text
projectJson =
  "{\n  \"name\": \"eval-workflow\",\n  \"version\": \"0.1.0\",\n  \"entrypoint\": \"workflows/main\",\n  \"env\": []\n}\n"

evalMainMd :: Text
evalMainMd =
  T.unlines
    [ "---",
      "name: workflows/main",
      "inputs:",
      "  src: String",
      "outputs:",
      "  got_ok: Bool",
      "imports:",
      "  - builtin/eval-workflow",
      "---",
      "",
      "```step",
      "r <- builtin/eval-workflow(source = ${inputs.src}, inputs = null)",
      "return { got_ok = ${r.ok} }",
      "```"
    ]

evalMainMdGood :: Text
evalMainMdGood =
  T.unlines
    [ "---",
      "name: workflows/main",
      "inputs:",
      "  src: String",
      "outputs:",
      "  succeeded: Bool",
      "imports:",
      "  - builtin/eval-workflow",
      "---",
      "",
      "```step",
      "r <- builtin/eval-workflow(source = ${inputs.src}, inputs = null)",
      "return { succeeded = ${r.ok} }",
      "```"
    ]

-- Agent helpers (adapted from AgentSpec) -------------------------------------

agentEnv ::
  RunStore ->
  Tracer ->
  UsageSeam ->
  Bool ->
  (QName -> Ident -> Map.Map Ident RValue -> IO (Either RuntimeError RValue)) ->
  AgentEnv
agentEnv store tracer usageSeam resume dispatch =
  AgentEnv
    { aeTracer = tracer,
      aeStore = store,
      aeResume = resume,
      aeUsage = usageSeam,
      aeQName = mainQ,
      aeStepId = "agent",
      aeStepKey = "agent-key",
      aeDispatch = dispatch
    }

scriptedGateway :: [ChatResponse] -> LLMGateway
scriptedGateway responses = gatewayOf $ \req ->
  let i = length [() | ToolTurn _ <- req.reqConversation]
   in pure $
        if i < length responses
          then Right (responses !! i)
          else Left EmptyResponse

gatewayOf :: (ChatRequest -> IO (Either LLMError ChatResponse)) -> LLMGateway
gatewayOf f =
  LLMGateway
    { gwName = "fake",
      gwGenerateText = \_hooks req -> f req,
      gwStreamText = \_ _ _ -> pure (Left EmptyResponse),
      gwGenerateObject = \_ _ _ -> pure (Left EmptyResponse)
    }

config :: LLMGateway -> ModelConfig
config gw =
  ModelConfig
    { mcGateway = gw,
      mcModel = "fake",
      mcPricing = PricingInfo 0 0,
      mcMaxTokens = 256,
      mcTemperature = Nothing,
      mcThinking = Nothing,
      mcRequestTimeout = Nothing,
      mcThrottleDelay = Nothing,
      mcRetryCount = 0,
      mcJitterBackoff = 0
    }

usage :: Usage
usage = Usage 5 7 0

toolResp :: Text -> Text -> Value -> ChatResponse
toolResp cid name args =
  ChatResponse "" [ToolCallBlock (mkToolCall cid name args)] (Just usage) Nothing

textResp :: Text -> ChatResponse
textResp t = ChatResponse t [TextBlock t] (Just usage) Nothing

record :: [(Ident, RValue)] -> RValue
record = VRecord . Map.fromList
