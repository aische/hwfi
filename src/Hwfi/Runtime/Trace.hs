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
    RunStatus (..),
    runStatusText,
    EventBody (..),
    TraceEvent (..),
    eventToJson,
    Tracer,
    newTracer,
    emit,
    snapshotEvents,
    snapshotJson,
    currentSeq,
  )
where

import Data.Aeson (Value (..), object, (.=))
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (defaultTimeLocale, formatTime, getCurrentTime)
import Data.Vector qualified as V
import Hwfi.Ast.Name (Ident, QName, renderQName)
import Hwfi.Runtime.Error (ErrorKind, errorKindText)

-- | The @op@ discriminator of a 'FileIo' event (§8.3.2).
data FileOp = OpRead | OpWrite | OpList
  deriving stock (Eq, Show)

fileOpText :: FileOp -> Text
fileOpText = \case
  OpRead -> "read"
  OpWrite -> "write"
  OpList -> "list"

-- | The terminal @status@ of a logical run (§8.3.2, §8.3.3).
data RunStatus = Completed | Aborted
  deriving stock (Eq, Show)

runStatusText :: RunStatus -> Text
runStatusText = \case
  Completed -> "completed"
  Aborted -> "aborted"

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

-- | An in-memory event accumulator. Holds the next @seq@ and the events so far
-- in reverse chronological order. M5 will additionally persist each emitted
-- event to @trace.jsonl@ through this same seam.
data Tracer = Tracer (IORef (Int, [TraceEvent]))

-- | Create a fresh tracer starting at @seq = 0@ (spec §8.3.1).
newTracer :: IO Tracer
newTracer = Tracer <$> newIORef (0, [])

-- | Append an event, assigning it the next @seq@ and the current timestamp.
emit :: Tracer -> EventBody -> IO TraceEvent
emit (Tracer ref) body = do
  now <- getCurrentTime
  let at = T.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S%3QZ" now)
  atomicModifyIORef' ref $ \(nextSeq, evs) ->
    let ev = TraceEvent nextSeq at body
     in ((nextSeq + 1, ev : evs), ev)

-- | All events so far, in chronological order (spec §8.3.5: @ctx.trace@ is the
-- ordered parse of the trace as persisted so far).
snapshotEvents :: Tracer -> IO [TraceEvent]
snapshotEvents (Tracer ref) = reverse . snd <$> readIORef ref

-- | The events so far as a JSON array, one object per event.
snapshotJson :: Tracer -> IO Value
snapshotJson t = Array . V.fromList . map eventToJson <$> snapshotEvents t

-- | The @seq@ that will be assigned to the next emitted event.
currentSeq :: Tracer -> IO Int
currentSeq (Tracer ref) = fst <$> readIORef ref
