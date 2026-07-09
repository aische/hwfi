-- | The trace event schema (spec ?8.3) and an in-memory tracer.
--
-- The 'TraceEvent' ADT is the load-bearing, stable API surface described in
-- ?8.3: the same shape is both appended to @trace.jsonl@ (persistence lands in
-- M5) and exposed to workflows via @ctx.trace : List<TraceEvent>@ (?5.2), so
-- agents can pattern-match on it. This module owns the shape and its JSON
-- encoding; M5 layers the append-only file writer and resume reconstruction on
-- top of the same 'Tracer' seam.
--
-- Common fields (?8.3.1)  @tag@, @seq@, @at@, and for in-step events @qname@
-- and @step_id@  are attached by 'emit', which assigns the monotonic,
-- gap-free @seq@ and the ISO-8601 millisecond timestamp.
module Hwfi.Runtime.Trace
  ( FileOp (..),
    fileOpText,
    fileOpFromText,
    RunStatus (..),
    runStatusText,
    runStatusFromText,
    EventBody (..),
    TraceEvent (..),
    eventToJson,
    eventFromJson,
    renderEvent,
    Tracer,
    newTracer,
    newPersistentTracer,
    emit,
    snapshotEvents,
    snapshotJson,
    sliceTrace,
    eventStepRef,
    currentSeq,
  )
where

import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson (Value (..), encode, object, (.:), (.=), (.!=), (.:?))
import Data.Aeson.Types (Parser, parseMaybe, withObject)
import Data.ByteString.Lazy qualified as BSL
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (defaultTimeLocale, formatTime, getCurrentTime)
import Data.Vector qualified as V
import Hwfi.Ast.Name (Ident, QName, qnameFromText, renderQName)
import Hwfi.Runtime.Error (ErrorKind, errorKindFromText, errorKindText)
import Hwfi.Runtime.RunUsage (formatCostUsd)
import System.IO (Handle, hFlush)

-- | The @op@ discriminator of a 'FileIo' event (?8.3.2). Covers the M4 read
-- (@read@\/@write@\/@list@) and the M7 navigation\/mutation ops (?6.2).
data FileOp
  = OpRead
  | OpWrite
  | OpList
  | OpReadSlice
  | OpFind
  | OpGrep
  | OpEdit
  | OpMove
  | OpCopy
  | OpRemove
  | OpMakeDir
  | OpRemoveDir
  deriving stock (Eq, Show)

fileOpText :: FileOp -> Text
fileOpText = \case
  OpRead -> "read"
  OpWrite -> "write"
  OpList -> "list"
  OpReadSlice -> "read-slice"
  OpFind -> "find"
  OpGrep -> "grep"
  OpEdit -> "edit"
  OpMove -> "move"
  OpCopy -> "copy"
  OpRemove -> "remove"
  OpMakeDir -> "make-dir"
  OpRemoveDir -> "remove-dir"

-- | Parse a 'FileOp' from its wire spelling; defaults to 'OpList' on an
-- unrecognised value (its @bytes@ is 0 and it has no side effects).
fileOpFromText :: Text -> FileOp
fileOpFromText = \case
  "read" -> OpRead
  "write" -> OpWrite
  "read-slice" -> OpReadSlice
  "find" -> OpFind
  "grep" -> OpGrep
  "edit" -> OpEdit
  "move" -> OpMove
  "copy" -> OpCopy
  "remove" -> OpRemove
  "make-dir" -> OpMakeDir
  "remove-dir" -> OpRemoveDir
  _ -> OpList

-- | The terminal @status@ of a logical run (?8.3.2, ?8.3.3).
data RunStatus = Completed | Aborted | Crashed
  deriving stock (Eq, Show)

runStatusText :: RunStatus -> Text
runStatusText = \case
  Completed -> "completed"
  Aborted -> "aborted"
  Crashed -> "crashed"

-- | Parse a 'RunStatus' from its wire spelling; unknown values map to 'Aborted'.
runStatusFromText :: Text -> RunStatus
runStatusFromText = \case
  "completed" -> Completed
  "crashed" -> Crashed
  _ -> Aborted

