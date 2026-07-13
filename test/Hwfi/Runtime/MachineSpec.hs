module Hwfi.Runtime.MachineSpec where

import Data.Aeson (Value (..), object, (.=))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Map.Strict qualified as Map
import Hwfi.Ast.Name (Ident, QName, qnameFromText)
import Hwfi.Ast.Step (Binder (..), ParOnError (..))
import Hwfi.Check (checkProject)
import Hwfi.Compat (ModelConfig (..))
import Hwfi.Parse.Project (loadProject)
import Hwfi.Runtime.Agent (sanitizeToolName)
import Hwfi.Runtime.RunCommon (projectContentHash)
import Hwfi.Runtime.Gateways (ModelStore)
import Hwfi.Runtime.Machine
import Hwfi.Runtime.MachinePar (allSlotsTerminal)
import Hwfi.Runtime.MachinePath (StmtContext (..), advancePath, initialStmtPath, resolveStmtPath)
import Hwfi.Runtime.MachineSnapshot (decodeMachine, encodeMachine)
import Hwfi.Runtime.StepDriver (approveConfirm, pauseMachine, runMachine, stepMachine)
import Hwfi.Runtime.StepEnv (ConfirmPolicy (..), StepEnv (..), StepOutcome (..), newStepEnv)
import Hwfi.Runtime.Value (RValue (..))
import Hwfi.Runtime.Workspace (newWorkspace)
import Hwfi.TypedProject (TypedProject)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import Data.Text.IO qualified as TIO
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
import LLM.Generate.ModelConfig (ModelWithFallbacks (..))
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = do
  describe "Machine snapshot (M0)" $ do
    it "round-trips a minimal running machine" $ do
      let m =
            initialMachine
              ""
              "abc123"
              (qnameFromText "workflows/main")
              Map.empty
      case decodeMachine (encodeMachine m) of
        Left err -> expectationFailure (T.unpack err)
        Right m' -> encodeMachine m' `shouldBe` encodeMachine m

    it "round-trips par and agent-heavy state" $ do
      let confirm =
            ConfirmRequest
              { crBranchIndex = Just 1,
                crQName = qnameFromText "builtin/exec",
                crStepId = "run",
                crTitle = "Run tests?",
                crDetail = object []
              }
          branch =
            initialMachine "loop#0/" "hash" (qnameFromText "workflows/inner") Map.empty
          par =
            ParJoinState
              { pjsLoopId = "items",
                pjsScope = "",
                pjsBinder = BindDiscard,
                pjsMaxConcurrency = 4,
                pjsOnError = ParOnErrorFail,
                pjsItems = [VJson (Number 1), VJson (Number 2)],
                pjsSlots = [ParSlotDone (VJson (Number 10)), ParSlotRunning],
                pjsActive = Map.singleton 1 (mkBranch branch),
                pjsNextIndex = 2,
                pjsPhase = ParDraining,
                pjsConfirmQueue = [confirm],
                pjsLoopPath = StmtPath (qnameFromText "workflows/main") [PathSegment 0 Nothing],
                pjsResumePath = StmtPath (qnameFromText "workflows/main") [PathSegment 1 Nothing],
                pjsParentBindings = Map.empty
              }
          agent =
            AgentState
              { agStepRef = StepRef (qnameFromText "workflows/main") "agent",
                agBinder = BindDiscard,
                agTarget = qnameFromText "builtin/llm-agent",
                agPending =
                  PendingAgent
                    { paSystem = "sys",
                      paPrompt = "go",
                      paModelName = "fast",
                      paMaxRounds = 4,
                      paInitialTools = [],
                      paSubmitSchema = Nothing,
                      paHistory = [UserTurn "hi"],
                      paToolRounds = [],
                      paActiveToolIds = ["builtin/read-file"],
                      paLoadedInstructionIds = [],
                      paInstructionChars = 0,
                      paPendingInjections = []
                    },
                agRound = 2,
                agSubmitRequired = True,
                agToolRound = Nothing
              }
          m =
            (initialMachine "" "hash" (qnameFromText "workflows/main") Map.empty)
              { mStatus = MsPaused (PauseAwaitingConfirm confirm),
                mCurrent = CurAgent agent,
                mFrames = [FrPar par]
              }
      case decodeMachine (encodeMachine m) of
        Left err -> expectationFailure (T.unpack err)
        Right m' -> encodeMachine m' `shouldBe` encodeMachine m

  describe "MachinePath (M0)" $ do
    it "resolves the first statement of a fixture workflow" $ do
      tp <- loadFixture
      case initialStmtPath tp (qnameFromText "workflows/main") of
        Left err -> expectationFailure (T.unpack err)
        Right path ->
          case resolveStmtPath tp path of
            Left err -> expectationFailure (T.unpack err)
            Right ctx -> scIndex ctx `shouldBe` 0

    it "advances to the next sibling index" $ do
      tp <- loadFixture
      path0 <- case initialStmtPath tp (qnameFromText "workflows/main") of
        Left err -> fail (T.unpack err)
        Right p -> pure p
      let path1 = advancePath path0
      case resolveStmtPath tp path1 of
        Left err -> expectationFailure (T.unpack err)
        Right ctx -> scIndex ctx `shouldBe` 1

  describe "StepDriver (M0/M1)" $ do
    it "moves CurReady to CurDispatch on the first step" $
      withSystemTempDirectory "hwfi-m0-ws" $ \ws -> do
        tp <- loadFixture
        workspace <- newWorkspace ws
        env <- newStepEnv tp workspace Map.empty "test" "workflows/main"
        let m0 = initialMachine "" (projectContentHash tp) (qnameFromText "workflows/main") Map.empty
        result <- stepMachine env m0
        case result of
          Left err -> expectationFailure (show err)
          Right (Stepped m1) -> m1.mCurrent `shouldSatisfy` isDispatch
          Right other -> expectationFailure ("unexpected outcome: " <> show other)

    it "pauseMachine sets explicit paused status" $ do
      let m = initialMachine "" "h" (qnameFromText "w") Map.empty
      pauseMachine m `shouldSatisfy` (\m' -> case mStatus m' of MsPaused PauseExplicit -> True; _ -> False)

  describe "StepDriver sequential (M1)" $ do
    it "runs the file-only fixture to completion" $
      withSystemTempDirectory "hwfi-m1-ws" $ \ws -> do
        tp <- loadChecked "test/fixtures/run/file-only"
        createDirectoryIfMissing True ws
        writeFile (ws </> "input.txt") "the source content"
        workspace <- newWorkspace ws
        env <- newStepEnv tp workspace Map.empty "m1-run" "workflows/main"
        let m0 =
              initialMachine
                ""
                (projectContentHash tp)
                (qnameFromText "workflows/main")
                ( Map.fromList
                    [ ("src", VFileRef "input.txt"),
                      ("dst", VFileRef "out.txt")
                    ]
                )
        result <- runMachine env m0
        case result of
          Left err -> expectationFailure (show err)
          Right (RunCompleted (VRecord outs)) ->
            Map.lookup "content" outs `shouldBe` Just (VString "the source content")
          Right other -> expectationFailure ("unexpected outcome: " <> show other)

  describe "StepDriver agent (M2)" $ do
    it "runs the agent-ok fixture to completion" $
      withSystemTempDirectory "hwfi-m2-ws" $ \ws -> do
        tp <- loadChecked "test/fixtures/check/agent-ok"
        workspace <- newWorkspace ws
        baseEnv <- newStepEnv tp workspace Map.empty "m2-agent" "workflows/main"
        let env = withModels baseEnv (scriptedGateway [searchCall "c1", textResp "The answer is 42."])
            m0 =
              initialMachine
                ""
                (projectContentHash tp)
                (qnameFromText "workflows/main")
                (Map.singleton "q" (VString "what is haskell?"))
        result <- runMachine env m0
        case result of
          Left err -> expectationFailure (show err)
          Right (RunCompleted (VRecord outs)) ->
            Map.lookup "answer" outs `shouldBe` Just (VString "The answer is 42.")
          Right other -> expectationFailure ("unexpected outcome: " <> show other)

    it "resumes mid-agent from snapshot without re-invoking the model" $
      withSystemTempDirectory "hwfi-m2-resume" $ \ws -> do
        tp <- loadChecked "test/fixtures/check/agent-ok"
        workspace <- newWorkspace ws
        baseEnv <- newStepEnv tp workspace Map.empty "m2-resume" "workflows/main"
        let liveEnv = withModels baseEnv (scriptedGateway [searchCall "c1", textResp "cached answer"])
            m0 =
              initialMachine
                ""
                (projectContentHash tp)
                (qnameFromText "workflows/main")
                (Map.singleton "q" (VString "question"))
        mMid <- stepUntilToolRound liveEnv m0
        case decodeMachine (encodeMachine mMid) of
          Left err -> expectationFailure (T.unpack err)
          Right restored -> do
            let resumeEnv = withModels baseEnv resumeGateway
            result <- runMachine resumeEnv restored
            case result of
              Left err -> expectationFailure (show err)
              Right (RunCompleted (VRecord outs)) ->
                Map.lookup "answer" outs `shouldBe` Just (VString "cached answer")
              Right other -> expectationFailure ("unexpected outcome: " <> show other)

  describe "StepDriver par (M3)" $ do
    it "runs par(max = 2) in input order" $
      withSystemTempDirectory "hwfi-m3-par" $ \proj ->
        withSystemTempDirectory "hwfi-m3-par-ws" $ \ws -> do
          writeParProject proj parEchoMd
          createDirectoryIfMissing True ws
          writeFile (ws </> "log.txt") ""
          tp <- loadChecked proj
          workspace <- newWorkspace ws
          env <- newStepEnv tp workspace Map.empty "m3-par" "workflows/main"
          let m0 =
                initialMachine
                  ""
                  (projectContentHash tp)
                  (qnameFromText "workflows/main")
                  (Map.singleton "items" (VList [VString "a", VString "b", VString "c"]))
          result <- runMachine env m0
          case result of
            Left err -> expectationFailure (show err)
            Right (RunCompleted (VRecord outs)) ->
              Map.lookup "got" outs `shouldBe` Just (VString "b\n")
            Right other -> expectationFailure ("unexpected outcome: " <> show other)
          lineCount (ws </> "log.txt") `shouldReturn` 3

    it "resumes mid-par from a branch snapshot" $
      withSystemTempDirectory "hwfi-m3-par-resume" $ \proj ->
        withSystemTempDirectory "hwfi-m3-par-resume-ws" $ \ws -> do
          writeParProject proj parEchoMd
          tp <- loadChecked proj
          workspace <- newWorkspace ws
          env <- newStepEnv tp workspace Map.empty "m3-par-resume" "workflows/main"
          let m0 =
                initialMachine
                  ""
                  (projectContentHash tp)
                  (qnameFromText "workflows/main")
                  (Map.singleton "items" (VList [VString "a", VString "b", VString "c"]))
          mMid <- stepUntilParMid env m0
          case decodeMachine (encodeMachine mMid) of
            Left err -> expectationFailure (T.unpack err)
            Right restored -> do
              result <- runMachine env restored
              case result of
                Left err -> expectationFailure (show err)
                Right (RunCompleted (VRecord outs)) ->
                  Map.lookup "got" outs `shouldBe` Just (VString "b\n")
                Right other -> expectationFailure ("unexpected outcome: " <> show other)

    it "drains and pauses on exec confirm inside par, then continues after approve" $
      withSystemTempDirectory "hwfi-m3-par-confirm" $ \proj ->
        withSystemTempDirectory "hwfi-m3-par-confirm-ws" $ \ws -> do
          writeParProject proj parGitMd
          tp <- loadChecked proj
          workspace <- newWorkspace ws
          baseEnv <- newStepEnv tp workspace Map.empty "m3-confirm" "workflows/main"
          let env = baseEnv {seConfirmPolicy = ConfirmHold}
              m0 =
                initialMachine
                  ""
                  (projectContentHash tp)
                  (qnameFromText "workflows/main")
                  (Map.singleton "items" (VList [VString "only"]))
          halted <- runUntilHalt env m0
          case mStatus halted of
            MsPaused (PauseAwaitingConfirm _) -> pure ()
            s -> expectationFailure ("expected awaiting confirm, got: " <> show s)
          approved <- approveConfirm env halted
          result <- runMachine env approved
          case result of
            Left err -> expectationFailure (show err)
            Right (RunCompleted (VRecord outs)) ->
              Map.lookup "code" outs `shouldBe` Just (VInt 0)
            Right other -> expectationFailure ("unexpected outcome: " <> show other)

