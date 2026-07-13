-- | Agent stepping for the v2 machine runtime (M2).
--
-- One 'stepAgent' call performs exactly one transition: a model call, one tool
-- call, or mixed-submit recovery. Agent state lives in the machine snapshot;
-- intra-step sub-key cache replay is not used (see @docs/execution-model.md@).
module Hwfi.Runtime.MachineAgent
  ( initAgentState,
    stepAgent,
  )
where

import Control.Monad (void, zipWithM_)
import Data.Aeson (Value (..), object)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isNothing, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Hwfi.Ast.Name (Ident, QName, qnameFromText, renderQName)
import Hwfi.Ast.Skill (SkillKind (..))
import Hwfi.Ast.Step (Binder (..))
import Hwfi.Check.Builtins
  ( Callee (..),
    isBuiltin,
    llmAgentObjectQName,
    loadSkillQName,
    lookupBuiltin,
  )
import Hwfi.Compat
  ( ChatResponse (..),
    ContentBlock (..),
    GenRequest (..),
    ToolCall (..),
    ToolDef (..),
    ToolResult (..),
    Turn (..),
    Usage (..),
    generateTextWithFallbacks,
    llmHooks,
    noHooks,
  )
import Hwfi.Project.Manifest (SkillPolicy (..), execPolicy)
import Hwfi.Runtime.Context (RunInfo (..))
import Hwfi.Runtime.Agent
  ( AdvertisedTool (..),
    AgentSpec (..),
    SubmitSpec (..),
    advertisedToolDef,
    coerceArgs,
    isSubmit,
    sanitizeToolName,
    submitToolDef,
    submitToolName,
    validateSubmit,
  )
import Hwfi.Runtime.Builtins (BuiltinEnv (..), runBuiltin)
import Hwfi.Runtime.Error
  ( ErrorKind (..),
    RuntimeError (..),
    atStep,
    internalError,
    llmError,
  )
import Hwfi.Runtime.Error qualified as Err
import Hwfi.Runtime.EvalWorkflow (EvalWorkflowSeam (..))
import Hwfi.Runtime.Gateways (lookupModel, modelCatalogFingerprint, primaryModel)
import Hwfi.Runtime.Machine
  ( AgentState (..),
    Current (..),
    Machine (..),
    PendingAgent (..),
    StepRef (..),
    ToolRound (..),
  )
import Hwfi.Runtime.Skills (instructionInjectionText, loadSkillResultRecord)
import Hwfi.Runtime.StepEnv (StepEnv (..))
import Hwfi.Runtime.Trace (EventBody (..), emit)
import Hwfi.Runtime.Usage (UsageSeam, checkBudgetSeam, recordBilledCall)
import Hwfi.Runtime.Value (RValue (..), RefKind (..), canonicalJson, redactedJson, valueToJson)
import Hwfi.SkillCatalog
  ( SkillEntry (..),
    lookupSkillEntry,
    skillKindText,
    skillPolicyFromManifest,
  )
import Hwfi.Type (Type (..))
import Hwfi.TypedProject
  ( Fingerprint (..),
    ResolvedSignature (..),
    TypedDecl (..),
    TypedProject (..),
    lookupTyped,
    tpManifest,
    tpSkillCatalog,
  )
import LLM (defaultDebugHooks)

-- | Initialise agent reducible state from evaluated step arguments.
agentErrRef :: AgentState -> Err.StepRef
agentErrRef ag = Err.StepRef (srQName (agStepRef ag)) (srStepId (agStepRef ag))

initAgentState ::
  StepEnv ->
  StepRef ->
  Binder ->
  QName ->
  Map Ident RValue ->
  Either RuntimeError AgentState
