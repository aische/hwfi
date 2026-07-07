-- | The trace event schema (spec §8.3) and an in-memory tracer.
--
-- The 'TraceEvent' ADT is the load-bearing, stable API surface described in
-- §8.3: the same shape is both appended to @trace.jsonl@ (persistence lands in
-- M5) and exposed to workflows via @ctx.trace : List<TraceEvent>@ (§5.2), so
-- agents can pattern-match on it. This module owns the shape and its JSON
-- encoding; M5 layers the append-only file writer and resume reconstruction on
-- top of the same 'Tracer' seam.
--
-- Common fields (§8.3.1) — @tag@, @seq@, @at@, and for in-step events @qname@
-- and @step_id@ — are attached by 'emit', which assigns the monotonic,
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
    currentSeq,
  )
where

import Data.Aeson (Value (..), encode, object, (.:), (.=))
import Data.Aeson.Types (Parser, parseMaybe, withObject)
import Data.ByteString.Lazy qualified as BSL
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (defaultTimeLocale, formatTime, getCurrentTime)
import Data.Vector qualified as V
import Hwfi.Ast.Name (Ident, QName, qnameFromText, renderQName)
import Hwfi.Runtime.Error (ErrorKind, errorKindFromText, errorKindText)
import System.IO (Handle, hFlush)

-- | The @op@ discriminator of a 'FileIo' event (§8.3.2).
data FileOp = OpRead | OpWrite | OpList
  deriving stock (Eq, Show)

fileOpText :: FileOp -> Text
fileOpText = \case
  OpRead -> "read"
  OpWrite -> "write"
  OpList -> "list"

-- | Parse a 'FileOp' from its wire spelling; defaults to 'OpList' on an
-- unrecognised value (its @bytes@ is 0 and it has no side effects).
fileOpFromText :: Text -> FileOp
fileOpFromText = \case
  "read" -> OpRead
  "write" -> OpWrite
  _ -> OpList

-- | The terminal @status@ of a logical run (§8.3.2, §8.3.3).
data RunStatus = Completed | Aborted
  deriving stock (Eq, Show)

runStatusText :: RunStatus -> Text
runStatusText = \case
  Completed -> "completed"
  Aborted -> "aborted"

-- | Parse a 'RunStatus' from its wire spelling; defaults to 'Aborted'.
runStatusFromText :: Text -> RunStatus
runStatusFromText = \case
  "completed" -> Completed
  _ -> Aborted

-- | The variant-specific payload of a trace event (spec §8.3.2). The common
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
    LlmCall QName Ident Text Text Text Text Int Int
  | -- | @file-io@: qname, step id, op, workspace-relative path, byte count.
    FileIo QName Ident FileOp Text Int
  | -- | @error@: qname, step id, message, kind.
    ErrorEvent QName Ident Text ErrorKind
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

-- | Encode a trace event as a single JSON object (spec §8.3). Field names and
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
      LlmCall q sid model system prompt response tin tout ->
        [ "tag" .= ("llm-call" :: Text),
          "qname" .= renderQName q,
          "step_id" .= sid,
          "model" .= model,
          "system" .= system,
          "prompt" .= prompt,
          "response" .= response,
          "tokens_in" .= tin,
          "tokens_out" .= tout
        ]
      FileIo q sid op path bytes ->
        [ "tag" .= ("file-io" :: Text),
          "qname" .= renderQName q,
          "step_id" .= sid,
          "op" .= fileOpText op,
          "path" .= path,
          "bytes" .= bytes
        ]
      ErrorEvent q sid message kind ->
        [ "tag" .= ("error" :: Text),
          "qname" .= renderQName q,
          "step_id" .= sid,
          "message" .= message,
          "kind" .= errorKindText kind
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

-- | Decode a single @trace.jsonl@ line back into a 'TraceEvent' (spec §8.3),
-- the inverse of 'eventToJson'. Used to reconstruct @ctx.trace@ and continue
-- @seq@ numbering on resume (§8.3.5, §8.2), and by @hwfi show@. Returns
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
      "file-io" ->
        FileIo <$> qn o <*> o .: "step_id" <*> (fileOpFromText <$> o .: "op") <*> o .: "path" <*> o .: "bytes"
      "error" ->
        ErrorEvent <$> qn o <*> o .: "step_id" <*> o .: "message" <*> (errorKindFromText <$> o .: "kind")
      "resumed" ->
        Resumed <$> o .: "run_id" <*> o .: "from_seq"
      "run-end" ->
        RunEnd <$> o .: "run_id" <*> (runStatusFromText <$> o .: "status")
      other -> fail ("unknown trace tag: " <> T.unpack other)
    qn o = qnameFromText <$> o .: "qname"

-- | A one-line human-readable rendering of a trace event for @hwfi show@
-- (spec §9). Not a wire format; 'eventToJson' remains the persisted form.
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
      LlmCall q sid model _ _ _ tin tout ->
        "llm-call    " <> step q sid <> "  model=" <> model <> "  tokens=" <> T.pack (show tin) <> "/" <> T.pack (show tout)
      FileIo q sid op path bytes ->
        "file-io     " <> step q sid <> "  " <> fileOpText op <> " " <> path <> " (" <> T.pack (show bytes) <> "B)"
      ErrorEvent q sid msg _ ->
        "error       " <> step q sid <> "  " <> msg
      Resumed runId fromSeq ->
        "resumed     " <> runId <> "  from_seq=" <> T.pack (show fromSeq)
      RunEnd runId status ->
        "run-end     " <> runId <> "  status=" <> runStatusText status
    shortHash = T.take 12

-- | An event accumulator with an optional append-only file sink. Holds the
-- next @seq@ and the events so far in reverse chronological order. When a sink
-- is present, 'emit' also appends the event's JSON line to @trace.jsonl@ and
-- flushes, so a crash mid-run leaves a durable prefix to resume from (§8.2).
data Tracer = Tracer (IORef (Int, [TraceEvent])) (Maybe Handle)

-- | Create a fresh in-memory tracer starting at @seq = 0@ (spec §8.3.1). Used
-- by tests and callers that do not persist.
newTracer :: IO Tracer
newTracer = do
  ref <- newIORef (0, [])
  pure (Tracer ref Nothing)

-- | Create a tracer that appends every emitted event to @h@, seeded with the
-- events already persisted (in chronological order) and the next @seq@ to
-- assign. On a fresh run this is @(h, [], 0)@; on resume it is the parsed
-- @trace.jsonl@ and @last-seq + 1@ (spec §8.2, §8.3.5).
newPersistentTracer :: Handle -> [TraceEvent] -> Int -> IO Tracer
newPersistentTracer h preload nextSeq = do
  ref <- newIORef (nextSeq, reverse preload)
  pure (Tracer ref (Just h))

-- | Append an event, assigning it the next @seq@ and the current timestamp,
-- and persisting it to the sink (if any) before returning.
emit :: Tracer -> EventBody -> IO TraceEvent
emit (Tracer ref sink) body = do
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

-- | All events so far, in chronological order (spec §8.3.5: @ctx.trace@ is the
-- ordered parse of the trace as persisted so far).
snapshotEvents :: Tracer -> IO [TraceEvent]
snapshotEvents (Tracer ref _) = reverse . snd <$> readIORef ref

-- | The events so far as a JSON array, one object per event.
snapshotJson :: Tracer -> IO Value
snapshotJson t = Array . V.fromList . map eventToJson <$> snapshotEvents t

-- | The @seq@ that will be assigned to the next emitted event.
currentSeq :: Tracer -> IO Int
currentSeq (Tracer ref _) = fst <$> readIORef ref
