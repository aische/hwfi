-- | JSON persistence for 'Machine' snapshots (v2 runtime).
module Hwfi.Runtime.MachineSnapshot
  ( encodeMachine,
    decodeMachine,
  )
where

import Control.Monad (unless)
import Data.Bifunctor (first)
import Data.Aeson
  ( ToJSON (..),
    Value (..),
    object,
    withArray,
    withObject,
    (.:),
    (.:?),
    (.=),
  )
import Data.Aeson.Types (Parser, parseEither, (.!=))
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Hwfi.Ast.Name (Ident, qnameFromText, renderQName)
import Hwfi.Ast.Step (Binder (..), ParOnError (..), StepStmt (..))
import Hwfi.Ast.Step qualified as Step
import Hwfi.Runtime.Machine
import Hwfi.Runtime.Value (RValue (..), RefKind (..), coerceFromJson, valueToJson)
import Hwfi.Source (Pos (..), singletonSpan)
import Hwfi.Type (Type (TyJson))

encodeMachine :: Machine -> Value
encodeMachine m =
  object
    [ "version" .= (2 :: Int),
      "status" .= encodeStatus (mStatus m),
      "project_hash" .= mProjectHash m,
      "scope" .= mScope m,
      "path" .= encodePath (mPath m),
      "current" .= encodeCurrent (mCurrent m),
      "frames" .= map encodeFrame (mFrames m),
      "bindings" .= encodeBindings (mBindings m),
      "last_result" .= fmap valueToJson (mLastResult m),
      "error" .= mError m
    ]

decodeMachine :: Value -> Either Text Machine
decodeMachine v = first T.pack (parseEither parseMachine v)

parseMachine :: Value -> Parser Machine
parseMachine =
  withObject "machine" $ \o -> do
    ver <- o .: "version"
    unless (ver == (2 :: Int)) $ fail "unsupported machine snapshot version"
    Machine
      <$> (o .: "status" >>= parseStatus)
      <*> o .: "project_hash"
      <*> o .: "scope"
      <*> (o .: "path" >>= parsePath)
      <*> (o .: "current" >>= parseCurrent)
      <*> (o .: "frames" >>= parseFrames)
      <*> (o .: "bindings" >>= parseBindings)
      <*> (o .:? "last_result" >>= traverse parseRValue)
      <*> o .:? "error"

parseFrames :: Value -> Parser [Frame]
parseFrames = withArray "frames" $ \a -> traverse parseFrame (V.toList a)

parseRValue :: Value -> Parser RValue
parseRValue v = case coerceFromJson TyJson v of
  Left e -> fail (T.unpack e)
  Right r -> pure r

encodeStatus :: MachineStatus -> Value
encodeStatus = \case
  MsRunning -> object ["tag" .= ("running" :: Text)]
  MsDraining -> object ["tag" .= ("draining" :: Text)]
  MsPaused r -> object ["tag" .= ("paused" :: Text), "reason" .= encodePause r]
  MsCompleted -> object ["tag" .= ("completed" :: Text)]
  MsFailed -> object ["tag" .= ("failed" :: Text)]

parseStatus :: Value -> Parser MachineStatus
parseStatus = withObject "status" $ \o -> do
  tag <- o .: "tag"
  case tag of
    "running" -> pure MsRunning
    "draining" -> pure MsDraining
    "paused" -> MsPaused <$> (o .: "reason" >>= parsePause)
    "completed" -> pure MsCompleted
    "failed" -> pure MsFailed
    _ -> fail ("unknown machine status: " <> T.unpack tag)

encodePause :: PauseReason -> Value
encodePause = \case
  PauseExplicit -> object ["tag" .= ("explicit" :: Text)]
  PauseAwaitingConfirm c -> object ["tag" .= ("awaiting_confirm" :: Text), "confirm" .= encodeConfirm c]
  PauseCrashRecovery -> object ["tag" .= ("crash_recovery" :: Text)]

