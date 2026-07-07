{-# LANGUAGE OverloadedRecordDot #-}

module Hwfi.Runtime.AgentSpec (spec) where

import Data.Aeson (Value (..), object, (.=))
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Vector qualified as V
import Hwfi.Ast.Name (Ident, QName, qnameFromText)
import Hwfi.Runtime.Agent
  ( AdvertisedTool (..),
    AgentEnv (..),
    AgentSpec (..),
    SubmitSpec (..),
    advertisedToolDef,
    runAgent,
    sanitizeToolName,
    submitToolDef,
    submitToolName,
  )
import Hwfi.Runtime.Error (ErrorKind (..), RuntimeError (..), internalError, reKind)
import Hwfi.Runtime.RunStore (RunStore, createRunStore)
import Hwfi.Runtime.Trace (EventBody (..), TraceEvent (..), Tracer, newTracer, snapshotEvents)
import Hwfi.Runtime.Value (RValue (..))
import Hwfi.Type (Type (..))
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
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = describe "Agent loop (§6.1)" $ do
  describe "builtin/llm-agent — free-text termination" $ do
    it "drives a tool round then returns the model's final text (A17)" $
      withEnv $ \store tracer -> do
        calls <- newIORef (0 :: Int)
        let gw = scriptedGateway [searchCall "c1", textResp "The answer is 42."]
        res <- runAgent (env store tracer False (countingDispatch calls searchResult)) (textSpec gw)
        res `shouldBe` Right (record [("text", VString "The answer is 42."), ("rounds", VInt 2)])
        readIORef calls `shouldReturn` 1

    it "feeds an unknown tool name back as a recoverable result (§6.1.4)" $
      withEnv $ \store tracer -> do
        calls <- newIORef (0 :: Int)
        let gw = scriptedGateway [toolResp "c1" "does_not_exist" (object []), textResp "done"]
        res <- runAgent (env store tracer False (countingDispatch calls searchResult)) (textSpec gw)
        res `shouldBe` Right (record [("text", VString "done"), ("rounds", VInt 2)])
        -- The unknown tool never reaches dispatch.
        readIORef calls `shouldReturn` 0

    it "fails fatally when max_rounds is exhausted without terminating (§6.1.4)" $
      withEnv $ \store tracer -> do
        calls <- newIORef (0 :: Int)
        let gw = scriptedGateway [searchCall "c1", searchCall "c2", searchCall "c3"]
            spec' = (textSpec gw) {asMaxRounds = 1}
        res <- runAgent (env store tracer False (countingDispatch calls searchResult)) spec'
        reKind (fromLeft res) `shouldBe` KLlm

  describe "builtin/llm-agent-object — submit termination" $ do
    it "returns the validated submit payload as the typed value (A19)" $
      withEnv $ \store tracer -> do
        calls <- newIORef (0 :: Int)
        let gw = scriptedGateway [searchCall "c1", submitCall "c2" (object ["answer" .= ("42" :: Text)])]
        res <- runAgent (env store tracer False (countingDispatch calls searchResult)) (objectSpec gw)
        res `shouldBe` Right (record [("value", VJson (object ["answer" .= ("42" :: Text)])), ("rounds", VInt 2)])

    it "rejects a round mixing submit with another call, then accepts submit alone (§6.1.3)" $
      withEnv $ \store tracer -> do
        calls <- newIORef (0 :: Int)
        let gw =
              scriptedGateway
                [ mixedResp,
                  submitCall "c9" (object ["answer" .= ("late" :: Text)])
                ]
        res <- runAgent (env store tracer False (countingDispatch calls searchResult)) (objectSpec gw)
        res `shouldBe` Right (record [("value", VJson (object ["answer" .= ("late" :: Text)])), ("rounds", VInt 2)])
        evs <- snapshotEvents tracer
        any recoverableToolResult evs `shouldBe` True

    it "feeds a schema-invalid submit back as recoverable, then accepts a valid one (§6.1.3)" $
      withEnv $ \store tracer -> do
        calls <- newIORef (0 :: Int)
        let gw =
              scriptedGateway
                [ submitCall "c1" (object ["wrong" .= ("x" :: Text)]),
                  submitCall "c2" (object ["answer" .= ("ok" :: Text)])
                ]
        res <- runAgent (env store tracer False (countingDispatch calls searchResult)) (objectSpec gw)
        res `shouldBe` Right (record [("value", VJson (object ["answer" .= ("ok" :: Text)])), ("rounds", VInt 2)])

  describe "intra-step caching and resume (§8.2.1, A21)" $ do
    it "replays cached model and tool calls without re-invoking either on resume" $
      withEnv $ \store tracer -> do
        calls <- newIORef (0 :: Int)
        let liveGw = scriptedGateway [searchCall "c1", textResp "cached answer"]
        primed <- runAgent (env store tracer False (countingDispatch calls searchResult)) (textSpec liveGw)
        primed `shouldBe` Right (record [("text", VString "cached answer"), ("rounds", VInt 2)])
        readIORef calls `shouldReturn` 1
        -- Resume against a gateway/dispatch that fail if touched: the cache must
        -- satisfy every model and tool call.
        tracer2 <- newTracer
        resumed <-
          runAgent
            (env store tracer2 True explodingDispatch)
            (textSpec explodingGateway)
        resumed `shouldBe` primed

-- Fixtures -------------------------------------------------------------------

searchQ :: QName
searchQ = qnameFromText "tools/search"

mainQ :: QName
mainQ = qnameFromText "workflows/main"

searchTool :: AdvertisedTool
searchTool =
  AdvertisedTool
    { atQName = searchQ,
      atToolDef = advertisedToolDef searchQ [("query", TyString)],
      atInputs = [("query", TyString)],
      atFingerprint = "search-fp-v1"
    }

textSpec :: LLMGateway -> AgentSpec
textSpec gw =
  AgentSpec
    { asSystem = "You are a test agent.",
      asPrompt = "What is the answer?",
      asModelName = "fast",
      asModel = modelWith gw,
      asModelFingerprint = "fast|fake|256",
      asTools = [searchTool],
      asMaxRounds = 4,
      asSubmit = Nothing
    }

objectSpec :: LLMGateway -> AgentSpec
objectSpec gw = (textSpec gw) {asSubmit = Just submitSpec}

submitSpec :: SubmitSpec
submitSpec =
  SubmitSpec
    { ssSchema = submitSchema,
      ssToolDef = submitToolDef submitSchema
    }

submitSchema :: Value
submitSchema =
  object
    [ "type" .= ("object" :: Text),
      "properties" .= object ["answer" .= object ["type" .= ("string" :: Text)]],
      "required" .= Array (V.fromList [String "answer"]),
      "additionalProperties" .= False
    ]

-- Environment ----------------------------------------------------------------

withEnv :: (RunStore -> Tracer -> IO a) -> IO a
withEnv k =
  withSystemTempDirectory "hwfi-agent" $ \dir -> do
    store <- createRunStore dir "run-agent"
    tracer <- newTracer
    k store tracer

env ::
  RunStore ->
  Tracer ->
  Bool ->
  (QName -> Ident -> Map Ident RValue -> IO (Either RuntimeError RValue)) ->
  AgentEnv
env store tracer resume dispatch =
  AgentEnv
    { aeTracer = tracer,
      aeStore = store,
      aeResume = resume,
      aeQName = mainQ,
      aeStepId = "agent",
      aeStepKey = "step-key-fixed",
      aeDispatch = dispatch
    }

-- | A dispatch that returns a canned result and counts invocations.
countingDispatch ::
  IORef Int ->
  RValue ->
  QName ->
  Ident ->
  Map Ident RValue ->
  IO (Either RuntimeError RValue)
countingDispatch calls result _ _ _ = do
  modifyIORef' calls (+ 1)
  pure (Right result)

-- | A dispatch that must never be called (resume should hit the cache).
explodingDispatch :: QName -> Ident -> Map Ident RValue -> IO (Either RuntimeError RValue)
explodingDispatch _ _ _ = pure (Left (internalError "dispatch invoked during a fully-cached resume"))

searchResult :: RValue
searchResult = record [("hits", VList [VString "result A", VString "result B"])]

-- Fake gateway ---------------------------------------------------------------

modelWith :: LLMGateway -> ModelWithFallbacks
modelWith gw = ModelWithFallbacks (config gw) []

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

-- | A gateway that answers with a scripted response per round, where the round
-- index is the number of tool turns already in the conversation.
scriptedGateway :: [ChatResponse] -> LLMGateway
scriptedGateway responses = gatewayOf $ \req ->
  let i = length [() | ToolTurn _ <- req.reqConversation]
   in pure $
        if i < length responses
          then Right (responses !! i)
          else Left EmptyResponse

-- | A gateway that fails if invoked (used to prove resume never calls it).
explodingGateway :: LLMGateway
explodingGateway = gatewayOf (\_ -> pure (Left (NetworkError "gateway invoked during a fully-cached resume")))

gatewayOf :: (ChatRequest -> IO (Either LLMError ChatResponse)) -> LLMGateway
gatewayOf f =
  LLMGateway
    { gwName = "fake",
      gwGenerateText = \_hooks req -> f req,
      gwStreamText = \_ _ _ -> pure (Left EmptyResponse),
      gwGenerateObject = \_ _ _ -> pure (Left EmptyResponse)
    }

-- Scripted responses ---------------------------------------------------------

usage :: Usage
usage = Usage 5 7 0

toolResp :: Text -> Text -> Value -> ChatResponse
toolResp cid name args =
  ChatResponse "" [ToolCallBlock (mkToolCall cid name args)] (Just usage) Nothing

searchCall :: Text -> ChatResponse
searchCall cid = toolResp cid (sanitizeToolName searchQ) (object ["query" .= ("haskell" :: Text)])

submitCall :: Text -> Value -> ChatResponse
submitCall cid args = toolResp cid submitToolName args

textResp :: Text -> ChatResponse
textResp t = ChatResponse t [TextBlock t] (Just usage) Nothing

-- | A response mixing a submit call with a regular tool call in one round.
mixedResp :: ChatResponse
mixedResp =
  ChatResponse
    ""
    [ ToolCallBlock (mkToolCall "s1" submitToolName (object ["answer" .= ("early" :: Text)])),
      ToolCallBlock (mkToolCall "t1" (sanitizeToolName searchQ) (object ["query" .= ("x" :: Text)]))
    ]
    (Just usage)
    Nothing

-- Helpers --------------------------------------------------------------------

record :: [(Ident, RValue)] -> RValue
record = VRecord . Map.fromList

fromLeft :: Either RuntimeError RValue -> RuntimeError
fromLeft (Left e) = e
fromLeft (Right v) = error ("expected Left, got " <> show v)

recoverableToolResult :: TraceEvent -> Bool
recoverableToolResult (TraceEvent _ _ (AgentToolResult _ _ _ _ _ _ recov)) = recov
recoverableToolResult _ = False