-- | The variant-specific payload of a trace event (spec ?8.3.2). The common
-- @seq@\/@at@ fields live on 'TraceEvent'; in-step variants carry their
-- @qname@\/@step_id@ here.
data EventBody
  = -- | @run-start@: run id, entrypoint qname, root inputs (redacted), project hash.
    RunStart Text Text Value Text
  | -- | @step-start@: qname, step id, resolved args (redacted), cacheable flag.
    StepStart QName Ident Value Bool
  | -- | @step-end@: qname, step id, result (redacted), duration in ms.
    StepEnd QName Ident Value Int
  | -- | @llm-call@: qname, step id, model, system, prompt, response, tokens in\/out.
    LlmCall QName Ident Text Text Text Text Int Int Double
  | -- | @file-io@: qname, step id, op, workspace-relative path, byte count.
    FileIo QName Ident FileOp Text Int
  | -- | @exec@ (?8.3.2): qname, step id, allowlisted program basename, argv
    -- (redacted), exit code, timed-out flag, captured stdout\/stderr byte sizes.
    Exec QName Ident Text Value Int Bool Int Int
  | -- | @error@: qname, step id, message, kind.
    ErrorEvent QName Ident Text ErrorKind
  | -- | @agent-round-start@ (?8.3.2): qname, step id, 0-based round index.
    AgentRoundStart QName Ident Int
  | -- | @agent-tool-call@ (?8.3.2): qname, step id, round, call index within
    -- the round, resolved tool qname (or @"submit"@), decoded args (redacted).
    AgentToolCall QName Ident Int Int Text Value
  | -- | @agent-tool-result@ (?8.3.2): qname, step id, round, call index, tool,
    -- serialised result (redacted), and whether it is a fed-back recoverable
    -- error (?6.1.4).
    AgentToolResult QName Ident Int Int Text Value Bool
  | -- | @agent-round-end@ (?8.3.2): qname, step id, round, whether the model
    -- terminated the loop this round.
    AgentRoundEnd QName Ident Int Bool
  | -- | @if-branch@ (?13, M8): qname, if-id, the branch taken
    -- (@"then"@\/@"else"@\/@"none"@).
    IfBranch QName Ident Text
  | -- | @loop-start@ (?13, M8; ?4.3, M9): qname, loop-id, kind
  -- (@"foreach"@\/@"par"@\/@"while"@), iteration count (@Nothing@ for @while@).
    LoopStart QName Ident Text (Maybe Int)
  | -- | @loop-iter@ (?13, M8): qname, loop-id, 0-based iteration index.
    LoopIter QName Ident Int
  | -- | @loop-end@ (?13, M8): qname, loop-id, iteration count.
    LoopEnd QName Ident Int
  | -- | @while-pred@ (?4.3, M9): qname, while-id, iteration, predicate decision.
    WhilePred QName Ident Int Bool Text
  | -- | @workflow-log@ (?13.1.5): qname, step id, message, optional fields (redacted).
    WorkflowLog QName Ident Text Value
  | -- | @skill-discover@ (6.7.1): qname, step id, query, kinds, limit, result count.
    SkillDiscover QName Ident Text [Text] Int Int
  | -- | @skill-load@ (6.7.2): qname, step id, skill id, kind, loaded flag.
    SkillLoad QName Ident Text Text Bool
  | -- | @resumed@: run id, last seq of the interrupted attempt.
    Resumed Text Int
  | -- | @run-end@: run id, terminal status.
    RunEnd Text RunStatus
  deriving stock (Eq, Show)

-- | A trace event with its assigned common fields.
data TraceEvent = TraceEvent
  { teSeq :: !Int,
    teAt :: !Text,
    teBody :: !EventBody
  }
  deriving stock (Eq, Show)

