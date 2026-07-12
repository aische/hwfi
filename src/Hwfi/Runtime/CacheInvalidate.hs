-- | Author-visible cache invalidation policy (spec §13.1.4).
--
-- @hwfi cache invalidate@ drops persisted step results from a chosen point in
-- trace order onward, leaving upstream cache entries intact so @hwfi resume@
-- re-executes only the affected suffix.
module Hwfi.Runtime.CacheInvalidate
  ( InvalidateFrom (..),
    parseStepRef,
    invalidateCacheFrom,
    invalidateRunCacheFrom,
  )
where

import Data.List (nub)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Hwfi.Ast.Name (Ident, QName, qnameFromText, renderQName)
import Hwfi.Runtime.RunStore
  ( RunStore,
    deleteCachedResults,
    purgeAgentSubCaches,
    readTraceEvents,
  )
import Hwfi.Runtime.Trace (EventBody (..), TraceEvent (..))

-- | What point in trace order to invalidate from (inclusive).
data InvalidateFrom
  = -- | A persisted content-addressed step-key or while decision-key.
    FromStepKey Text
  | -- | The first @step-start@\/@step-end@ matching @qname#step-id@.
    FromStepRef QName Ident
  deriving stock (Eq, Show)

-- | Parse @qname#step-id@ for @--from-step@.
parseStepRef :: Text -> Either Text (QName, Ident)
parseStepRef raw =
  case T.breakOn "#" raw of
    (q, rest)
      | not (T.null q) && "#" `T.isPrefixOf` rest ->
          let sid = T.drop 1 rest
           in if T.null sid
                then Left "expected --from-step qname#step-id (e.g. workflows/main#read)"
                else Right (qnameFromText q, sid)
    _ -> Left "expected --from-step qname#step-id (e.g. workflows/main#read)"

-- | Drop cached step results from @from@ onward in trace order. Trace and
-- @run.json@ are left intact.
invalidateCacheFrom :: RunStore -> [TraceEvent] -> InvalidateFrom -> IO (Either Text Int)
invalidateCacheFrom store events from_ = do
  case cutoffSeq events from_ of
    Left err -> pure (Left err)
    Right cutoff -> do
      let (keys, agentKeys) = keysFromSeq events cutoff
      nWorkflow <- deleteCachedResults store keys
      agentDeleted <- mapM (purgeAgentSubCaches store) agentKeys
      pure (Right (nWorkflow + sum agentDeleted))

cutoffSeq :: [TraceEvent] -> InvalidateFrom -> Either Text Int
cutoffSeq events = \case
  FromStepKey key ->
    case [teSeq ev | ev <- events, eventHasKey key (teBody ev)] of
      (seq_ : _) -> Right seq_
      [] ->
        Left $
          "no trace event carries step_key/decision_key "
            <> T.take 12 key
            <> " (use `hwfi show` to inspect keys, or `hwfi cache clear` for a full wipe)"
  FromStepRef q sid ->
    case [teSeq ev | ev <- events, eventMatchesRef q sid (teBody ev)] of
      (seq_ : _) -> Right seq_
      [] ->
        Left $
          "no step "
            <> renderQName q
            <> "#"
            <> sid
            <> " in trace (check qname and step-id with `hwfi show`)"

keysFromSeq :: [TraceEvent] -> Int -> ([Text], [Text])
keysFromSeq events cutoff =
  let suffix = [ev | ev@(TraceEvent seq_ _ _) <- events, seq_ >= cutoff]
      keys = nub (concatMap eventCacheKeys (map teBody suffix))
      agentKeys =
        nub
          [ k
            | TraceEvent _ _ (StepStart _ _ _ False (Just k)) <- suffix
          ]
   in (keys, agentKeys)

eventHasKey :: Text -> EventBody -> Bool
eventHasKey want = any (keyMatches want) . eventBodyKeys

keyMatches :: Text -> Text -> Bool
keyMatches want got = got == want || T.isPrefixOf want got

eventBodyKeys :: EventBody -> [Text]
eventBodyKeys = \case
  StepStart _ _ _ _ mKey -> maybeToList mKey
  StepEnd _ _ _ _ mKey -> maybeToList mKey
  WhilePred _ _ _ _ _ mKey -> maybeToList mKey
  _ -> []

maybeToList :: Maybe a -> [a]
maybeToList = mapMaybe id . pure

eventMatchesRef :: QName -> Ident -> EventBody -> Bool
eventMatchesRef q sid = \case
  StepStart q' sid' _ _ _ -> q' == q && sid' == sid
  StepEnd q' sid' _ _ _ -> q' == q && sid' == sid
  _ -> False

eventCacheKeys :: EventBody -> [Text]
eventCacheKeys = eventBodyKeys

-- | Load trace and invalidate in one call (CLI convenience).
invalidateRunCacheFrom :: RunStore -> InvalidateFrom -> IO (Either Text Int)
invalidateRunCacheFrom store from_ = do
  events <- readTraceEvents store
  if hasKeyMetadata events
    then invalidateCacheFrom store events from_
    else
      pure . Left $
        "trace has no step_key metadata; run once with this hwfi version, use `hwfi cache clear`, or resume to record keys"

hasKeyMetadata :: [TraceEvent] -> Bool
hasKeyMetadata events =
  not (null events)
    && any eventCarriesKey (map teBody events)
  where
    eventCarriesKey = \case
      StepEnd _ _ _ _ (Just _) -> True
      WhilePred _ _ _ _ _ (Just _) -> True
      StepStart _ _ _ _ (Just _) -> True
      _ -> False