parsePause :: Value -> Parser PauseReason
parsePause = withObject "pause" $ \o -> do
  tag <- o .: "tag"
  case tag of
    "explicit" -> pure PauseExplicit
    "awaiting_confirm" -> PauseAwaitingConfirm <$> (o .: "confirm" >>= parseConfirm)
    "crash_recovery" -> pure PauseCrashRecovery
    _ -> fail ("unknown pause reason: " <> T.unpack tag)

encodeConfirm :: ConfirmRequest -> Value
encodeConfirm c =
  object
    [ "branch_index" .= crBranchIndex c,
      "qname" .= renderQName (crQName c),
      "step_id" .= crStepId c,
      "title" .= crTitle c,
      "detail" .= crDetail c
    ]

parseConfirm :: Value -> Parser ConfirmRequest
parseConfirm = withObject "confirm" $ \o ->
  ConfirmRequest <$> o .:? "branch_index" <*> (qnameFromText <$> o .: "qname") <*> o .: "step_id" <*> o .: "title"
    <*> o .: "detail"

encodePath :: StmtPath -> Value
encodePath (StmtPath q segs) =
  object
    [ "qname" .= renderQName q,
      "segments" .= map encodeSegment segs
    ]

parsePath :: Value -> Parser StmtPath
parsePath = withObject "path" $ \o ->
  (StmtPath . qnameFromText <$> (o .: "qname")) <*> (o .: "segments" >>= traverse parseSegment)

encodeSegment :: PathSegment -> Value
encodeSegment (PathSegment i mBlock) =
  object
    [ "index" .= i,
      "block" .= fmap encodeBlock mBlock
    ]

parseSegment :: Value -> Parser PathSegment
parseSegment = withObject "segment" $ \o ->
  PathSegment <$> o .: "index" <*> (o .:? "block" >>= traverse parseBlockText)

encodeBlock :: BlockKind -> Text
encodeBlock = \case
  BkIfThen -> "if_then"
  BkIfElse -> "if_else"
  BkLoopBody -> "loop_body"
  BkTryTry -> "try_try"
  BkTryCatch -> "try_catch"
  BkWhileInline -> "while_inline"

parseBlockText :: Text -> Parser BlockKind
parseBlockText t = case decodeBlockText t of
  Left e -> fail (T.unpack e)
  Right b -> pure b

decodeBlockText :: Text -> Either Text BlockKind
decodeBlockText = \case
  "if_then" -> Right BkIfThen
  "if_else" -> Right BkIfElse
  "loop_body" -> Right BkLoopBody
  "try_try" -> Right BkTryTry
  "try_catch" -> Right BkTryCatch
  "while_inline" -> Right BkWhileInline
  t -> Left ("unknown block kind: " <> t)

encodeCurrent :: Current -> Value
encodeCurrent = \case
  CurReady -> object ["tag" .= ("ready" :: Text)]
  CurDispatch s ->
    object
      [ "tag" .= ("dispatch" :: Text),
        "step_id" .= stepId s,
        "target" .= renderQName (stepTarget s)
      ]
  CurAgent ag -> object ["tag" .= ("agent" :: Text), "agent" .= encodeAgent ag]
  CurAwaitConfirm c -> object ["tag" .= ("await_confirm" :: Text), "confirm" .= encodeConfirm c]
  CurParPool -> object ["tag" .= ("par_pool" :: Text)]

parseCurrent :: Value -> Parser Current
parseCurrent = withObject "current" $ \o -> do
  tag <- o .: "tag"
  case tag of
    "ready" -> pure CurReady
    "dispatch" -> do
      sid <- o .: "step_id"
      tgt <- qnameFromText <$> o .: "target"
      pure (CurDispatch (StepStmt BindDiscard tgt [] sid (singletonSpan (Pos 0 0))))
    "agent" -> CurAgent <$> (o .: "agent" >>= parseAgent)
    "await_confirm" -> CurAwaitConfirm <$> (o .: "confirm" >>= parseConfirm)
    "par_pool" -> pure CurParPool
    _ -> fail ("unknown current tag: " <> T.unpack tag)