-- | Encode a trace event as a single JSON object (spec ?8.3). Field names and
-- @tag@ spellings match the schema verbatim.
eventToJson :: TraceEvent -> Value
eventToJson (TraceEvent s at body) = object (common <> bodyPairs)
  where
    common = ["seq" .= s, "at" .= at]
    bodyPairs = case body of
      RunStart runId entry inputs projectHash ->
        [ "tag" .= ("run-start" :: Text),
          "run_id" .= runId,
          "entrypoint" .= entry,
          "inputs" .= inputs,
          "project_hash" .= projectHash
        ]
      StepStart q sid args cacheable ->
        [ "tag" .= ("step-start" :: Text),
          "qname" .= renderQName q,
          "step_id" .= sid,
          "args" .= args,
          "cacheable" .= cacheable
        ]
      StepEnd q sid result durMs ->
        [ "tag" .= ("step-end" :: Text),
          "qname" .= renderQName q,
          "step_id" .= sid,
          "result" .= result,
          "duration_ms" .= durMs
        ]
      LlmCall q sid model system prompt response tin tout cost ->
        [ "tag" .= ("llm-call" :: Text),
          "qname" .= renderQName q,
          "step_id" .= sid,
          "model" .= model,
          "system" .= system,
          "prompt" .= prompt,
          "response" .= response,
          "tokens_in" .= tin,
          "tokens_out" .= tout,
          "cost_usd" .= cost
        ]
      FileIo q sid op path bytes ->
        [ "tag" .= ("file-io" :: Text),
          "qname" .= renderQName q,
          "step_id" .= sid,
          "op" .= fileOpText op,
          "path" .= path,
          "bytes" .= bytes
        ]
      Exec q sid program args exitCode timedOut outBytes errBytes ->
        [ "tag" .= ("exec" :: Text),
          "qname" .= renderQName q,
          "step_id" .= sid,
          "program" .= program,
          "args" .= args,
          "exit_code" .= exitCode,
          "timed_out" .= timedOut,
          "stdout_bytes" .= outBytes,
          "stderr_bytes" .= errBytes
        ]
      ErrorEvent q sid message kind ->
        [ "tag" .= ("error" :: Text),
          "qname" .= renderQName q,
          "step_id" .= sid,
          "message" .= message,
          "kind" .= errorKindText kind
        ]
      AgentRoundStart q sid round_ ->
        [ "tag" .= ("agent-round-start" :: Text),
          "qname" .= renderQName q,
          "step_id" .= sid,
          "round" .= round_
        ]
      AgentToolCall q sid round_ callIx tool args ->
        [ "tag" .= ("agent-tool-call" :: Text),
          "qname" .= renderQName q,
          "step_id" .= sid,
          "round" .= round_,
          "call_index" .= callIx,
          "tool" .= tool,
          "args" .= args
        ]
      AgentToolResult q sid round_ callIx tool result recoverable ->
        [ "tag" .= ("agent-tool-result" :: Text),
          "qname" .= renderQName q,
          "step_id" .= sid,
          "round" .= round_,
          "call_index" .= callIx,
          "tool" .= tool,
          "result" .= result,
          "recoverable_error" .= recoverable
        ]
      AgentRoundEnd q sid round_ finished ->
        [ "tag" .= ("agent-round-end" :: Text),
          "qname" .= renderQName q,
          "step_id" .= sid,
          "round" .= round_,
          "finished" .= finished
        ]
      IfBranch q sid branch ->
        [ "tag" .= ("if-branch" :: Text),
          "qname" .= renderQName q,
          "step_id" .= sid,
          "branch" .= branch
        ]
      LoopStart q sid kind mCount ->
        [ "tag" .= ("loop-start" :: Text),
          "qname" .= renderQName q,
          "step_id" .= sid,
          "kind" .= kind
        ]
          <> maybe [] (\n -> ["count" .= n]) mCount
      LoopIter q sid ix ->
        [ "tag" .= ("loop-iter" :: Text),
          "qname" .= renderQName q,
          "step_id" .= sid,
          "index" .= ix
        ]
      LoopEnd q sid count ->
        [ "tag" .= ("loop-end" :: Text),
          "qname" .= renderQName q,
          "step_id" .= sid,
          "count" .= count
        ]
      WhilePred q sid ix cont reason ->
        [ "tag" .= ("while-pred" :: Text),
          "qname" .= renderQName q,
          "step_id" .= sid,
          "iteration" .= ix,
          "continue" .= cont,
          "reason" .= reason
        ]
      WorkflowLog q sid message fields ->
        [ "tag" .= ("workflow-log" :: Text),
          "qname" .= renderQName q,
          "step_id" .= sid,
          "message" .= message,
          "fields" .= fields
        ]
      SkillDiscover q sid query kinds limit count ->
        [ "tag" .= ("skill-discover" :: Text),
          "qname" .= renderQName q,
          "step_id" .= sid,
          "query" .= query,
          "kinds" .= kinds,
          "limit" .= limit,
          "result_count" .= count
        ]
      SkillLoad q sid skillId kind loaded ->
        [ "tag" .= ("skill-load" :: Text),
          "qname" .= renderQName q,
          "step_id" .= sid,
          "id" .= skillId,
          "kind" .= kind,
          "loaded" .= loaded
        ]
      Resumed runId fromSeq ->
        [ "tag" .= ("resumed" :: Text),
          "run_id" .= runId,
          "from_seq" .= fromSeq
        ]
      RunEnd runId status ->
        [ "tag" .= ("run-end" :: Text),
          "run_id" .= runId,
          "status" .= runStatusText status
        ]