loadFixture :: IO TypedProject
loadFixture = loadChecked "test/fixtures/check/ok"

parProjectJson :: Text
parProjectJson =
  T.unlines
    [ "{",
      "  \"name\": \"m3-par\",",
      "  \"version\": \"0.1.0\",",
      "  \"entrypoint\": \"workflows/main\",",
      "  \"env\": [],",
      "  \"exec\": { \"allow\": [\"sh\", \"git\"], \"env\": [\"PATH\"] }",
      "}"
    ]

writeParProject :: FilePath -> Text -> IO ()
writeParProject dir mainMd = do
  createDirectoryIfMissing True (dir </> "workflows")
  TIO.writeFile (dir </> "project.json") parProjectJson
  TIO.writeFile (dir </> "model-catalog.json") "[]\n"
  TIO.writeFile (dir </> "workflows" </> "main.md") mainMd

parEchoMd :: Text
parEchoMd =
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
      "rs <- par(max = 2) it in ${inputs.items} {",
      "  r <- builtin/exec(program = \"sh\", args = [\"-c\", \"echo ${it} >> log.txt; echo ${it}\"], stdin = \"\", timeout_ms = 0) @run",
      "} @fan",
      "return { got = ${rs[1].stdout} }",
      "```"
    ]

parGitMd :: Text
parGitMd =
  T.unlines
    [ "---",
      "name: workflows/main",
      "inputs:",
      "  items: List<String>",
      "outputs:",
      "  code: Int",
      "imports:",
      "  - builtin/exec",
      "---",
      "",
      "## flow",
      "",
      "```step",
      "rs <- par(max = 1) it in ${inputs.items} {",
      "  r <- builtin/exec(program = \"sh\", args = [\"-c\", \"true\"], stdin = \"\", timeout_ms = 0) @run",
      "} @fan",
      "return { code = ${rs[0].exit_code} }",
      "```"
    ]

