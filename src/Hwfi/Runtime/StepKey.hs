-- | Step-key hashing (spec §8.1): the content address under which a cacheable
-- step's result is persisted so it can be skipped on resume.
--
-- @
-- step-key = hash( qname, step-id, resolved-args, ctx-projection, callee-fingerprint )
-- @
--
-- The key is stable across abort/resume for an unchanged step, and changes
-- whenever anything that could alter the step's result changes:
--
--   * the enclosing @qname@ and @step-id@ locate the step;
--   * @resolved-args@ is the canonical JSON of the evaluated arguments — with a
--     first-class @ToolRef@\/@WorkflowRef@ value contributing the /fingerprint/
--     of its target rather than its qname (§8.1), so passing an edited workflow
--     as a value invalidates correctly;
--   * @ctx-projection@ is the canonical rendering of the /stable/ @ctx.*@ fields
--     the step references (volatile fields make the step non-cacheable, so they
--     never reach here — §8.1);
--   * @callee-fingerprint@ is the Merkle fingerprint of the call target, so
--     editing the callee (or anything it transitively calls) changes the key
--     and forces recomputation (A13);
--   * for one-shot LLM builtins (@builtin/llm-generate@, @builtin/llm-chat@,
--     @builtin/llm-gen-object@), @ctx-projection@ also includes a
--     @model-catalog-fp@ line derived from the resolved catalog entry named by
--     the @model@ argument (§8.1), so editing @model-catalog.json@ busts the
--     cache on resume.
--
-- Secrets are hashed by their /actual/ value (not the trace placeholder): two
-- runs with different secret inputs must get different keys, and the key is a
-- one-way hash so nothing is leaked.
module Hwfi.Runtime.StepKey
  ( computeStepKey,
    computeWhileDecisionKey,
    sha256Hex,
  )
where

import Crypto.Hash (Digest, SHA256, hash)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.List (sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (encodeUtf8)
import Data.Vector qualified as V
import Hwfi.Ast.Name (Ident, QName, renderQName)
import Hwfi.Runtime.Value (RValue (..), canonicalJson, valueToJson)

-- | Compute the hex step-key (spec §8.1).
computeStepKey ::
  -- | Fingerprint text of a @ToolRef@\/@WorkflowRef@ value's target, for the
  -- @resolved-args@ substitution. 'Nothing' leaves the qname's textual form.
  (QName -> Maybe Text) ->
  -- | Enclosing workflow qname.
  QName ->
  -- | Step id.
  Ident ->
  -- | Resolved (evaluated) argument values.
  Map Ident RValue ->
  -- | Stable @ctx@ projection: @(rendered-path, canonical-value)@ pairs.
  [(Text, Text)] ->
  -- | Callee fingerprint (empty when statically unknown and unresolved).
  Text ->
  Text
computeStepKey refFp q sid args ctxProjection calleeFp =
  sha256Hex payload
  where
    payload =
      T.intercalate
        "\n"
        [ "qname:" <> renderQName q,
          "step:" <> sid,
          "args:" <> canonicalJson (argsToJson refFp args),
          "ctx:" <> renderProjection ctxProjection,
          "callee:" <> calleeFp
        ]

-- | Render the ctx projection deterministically: sorted @path=value@ lines.
renderProjection :: [(Text, Text)] -> Text
renderProjection = T.intercalate ";" . sort . map (\(p, v) -> p <> "=" <> v)

-- | Convert the argument map to JSON for hashing, substituting each first-class
-- ref value with a fingerprint marker (§8.1) and keeping secret payloads in the
-- clear so distinct secrets hash distinctly.
argsToJson :: (QName -> Maybe Text) -> Map Ident RValue -> Aeson.Value
argsToJson refFp args =
  Aeson.Object (KM.fromList [(K.fromText k, toJson v) | (k, v) <- Map.toList args])
  where
    toJson = \case
      VRef _ q -> Aeson.String ("ref:" <> fromMaybe (renderQName q) (refFp q))
      VSecret _ inner -> toJson inner
      VList xs -> Aeson.Array (V.fromList (map toJson xs))
      VRecord m -> Aeson.Object (KM.fromList [(K.fromText k, toJson x) | (k, x) <- Map.toList m])
      other -> valueToJson other

sha256Hex :: Text -> Text
sha256Hex t = T.pack (show digest)
  where
    digest = hash (encodeUtf8 t) :: Digest SHA256

-- | Compute the hex decision-key for a @while@ predicate evaluation (§4.3.5).
computeWhileDecisionKey :: QName -> Text -> Ident -> Int -> Text
computeWhileDecisionKey q scope whileId i =
  sha256Hex payload
  where
    payload =
      T.intercalate
        "\n"
        [ "qname:" <> renderQName q,
          "step:" <> scope <> whileId,
          "kind:while-pred",
          "iter:" <> T.pack (show i)
        ]