encodeAgent :: AgentState -> Value
encodeAgent ag =
  object
    [ "step_ref"
        .= object
          [ "qname" .= renderQName (srQName (agStepRef ag)),
            "step_id" .= srStepId (agStepRef ag)
          ],
      "binder" .= encodeBinder (agBinder ag),
      "target" .= renderQName (agTarget ag),
      "round" .= agRound ag,
      "submit_required" .= agSubmitRequired ag,
      "pending" .= encodePending (agPending ag),
      "tool_round" .= fmap encodeToolRound (agToolRound ag)
    ]

parseAgent :: Value -> Parser AgentState
parseAgent = withObject "agent" $ \o -> do
  ref <- o .: "step_ref"
  qnText <- withObject "step_ref" (.: "qname") ref
  sid <- withObject "step_ref" (.: "step_id") ref
  binder <- o .:? "binder" >>= \case
    Just b -> parseBinderField b
    Nothing -> pure BindDiscard
  target <- qnameFromText <$> o .:? "target" .!= "builtin/llm-agent"
  pending <- o .: "pending" >>= parsePending
  roundIx <- o .: "round"
  submitReq <- o .: "submit_required"
  toolRound <- o .:? "tool_round" >>= traverse parseToolRound
  pure
    AgentState
      { agStepRef = StepRef (qnameFromText qnText) sid,
        agBinder = binder,
        agTarget = target,
        agPending = pending,
        agRound = roundIx,
        agSubmitRequired = submitReq,
        agToolRound = toolRound
      }

parseBinderField :: Text -> Parser Binder
parseBinderField = \case
  "_" -> pure BindDiscard
  n -> pure (BindName n)

encodePending :: PendingAgent -> Value
encodePending pa =
  object
    [ "system" .= paSystem pa,
      "prompt" .= paPrompt pa,
      "model" .= paModelName pa,
      "max_rounds" .= paMaxRounds pa,
      "initial_tools" .= initialToolQnames (paInitialTools pa),
      "submit_schema" .= paSubmitSchema pa,
      "history" .= toJSON (paHistory pa),
      "tool_rounds" .= toJSON (paToolRounds pa),
      "active_tool_ids" .= paActiveToolIds pa,
      "loaded_instruction_ids" .= paLoadedInstructionIds pa,
      "instruction_chars" .= paInstructionChars pa,
      "pending_injections" .= paPendingInjections pa
    ]

parsePending :: Value -> Parser PendingAgent
parsePending = withObject "pending" $ \o -> do
  system <- o .: "system"
  prompt <- o .: "prompt"
  modelName <- o .:? "model" .!= "fast"
  maxRounds <- o .:? "max_rounds" .!= 4
  initialTools <-
    o .:? "initial_tools" >>= \case
      Nothing -> pure []
      Just v -> parseInitialTools v
  submitSchema <- o .:? "submit_schema"
  history <- o .: "history"
  toolRounds <- o .:? "tool_rounds" .!= []
  activeIds <- o .:? "active_tool_ids" .!= []
  loadedIds <- o .:? "loaded_instruction_ids" .!= []
  instrChars <- o .:? "instruction_chars" .!= 0
  pendingInj <- o .:? "pending_injections" .!= []
  pure
    PendingAgent
      { paSystem = system,
        paPrompt = prompt,
        paModelName = modelName,
        paMaxRounds = maxRounds,
        paInitialTools = initialTools,
        paSubmitSchema = submitSchema,
        paHistory = history,
        paToolRounds = toolRounds,
        paActiveToolIds = activeIds,
        paLoadedInstructionIds = loadedIds,
        paInstructionChars = instrChars,
        paPendingInjections = pendingInj
      }

encodeToolRound :: ToolRound -> Value
encodeToolRound tr =
  object
    [ "assistant" .= toJSON (trAssistant tr),
      "pending" .= toJSON (trPending tr),
      "completed" .= toJSON (trCompleted tr),
      "active" .= fmap toJSON (trActive tr)
    ]

parseToolRound :: Value -> Parser ToolRound
parseToolRound = withObject "tool_round" $ \o ->
  ToolRound <$> o .: "assistant" <*> o .: "pending" <*> o .: "completed" <*> o .:? "active"

initialToolQnames :: [RValue] -> Value
initialToolQnames tools =
  Array (V.fromList [String (renderQName q) | VRef _ q <- tools])