-- | Decode a single @trace.jsonl@ line back into a 'TraceEvent' (spec ?8.3),
-- the inverse of 'eventToJson'. Used to reconstruct @ctx.trace@ and continue
-- @seq@ numbering on resume (?8.3.5, ?8.2), and by @hwfi show@. Returns
-- 'Nothing' on a malformed line so a corrupt trailing write (e.g. from a crash
-- mid-append) is skipped rather than aborting the reader.
eventFromJson :: Value -> Maybe TraceEvent
eventFromJson = parseMaybe parseEvent

parseEvent :: Value -> Parser TraceEvent
parseEvent = withObject "TraceEvent" $ \o -> do
  s <- o .: "seq"
  at <- o .: "at"
  tag <- o .: "tag" :: Parser Text
  body <- parseBody tag o
  pure (TraceEvent s at body)
  where
    parseBody tag o = case tag of
      "run-start" ->
        RunStart <$> o .: "run_id" <*> o .: "entrypoint" <*> o .: "inputs" <*> o .: "project_hash"
      "step-start" ->
        StepStart <$> qn o <*> o .: "step_id" <*> o .: "args" <*> o .: "cacheable"
      "step-end" ->
        StepEnd <$> qn o <*> o .: "step_id" <*> o .: "result" <*> o .: "duration_ms"
      "llm-call" ->
        LlmCall
          <$> qn o
          <*> o .: "step_id"
          <*> o .: "model"
          <*> o .: "system"
          <*> o .: "prompt"
          <*> o .: "response"
          <*> o .: "tokens_in"
          <*> o .: "tokens_out"
          <*> o .:? "cost_usd" .!= 0
      "file-io" ->
        FileIo <$> qn o <*> o .: "step_id" <*> (fileOpFromText <$> o .: "op") <*> o .: "path" <*> o .: "bytes"
      "exec" ->
        Exec
          <$> qn o
          <*> o .: "step_id"
          <*> o .: "program"
          <*> o .: "args"
          <*> o .: "exit_code"
          <*> o .: "timed_out"
          <*> o .: "stdout_bytes"
          <*> o .: "stderr_bytes"
      "error" ->
        ErrorEvent <$> qn o <*> o .: "step_id" <*> o .: "message" <*> (errorKindFromText <$> o .: "kind")
      "agent-round-start" ->
        AgentRoundStart <$> qn o <*> o .: "step_id" <*> o .: "round"
      "agent-tool-call" ->
        AgentToolCall
          <$> qn o
          <*> o .: "step_id"
          <*> o .: "round"
          <*> o .: "call_index"
          <*> o .: "tool"
          <*> o .: "args"
      "agent-tool-result" ->
        AgentToolResult
          <$> qn o
          <*> o .: "step_id"
          <*> o .: "round"
          <*> o .: "call_index"
          <*> o .: "tool"
          <*> o .: "result"
          <*> o .: "recoverable_error"
      "agent-round-end" ->
        AgentRoundEnd <$> qn o <*> o .: "step_id" <*> o .: "round" <*> o .: "finished"
      "if-branch" ->
        IfBranch <$> qn o <*> o .: "step_id" <*> o .: "branch"
      "loop-start" ->
        LoopStart <$> qn o <*> o .: "step_id" <*> o .: "kind" <*> o .:? "count"
      "loop-iter" ->
        LoopIter <$> qn o <*> o .: "step_id" <*> o .: "index"
      "loop-end" ->
        LoopEnd <$> qn o <*> o .: "step_id" <*> o .: "count"
      "while-pred" ->
        WhilePred <$> qn o <*> o .: "step_id" <*> o .: "iteration" <*> o .: "continue" <*> o .: "reason"
      "workflow-log" ->
        WorkflowLog <$> qn o <*> o .: "step_id" <*> o .: "message" <*> o .: "fields"
      "skill-discover" ->
        SkillDiscover <$> qn o <*> o .: "step_id" <*> o .: "query" <*> o .: "kinds" <*> o .: "limit" <*> o .: "result_count"
      "skill-load" ->
        SkillLoad <$> qn o <*> o .: "step_id" <*> o .: "id" <*> o .: "kind" <*> o .: "loaded"
      "resumed" ->
        Resumed <$> o .: "run_id" <*> o .: "from_seq"
      "run-end" ->
        RunEnd <$> o .: "run_id" <*> (runStatusFromText <$> o .: "status")
      other -> fail ("unknown trace tag: " <> T.unpack other)
    qn o = qnameFromText <$> o .: "qname"