initAgentState env stepRef binder target argMap = do
  system <- reqText "system"
  prompt <- reqText "prompt"
  modelName <- reqText "model"
  maxRounds <- reqInt "max_rounds"
  tools <- reqList "tools"
  submitSchema <-
    if target == llmAgentObjectQName
      then Just . valueToJson <$> reqValue "schema"
      else Right Nothing
  Right
    AgentState
      { agStepRef = stepRef,
        agBinder = binder,
        agTarget = target,
        agPending =
          PendingAgent
            { paSystem = system,
              paPrompt = prompt,
              paModelName = modelName,
              paMaxRounds = maxRounds,
              paInitialTools = tools,
              paSubmitSchema = submitSchema,
              paHistory = [UserTurn prompt],
              paToolRounds = [],
              paActiveToolIds = [],
              paLoadedInstructionIds = [],
              paInstructionChars = 0,
              paPendingInjections = []
            },
        agRound = 0,
        agSubmitRequired = target == llmAgentObjectQName,
        agToolRound = Nothing
      }
  where
    reqValue name = case Map.lookup name argMap of
      Just v -> Right v
      Nothing -> Left (internalError ("agent argument '" <> name <> "' is missing at runtime"))
    reqText name =
      reqValue name >>= \case
        VString t -> Right t
        VFileRef t -> Right t
        _ -> Left (internalError ("agent argument '" <> name <> "' is not text"))
    reqInt name =
      reqValue name >>= \case
        VInt n -> Right (fromInteger n)
        _ -> Left (internalError ("agent argument '" <> name <> "' is not an integer"))
    reqList name =
      reqValue name >>= \case
        VList xs -> Right xs
        _ -> Left (internalError ("agent argument '" <> name <> "' is not a list"))