parseInitialTools :: Value -> Parser [RValue]
parseInitialTools = withArray "initial_tools" $ \a ->
  traverse parseToolQname (V.toList a)
  where
    parseToolQname (String qn) = pure (VRef RTool (qnameFromText qn))
    parseToolQname v = fail ("initial_tools entry is not a qname string: " <> show v)

encodeFrame :: Frame -> Value
encodeFrame = \case
  FrSeq {fsScope, fsResumePath, fsBinder, fsBindings} ->
    object
      [ "tag" .= ("seq" :: Text),
        "scope" .= fsScope,
        "resume_path" .= encodePath fsResumePath,
        "binder" .= fmap encodeBinder fsBinder,
        "bindings" .= encodeBindings fsBindings
      ]
  FrPar pjs -> object ["tag" .= ("par" :: Text), "par" .= encodePar pjs]
  FrForeach ff -> object ["tag" .= ("foreach" :: Text), "foreach" .= encodeForeach ff]
  FrWhile wf -> object ["tag" .= ("while" :: Text), "while" .= encodeWhile wf]
  FrTry tf -> object ["tag" .= ("try" :: Text), "try" .= encodeTry tf]

parseFrame :: Value -> Parser Frame
parseFrame = withObject "frame" $ \o -> do
  tag <- o .: "tag"
  case tag of
    "seq" ->
      FrSeq <$> o .: "scope" <*> (o .: "resume_path" >>= parsePath) <*> (o .:? "binder" >>= traverse parseBinderText)
        <*> (o .:? "bindings" >>= maybe (pure Map.empty) parseBindings)
    "par" -> FrPar <$> (o .: "par" >>= parsePar)
    "foreach" -> FrForeach <$> (o .: "foreach" >>= parseForeach)
    "while" -> FrWhile <$> (o .: "while" >>= parseWhile)
    "try" -> FrTry <$> (o .: "try" >>= parseTry)
    _ -> fail ("unknown frame tag: " <> T.unpack tag)

encodePar :: ParJoinState -> Value
encodePar pjs =
  object
    [ "loop_id" .= pjsLoopId pjs,
      "scope" .= pjsScope pjs,
      "binder" .= encodeBinder (pjsBinder pjs),
      "max_concurrency" .= pjsMaxConcurrency pjs,
      "on_error" .= encodeParOnError (pjsOnError pjs),
      "items" .= map valueToJson (pjsItems pjs),
      "slots" .= map encodeParSlot (pjsSlots pjs),
      "active" .= encodeActive (pjsActive pjs),
      "next_index" .= pjsNextIndex pjs,
      "phase" .= encodeParPhase (pjsPhase pjs),
      "confirm_queue" .= map encodeConfirm (pjsConfirmQueue pjs),
      "loop_path" .= encodePath (pjsLoopPath pjs),
      "resume_path" .= encodePath (pjsResumePath pjs),
      "parent_bindings" .= encodeBindings (pjsParentBindings pjs)
    ]

parsePar :: Value -> Parser ParJoinState
parsePar = withObject "par" $ \o -> do
  items <- traverse parseRValue =<< o .: "items"
  ParJoinState
    <$> o .: "loop_id"
    <*> o .: "scope"
    <*> (o .: "binder" >>= parseBinderText)
    <*> o .: "max_concurrency"
    <*> (o .: "on_error" >>= parseParOnErrorText)
    <*> pure items
    <*> (o .: "slots" >>= traverse parseParSlot)
    <*> (o .: "active" >>= parseActive)
    <*> o .: "next_index"
    <*> (o .: "phase" >>= parseParPhaseText)
    <*> (o .: "confirm_queue" >>= traverse parseConfirm)
    <*> (o .: "loop_path" >>= parsePath)
    <*> (o .: "resume_path" >>= parsePath)
    <*> (o .:? "parent_bindings" >>= maybe (pure Map.empty) parseBindings)

encodeActive :: Map Int BranchMachine -> Value
encodeActive m =
  object [K.fromText (T.pack (show k)) .= encodeMachine (unBranch bm) | (k, bm) <- Map.toList m]