-- | A one-line human-readable rendering of a trace event for @hwfi show@
-- (spec ?9). Not a wire format; 'eventToJson' remains the persisted form.
renderEvent :: TraceEvent -> Text
renderEvent (TraceEvent s at body) =
  pad6 s <> "  " <> at <> "  " <> renderBody body
  where
    pad6 n = let t = T.pack (show n) in T.replicate (max 0 (6 - T.length t)) " " <> t
    at' = renderQName
    step q sid = at' q <> "#" <> sid
    renderBody = \case
      RunStart runId entry _ ph ->
        "run-start   " <> runId <> "  entry=" <> entry <> "  project=" <> shortHash ph
      StepStart q sid _ cacheable ->
        "step-start  " <> step q sid <> (if cacheable then "  [cacheable]" else "  [volatile]")
      StepEnd q sid _ ms ->
        "step-end    " <> step q sid <> "  " <> T.pack (show ms) <> "ms"
      LlmCall q sid model _ _ _ tin tout cost ->
        "llm-call    "
          <> step q sid
          <> "  model="
          <> model
          <> "  tokens="
          <> T.pack (show tin)
          <> "/"
          <> T.pack (show tout)
          <> "  $"
          <> formatCostUsd cost
      FileIo q sid op path bytes ->
        "file-io     " <> step q sid <> "  " <> fileOpText op <> " " <> path <> " (" <> T.pack (show bytes) <> "B)"
      Exec q sid program _ exitCode timedOut _ _ ->
        "exec        "
          <> step q sid
          <> "  "
          <> program
          <> "  exit="
          <> T.pack (show exitCode)
          <> (if timedOut then " [timed-out]" else "")
      ErrorEvent q sid msg _ ->
        "error       " <> step q sid <> "  " <> msg
      AgentRoundStart q sid round_ ->
        "agent-round " <> step q sid <> "  round=" <> T.pack (show round_) <> " start"
      AgentToolCall q sid round_ callIx tool _ ->
        "agent-call  " <> step q sid <> "  round=" <> T.pack (show round_) <> " #" <> T.pack (show callIx) <> "  " <> tool
      AgentToolResult q sid round_ callIx tool _ recoverable ->
        "agent-result"
          <> " "
          <> step q sid
          <> "  round="
          <> T.pack (show round_)
          <> " #"
          <> T.pack (show callIx)
          <> "  "
          <> tool
          <> (if recoverable then "  [recoverable]" else "")
      AgentRoundEnd q sid round_ finished ->
        "agent-round " <> step q sid <> "  round=" <> T.pack (show round_) <> (if finished then " end [final]" else " end")
      IfBranch q sid branch ->
        "if-branch   " <> step q sid <> "  -> " <> branch
      LoopStart q sid kind mCount ->
        "loop-start  "
          <> step q sid
          <> "  "
          <> kind
          <> maybe "" (\n -> "  count=" <> T.pack (show n)) mCount
      LoopIter q sid ix ->
        "loop-iter   " <> step q sid <> "  #" <> T.pack (show ix)
      LoopEnd q sid count ->
        "loop-end    " <> step q sid <> "  count=" <> T.pack (show count)
      WhilePred q sid ix cont reason ->
        "while-pred  "
          <> step q sid
          <> "  #"
          <> T.pack (show ix)
          <> "  continue="
          <> (if cont then "true" else "false")
          <> "  "
          <> reason
      WorkflowLog q sid message fields ->
        "workflow-log " <> step q sid <> "  " <> message <> fieldsSuffix fields
      SkillDiscover q sid query _ limit count ->
        "skill-discover " <> step q sid <> "  query=" <> query <> "  limit=" <> T.pack (show limit) <> "  count=" <> T.pack (show count)
      SkillLoad q sid skillId kind loaded ->
        "skill-load    " <> step q sid <> "  id=" <> skillId <> "  kind=" <> kind <> "  loaded=" <> (if loaded then "true" else "false")
      Resumed runId fromSeq ->
        "resumed     " <> runId <> "  from_seq=" <> T.pack (show fromSeq)
      RunEnd runId status ->
        "run-end     " <> runId <> "  status=" <> runStatusText status
    shortHash = T.take 12
    fieldsSuffix Null = ""
    fieldsSuffix (Object km) | KM.null km = ""
    fieldsSuffix _ = "  (+fields)"

