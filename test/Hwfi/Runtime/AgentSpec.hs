{-# LANGUAGE OverloadedRecordDot #-}

module Hwfi.Runtime.AgentSpec (spec) where

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Vector qualified as V
import Hwfi.Ast.Name (Ident, QName, qnameFromText)
import Hwfi.Check (checkProject)
import Hwfi.Check.Builtins (discoverSkillsQName, loadSkillQName)
import Hwfi.Parse.Project (loadProject)
import Hwfi.Project.Manifest (ExecPolicy (..), defaultSkillPolicy)
import Hwfi.Runtime.Agent
  ( AdvertisedTool (..),
    AgentEnv (..),
    AgentSkillState (..),
    AgentSpec (..),
    SubmitSpec (..),
    advertisedToolDef,
    agentCheckpointKey,
    emptyAgentSkillState,
    modelSubKey,
    runAgent,
    sanitizeToolName,
    submitToolDef,
    submitToolName,
    toolModelJson,
  )
import Hwfi.Runtime.Builtins (BuiltinEnv (..), runBuiltin)
import Hwfi.Runtime.Error (ErrorKind (..), RuntimeError (..), StepRef (..), internalError, reKind)
import Hwfi.Runtime.RunStore (RunStore, createRunStore, deleteCachedResult, lookupCachedResult)
import Hwfi.Runtime.RunUsage (emptyRunUsage)
import Hwfi.Runtime.Trace (EventBody (..), TraceEvent (..), Tracer, newTracer, snapshotEvents)
import Hwfi.Runtime.Usage (UsageSeam (..), newUsageSeam)
import Hwfi.Runtime.Value (RValue (..))
import Hwfi.Runtime.Workspace (Workspace, newWorkspace, readTextFile, writeTextFile)
import Hwfi.SkillCatalog (emptySkillCatalog)
import Hwfi.Type (Type (..))
import Hwfi.TypedProject (TypedProject (..))
import LLM.Core.Types
  ( ChatRequest (..),
    ChatResponse (..),
    ContentBlock (..),
    LLMError (..),
    LLMGateway (..),
    ToolDef (..),
    ToolResult (..),
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
spec = describe "Agent loop (§6.1)" $ do
  describe "builtin/llm-agent — free-text termination" $ do
    it "drives a tool round then returns the model's final text (A17)" $
      withEnv $ \store tracer usageSeam skillState -> do
        calls <- newIORef (0 :: Int)
        let gw = scriptedGateway [searchCall "c1", textResp "The answer is 42."]
        res <- runAgent (env store tracer usageSeam False (countingDispatch calls searchResult) skillState) (textSpec gw)
        res `shouldBe` Right (record [("text", VString "The answer is 42."), ("rounds", VInt 2)])
        readIORef calls `shouldReturn` 1

    it "feeds an unknown tool name back as a recoverable result (§6.1.4)" $
      withEnv $ \store tracer usageSeam skillState -> do
        calls <- newIORef (0 :: Int)
        let gw = scriptedGateway [toolResp "c1" "does_not_exist" (object []), textResp "done"]
        res <- runAgent (env store tracer usageSeam False (countingDispatch calls searchResult) skillState) (textSpec gw)
        res `shouldBe` Right (record [("text", VString "done"), ("rounds", VInt 2)])
        -- The unknown tool never reaches dispatch.
        readIORef calls `shouldReturn` 0

    it "fails fatally when max_rounds is exhausted without terminating (§6.1.4)" $
      withEnv $ \store tracer usageSeam skillState -> do
        calls <- newIORef (0 :: Int)
        let gw = scriptedGateway [searchCall "c1", searchCall "c2", searchCall "c3"]
            spec' = (textSpec gw) {asMaxRounds = 1}
        res <- runAgent (env store tracer usageSeam False (countingDispatch calls searchResult) skillState) spec'
        reKind (fromLeft res) `shouldBe` KLlm

  describe "builtin/llm-agent-object — submit termination" $ do
    it "returns the validated submit payload as the typed value (A19)" $
      withEnv $ \store tracer usageSeam skillState -> do
        calls <- newIORef (0 :: Int)
        let gw = scriptedGateway [searchCall "c1", submitCall "c2" (object ["answer" .= ("42" :: Text)])]
        res <- runAgent (env store tracer usageSeam False (countingDispatch calls searchResult) skillState) (objectSpec gw)
        res `shouldBe` Right (record [("value", VJson (object ["answer" .= ("42" :: Text)])), ("rounds", VInt 2)])

    it "rejects a round mixing submit with another call, then accepts submit alone (§6.1.3)" $
      withEnv $ \store tracer usageSeam skillState -> do
        calls <- newIORef (0 :: Int)
        let gw =
              scriptedGateway
                [ mixedResp,
                  submitCall "c9" (object ["answer" .= ("late" :: Text)])
                ]
        res <- runAgent (env store tracer usageSeam False (countingDispatch calls searchResult) skillState) (objectSpec gw)
        res `shouldBe` Right (record [("value", VJson (object ["answer" .= ("late" :: Text)])), ("rounds", VInt 2)])
        evs <- snapshotEvents tracer
        any recoverableToolResult evs `shouldBe` True

    it "feeds a schema-invalid submit back as recoverable, then accepts a valid one (§6.1.3)" $
      withEnv $ \store tracer usageSeam skillState -> do
        calls <- newIORef (0 :: Int)
        let gw =
              scriptedGateway
                [ submitCall "c1" (object ["wrong" .= ("x" :: Text)]),
                  submitCall "c2" (object ["answer" .= ("ok" :: Text)])
                ]
        res <- runAgent (env store tracer usageSeam False (countingDispatch calls searchResult) skillState) (objectSpec gw)
        res `shouldBe` Right (record [("value", VJson (object ["answer" .= ("ok" :: Text)])), ("rounds", VInt 2)])

  describe "intra-step caching and resume (§8.2.1, A21)" $ do
    it "replays cached model and tool calls without re-invoking either on resume" $
      withEnv $ \store tracer usageSeam skillState -> do
        calls <- newIORef (0 :: Int)
        let liveGw = scriptedGateway [searchCall "c1", textResp "cached answer"]
        primed <- runAgent (env store tracer usageSeam False (countingDispatch calls searchResult) skillState) (textSpec liveGw)
        primed `shouldBe` Right (record [("text", VString "cached answer"), ("rounds", VInt 2)])
        readIORef calls `shouldReturn` 1
        -- Resume against a gateway/dispatch that fail if touched: the cache must
        -- satisfy every model and tool call.
        tracer2 <- newTracer
        usageBefore <- readIORef (usRef usageSeam)
        resumed <-
          runAgent
            (env store tracer2 usageSeam True explodingDispatch skillState)
            (textSpec explodingGateway)
        resumed `shouldBe` primed
        usageAfter <- readIORef (usRef usageSeam)
        usageAfter `shouldBe` usageBefore
        evs2 <- snapshotEvents tracer2
        length [() | TraceEvent _ _ (LlmCall {}) <- evs2] `shouldBe` 0

    it "feeds the model redacted tool JSON from cache when outputs include Secret (D3)" $ do
      let secretTool =
            searchTool
              { atOutputs = [("token", TySecret TyString), ("label", TyString)]
              }
          cached = object ["token" .= ("sekrit" :: Text), "label" .= ("ok" :: Text)]
      T.unpack (toolModelJson secretTool cached) `shouldNotContain` "sekrit"

    it "resumes from a persisted checkpoint without re-walking earlier rounds (8.g)" $
      withEnv $ \store tracer usageSeam skillState -> do
        calls <- newIORef (0 :: Int)
        let primingSpec = (textSpec crashAfterTwoToolRounds) {asMaxRounds = 4}
            resumeSpec = (textSpec finishAfterTwoToolRounds) {asMaxRounds = 4}
            dispatch = countingDispatch calls searchResult
            agentEnv resume = env store tracer usageSeam resume dispatch skillState
        first <- runAgent (agentEnv False) primingSpec
        reKind (fromLeft first) `shouldBe` KLlm
        ckptVal <- lookupCachedResult store (agentCheckpointKey "step-key-fixed")
        ckptVal `shouldSatisfy` isJust
        let resumeEnv = agentEnv True
        -- Drop intra-step model caches for completed rounds; resume must still
        -- succeed by jumping to the checkpoint rather than replaying round 0.
        deleteCachedResult store (modelSubKey resumeEnv primingSpec (asTools primingSpec) [UserTurn (asPrompt primingSpec)] 0)
        case ckptVal >>= decodeCheckpointForTest of
          Just msgsAtRound2 ->
            deleteCachedResult store (modelSubKey resumeEnv primingSpec (asTools primingSpec) (init (init msgsAtRound2)) 1)
          Nothing -> expectationFailure "checkpoint missing after partial agent run"
        resumed <- runAgent resumeEnv resumeSpec
        resumed `shouldBe` Right (record [("text", VString "done"), ("rounds", VInt 3)])
        lookupCachedResult store (agentCheckpointKey "step-key-fixed") `shouldReturn` Nothing

  describe "skill loading in agent loop (§6.7)" $ do
    it "A47: load-skill injects instruction content and is idempotent" $
      withSkillAgent $ \tp store tracer usageSeam skillState -> do
        reqs <- newIORef ([] :: [ChatRequest])
        let gw =
              capturingGateway
                reqs
                [ loadSkillCall "c1" "skills/shell-guide",
                  loadSkillCall "c2" "skills/shell-guide",
                  textResp "done"
                ]
            spec' = skillToolboxSpec gw
            agent = skillAgentEnv store tracer usageSeam False (\_ _ _ -> pure (Right (record []))) skillState tp
        res <- runAgent agent spec'
        res `shouldBe` Right (record [("text", VString "done"), ("rounds", VInt 3)])
        requests <- readIORef reqs
        length requests `shouldSatisfy` (>= 2)
        let round1Msgs = (requests !! 1).reqConversation
        any (hasUserText "Loaded skill: skills/shell-guide") round1Msgs `shouldBe` True
        any (hasUserText instructionBodyText) round1Msgs `shouldBe` True

    it "A48: load-skill adds a callable skill to the next model round" $
      withSkillAgent $ \tp store tracer usageSeam skillState -> do
        reqs <- newIORef ([] :: [ChatRequest])
        let gw =
              capturingGateway
                reqs
                [ loadSkillCall "c1" "skills/fix-shell",
                  textResp "done"
                ]
            spec' = skillToolboxSpec gw
            agent = skillAgentEnv store tracer usageSeam False (\_ _ _ -> pure (Right (record []))) skillState tp
        res <- runAgent agent spec'
        res `shouldBe` Right (record [("text", VString "done"), ("rounds", VInt 2)])
        requests <- readIORef reqs
        length requests `shouldSatisfy` (>= 2)
        let toolNames = map toolDefName (head requests).reqTools
        sanitizeToolName fixShellQ `elem` toolNames `shouldBe` True

    it "A49: resume restores loaded skills without re-dispatching load-skill" $
      withSkillAgent $ \tp store tracer usageSeam skillState -> do
        let primingSpec = (skillToolboxSpec crashAfterSkillLoads) {asMaxRounds = 4}
            agent resume = skillAgentEnv store tracer usageSeam resume (\_ _ _ -> pure (Right (record []))) skillState tp
        first <- runAgent (agent False) primingSpec
        reKind (fromLeft first) `shouldBe` KLlm
        ckptVal <- lookupCachedResult store (agentCheckpointKey "step-key-fixed")
        ckptVal `shouldSatisfy` isJust
        case ckptVal >>= decodeCheckpointSkillIds of
          Just (active, loaded) -> do
            "skills/fix-shell" `elem` active `shouldBe` True
            "skills/shell-guide" `elem` loaded `shouldBe` True
          Nothing -> expectationFailure "checkpoint missing skill ids"
        resumedReqs <- newIORef ([] :: [ChatRequest])
        let resumeGw =
              gatewayOf $ \req -> do
                modifyIORef' resumedReqs (req :)
                let toolRounds = length [() | ToolTurn _ <- req.reqConversation]
                pure $
                  if toolRounds >= 2
                    then Right (textResp "done")
                    else Left (NetworkError "resume expected skill loads in checkpoint")
            resumeSpec = skillToolboxSpec resumeGw
        resumed <- runAgent (agent True) resumeSpec
        resumed `shouldBe` Right (record [("text", VString "done"), ("rounds", VInt 3)])
        requests <- readIORef resumedReqs
        case requests of
          (req : _) ->
            sanitizeToolName fixShellQ `elem` map toolDefName req.reqTools `shouldBe` True
          [] -> expectationFailure "expected resumed model request with expanded tools"

  describe "coding loop end-to-end (§6.2, §6.3, A26)" $
    it "reacts to a failing exec by editing a file and re-running until it passes" $
      withCodingEnv $ \store tracer usageSeam ws skillState -> do
        -- The source lacks the token the build checks for, so the first build
        -- fails; the agent must edit it and re-run.
        _ <- writeTextFile ws "src.txt" "foo\n"
        let benv =
              BuiltinEnv
                { beWorkspace = ws,
                  beModels = Map.empty,
                  beTracer = tracer,
                  beStep = StepRef mainQ "agent",
                  beExecPolicy = Just codingPolicy,
                  beUsage = usageSeam,
                  beIntrospect = pure Null,
                  beEvalWorkflow = Nothing,
                  beRunId = "run-agent",
                  beSkillCatalog = emptySkillCatalog defaultSkillPolicy
                }
            dispatch q _sid = runBuiltin benv q
        res <- runAgent (env store tracer usageSeam False dispatch skillState) codingSpec
        res `shouldBe` Right (record [("text", VString "build passed"), ("rounds", VInt 4)])
        -- The edit was actually applied to the sandboxed workspace.
        edited <- readTextFile ws "src.txt"
        fmap fst edited `shouldBe` Right "bar\n"

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
      atOutputs = [("hits", TyList TyString)],
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

-- Coding-loop fixtures (A26) --------------------------------------------------

execQ :: QName
execQ = qnameFromText "builtin/exec"

editQ :: QName
editQ = qnameFromText "builtin/edit-file"

execInputs :: [(Ident, Type)]
execInputs = [("program", TyString), ("args", TyList TyString), ("stdin", TyString), ("timeout_ms", TyInt)]

editInputs :: [(Ident, Type)]
editInputs = [("path", TyFileRef), ("find", TyString), ("replace", TyString), ("expect", TyInt)]

execTool :: AdvertisedTool
execTool =
  AdvertisedTool
    { atQName = execQ,
      atToolDef = advertisedToolDef execQ execInputs,
      atInputs = execInputs,
      atOutputs =
        [ ("exit_code", TyInt),
          ("stdout", TyString),
          ("stderr", TyString),
          ("timed_out", TyBool)
        ],
      atFingerprint = "exec-fp-v1"
    }

editTool :: AdvertisedTool
editTool =
  AdvertisedTool
    { atQName = editQ,
      atToolDef = advertisedToolDef editQ editInputs,
      atInputs = editInputs,
      atOutputs = [],
      atFingerprint = "edit-fp-v1"
    }

codingPolicy :: ExecPolicy
codingPolicy =
  ExecPolicy
    { execAllow = ["sh"],
      execEnv = ["PATH"],
      execTimeoutMs = 5000,
      execMaxOutputBytes = 65536
    }

codingSpec :: AgentSpec
codingSpec =
  (textSpec codingGateway)
    { asPrompt = "Make the build pass.",
      asTools = [editTool, execTool],
      asMaxRounds = 8
    }

-- | A build command that succeeds only once @src.txt@ contains @bar@.
buildCmd :: [Text]
buildCmd = ["-c", "grep -q bar src.txt"]

-- | The scripted coding agent: run the build; if it fails, edit the source and
-- re-run; once it passes, answer with plain text. The decision is driven by the
-- real @exit_code@ the executor fed back, so the loop genuinely reacts to it.
codingGateway :: LLMGateway
codingGateway = gatewayOf $ \req ->
  pure . Right $
    let results = [tr | ToolTurn trs <- req.reqConversation, tr <- trs]
     in case reverse results of
          [] -> execCall
          (tr : _)
            | tr.trName == sanitizeToolName execQ ->
                if "\"exit_code\":0" `T.isInfixOf` tr.trContent
                  then textResp "build passed"
                  else editCall
            | tr.trName == sanitizeToolName editQ -> execCall
            | otherwise -> textResp "done"
  where
    execCall =
      toolResp "c-exec" (sanitizeToolName execQ) $
        object
          [ "program" .= ("sh" :: Text),
            "args" .= buildCmd,
            "stdin" .= ("" :: Text),
            "timeout_ms" .= (0 :: Int)
          ]
    editCall =
      toolResp "c-edit" (sanitizeToolName editQ) $
        object
          [ "path" .= ("src.txt" :: Text),
            "find" .= ("foo" :: Text),
            "replace" .= ("bar" :: Text),
            "expect" .= (1 :: Int)
          ]

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

-- Skill-loading fixtures (§6.7, A47–A49) ---------------------------------------

fixShellQ :: QName
fixShellQ = qnameFromText "skills/fix-shell"

instructionBodyText :: Text
instructionBodyText = "Always check PATH before running shell commands."

discoverSkillTool :: AdvertisedTool
discoverSkillTool =
  AdvertisedTool
    { atQName = discoverSkillsQName,
      atToolDef =
        advertisedToolDef
          discoverSkillsQName
          [("query", TyString), ("kinds", TyList TyString), ("limit", TyInt)],
      atInputs = [("query", TyString), ("kinds", TyList TyString), ("limit", TyInt)],
      atOutputs =
        [ ("ok", TyBool),
          ("skills", TyList TyJson),
          ("error", TyString)
        ],
      atFingerprint = "discover-skills-fp"
    }

loadSkillTool :: AdvertisedTool
loadSkillTool =
  AdvertisedTool
    { atQName = loadSkillQName,
      atToolDef = advertisedToolDef loadSkillQName [("id", TyString)],
      atInputs = [("id", TyString)],
      atOutputs =
        [ ("ok", TyBool),
          ("kind", TyString),
          ("loaded", TyBool),
          ("content", TyString),
          ("error", TyString)
        ],
      atFingerprint = "load-skill-fp"
    }

fixShellTool :: AdvertisedTool
fixShellTool =
  AdvertisedTool
    { atQName = fixShellQ,
      atToolDef = advertisedToolDef fixShellQ [("path", TyString)],
      atInputs = [("path", TyString)],
      atOutputs = [("ok", TyBool)],
      atFingerprint = "fix-shell-fp"
    }

skillToolboxSpec :: LLMGateway -> AgentSpec
skillToolboxSpec gw =
  (textSpec gw)
    { asTools = [discoverSkillTool, loadSkillTool, searchTool]
    }

skillAgentEnv ::
  RunStore ->
  Tracer ->
  UsageSeam ->
  Bool ->
  (QName -> Ident -> Map Ident RValue -> IO (Either RuntimeError RValue)) ->
  IORef AgentSkillState ->
  TypedProject ->
  AgentEnv
skillAgentEnv store tracer usageSeam resume dispatch skillState tp =
  (env store tracer usageSeam resume dispatch skillState)
    { aeSkillCatalog = tpSkillCatalog tp,
      aeBuildTool = \q -> if q == fixShellQ then Just fixShellTool else Nothing
    }

withSkillAgent ::
  (TypedProject -> RunStore -> Tracer -> UsageSeam -> IORef AgentSkillState -> IO a) -> IO a
withSkillAgent k =
  withSystemTempDirectory "hwfi-agent-skills" $ \dir -> do
    writeSkillAgentProject dir
    tp <- loadCheckedAgent dir
    store <- createRunStore dir "run-agent"
    usageSeam <- newUsageSeam store Nothing emptyRunUsage
    tracer <- newTracer
    skillState <- newIORef emptyAgentSkillState
    k tp store tracer usageSeam skillState

loadCheckedAgent :: FilePath -> IO TypedProject
loadCheckedAgent dir = do
  eproj <- loadProject dir
  case eproj of
    Left ds -> error ("fixture parse failed: " <> show ds)
    Right proj -> case checkProject proj of
      Left errs -> error ("fixture check failed: " <> show errs)
      Right tp -> pure tp

writeSkillAgentProject :: FilePath -> IO ()
writeSkillAgentProject dir = do
  createDirectoryIfMissing True (dir </> "workflows")
  createDirectoryIfMissing True (dir </> "skills")
  createDirectoryIfMissing True (dir </> "tools")
  TIO.writeFile (dir </> "project.json") skillAgentProjectJson
  TIO.writeFile (dir </> "model-catalog.json") "[]\n"
  TIO.writeFile (dir </> "skills" </> "fix-shell.md") skillFixShellMd
  TIO.writeFile (dir </> "skills" </> "shell-guide.md") skillShellGuideMd
  TIO.writeFile (dir </> "tools" </> "search.md") skillSearchMd
  TIO.writeFile (dir </> "workflows" </> "main.md") skillAgentMainMd

skillSearchMd :: Text
skillSearchMd =
  T.unlines
    [ "---",
      "name: tools/search",
      "inputs:",
      "  query: String",
      "outputs:",
      "  hits: List<String>",
      "---",
      "",
      "```step",
      "return { hits = [] }",
      "```"
    ]

skillAgentProjectJson :: Text
skillAgentProjectJson =
  "{\n  \"name\": \"agent-skills\",\n  \"version\": \"0.1.0\",\n  \"entrypoint\": \"workflows/main\",\n  \"env\": []\n}\n"

skillFixShellMd :: Text
skillFixShellMd =
  T.unlines
    [ "---",
      "name: skills/fix-shell",
      "skill:",
      "  kind: callable",
      "  summary: Repair shell scripts",
      "  tags: [shell, repair]",
      "inputs:",
      "  path: String",
      "outputs:",
      "  ok: Bool",
      "---",
      "",
      "```step",
      "return { ok = true }",
      "```"
    ]

skillShellGuideMd :: Text
skillShellGuideMd =
  T.unlines
    [ "---",
      "name: skills/shell-guide",
      "skill:",
      "  kind: instruction",
      "  summary: Shell repair playbook",
      "  tags: [shell, guide]",
      "---",
      "",
      instructionBodyText
    ]

skillAgentMainMd :: Text
skillAgentMainMd =
  T.unlines
    [ "---",
      "name: workflows/main",
      "inputs:",
      "  q: String",
      "outputs:",
      "  answer: String",
      "---",
      "",
      "```step",
      "return { answer = ${inputs.q} }",
      "```"
    ]

toolDefName :: ToolDef -> Text
toolDefName (ToolDef n _ _ _) = n

capturingGateway :: IORef [ChatRequest] -> [ChatResponse] -> LLMGateway
capturingGateway ref responses = gatewayOf $ \req -> do
  modifyIORef' ref (req :)
  let toolRounds = length [() | ToolTurn _ <- req.reqConversation]
  pure $
    if toolRounds < length responses
      then Right (responses !! toolRounds)
      else Left EmptyResponse

crashAfterSkillLoads :: LLMGateway
crashAfterSkillLoads =
  gatewayOf $ \req ->
    let toolRounds = length [() | ToolTurn _ <- req.reqConversation]
     in pure $
          case toolRounds of
            0 -> Right (loadSkillCall "c1" "skills/shell-guide")
            1 -> Right (loadSkillCall "c2" "skills/fix-shell")
            _ -> Left (NetworkError "simulated crash after skill loads")

loadSkillCall :: Text -> Text -> ChatResponse
loadSkillCall cid skillId =
  toolResp cid (sanitizeToolName loadSkillQName) (object ["id" .= skillId])

hasUserText :: Text -> Turn -> Bool
hasUserText needle = \case
  UserTurn t -> needle `T.isInfixOf` t
  _ -> False

decodeCheckpointSkillIds :: Value -> Maybe ([Text], [Text])
decodeCheckpointSkillIds = \case
  Object o -> do
    active <- textList (KM.lookup "active_tool_ids" o)
    loaded <- textList (KM.lookup "loaded_instruction_ids" o)
    Just (active, loaded)
  _ -> Nothing
  where
    textList (Just (Array a)) = Just [t | String t <- V.toList a]
    textList _ = Just []

-- Environment ----------------------------------------------------------------

withEnv :: (RunStore -> Tracer -> UsageSeam -> IORef AgentSkillState -> IO a) -> IO a
withEnv k =
  withSystemTempDirectory "hwfi-agent" $ \dir -> do
    store <- createRunStore dir "run-agent"
    usageSeam <- newUsageSeam store Nothing emptyRunUsage
    tracer <- newTracer
    skillState <- newIORef emptyAgentSkillState
    k store tracer usageSeam skillState

-- | Like 'withEnv' but also provides a real sandboxed workspace so tool calls
-- can genuinely mutate files and run commands (A26).
withCodingEnv :: (RunStore -> Tracer -> UsageSeam -> Workspace -> IORef AgentSkillState -> IO a) -> IO a
withCodingEnv k =
  withSystemTempDirectory "hwfi-coding" $ \dir -> do
    store <- createRunStore dir "run-agent"
    usageSeam <- newUsageSeam store Nothing emptyRunUsage
    tracer <- newTracer
    skillState <- newIORef emptyAgentSkillState
    let wsDir = dir </> "ws"
    createDirectoryIfMissing True wsDir
    ws <- newWorkspace wsDir
    k store tracer usageSeam ws skillState

env ::
  RunStore ->
  Tracer ->
  UsageSeam ->
  Bool ->
  (QName -> Ident -> Map Ident RValue -> IO (Either RuntimeError RValue)) ->
  IORef AgentSkillState ->
  AgentEnv
env store tracer usageSeam resume dispatch skillState =
  AgentEnv
    { aeTracer = tracer,
      aeStore = store,
      aeResume = resume,
      aeUsage = usageSeam,
      aeQName = mainQ,
      aeStepId = "agent",
      aeStepKey = "step-key-fixed",
      aeDispatch = dispatch,
      aeSkillPolicy = defaultSkillPolicy,
      aeSkillCatalog = emptySkillCatalog defaultSkillPolicy,
      aeSkillState = skillState,
      aeBuildTool = const Nothing
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

-- Gateways for checkpoint resume (8.g) -----------------------------------------

-- | Two tool rounds, then fail on the third model call (simulated crash).
crashAfterTwoToolRounds :: LLMGateway
crashAfterTwoToolRounds =
  gatewayOf $ \req ->
    let toolRounds = length [() | ToolTurn _ <- req.reqConversation]
     in pure $
          if toolRounds < 2
            then Right (searchCall ("c" <> tshow (toolRounds + 1)))
            else Left (NetworkError "simulated crash at final model round")

-- | After two tool rounds in the conversation, answer with plain text.
finishAfterTwoToolRounds :: LLMGateway
finishAfterTwoToolRounds =
  gatewayOf $ \req ->
    let toolRounds = length [() | ToolTurn _ <- req.reqConversation]
     in pure $
          if toolRounds < 2
            then Right (searchCall ("c" <> tshow (toolRounds + 1)))
            else Right (textResp "done")

decodeCheckpointForTest :: Value -> Maybe [Turn]
decodeCheckpointForTest = \case
  Object o -> case KM.lookup "messages" o of
    Just v -> case Aeson.fromJSON v of
      Aeson.Success ts -> Just ts
      Aeson.Error _ -> Nothing
    Nothing -> Nothing
  _ -> Nothing

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
submitCall cid = toolResp cid submitToolName

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

tshow :: (Show a) => a -> Text
tshow = T.pack . show