parseActive :: Value -> Parser (Map Int BranchMachine)
parseActive = withObject "active" $ \o ->
  Map.fromList <$> traverse parseActivePair (KM.toList o)
  where
    parseActivePair (k, v) = do
      idx <- parseIndexKey (K.toText k)
      bm <- parseMachine v
      pure (idx, mkBranch bm)
    parseIndexKey t = case reads (T.unpack t) of
      [(n, "")] -> pure n
      _ -> fail ("invalid branch index: " <> T.unpack t)

encodeParSlot :: ParSlot -> Value
encodeParSlot = \case
  ParSlotPending -> object ["tag" .= ("pending" :: Text)]
  ParSlotRunning -> object ["tag" .= ("running" :: Text)]
  ParSlotDone v -> object ["tag" .= ("done" :: Text), "value" .= valueToJson v]
  ParSlotFailed msg -> object ["tag" .= ("failed" :: Text), "error" .= msg]
  ParSlotAwaitingConfirm c -> object ["tag" .= ("awaiting_confirm" :: Text), "confirm" .= encodeConfirm c]

parseParSlot :: Value -> Parser ParSlot
parseParSlot = withObject "par_slot" $ \o -> do
  tag <- o .: "tag"
  case tag of
    "pending" -> pure ParSlotPending
    "running" -> pure ParSlotRunning
    "done" -> ParSlotDone <$> (o .: "value" >>= parseRValue)
    "failed" -> ParSlotFailed <$> o .: "error"
    "awaiting_confirm" -> ParSlotAwaitingConfirm <$> (o .: "confirm" >>= parseConfirm)
    _ -> fail ("unknown par slot: " <> T.unpack tag)

encodeParPhase :: ParPoolPhase -> Text
encodeParPhase = \case
  ParScheduling -> "scheduling"
  ParDraining -> "draining"
  ParPausedConfirm -> "paused_confirm"

parseParPhaseText :: Text -> Parser ParPoolPhase
parseParPhaseText t = case decodeParPhaseText t of
  Left e -> fail (T.unpack e)
  Right p -> pure p

decodeParPhaseText :: Text -> Either Text ParPoolPhase
decodeParPhaseText = \case
  "scheduling" -> Right ParScheduling
  "draining" -> Right ParDraining
  "paused_confirm" -> Right ParPausedConfirm
  t -> Left ("unknown par phase: " <> t)

encodeParOnError :: ParOnError -> Text
encodeParOnError = \case
  Step.ParOnErrorFail -> "fail"
  Step.ParOnErrorCollect -> "collect"

parseParOnErrorText :: Text -> Parser ParOnError
parseParOnErrorText t = case decodeParOnErrorText t of
  Left e -> fail (T.unpack e)
  Right p -> pure p

decodeParOnErrorText :: Text -> Either Text ParOnError
decodeParOnErrorText = \case
  "fail" -> Right Step.ParOnErrorFail
  "collect" -> Right Step.ParOnErrorCollect
  t -> Left ("unknown par on_error: " <> t)

encodeWhile :: WhileFrame -> Value
encodeWhile wf =
  object
    [ "loop_id" .= wfLoopId wf,
      "scope" .= wfScope wf,
      "binder" .= encodeBinder (wfBinder wf),
      "iteration" .= wfIteration wf,
      "max_iterations" .= wfMaxIterations wf,
      "acc" .= map valueToJson (wfAcc wf),
      "carry" .= fmap valueToJson (wfCarry wf),
      "resume_path" .= encodePath (wfResumePath wf),
      "while_path" .= encodePath (wfWhilePath wf),
      "phase" .= encodeWhilePhase (wfPhase wf)
    ]

parseWhile :: Value -> Parser WhileFrame
parseWhile = withObject "while" $ \o -> do
  acc <- traverse parseRValue =<< o .: "acc"
  carry <- o .:? "carry" >>= traverse parseRValue
  WhileFrame <$> o .: "loop_id" <*> o .: "scope" <*> (o .: "binder" >>= parseBinderText) <*> o .: "iteration"
    <*> o .: "max_iterations"
    <*> pure acc
    <*> pure carry
    <*> (o .: "resume_path" >>= parsePath)
    <*> (o .: "while_path" >>= parsePath)
    <*> (o .: "phase" >>= parseWhilePhaseText)

