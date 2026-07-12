-- | The agentic tool-use loop for @builtin/llm-agent@ /
-- @builtin/llm-agent-object@ (spec ?6.1).
--
-- Where the one-shot LLM builtins are workflow-driven, this is LLM-driven:
-- within a single step the model is advertised a set of tools (the project's
-- own declarations) and autonomously issues tool calls in a loop until it
-- yields a final answer (?6.1). The loop is expressed as an explicit
-- round\/tool-call state machine over 'RValue', modelled on the reference
-- evaluator in @../llm-workflow@ but without @unsafeCoerce@ (hwfi values are
-- already dynamically typed). A model-chosen tool call is reified as a nested
-- executor step ('aeDispatch') so its effects go through the sandboxed
-- 'Hwfi.Runtime.Workspace' and its events nest under the agent step (?6.1.2,
-- ?8.3.3.7).
--
-- Determinism vs. caching (?8.1, ?8.2.1): the agent step is a non-cacheable
-- black box, but every /model call/ and every /tool call/ inside it is
-- individually content-addressed under the enclosing agent step-key and reused
-- from 'RunStore' on resume. A resumed loop therefore replays deterministically
-- ��� reusing the model's prior choices and tool results ��� without re-paying LLM
-- calls or re-running tool side effects. Caching is consulted only on resume
-- ('aeResume'); every attempt writes cache entries (mirroring the executor).
module Hwfi.Runtime.Agent
  ( AdvertisedTool (..),
    SubmitSpec (..),
    AgentSpec (..),
    AgentEnv (..),
    AgentCheckpoint (..),
    AgentSkillState (..),
    emptyAgentSkillState,
    toolModelJson,
    runAgent,
    agentCheckpointKey,
    modelSubKey,
    sanitizeToolName,
    advertisedToolDef,
    submitToolDef,
    submitToolName,
  )
where