-- | An event accumulator with an optional append-only file sink. Holds the
-- next @seq@ and the events so far in reverse chronological order. When a sink
-- is present, 'emit' also appends the event's JSON line to @trace.jsonl@ and
-- flushes, so a crash mid-run leaves a durable prefix to resume from (?8.2).
--
-- The 'MVar' serialises the whole of 'emit' so that concurrent @par@
-- iterations (?13, M8) cannot interleave @seq@ assignment with the file write:
-- the persisted line order always matches @seq@ order, which resume relies on
-- to reconstruct @ctx.trace@ identically (?8.3.5).
data Tracer = Tracer (MVar ()) (IORef (Int, [TraceEvent])) (Maybe Handle)

-- | Create a fresh in-memory tracer starting at @seq = 0@ (spec ?8.3.1). Used
-- by tests and callers that do not persist.
newTracer :: IO Tracer
newTracer = do
  lock <- newMVar ()
  ref <- newIORef (0, [])
  pure (Tracer lock ref Nothing)

-- | Create a tracer that appends every emitted event to @h@, seeded with the
-- events already persisted (in chronological order) and the next @seq@ to
-- assign. On a fresh run this is @(h, [], 0)@; on resume it is the parsed
-- @trace.jsonl@ and @last-seq + 1@ (spec ?8.2, ?8.3.5).
newPersistentTracer :: Handle -> [TraceEvent] -> Int -> IO Tracer
newPersistentTracer h preload nextSeq = do
  lock <- newMVar ()
  ref <- newIORef (nextSeq, reverse preload)
  pure (Tracer lock ref (Just h))