encodeWhilePhase :: WhilePhase -> Text
encodeWhilePhase = \case
  WhileRunPred -> "pred"
  WhileRunBody -> "body"

parseWhilePhaseText :: Text -> Parser WhilePhase
parseWhilePhaseText t = case decodeWhilePhaseText t of
  Left e -> fail (T.unpack e)
  Right p -> pure p

decodeWhilePhaseText :: Text -> Either Text WhilePhase
decodeWhilePhaseText = \case
  "pred" -> Right WhileRunPred
  "body" -> Right WhileRunBody
  t -> Left ("unknown while phase: " <> t)

encodeForeach :: ForeachFrame -> Value
encodeForeach ff =
  object
    [ "loop_id" .= ffLoopId ff,
      "scope" .= ffScope ff,
      "binder" .= encodeBinder (ffBinder ff),
      "var" .= ffVar ff,
      "items" .= map valueToJson (ffItems ff),
      "index" .= ffIndex ff,
      "acc" .= map valueToJson (ffAcc ff),
      "resume_path" .= encodePath (ffResumePath ff),
      "body_entry" .= encodePath (ffBodyEntry ff)
    ]

parseForeach :: Value -> Parser ForeachFrame
parseForeach = withObject "foreach" $ \o -> do
  items <- traverse parseRValue =<< o .: "items"
  acc <- traverse parseRValue =<< o .: "acc"
  ForeachFrame <$> o .: "loop_id" <*> o .: "scope" <*> (o .: "binder" >>= parseBinderText) <*> o .: "var"
    <*> pure items
    <*> o .: "index"
    <*> pure acc
    <*> (o .: "resume_path" >>= parsePath)
    <*> (o .: "body_entry" >>= parsePath)

encodeTry :: TryFrame -> Value
encodeTry tf =
  object
    [ "loop_id" .= tfLoopId tf,
      "scope" .= tfScope tf,
      "binder" .= encodeBinder (tfBinder tf),
      "phase" .= encodeTryPhase (tfPhase tf),
      "resume_path" .= encodePath (tfResumePath tf),
      "try_path" .= encodePath (tfTryPath tf)
    ]

parseTry :: Value -> Parser TryFrame
parseTry = withObject "try" $ \o ->
  TryFrame <$> o .: "loop_id" <*> o .: "scope" <*> (o .: "binder" >>= parseBinderText) <*> (o .: "phase" >>= parseTryPhaseText)
    <*> (o .: "resume_path" >>= parsePath)
    <*> (o .: "try_path" >>= parsePath)

encodeTryPhase :: TryPhase -> Text
encodeTryPhase = \case
  TryInTry -> "try"
  TryInCatch -> "catch"

parseTryPhaseText :: Text -> Parser TryPhase
parseTryPhaseText t = case decodeTryPhaseText t of
  Left e -> fail (T.unpack e)
  Right p -> pure p

decodeTryPhaseText :: Text -> Either Text TryPhase
decodeTryPhaseText = \case
  "try" -> Right TryInTry
  "catch" -> Right TryInCatch
  t -> Left ("unknown try phase: " <> t)

encodeBinder :: Binder -> Text
encodeBinder = \case
  BindName n -> n
  BindDiscard -> "_"

parseBinderText :: Text -> Parser Binder
parseBinderText t = case decodeBinderText t of
  Left e -> fail (T.unpack e)
  Right b -> pure b

decodeBinderText :: Text -> Either Text Binder
decodeBinderText t
  | t == "_" = Right BindDiscard
  | otherwise = Right (BindName t)

encodeBindings :: Map Ident RValue -> Value
encodeBindings bs =
  object [K.fromText k .= valueToJson v | (k, v) <- Map.toList bs]

parseBindings :: Value -> Parser (Map Ident RValue)
parseBindings = withObject "bindings" $ \o ->
  Map.fromList <$> traverse parseBindingPair (KM.toList o)
  where
    parseBindingPair (k, v) = do
      val <- parseRValue v
      pure (K.toText k, val)