import Control.Monad (unless, void, when)
import Data.Aeson (Value (..), fromJSON, object, toJSON, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.Either (fromRight)
import Data.Functor ((<&>))
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isNothing, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Hwfi.Ast.Name (Ident, QName, qnameFromText, renderQName)
import Hwfi.Ast.Skill (SkillKind (..))
import Hwfi.Check.Builtins (loadSkillQName)
import Hwfi.Compat
  ( ChatResponse (..),
    ContentBlock (..),
    GenRequest (..),
    ModelWithFallbacks,
    ToolCall (..),
    ToolDef (..),
    ToolResult (..),
    Turn (..),
    Usage (..),
    generateTextWithFallbacks,
    llmHooks,
    noHooks,
  )
import Hwfi.Project.Manifest (SkillPolicy (..))
import Hwfi.Runtime.Error (ErrorKind (..), RuntimeError (..), llmError)
import Hwfi.Runtime.Gateways (primaryModel)
import Hwfi.Runtime.RunStore (RunStore, cacheStepResult, deleteCachedResult, lookupCachedResult, registerAgentSubCache)
import Hwfi.Runtime.Schema (recordSchema)
import Hwfi.Runtime.Skills (instructionInjectionText, loadSkillResultRecord)
import Hwfi.Runtime.StepKey (sha256Hex)
import Hwfi.Runtime.Trace (EventBody (..), Tracer, emit)
import Hwfi.Runtime.Usage (UsageSeam, checkBudgetSeam, recordBilledCall)
import Hwfi.Runtime.Value (RValue (..), canonicalJson, coerceFromJson, redactedJson, valueToJson)
import Hwfi.SkillCatalog
  ( SkillCatalog,
    SkillEntry (..),
    lookupSkillEntry,
    skillKindText,
  )
import Hwfi.Type (Type (..))
import LLM (defaultDebugHooks)

-- | One tool advertised to the model: the resolved ref's qname, its provider
-- 'ToolDef' (schema-translated inputs, ?6.1.1), the declared input\/output
-- types (for coercion), and its Merkle fingerprint (for the tool-call sub-key,
-- ?8.2.1).
data AdvertisedTool = AdvertisedTool
  { atQName :: QName,
    atToolDef :: ToolDef,
    atInputs :: [(Ident, Type)],
    atOutputs :: [(Ident, Type)],
    atFingerprint :: Text
  }

-- | The terminating @submit@ tool of @builtin/llm-agent-object@ (?6.1.3): the
-- JSON Schema its arguments are validated against, and the 'ToolDef' advertised
-- to the model.
data SubmitSpec = SubmitSpec
  { ssSchema :: Value,
    ssToolDef :: ToolDef
  }

-- | Mutable skill-loading state for one agent step (§6.7).
data AgentSkillState = AgentSkillState
  { assLoadedCallable :: [QName],
    assLoadedInstruction :: [QName],
    assInstructionChars :: Int,
    assPendingInjections :: [Text]
  }
  deriving stock (Eq, Show)

emptyAgentSkillState :: AgentSkillState
emptyAgentSkillState =
  AgentSkillState
    { assLoadedCallable = [],
      assLoadedInstruction = [],
      assInstructionChars = 0,
      assPendingInjections = []
    }

-- | Everything the loop needs about the requested agent step.
data AgentSpec = AgentSpec
  { asSystem :: Text,
    asPrompt :: Text,
    asModelName :: Text,
    asModel :: ModelWithFallbacks,
    -- | Catalog fingerprint of 'asModelName' for the model-call sub-key (?8.2.1).
    asModelFingerprint :: Text,
    asTools :: [AdvertisedTool],
    asMaxRounds :: Int,
    -- | 'Just' for @builtin/llm-agent-object@ (mandatory typed 'submit'
    -- termination), 'Nothing' for @builtin/llm-agent@ (free-text termination).
    asSubmit :: Maybe SubmitSpec
  }

-- | The effectful seams the loop needs from the executor.
data AgentEnv = AgentEnv
  { aeTracer :: Tracer,
    aeStore :: RunStore,
    aeResume :: Bool,
    aeUsage :: UsageSeam,
    aeQName :: QName,
    aeStepId :: Ident,
    aeStepKey :: Text,
    aeDispatch :: QName -> Ident -> Map Ident RValue -> IO (Either RuntimeError RValue),
    aeSkillPolicy :: SkillPolicy,
    aeSkillCatalog :: SkillCatalog,
    aeSkillState :: IORef AgentSkillState,
    aeBuildTool :: QName -> Maybe AdvertisedTool
  }

-- | The model's assistant response, distilled to what the loop and its cache
-- need (final text, reasoning, and any tool calls it chose).
data AgentResponse = AgentResponse
  { arText :: Text,
    arReasoning :: Maybe Text,
    arToolCalls :: [ToolCall]
  }

-- | Persisted agent-loop position (�8.2.1 optional 8.g): the conversation
-- history and the next round index to drive. Lets resume skip re-walking
-- completed rounds whose intra-step sub-caches may be absent.
data AgentCheckpoint = AgentCheckpoint
  { acMessages :: [Turn],
    acNextRound :: Int,
    acActiveToolIds :: [Text],
    acLoadedInstructionIds :: [Text]
  }
  deriving stock (Eq, Show)

-- | Run the agent loop, returning the step's result record (spec ?6.1):
-- @{ text, rounds }@ for @builtin/llm-agent@ or @{ value, rounds }@ for
-- @builtin/llm-agent-object@. A 'Left' is a fatal error (?6.1.4).
runAgent :: AgentEnv -> AgentSpec -> IO (Either RuntimeError RValue)
runAgent env spec = do
  restoreSkillState env (aeSkillState env)
  (messages, roundIx) <- resolveStart env spec (aeSkillState env)
  result <- driveRounds env spec (aeSkillState env) messages roundIx
  case result of
    Right _ -> clearAgentCheckpoint env
    Left _ -> pure ()
  pure result

-- | On resume, reload a persisted checkpoint when present; otherwise replay
-- from round 0 (�8.2.1 backward compatibility).
resolveStart :: AgentEnv -> AgentSpec -> IORef AgentSkillState -> IO ([Turn], Int)
resolveStart env spec _skillState
  | not (aeResume env) = pure (initialMessages spec, 0)
  | otherwise = do
      mCkpt <- loadAgentCheckpoint (aeStore env) (aeStepKey env)
      pure $ case mCkpt of
        Just ckpt -> (acMessages ckpt, acNextRound ckpt)
        Nothing -> (initialMessages spec, 0)

restoreSkillState :: AgentEnv -> IORef AgentSkillState -> IO ()
restoreSkillState env skillState
  | not (aeResume env) = pure ()
  | otherwise = do
      mCkpt <- loadAgentCheckpoint (aeStore env) (aeStepKey env)
      case mCkpt of
        Nothing -> pure ()
        Just ckpt ->
          writeIORef skillState $
            AgentSkillState
              { assLoadedCallable = map qnameFromText (acActiveToolIds ckpt),
                assLoadedInstruction = map qnameFromText (acLoadedInstructionIds ckpt),
                assInstructionChars = 0,
                assPendingInjections = []
              }

initialMessages :: AgentSpec -> [Turn]
initialMessages spec = [UserTurn (asPrompt spec)]

-- Round loop -----------------------------------------------------------------

driveRounds :: AgentEnv -> AgentSpec -> IORef AgentSkillState -> [Turn] -> Int -> IO (Either RuntimeError RValue)
driveRounds env spec skillState messages roundIx
  | roundIx >= asMaxRounds spec =
      pure . Left . llmError $
        "agent reached max_rounds ("
          <> tshow (asMaxRounds spec)
          <> ") without terminating (?6.1.3, ?6.1.4)"
  | otherwise = do
      -- 'AgentRoundStart'/'AgentRoundEnd' are emitted lazily: a round whose
      -- model call and tool calls are all served from cache on resume emits no
      -- new events (?8.3.3.7), so the marker is written on the first real event.
      startedRef <- newIORef False
      let ensureStart = do
            started <- readIORef startedRef
            unless started $ do
              void $ emit (aeTracer env) (AgentRoundStart (aeQName env) (aeStepId env) roundIx)
              writeIORef startedRef True
          endRound finished = do
            started <- readIORef startedRef
            when started $
              void $
                emit (aeTracer env) (AgentRoundEnd (aeQName env) (aeStepId env) roundIx finished)
      modelResult <- runModelCall env spec skillState messages roundIx ensureStart
      case modelResult of
        Left err -> pure (Left err)
        Right assistant
          | null (arToolCalls assistant) -> do
              result <- finishTextRound env spec assistant roundIx
              endRound True
              pure result
          | otherwise -> do
              let messages' = messages <> [AssistantTurn (arText assistant) (arReasoning assistant) (arToolCalls assistant)]
              outcome <- runToolCalls env spec skillState (arToolCalls assistant) roundIx ensureStart
              case outcome of
                Terminated val -> endRound True >> pure (Right val)
                FatalTool err -> endRound False >> pure (Left err)
                Continue results -> do
                  endRound False
                  let messages'' = messages' <> [ToolTurn results]
                      nextRound = roundIx + 1
                  saveAgentCheckpoint env skillState messages'' nextRound
                  driveRounds env spec skillState messages'' nextRound

-- | Terminate a round in which the model produced no tool calls: for
-- @builtin/llm-agent@ this is the final free-text answer; for
-- @builtin/llm-agent-object@ finishing without a @submit@ is a hard error
-- (?6.1.3).
finishTextRound :: AgentEnv -> AgentSpec -> AgentResponse -> Int -> IO (Either RuntimeError RValue)
finishTextRound _ spec assistant roundIx = case asSubmit spec of
  Nothing ->
    pure . Right $
      VRecord (Map.fromList [("text", VString (arText assistant)), ("rounds", roundsValue roundIx)])
  Just _ ->
    pure . Left . llmError $
      "agent finished with plain text but this step requires a terminating submit call (?6.1.3)"

-- Model call (cached per round, ?8.2.1) --------------------------------------

runModelCall :: AgentEnv -> AgentSpec -> IORef AgentSkillState -> [Turn] -> Int -> IO () -> IO (Either RuntimeError AgentResponse)
runModelCall env spec skillState messages roundIx ensureStart = do
  messages' <- applyPendingInjections skillState messages
  active <- activeTools env spec skillState
  let key = modelSubKey env spec active messages' roundIx
  mCached <- if aeResume env then lookupCachedResult (aeStore env) key else pure Nothing
  case mCached >>= decodeResponse of
    Just cached -> pure (Right cached) -- cache hit: no new events (?8.3.3.7)
    Nothing -> do
      ensureStart
      budget <- checkBudgetSeam (aeUsage env)
      case budget of
        Left err -> pure (Left err)
        Right _ -> do
          result <- generateTextWithFallbacks (genReq spec active messages') (asModel spec)
          case result of
            Left gerr -> pure (Left (llmError ("agent model call failed: " <> tshow gerr)))
            Right resp -> do
              let assistant = responseOf resp
                  usage = fromMaybe (Usage 0 0 0) resp.respUsage
              cost <- recordBilledCall (aeUsage env) (primaryModel (asModel spec)) usage
              emitLlmCall env spec messages' resp cost
              cacheStepResult (aeStore env) key (encodeResponse assistant)
              registerAgentSubCache (aeStore env) (aeStepKey env) key
              pure (Right assistant)

genReq :: AgentSpec -> [AdvertisedTool] -> [Turn] -> GenRequest
genReq spec tools messages =
  GenRequest
    { grSystemPrompt = if T.null (asSystem spec) then Nothing else Just (asSystem spec),
      grMessages = messages,
      grTools = map atToolDef tools <> maybe [] (pure . ssToolDef) (asSubmit spec),
      grAbortSignal = Nothing,
      grLLMHooks = llmHooks defaultDebugHooks,
      grHooks = noHooks
    }

responseOf :: ChatResponse -> AgentResponse
responseOf resp =
  AgentResponse
    { arText = resp.respText,
      arReasoning = resp.respReasoning,
      arToolCalls = [tc | ToolCallBlock tc <- resp.respContent]
    }

-- Tool calls (each cached per (round, call-index), ?8.2.1) --------------------

-- | The outcome of running a round's tool calls.
data ToolOutcome
  = -- | A @submit@ call terminated the loop with the given result record.
    Terminated RValue
  | -- | All calls ran (possibly with recoverable errors); feed results back.
    Continue [ToolResult]
  | -- | A fatal (non-recoverable) failure aborts the run (?6.1.4).
    FatalTool RuntimeError

runToolCalls :: AgentEnv -> AgentSpec -> IORef AgentSkillState -> [ToolCall] -> Int -> IO () -> IO ToolOutcome
runToolCalls env spec skillState toolCalls roundIx ensureStart
  -- ?6.1.3: a round mixing 'submit' with other calls is rejected wholesale ��� no
  -- call runs, and the model is told to call submit alone.
  | mixesSubmit = rejectMixedSubmit env roundIx ensureStart toolCalls
  | otherwise = go 0 [] toolCalls
  where
    mixesSubmit = case asSubmit spec of
      Just _ -> any isSubmit toolCalls && length toolCalls > 1
      Nothing -> False

    go _ acc [] = pure (Continue (reverse acc))
    go ix acc (tc : rest) = do
      r <- runOneCall env spec skillState roundIx ix ensureStart tc
      case r of
        CallTerminated val -> pure (Terminated val)
        CallFatal err -> pure (FatalTool err)
        CallResult tr -> go (ix + 1) (tr : acc) rest

data CallOutcome
  = CallTerminated RValue
  | CallResult ToolResult
  | CallFatal RuntimeError

runOneCall :: AgentEnv -> AgentSpec -> IORef AgentSkillState -> Int -> Int -> IO () -> ToolCall -> IO CallOutcome
runOneCall env spec skillState roundIx callIx ensureStart tc
  | isSubmit tc = runSubmitCall env spec roundIx callIx ensureStart tc
  | otherwise = do
      tools <- activeTools env spec skillState
      case lookupTool tools tc.tcName of
        Nothing -> do
          ensureStart
          emitToolCall env roundIx callIx tc.tcName tc.tcArguments
          let msg = "unknown tool '" <> tc.tcName <> "'; it is not one of the advertised tools"
          recoverable env roundIx callIx tc.tcName tc msg
        Just tool -> runAdvertisedCall env spec skillState roundIx callIx ensureStart tc tool

-- | Run an advertised (non-@submit@) tool call as a nested executor step,
-- honouring the tool-call sub-cache (?8.2.1, ?6.1.2).
runAdvertisedCall :: AgentEnv -> AgentSpec -> IORef AgentSkillState -> Int -> Int -> IO () -> ToolCall -> AdvertisedTool -> IO CallOutcome
runAdvertisedCall env _spec skillState roundIx callIx ensureStart tc tool
  | atQName tool == loadSkillQName =
      runLoadSkillCall env skillState roundIx callIx ensureStart tc
  | otherwise =
      case coerceArgs (atInputs tool) tc.tcArguments of
        Left reason -> do
          -- ?6.1.4: malformed/ill-typed arguments are recoverable.
          ensureStart
          emitToolCall env roundIx callIx (renderQName (atQName tool)) tc.tcArguments
          recoverable env roundIx callIx (renderQName (atQName tool)) tc ("invalid arguments: " <> reason)
        Right resolved -> do
          let argsJson = valueToJson (VRecord resolved)
              key = toolSubKey env roundIx callIx (atFingerprint tool) argsJson
          mCached <- if aeResume env then lookupCachedResult (aeStore env) key else pure Nothing
          case mCached of
            Just cachedJson ->
              -- Cache hit: no new events; feed the model a redacted view (D3).
              pure (CallResult (toolResult tc (toolModelJson tool cachedJson)))
            Nothing -> do
              ensureStart
              emitToolCall env roundIx callIx (renderQName (atQName tool)) tc.tcArguments
              let sid = toolStepId env roundIx callIx
              void $ emit (aeTracer env) (StepStart (atQName tool) sid (redactedJson (VRecord resolved)) True Nothing)
              dr <- aeDispatch env (atQName tool) sid resolved
              case dr of
                Left err
                  | reKind err == KInternal -> do
                      void $ emit (aeTracer env) (ErrorEvent (atQName tool) sid (reMessage err) (reKind err))
                      pure (CallFatal err)
                  | otherwise -> do
                      -- ?6.1.4: a tool result the callee surfaces as an error is recoverable.
                      void $ emit (aeTracer env) (ErrorEvent (atQName tool) sid (reMessage err) (reKind err))
                      recoverable env roundIx callIx (renderQName (atQName tool)) tc ("tool error: " <> reMessage err)
                Right result -> do
                  let actual = valueToJson result
                      redacted = redactedJson result
                  void $ emit (aeTracer env) (StepEnd (atQName tool) sid redacted 0 Nothing)
                  -- Cache actual values (�8.2.1); redact only in trace/events (D3).
                  cacheStepResult (aeStore env) key actual
                  registerAgentSubCache (aeStore env) (aeStepKey env) key
                  void $
                    emit (aeTracer env) (AgentToolResult (aeQName env) (aeStepId env) roundIx callIx (renderQName (atQName tool)) redacted False)
                  pure (CallResult (toolResult tc (canonicalJson redacted)))

runLoadSkillCall :: AgentEnv -> IORef AgentSkillState -> Int -> Int -> IO () -> ToolCall -> IO CallOutcome
runLoadSkillCall env skillState roundIx callIx ensureStart tc = do
  ensureStart
  emitToolCall env roundIx callIx (renderQName loadSkillQName) tc.tcArguments
  case coerceArgs [("id", TyString)] tc.tcArguments of
    Left reason ->
      recoverable env roundIx callIx (renderQName loadSkillQName) tc ("invalid arguments: " <> reason)
    Right resolved ->
      case Map.lookup "id" resolved of
        Just (VString skillId) -> do
          st <- readIORef skillState
          let (st', rv) = agentLoadSkill env st skillId
          writeIORef skillState st'
          case rv of
            VRecord m
              | Map.lookup "ok" m == Just (VBool True) ->
                  let kind = fieldText m "kind"
                      loaded = Map.lookup "loaded" m == Just (VBool True)
                   in do
                        void $
                          emit
                            (aeTracer env)
                            (SkillLoad (aeQName env) (aeStepId env) skillId kind loaded)
                        recoverableJson env roundIx callIx (renderQName loadSkillQName) tc rv
            _ -> recoverableJson env roundIx callIx (renderQName loadSkillQName) tc rv
        _ ->
          recoverable env roundIx callIx (renderQName loadSkillQName) tc "missing argument 'id'"
  where
    fieldText m name = case Map.lookup name m of
      Just (VString t) -> t
      _ -> ""

recoverableJson :: AgentEnv -> Int -> Int -> Text -> ToolCall -> RValue -> IO CallOutcome
recoverableJson env roundIx callIx toolLabel tc rv = do
  void $
    emit
      (aeTracer env)
      (AgentToolResult (aeQName env) (aeStepId env) roundIx callIx toolLabel (valueToJson rv) True)
  pure (CallResult (toolResult tc (canonicalJson (valueToJson rv))))

agentLoadSkill :: AgentEnv -> AgentSkillState -> Text -> (AgentSkillState, RValue)
agentLoadSkill env st skillId =
  case lookupSkillEntry (qnameFromText skillId) (aeSkillCatalog env) of
    Nothing ->
      (st, loadSkillResultRecord False "" False False "" ("unknown skill id '" <> skillId <> "'"))
    Just e ->
      case seKind e of
        SkillInstruction -> loadInstruction env st e skillId
        SkillCallable -> loadCallable env st e skillId

loadInstruction :: AgentEnv -> AgentSkillState -> SkillEntry -> Text -> (AgentSkillState, RValue)
loadInstruction env st e skillId =
  let policy = aeSkillPolicy env
   in if seId e `elem` assLoadedInstruction st
        then
          ( st,
            loadSkillResultRecord True (skillKindText SkillInstruction) False False (fromMaybe "" (seBody e)) ""
          )
        else
          if length (assLoadedInstruction st) >= spMaxInstructionLoads policy
            then (st, loadSkillResultRecord False (skillKindText SkillInstruction) False False "" "instruction load cap exceeded")
            else
              let body = fromMaybe "" (seBody e)
                  newChars = assInstructionChars st + T.length body
               in if newChars > spMaxInstructionChars policy
                    then (st, loadSkillResultRecord False (skillKindText SkillInstruction) False False "" "instruction body exceeds max_instruction_chars")
                    else
                      let q = seId e
                          injection = instructionInjectionText skillId body
                       in ( st
                              { assLoadedInstruction = q : assLoadedInstruction st,
                                assInstructionChars = newChars,
                                assPendingInjections = assPendingInjections st <> [injection]
                              },
                            loadSkillResultRecord True (skillKindText SkillInstruction) True True body ""
                          )

loadCallable :: AgentEnv -> AgentSkillState -> SkillEntry -> Text -> (AgentSkillState, RValue)
loadCallable env st e _skillId =
  let q = seId e
   in if q `elem` assLoadedCallable st
        then (st, loadSkillResultRecord True (skillKindText SkillCallable) False False "" "")
        else
          if not (seChecked e)
            then (st, loadSkillResultRecord False (skillKindText SkillCallable) False False "" "callable skill failed hwfi check")
            else
              if not (seAgentEligible e)
                then (st, loadSkillResultRecord False (skillKindText SkillCallable) False False "" "callable skill is not agent-eligible")
                else
                  if length (assLoadedCallable st) >= spMaxCallableLoads (aeSkillPolicy env)
                    then (st, loadSkillResultRecord False (skillKindText SkillCallable) False False "" "callable load cap exceeded")
                    else
                      if isNothing (aeBuildTool env q)
                        then (st, loadSkillResultRecord False (skillKindText SkillCallable) False False "" "callable skill could not be resolved")
                        else
                          ( st {assLoadedCallable = q : assLoadedCallable st},
                            loadSkillResultRecord True (skillKindText SkillCallable) True False "" ""
                          )

applyPendingInjections :: IORef AgentSkillState -> [Turn] -> IO [Turn]
applyPendingInjections ref msgs = do
  st <- readIORef ref
  case assPendingInjections st of
    [] -> pure msgs
    pending -> do
      writeIORef ref st {assPendingInjections = []}
      pure (msgs <> [UserTurn t | t <- pending])

activeTools :: AgentEnv -> AgentSpec -> IORef AgentSkillState -> IO [AdvertisedTool]
activeTools env spec skillState = do
  st <- readIORef skillState
  let dynamic = mapMaybe (aeBuildTool env) (assLoadedCallable st)
  pure (asTools spec ++ dynamic)

-- | Run the terminating @submit@ call (?6.1.3). Because a mixed submit round is
-- rejected earlier, submit is guaranteed to be the sole call here.
runSubmitCall :: AgentEnv -> AgentSpec -> Int -> Int -> IO () -> ToolCall -> IO CallOutcome
runSubmitCall env spec roundIx callIx ensureStart tc = do
  ensureStart
  emitToolCall env roundIx callIx submitToolName tc.tcArguments
  case asSubmit spec of
    Nothing ->
      -- Should not happen (submit is only advertised for the object variant).
      recoverable env roundIx callIx submitToolName tc "submit is not available for this agent step"
    Just submit -> case validateSubmit (ssSchema submit) tc.tcArguments of
      Left reason ->
        -- ?6.1.3: a decode failure is recoverable ��� the model can retry.
        recoverable env roundIx callIx submitToolName tc ("submit decode error: " <> reason)
      Right validated -> do
        void $
          emit (aeTracer env) (AgentToolResult (aeQName env) (aeStepId env) roundIx callIx submitToolName validated False)
        pure . CallTerminated $
          VRecord (Map.fromList [("value", VJson validated), ("rounds", roundsValue roundIx)])

-- | Reject a round that mixes @submit@ with other tool calls (?6.1.3): feed a
-- recoverable message back for every call and run none of them.
rejectMixedSubmit :: AgentEnv -> Int -> IO () -> [ToolCall] -> IO ToolOutcome
rejectMixedSubmit env roundIx ensureStart toolCalls = do
  ensureStart
  results <- mapM reject (zip [0 ..] toolCalls)
  pure (Continue results)
  where
    msg = "submit must be called on its own; no tools were run this round -- call submit alone (?6.1.3)"
    reject (ix, tc) = do
      emitToolCall env roundIx ix tc.tcName tc.tcArguments
      void $ emit (aeTracer env) (AgentToolResult (aeQName env) (aeStepId env) roundIx ix tc.tcName (String msg) True)
      pure (toolResult tc msg)

-- | Emit a recoverable 'AgentToolResult' and return the fed-back tool message.
recoverable :: AgentEnv -> Int -> Int -> Text -> ToolCall -> Text -> IO CallOutcome
recoverable env roundIx callIx toolLabel tc msg = do
  void $ emit (aeTracer env) (AgentToolResult (aeQName env) (aeStepId env) roundIx callIx toolLabel (String msg) True)
  pure (CallResult (toolResult tc msg))

-- Trace helpers --------------------------------------------------------------

emitToolCall :: AgentEnv -> Int -> Int -> Text -> Value -> IO ()
emitToolCall env roundIx callIx toolLabel args =
  void $ emit (aeTracer env) (AgentToolCall (aeQName env) (aeStepId env) roundIx callIx toolLabel args)

emitLlmCall :: AgentEnv -> AgentSpec -> [Turn] -> ChatResponse -> Double -> IO ()
emitLlmCall env spec messages resp cost =
  void $
    emit
      (aeTracer env)
      ( LlmCall
          (aeQName env)
          (aeStepId env)
          (asModelName spec)
          (asSystem spec)
          (renderConversation messages)
          resp.respText
          usage.usageInputTokens
          usage.usageOutputTokens
          cost
      )
  where
    usage = fromMaybe (Usage 0 0 0) resp.respUsage

renderConversation :: [Turn] -> Text
renderConversation = T.intercalate "\n" . map render
  where
    render = \case
      UserTurn t -> "user: " <> t
      AssistantTurn t _ calls ->
        "assistant: " <> t <> if null calls then "" else "  [calls: " <> T.intercalate ", " (map (.tcName) calls) <> "]"
      ToolTurn results -> "tool: " <> T.intercalate " | " (map (\r -> r.trName <> "=" <> r.trContent) results)

-- Sub-keys (?8.2.1) ----------------------------------------------------------

-- | Content-addressed key for the optional agent-loop checkpoint (�8.2.1 8.g).
agentCheckpointKey :: Text -> Text
agentCheckpointKey stepKey = sha256Hex ("agent-checkpoint:" <> stepKey)

saveAgentCheckpoint :: AgentEnv -> IORef AgentSkillState -> [Turn] -> Int -> IO ()
saveAgentCheckpoint env skillState messages nextRound = do
  st <- readIORef skillState
  cacheStepResult
    (aeStore env)
    (agentCheckpointKey (aeStepKey env))
    ( encodeCheckpoint
        messages
        nextRound
        (map renderQName (assLoadedCallable st))
        (map renderQName (assLoadedInstruction st))
    )
  registerAgentSubCache (aeStore env) (aeStepKey env) (agentCheckpointKey (aeStepKey env))

loadAgentCheckpoint :: RunStore -> Text -> IO (Maybe AgentCheckpoint)
loadAgentCheckpoint store stepKey =
  lookupCachedResult store (agentCheckpointKey stepKey) <&> (>>= decodeCheckpoint)

clearAgentCheckpoint :: AgentEnv -> IO ()
clearAgentCheckpoint env =
  deleteCachedResult (aeStore env) (agentCheckpointKey (aeStepKey env))

encodeCheckpoint :: [Turn] -> Int -> [Text] -> [Text] -> Value
encodeCheckpoint messages nextRound activeIds instructionIds =
  object
    [ "messages" .= toJSON messages,
      "next_round" .= nextRound,
      "active_tool_ids" .= activeIds,
      "loaded_instruction_ids" .= instructionIds
    ]

decodeCheckpoint :: Value -> Maybe AgentCheckpoint
decodeCheckpoint = \case
  Object o -> do
    msgs <- case KM.lookup "messages" o of
      Just v -> case fromJSON v of
        Aeson.Success ts -> Just ts
        Aeson.Error _ -> Nothing
      Nothing -> Nothing
    roundIx <- case KM.lookup "next_round" o of
      Just (Aeson.Number n) -> Just (floor n)
      _ -> Nothing
    activeIds <- textList (KM.lookup "active_tool_ids" o)
    instrIds <- textList (KM.lookup "loaded_instruction_ids" o)
    Just (AgentCheckpoint msgs roundIx activeIds instrIds)
  _ -> Nothing
  where
    textList (Just (Array a)) = Just [t | String t <- V.toList a]
    textList _ = Just []

modelSubKey :: AgentEnv -> AgentSpec -> [AdvertisedTool] -> [Turn] -> Int -> Text
modelSubKey env spec tools messages roundIx =
  sha256Hex . T.intercalate "\n" $
    [ "agent:" <> aeStepKey env,
      "kind:model",
      "round:" <> tshow roundIx,
      "model-fp:" <> asModelFingerprint spec,
      "tools-fp:" <> toolsFingerprintAt tools,
      "messages:" <> canonicalJson (toJSON messages)
    ]

toolsFingerprintAt :: [AdvertisedTool] -> Text
toolsFingerprintAt tools =
  sha256Hex (T.intercalate ";" entries)
  where
    entries = sort [renderQName (atQName t) <> "=" <> atFingerprint t | t <- tools]

toolSubKey :: AgentEnv -> Int -> Int -> Text -> Value -> Text
toolSubKey env roundIx callIx calleeFp argsJson =
  sha256Hex . T.intercalate "\n" $
    [ "agent:" <> aeStepKey env,
      "kind:tool",
      "round:" <> tshow roundIx,
      "call:" <> tshow callIx,
      "callee:" <> calleeFp,
      "args:" <> canonicalJson argsJson
    ]

toolStepId :: AgentEnv -> Int -> Int -> Ident
toolStepId env roundIx callIx =
  aeStepId env <> "~r" <> tshow roundIx <> "c" <> tshow callIx

-- Submit schema validation (?6.1.3) ------------------------------------------

-- | Validate @submit@ arguments against its JSON Schema. v1 checks the
-- arguments are an object and that every property named in the schema's
-- top-level @required@ array is present; a failure is a recoverable decode
-- error the model can correct. Returns the validated arguments as the result.
validateSubmit :: Value -> Value -> Either Text Value
validateSubmit schema args = case args of
  Object o -> case missing o of
    [] -> Right args
    ms -> Left ("missing required field(s): " <> T.intercalate ", " ms)
  _ -> Left "arguments must be a JSON object"
  where
    required = case schema of
      Object so -> case KM.lookup "required" so of
        Just (Array a) -> [t | String t <- V.toList a]
        _ -> []
      _ -> []
    missing o = [r | r <- required, not (KM.member (K.fromText r) o)]

-- Argument coercion ----------------------------------------------------------

-- | Coerce a model-supplied JSON arguments object into the callee's declared
-- input types (spec ?6.1.2), reusing the resume-time 'coerceFromJson'. A
-- failure is recoverable (fed back to the model, ?6.1.4).
coerceArgs :: [(Ident, Type)] -> Value -> Either Text (Map Ident RValue)
coerceArgs inputs = \case
  Object o -> Map.fromList <$> traverse (field o) inputs
  _ -> Left "arguments must be a JSON object"
  where
    field o (n, ty) = case KM.lookup (K.fromText n) o of
      Just v -> (,) n <$> either (Left . ((n <> ": ") <>)) Right (coerceFromJson ty v)
      Nothing -> Left ("missing argument '" <> n <> "'")

-- Cache (de)serialisation of an assistant response ---------------------------

encodeResponse :: AgentResponse -> Value
encodeResponse ar =
  object
    [ "text" .= arText ar,
      "reasoning" .= arReasoning ar,
      "tool_calls" .= toJSON (arToolCalls ar)
    ]

decodeResponse :: Value -> Maybe AgentResponse
decodeResponse = \case
  Object o -> do
    txt <- str (KM.lookup "text" o)
    calls <- case KM.lookup "tool_calls" o of
      Just v -> case fromJSON v of
        Aeson.Success cs -> Just cs
        Aeson.Error _ -> Nothing
      Nothing -> Just []
    Just (AgentResponse txt (KM.lookup "reasoning" o >>= optStr) calls)
  _ -> Nothing
  where
    str (Just (String t)) = Just t
    str _ = Nothing
    optStr (String t) = Just t
    optStr _ = Nothing

-- Tool-name mapping and ToolDef construction ---------------------------------

-- | The synthesized @submit@ tool's provider name (?6.1.3).
submitToolName :: Text
submitToolName = "submit"

-- | Whether a model tool call targets the @submit@ tool.
isSubmit :: ToolCall -> Bool
isSubmit tc = tc.tcName == submitToolName

-- | Map an advertised tool to the model by its provider name.
lookupTool :: [AdvertisedTool] -> Text -> Maybe AdvertisedTool
lookupTool tools name = lookup name [((atToolDef t).toolName, t) | t <- tools]

-- | A provider-safe tool name for a qname (some providers reject @/@\/@-@ in
-- function names). @tools/search@ becomes @tools_search@.
sanitizeToolName :: QName -> Text
sanitizeToolName q = T.map safe (renderQName q)
  where
    safe c
      | c == '/' || c == '-' = '_'
      | otherwise = c

-- | Build the provider 'ToolDef' for an advertised callee (spec ?6.1.1). The
-- checker guarantees eligibility, so 'recordSchema' succeeds; the empty-object
-- fallback keeps this total.
advertisedToolDef :: QName -> [(Ident, Type)] -> ToolDef
advertisedToolDef q inputs =
  ToolDef
    { toolName = sanitizeToolName q,
      toolDescription = "Call the '" <> renderQName q <> "' tool.",
      toolParameters = fromRight (object []) (recordSchema inputs),
      toolReadonly = False
    }

-- | Build the terminating @submit@ 'ToolDef' from the object variant's schema
-- (spec ?6.1.3). The description states the single-call rule the engine also
-- enforces.
submitToolDef :: Value -> ToolDef
submitToolDef schema =
  ToolDef
    { toolName = submitToolName,
      toolDescription =
        "Submit the final structured result. Call this ONLY when you have "
          <> "everything you need, and NEVER in the same response as any other "
          <> "tool call. Its arguments are the final result.",
      toolParameters = schema,
      toolReadonly = True
    }

-- Small helpers --------------------------------------------------------------

toolResult :: ToolCall -> Text -> ToolResult
toolResult tc = ToolResult tc.tcId tc.tcName

-- | JSON tool-result text for the model: redact secrets using the callee output
-- type when the cached value can be coerced (D3).
toolModelJson :: AdvertisedTool -> Value -> Text
toolModelJson tool cachedJson =
  case coerceFromJson (toolOutputType tool) cachedJson of
    Right rv -> canonicalJson (redactedJson rv)
    Left _ -> canonicalJson cachedJson

toolOutputType :: AdvertisedTool -> Type
toolOutputType tool = TyRecord [(n, t) | (n, t) <- atOutputs tool]

roundsValue :: Int -> RValue
roundsValue roundIx = VInt (fromIntegral (roundIx + 1))

tshow :: (Show a) => a -> Text
tshow = T.pack . show