-- | Append an event, assigning it the next @seq@ and the current timestamp,
-- and persisting it to the sink (if any) before returning. The critical
-- section is held under the tracer mutex so concurrent emitters produce a
-- consistent, in-order trace (?13, M8).
emit :: Tracer -> EventBody -> IO TraceEvent
emit (Tracer lock ref sink) body = withMVar lock $ \_ -> do
  now <- getCurrentTime
  let at = T.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S%3QZ" now)
  ev <-
    atomicModifyIORef' ref $ \(nextSeq, evs) ->
      let e = TraceEvent nextSeq at body
       in ((nextSeq + 1, e : evs), e)
  case sink of
    Nothing -> pure ()
    Just h -> do
      BSL.hPut h (encode (eventToJson ev) <> "\n")
      hFlush h
  pure ev

-- | All events so far, in chronological order (spec ?8.3.5: @ctx.trace@ is the
-- ordered parse of the trace as persisted so far).
snapshotEvents :: Tracer -> IO [TraceEvent]
snapshotEvents (Tracer _ ref _) = reverse . snd <$> readIORef ref

-- | The events so far as a JSON array, one object per event.
snapshotJson :: Tracer -> IO Value
snapshotJson t = Array . V.fromList . map eventToJson <$> snapshotEvents t

-- | The @seq@ that will be assigned to the next emitted event.
currentSeq :: Tracer -> IO Int
currentSeq (Tracer _ ref _) = fst <$> readIORef ref

-- Trace slice (?6.6.2) -------------------------------------------------------

-- | Extract the @(qname, step_id)@ pair carried by an in-step event body, if
-- any.
eventStepRef :: EventBody -> Maybe (QName, Ident)
eventStepRef = \case
  StepStart q sid _ _ -> Just (q, sid)
  StepEnd q sid _ _ -> Just (q, sid)
  LlmCall q sid _ _ _ _ _ _ _ -> Just (q, sid)
  FileIo q sid _ _ _ -> Just (q, sid)
  Exec q sid _ _ _ _ _ _ -> Just (q, sid)
  ErrorEvent q sid _ _ -> Just (q, sid)
  AgentRoundStart q sid _ -> Just (q, sid)
  AgentToolCall q sid _ _ _ _ -> Just (q, sid)
  AgentToolResult q sid _ _ _ _ _ -> Just (q, sid)
  AgentRoundEnd q sid _ _ -> Just (q, sid)
  IfBranch q sid _ -> Just (q, sid)
  LoopStart q sid _ _ -> Just (q, sid)
  LoopIter q sid _ -> Just (q, sid)
  LoopEnd q sid _ -> Just (q, sid)
  WhilePred q sid _ _ _ -> Just (q, sid)
  _ -> Nothing

-- | Return events belonging to one logical step in trace order (?6.6.2).
-- When @includeNested@ is false, only events whose @(qname, step_id)@ exactly
-- match are kept. When true, also includes nested sub-workflow events that fall
-- between the target step's @step-start@ and terminal (@step-end@ or @error@).
sliceTrace :: [TraceEvent] -> QName -> Ident -> Bool -> [TraceEvent]
sliceTrace events targetQ targetSid includeNested
  | includeNested = sliceNested events targetQ targetSid
  | otherwise = filter (eventMatches targetQ targetSid) events
  where
    eventMatches q sid (TraceEvent _ _ body) = case eventStepRef body of
      Just (q', sid') -> q' == q && sid' == sid
      Nothing -> False

sliceNested :: [TraceEvent] -> QName -> Ident -> [TraceEvent]
sliceNested events targetQ targetSid = go False events
  where
    go _ [] = []
    go inside (ev@(TraceEvent _ _ body) : es)
      | isTargetStart body =
          ev : go True es
      | inside && isTargetEnd body =
          ev : go False es
      | inside =
          ev : go True es
      | otherwise =
          go False es
    isTargetStart body = case body of
      StepStart q sid _ _ -> q == targetQ && sid == targetSid
      _ -> False
    isTargetEnd body = case body of
      StepEnd q sid _ _ -> q == targetQ && sid == targetSid
      ErrorEvent q sid _ _ -> q == targetQ && sid == targetSid
      _ -> False