lineCount :: FilePath -> IO Int
lineCount fp = length . lines <$> readFile fp

stepUntilParMid :: StepEnv -> Machine -> IO Machine
stepUntilParMid env m0 = loop m0
  where
    loop m
      | isParMid m = pure m
      | otherwise =
          stepMachine env m >>= \case
            Left err -> fail (show err)
            Right (Stepped m') -> loop m'
            Right other -> fail ("stopped before mid-par: " <> show other)

isParMid :: Machine -> Bool
isParMid m =
  case mFrames m of
    FrPar pjs : _ ->
      any isDone (pjsSlots pjs) && not (allSlotsTerminal (pjsSlots pjs))
    _ -> False
  where
    isDone = \case
      ParSlotDone _ -> True
      _ -> False

stepUntilParActive :: StepEnv -> Machine -> IO Machine
stepUntilParActive env m0 = loop m0
  where
    loop m
      | isParActive m = pure m
      | otherwise =
          stepMachine env m >>= \case
            Left err -> fail (show err)
            Right (Stepped m') -> loop m'
            Right other -> fail ("stopped before par active: " <> show other)

isParActive :: Machine -> Bool
isParActive m =
  case mFrames m of
    FrPar pjs : _ -> not (Map.null (pjsActive pjs))
    _ -> False

runUntilHalt :: StepEnv -> Machine -> IO Machine
runUntilHalt env m0 = loop m0
  where
    loop m =
      stepMachine env m >>= \case
        Left err -> fail (show err)
        Right (Stepped m') -> loop m'
        Right (StepHalted m') -> pure m'
        Right (RunCompleted _) -> fail "unexpected completion before confirm halt"

loadChecked :: FilePath -> IO TypedProject
loadChecked dir = do
  eproj <- loadProject dir
  project <- case eproj of
    Left ds -> fail (show ds)
    Right p -> pure p
  case checkProject project of
    Left errs -> fail (show errs)
    Right tp -> pure tp

isDispatch :: Current -> Bool
isDispatch = \case
  CurDispatch _ -> True
  _ -> False

withModels :: StepEnv -> LLMGateway -> StepEnv
withModels env gw = env {seModels = llmStore gw 0.1}

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
      mcRequestTimeout = Nothing,
      mcThrottleDelay = Nothing,
      mcRetryCount = 0,
      mcJitterBackoff = 0
    }

stepUntilToolRound :: StepEnv -> Machine -> IO Machine
stepUntilToolRound env m0 = loop m0
  where
    loop m =
      case mCurrent m of
        CurAgent ag | Just _ <- agToolRound ag -> pure m
        _ ->
          stepMachine env m >>= \case
            Left err -> fail (show err)
            Right (Stepped m') -> loop m'
            Right other -> fail ("stopped before tool round: " <> show other)

searchQ :: QName
searchQ = qnameFromText "tools/search"

scriptedGateway :: [ChatResponse] -> LLMGateway
scriptedGateway responses = gatewayOf $ \req ->
  let i = length [() | ToolTurn _ <- req.reqConversation]
   in pure $
        if i < length responses
          then Right (responses !! i)
          else Left EmptyResponse

explodingGateway :: LLMGateway
explodingGateway = gatewayOf (\_ -> pure (Left (NetworkError "gateway invoked during machine resume")))

-- | Fails if the model is called before any tool turn (round 0 replay); answers
-- on the post-tool model call.
resumeGateway :: LLMGateway
resumeGateway =
  gatewayOf $ \req ->
    let toolRounds = length [() | ToolTurn _ <- req.reqConversation]
     in if toolRounds == 0
          then pure (Left (NetworkError "model round 0 re-invoked on resume"))
          else pure (Right (textResp "cached answer"))

gatewayOf :: (ChatRequest -> IO (Either LLMError ChatResponse)) -> LLMGateway
gatewayOf f =
  LLMGateway
    { gwName = "fake",
      gwGenerateText = \_hooks req -> f req,
      gwStreamText = \_ _ _ -> pure (Left EmptyResponse),
      gwGenerateObject = \_ _ _ -> pure (Left EmptyResponse)
    }

fakeUsage :: Usage
fakeUsage = Usage 5 7 0

searchCall :: Text -> ChatResponse
searchCall cid =
  ChatResponse
    ""
    [ToolCallBlock (mkToolCall cid (sanitizeToolName searchQ) (object ["query" .= ("haskell" :: Text)]))]
    (Just fakeUsage)
    Nothing

textResp :: Text -> ChatResponse
textResp t = ChatResponse t [TextBlock t] (Just fakeUsage) Nothing