-- | Execute one agent transition. Returns 'Left' on fatal error, 'Right Nothing'
-- when the agent step is complete (caller should bind the result), or 'Right
-- (Just machine')' to continue stepping.
stepAgent ::
  StepEnv ->
  Machine ->
  AgentState ->
  IO (Either RuntimeError (Maybe RValue, Machine))
stepAgent env machine ag =
  case agToolRound ag of
    Nothing -> stepModel env machine ag
    Just tr -> stepTool env machine ag tr

-- Model transition -----------------------------------------------------------

stepModel :: StepEnv -> Machine -> AgentState -> IO (Either RuntimeError (Maybe RValue, Machine))
stepModel env machine ag
  | agRound ag >= paMaxRounds (agPending ag) =
      pure . Left . atStep (agentErrRef ag) . llmError $
        "agent reached max_rounds ("
          <> tshow (paMaxRounds (agPending ag))
          <> ") without terminating (§6.1.3, §6.1.4)"
  | otherwise = do
      spec <- case agentSpec env ag of
        Left e -> pure (Left (atStep (agentErrRef ag) e))
        Right s -> pure (Right s)
      case spec of
        Left e -> pure (Left e)
        Right agentSpec' -> do
          let (pa', messages) = applyInjections (agPending ag)
              ag' = ag {agPending = pa'}
          case activeTools env pa' of
            Left e -> pure (Left (atStep (agentErrRef ag') e))
            Right active -> do
              void $ emit (seTracer env) (AgentRoundStart (srQName (agStepRef ag')) (srStepId (agStepRef ag')) (agRound ag'))
              budget <- checkBudgetSeam (seUsage env)
              case budget of
                Left err -> pure (Left (atStep (agentErrRef ag') err))
                Right _ -> do
                  result <- generateTextWithFallbacks (genReq agentSpec' active messages) (asModel agentSpec')
                  case result of
                    Left gerr ->
                      pure . Left . atStep (agentErrRef ag') . llmError $
                        "agent model call failed: " <> tshow gerr
                    Right resp -> do
                      let assistant = responseOf resp
                          usage = fromMaybe (Usage 0 0 0) resp.respUsage
                      cost <- recordBilledCall (seUsage env) (primaryModel (asModel agentSpec')) usage
                      emitLlmCall env ag' messages resp cost
                      if null (arToolCalls assistant)
                        then finishText env machine ag' assistant
                        else do
                          let assistantTurn = AssistantTurn (arText assistant) (arReasoning assistant) (arToolCalls assistant)
                              tr =
                                ToolRound
                                  { trAssistant = assistantTurn,
                                    trPending = arToolCalls assistant,
                                    trCompleted = [],
                                    trActive = Nothing
                                  }
                          pure . Right . (Nothing,) $
                            machine
                              { mCurrent =
                                  CurAgent
                                    ag'
                                      { agToolRound = Just tr
                                      }
                              }

finishText :: StepEnv -> Machine -> AgentState -> AgentResponse -> IO (Either RuntimeError (Maybe RValue, Machine))
finishText env machine ag assistant
  | agSubmitRequired ag = do
      void $ emit (seTracer env) (AgentRoundEnd (srQName (agStepRef ag)) (srStepId (agStepRef ag)) (agRound ag) False)
      pure . Left . atStep (agentErrRef ag) . llmError $
        "agent finished with plain text but this step requires a terminating submit call (§6.1.3)"
  | otherwise = do
      void $ emit (seTracer env) (AgentRoundEnd (srQName (agStepRef ag)) (srStepId (agStepRef ag)) (agRound ag) True)
      pure . Right $
        ( Just
            ( VRecord
                ( Map.fromList
                    [ ("text", VString (arText assistant)),
                      ("rounds", roundsValue (agRound ag))
                    ]
                )
            ),
          machine
        )

-- Tool transition ------------------------------------------------------------

stepTool :: StepEnv -> Machine -> AgentState -> ToolRound -> IO (Either RuntimeError (Maybe RValue, Machine))
stepTool env machine ag tr
  | mixesSubmit ag tr =
      handleMixedSubmit env machine ag tr
  | null (trPending tr) && null (trCompleted tr) && isNothing (trActive tr) =
      pure . Left . atStep (agentErrRef ag) $
        internalError "agent tool round has no pending calls"
  | otherwise = case trActive tr of
      Just tc -> executeActiveTool env machine ag tr tc
      Nothing -> startNextTool env machine ag tr

mixesSubmit :: AgentState -> ToolRound -> Bool
mixesSubmit ag tr =
  agSubmitRequired ag && any isSubmit (trPending tr) && length (trPending tr) > 1

handleMixedSubmit :: StepEnv -> Machine -> AgentState -> ToolRound -> IO (Either RuntimeError (Maybe RValue, Machine))
handleMixedSubmit env machine ag tr = do
  let msg = "submit must be called on its own; no tools were run this round — call submit alone (§6.1.3)"
      results = [toolResult tc msg | tc <- trPending tr]
  zipWithM_ (\ix tc -> emitToolCall env ag (agRound ag) ix (tc.tcName) (tc.tcArguments)) [0 ..] (trPending tr)
  mapM_
    ( \(ix, tc) ->
        void $
          emit
            (seTracer env)
            (AgentToolResult (srQName (agStepRef ag)) (srStepId (agStepRef ag)) (agRound ag) ix (tc.tcName) (String msg) True)
    )
    (zip [0 ..] (trPending tr))
  finishToolRound env machine ag (tr {trPending = [], trCompleted = results, trActive = Nothing})

startNextTool :: StepEnv -> Machine -> AgentState -> ToolRound -> IO (Either RuntimeError (Maybe RValue, Machine))
startNextTool env machine ag tr =
  case trPending tr of
    [] -> finishToolRound env machine ag tr
    tc : rest ->
      if isSubmit tc
        then executeActiveTool env machine ag (tr {trPending = rest, trActive = Just tc}) tc
        else executeActiveTool env machine ag (tr {trPending = rest, trActive = Just tc}) tc

executeActiveTool :: StepEnv -> Machine -> AgentState -> ToolRound -> ToolCall -> IO (Either RuntimeError (Maybe RValue, Machine))
executeActiveTool env machine ag tr tc
  | isSubmit tc = runSubmit env machine ag tr tc
  | tc.tcName == sanitizeToolName loadSkillQName = runLoadSkill env machine ag tr tc
  | otherwise = do
      spec <- case agentSpec env ag of
        Left e -> pure (Left (atStep (agentErrRef ag) e))
        Right s -> pure (Right s)
      case spec of
        Left e -> pure (Left e)
        Right agentSpec' -> do
          case activeTools env (agPending ag) of
            Left e -> pure (Left (atStep (agentErrRef ag) e))
            Right active ->
              case lookupTool active tc.tcName of
                Nothing -> do
                  emitToolCall env ag (agRound ag) (callIndex tr) tc.tcName tc.tcArguments
                  recoverable env machine ag tr tc ("unknown tool '" <> tc.tcName <> "'; it is not one of the advertised tools")
                Just tool -> runAdvertised env machine ag tr tc tool agentSpec'

runAdvertised ::
  StepEnv ->
  Machine ->
  AgentState ->
  ToolRound ->
  ToolCall ->
  AdvertisedTool ->
  AgentSpec ->
  IO (Either RuntimeError (Maybe RValue, Machine))
runAdvertised env machine ag tr tc tool _agentSpec' =
  case coerceArgs (atInputs tool) tc.tcArguments of
    Left reason -> do
      emitToolCall env ag (agRound ag) (callIndex tr) (renderQName (atQName tool)) tc.tcArguments
      recoverable env machine ag tr tc ("invalid arguments: " <> reason)
    Right resolved -> do
      emitToolCall env ag (agRound ag) (callIndex tr) (renderQName (atQName tool)) tc.tcArguments
      let sid = toolStepId ag (agRound ag) (callIndex tr)
      void $
        emit
          (seTracer env)
          (StepStart (atQName tool) sid (redactedJson (VRecord resolved)) True Nothing)
      dr <- dispatchTool env machine ag (atQName tool) sid resolved
      case dr of
        Left err
          | reKind err == KInternal -> do
              void $ emit (seTracer env) (ErrorEvent (atQName tool) sid (reMessage err) (reKind err))
              pure . Left . atStep (agentErrRef ag) $ err
          | otherwise -> do
              void $ emit (seTracer env) (ErrorEvent (atQName tool) sid (reMessage err) (reKind err))
              recoverable env machine ag tr tc ("tool error: " <> reMessage err)
        Right result -> do
          let redacted = redactedJson result
          void $ emit (seTracer env) (StepEnd (atQName tool) sid redacted 0 Nothing)
          void $
            emit
              (seTracer env)
              ( AgentToolResult
                  (srQName (agStepRef ag))
                  (srStepId (agStepRef ag))
                  (agRound ag)
                  (callIndex tr)
                  (renderQName (atQName tool))
                  redacted
                  False
              )
          appendToolResult env machine ag tr tc (canonicalJson redacted)

runSubmit :: StepEnv -> Machine -> AgentState -> ToolRound -> ToolCall -> IO (Either RuntimeError (Maybe RValue, Machine))
runSubmit env machine ag tr tc = do
  emitToolCall env ag (agRound ag) (callIndex tr) submitToolName tc.tcArguments
  case paSubmitSchema (agPending ag) of
    Nothing ->
      recoverable env machine ag tr tc "submit is not available for this agent step"
    Just schema ->
      case validateSubmit schema tc.tcArguments of
        Left reason -> recoverable env machine ag tr tc ("submit decode error: " <> reason)
        Right validated -> do
          void $
            emit
              (seTracer env)
              ( AgentToolResult
                  (srQName (agStepRef ag))
                  (srStepId (agStepRef ag))
                  (agRound ag)
                  (callIndex tr)
                  submitToolName
                  validated
                  False
              )
          void $ emit (seTracer env) (AgentRoundEnd (srQName (agStepRef ag)) (srStepId (agStepRef ag)) (agRound ag) True)
          pure . Right $
            ( Just
                ( VRecord
                    ( Map.fromList
                        [ ("value", VJson validated),
                          ("rounds", roundsValue (agRound ag))
                        ]
                    )
                ),
              machine
            )

runLoadSkill :: StepEnv -> Machine -> AgentState -> ToolRound -> ToolCall -> IO (Either RuntimeError (Maybe RValue, Machine))
runLoadSkill env machine ag tr tc = do
  emitToolCall env ag (agRound ag) (callIndex tr) (renderQName loadSkillQName) tc.tcArguments
  case coerceArgs [("id", TyString)] tc.tcArguments of
    Left reason -> recoverable env machine ag tr tc ("invalid arguments: " <> reason)
    Right resolved ->
      case Map.lookup "id" resolved of
        Just (VString skillId) -> do
          let (pa', rv) = loadSkill env (agPending ag) skillId
              ag' = ag {agPending = pa'}
          case rv of
            VRecord m
              | Map.lookup "ok" m == Just (VBool True) ->
                  let kind = fieldText m "kind"
                      loaded = Map.lookup "loaded" m == Just (VBool True)
                   in do
                        void $
                          emit
                            (seTracer env)
                            (SkillLoad (srQName (agStepRef ag)) (srStepId (agStepRef ag)) skillId kind loaded)
                        recoverableJson env machine ag' tr tc rv
            _ -> recoverableJson env machine ag' tr tc rv
        _ -> recoverable env machine ag tr tc "missing argument 'id'"
  where
    fieldText m name = case Map.lookup name m of
      Just (VString t) -> t
      _ -> ""

recoverable :: StepEnv -> Machine -> AgentState -> ToolRound -> ToolCall -> Text -> IO (Either RuntimeError (Maybe RValue, Machine))
recoverable env machine ag tr tc msg = do
  void $
    emit
      (seTracer env)
      ( AgentToolResult
          (srQName (agStepRef ag))
          (srStepId (agStepRef ag))
          (agRound ag)
          (callIndex tr)
          (tc.tcName)
          (String msg)
          True
      )
  appendToolResult env machine ag tr tc msg

recoverableJson :: StepEnv -> Machine -> AgentState -> ToolRound -> ToolCall -> RValue -> IO (Either RuntimeError (Maybe RValue, Machine))
recoverableJson env machine ag tr tc rv = do
  void $
    emit
      (seTracer env)
      ( AgentToolResult
          (srQName (agStepRef ag))
          (srStepId (agStepRef ag))
          (agRound ag)
          (callIndex tr)
          (tc.tcName)
          (valueToJson rv)
          True
      )
  appendToolResult env machine ag tr tc (canonicalJson (valueToJson rv))

appendToolResult :: StepEnv -> Machine -> AgentState -> ToolRound -> ToolCall -> Text -> IO (Either RuntimeError (Maybe RValue, Machine))
appendToolResult env machine ag tr tc content = do
  let tr' = tr {trCompleted = toolResult tc content : trCompleted tr, trActive = Nothing}
  if null (trPending tr')
    then finishToolRound env machine ag tr'
    else
      pure . Right . (Nothing,) $
        machine
          { mCurrent = CurAgent ag {agToolRound = Just tr'}
          }

finishToolRound :: StepEnv -> Machine -> AgentState -> ToolRound -> IO (Either RuntimeError (Maybe RValue, Machine))
finishToolRound env machine ag tr = do
  let assistantTurn = trAssistant tr
      toolTurn = ToolTurn (reverse (trCompleted tr))
      pa = agPending ag
      pa' =
        pa
          { paHistory = paHistory pa <> [assistantTurn, toolTurn],
            paToolRounds = paToolRounds pa <> [toolTurn]
          }
      ag' =
        ag
          { agPending = pa',
            agRound = agRound ag + 1,
            agToolRound = Nothing
          }
  void $ emit (seTracer env) (AgentRoundEnd (srQName (agStepRef ag)) (srStepId (agStepRef ag)) (agRound ag) False)
  pure . Right . (Nothing,) $ machine {mCurrent = CurAgent ag'}

-- Dispatch -------------------------------------------------------------------

dispatchTool ::
  StepEnv ->
  Machine ->
  AgentState ->
  QName ->
  Ident ->
  Map Ident RValue ->
  IO (Either RuntimeError RValue)
dispatchTool env machine ag q sid argMap
  | isBuiltin q = runBuiltin (agentBuiltinEnv env machine ag q sid) q argMap
  | otherwise =
      case seRunWorkflow env of
        Nothing -> pure (Left (internalError "workflow dispatch seam not wired"))
        Just runWf -> do
          let childScope =
                mScope machine
                  <> srStepId (agStepRef ag)
                  <> "~r"
                  <> tshow (agRound ag)
                  <> "c"
                  <> tshow (callIndex (fromMaybe emptyToolRound (agToolRound ag)))
                  <> "/"
          runWf q childScope argMap
  where
    emptyToolRound =
      ToolRound (AssistantTurn "" Nothing []) [] [] Nothing

agentBuiltinEnv :: StepEnv -> Machine -> AgentState -> QName -> Ident -> BuiltinEnv
agentBuiltinEnv env machine _ag q sid =
  let manifest = tpManifest (seProject env)
   in BuiltinEnv
        { beWorkspace = seWorkspace env,
          beModels = seModels env,
          beTracer = seTracer env,
          beStep = Err.StepRef q sid,
          beExecPolicy = execPolicy manifest,
          beUsage = seUsage env,
          beIntrospect = pure (object []),
          beEvalWorkflow =
            Just
              EvalWorkflowSeam
                { ewsProject = seProject env,
                  ewsScope = mScope machine,
                  ewsExecute = \tp sc callee inputs -> do
                    let env' = env {seProject = tp}
                    case seRunWorkflow env' of
                      Nothing -> pure (Left (internalError "workflow dispatch seam not wired"))
                      Just runWf -> runWf callee sc inputs
                },
          beRunId = riRunId (seRunInfo env),
          beSkillCatalog = tpSkillCatalog (seProject env)
        }

-- Spec / tools ---------------------------------------------------------------

agentSpec :: StepEnv -> AgentState -> Either RuntimeError AgentSpec
agentSpec env ag = do
  let pa = agPending ag
  model <- lookupModel (paModelName pa) (seModels env)
  submit <-
    case paSubmitSchema pa of
      Nothing -> Right Nothing
      Just schema -> Right (Just (SubmitSpec {ssSchema = schema, ssToolDef = submitToolDef schema}))
  tools <- traverse (buildTool env) (paInitialTools pa)
  Right
    AgentSpec
      { asSystem = paSystem pa,
        asPrompt = paPrompt pa,
        asModelName = paModelName pa,
        asModel = model,
        asModelFingerprint = modelCatalogFingerprint (paModelName pa) (seModels env),
        asTools = tools,
        asMaxRounds = paMaxRounds pa,
        asSubmit = submit
      }

buildTool :: StepEnv -> RValue -> Either RuntimeError AdvertisedTool
buildTool env = \case
  VRef _ q -> do
    ins <- calleeInputTypes env q
    outs <- calleeOutputTypes env q
    Right
      AdvertisedTool
        { atQName = q,
          atToolDef = advertisedToolDef q ins,
          atInputs = ins,
          atOutputs = outs,
          atFingerprint = maybe "" fpText (fingerprintOfQName (seProject env) q)
        }
  _ -> Left (internalError "agent 'tools' element is not a ref value")

calleeInputTypes :: StepEnv -> QName -> Either RuntimeError [(Ident, Type)]
calleeInputTypes env q
  | isBuiltin q = case lookupBuiltin q of
      Just c -> Right (calleeInputs c)
      Nothing -> Left (internalError ("no such builtin: " <> renderQName q))
  | otherwise = case lookupTyped q (seProject env) of
      Just td -> Right (rsigInputs (tdSignature td))
      Nothing -> Left (internalError ("advertised tool not found: " <> renderQName q))

calleeOutputTypes :: StepEnv -> QName -> Either RuntimeError [(Ident, Type)]
calleeOutputTypes env q
  | isBuiltin q = case lookupBuiltin q of
      Just c -> Right (calleeOutputs c)
      Nothing -> Left (internalError ("no such builtin: " <> renderQName q))
  | otherwise = case lookupTyped q (seProject env) of
      Just td -> Right (rsigOutputs (tdSignature td))
      Nothing -> Left (internalError ("advertised tool not found: " <> renderQName q))

fingerprintOfQName :: TypedProject -> QName -> Maybe Fingerprint
fingerprintOfQName tp q = case lookupTyped q tp of
  Just td -> Just (tdFingerprint td)
  Nothing -> Nothing

fpText :: Fingerprint -> Text
fpText (Fingerprint t) = t

activeTools env pa =
  case (traverse (buildTool env) (paInitialTools pa), mapMaybe (buildToolFromId env) (paActiveToolIds pa)) of
    (Left e, _) -> Left (internalError (tshow e))
    (Right static, dynamic) -> Right (static ++ dynamic)

buildToolFromId :: StepEnv -> Text -> Maybe AdvertisedTool
buildToolFromId env skillId =
  case buildTool env (VRef RTool (qnameFromText skillId)) of
    Left _ -> Nothing
    Right t -> Just t

applyInjections :: PendingAgent -> (PendingAgent, [Turn])
applyInjections pa =
  case paPendingInjections pa of
    [] -> (pa, paHistory pa)
    pending ->
      ( pa {paPendingInjections = []},
        paHistory pa <> [UserTurn t | t <- pending]
      )

loadSkill :: StepEnv -> PendingAgent -> Text -> (PendingAgent, RValue)
loadSkill env pa skillId =
  case lookupSkillEntry (qnameFromText skillId) (tpSkillCatalog (seProject env)) of
    Nothing ->
      (pa, loadSkillResultRecord False "" False False "" ("unknown skill id '" <> skillId <> "'"))
    Just e ->
      case seKind e of
        SkillInstruction -> loadInstruction env pa e skillId
        SkillCallable -> loadCallable env pa e skillId

loadInstruction :: StepEnv -> PendingAgent -> SkillEntry -> Text -> (PendingAgent, RValue)
loadInstruction env pa e skillId =
  let policy = skillPolicyFromManifest (tpManifest (seProject env))
   in if skillId `elem` paLoadedInstructionIds pa
        then
          ( pa,
            loadSkillResultRecord True (skillKindText SkillInstruction) False False (fromMaybe "" (seBody e)) ""
          )
        else
          if length (paLoadedInstructionIds pa) >= spMaxInstructionLoads policy
            then (pa, loadSkillResultRecord False (skillKindText SkillInstruction) False False "" "instruction load cap exceeded")
            else
              let body = fromMaybe "" (seBody e)
                  newChars = paInstructionChars pa + T.length body
               in if newChars > spMaxInstructionChars policy
                    then (pa, loadSkillResultRecord False (skillKindText SkillInstruction) False False "" "instruction body exceeds max_instruction_chars")
                    else
                      let injection = instructionInjectionText skillId body
                       in ( pa
                              { paLoadedInstructionIds = skillId : paLoadedInstructionIds pa,
                                paInstructionChars = newChars,
                                paPendingInjections = paPendingInjections pa <> [injection]
                              },
                            loadSkillResultRecord True (skillKindText SkillInstruction) True True body ""
                          )

loadCallable :: StepEnv -> PendingAgent -> SkillEntry -> Text -> (PendingAgent, RValue)
loadCallable env pa e skillId =
  if skillId `elem` paActiveToolIds pa
        then (pa, loadSkillResultRecord True (skillKindText SkillCallable) False False "" "")
        else
          if not (seChecked e)
            then (pa, loadSkillResultRecord False (skillKindText SkillCallable) False False "" "callable skill failed hwfi check")
            else
              if not (seAgentEligible e)
                then (pa, loadSkillResultRecord False (skillKindText SkillCallable) False False "" "callable skill is not agent-eligible")
                else
                  if length (paActiveToolIds pa) >= spMaxCallableLoads (skillPolicyFromManifest (tpManifest (seProject env)))
                    then (pa, loadSkillResultRecord False (skillKindText SkillCallable) False False "" "callable load cap exceeded")
                    else
                      case buildTool env (VRef RTool (seId e)) of
                        Left _ ->
                          (pa, loadSkillResultRecord False (skillKindText SkillCallable) False False "" "callable skill could not be resolved")
                        Right _ ->
                          ( pa {paActiveToolIds = skillId : paActiveToolIds pa},
                            loadSkillResultRecord True (skillKindText SkillCallable) True False "" ""
                          )

-- Trace helpers --------------------------------------------------------------

emitToolCall :: StepEnv -> AgentState -> Int -> Int -> Text -> Value -> IO ()
emitToolCall env ag roundIx callIx toolLabel args =
  void $
    emit
      (seTracer env)
      (AgentToolCall (srQName (agStepRef ag)) (srStepId (agStepRef ag)) roundIx callIx toolLabel args)

emitLlmCall :: StepEnv -> AgentState -> [Turn] -> ChatResponse -> Double -> IO ()
emitLlmCall env ag messages resp cost =
  void $
    emit
      (seTracer env)
      ( LlmCall
          (srQName (agStepRef ag))
          (srStepId (agStepRef ag))
          (paModelName (agPending ag))
          (paSystem (agPending ag))
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

-- Response / small helpers ---------------------------------------------------

data AgentResponse = AgentResponse
  { arText :: Text,
    arReasoning :: Maybe Text,
    arToolCalls :: [ToolCall]
  }

responseOf :: ChatResponse -> AgentResponse
responseOf resp =
  AgentResponse
    { arText = resp.respText,
      arReasoning = resp.respReasoning,
      arToolCalls = [tc | ToolCallBlock tc <- resp.respContent]
    }

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

lookupTool :: [AdvertisedTool] -> Text -> Maybe AdvertisedTool
lookupTool tools name = lookup name [((atToolDef t).toolName, t) | t <- tools]

toolStepId :: AgentState -> Int -> Int -> Ident
toolStepId ag roundIx callIx =
  srStepId (agStepRef ag) <> "~r" <> tshow roundIx <> "c" <> tshow callIx

callIndex :: ToolRound -> Int
callIndex tr = length (trCompleted tr)

toolResult :: ToolCall -> Text -> ToolResult
toolResult tc = ToolResult tc.tcId tc.tcName

roundsValue :: Int -> RValue
roundsValue roundIx = VInt (fromIntegral (roundIx + 1))

tshow :: (Show a) => a -> Text
tshow = T.pack . show
