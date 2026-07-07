-- | Signature → JSON-Schema translation for agentic tool-use (spec §6.1.1).
--
-- Each callable ref advertised to a model becomes a provider tool whose
-- parameter schema is a total translation of the callee's resolved input
-- types. The same translation drives the terminating @submit@ tool of
-- @builtin/llm-agent-object@ (§6.1.3), applied to its @schema@ argument.
--
-- The translation is /partial/ on exactly the types the spec forbids as
-- model-supplied inputs: @Secret<_>@ (§5.5), @ToolRef@\/@WorkflowRef@, and
-- @Bytes@ (§3.2.1). A callee taking any of these is **ineligible** as an agent
-- tool and is rejected at @hwfi check@ (§5.6.9, A18); 'ineligibilityReasons'
-- is the pure predicate the checker uses.
--
-- This module is IO-free and unit-testable in isolation (task 6.a).
module Hwfi.Runtime.Schema
  ( typeToSchema,
    recordSchema,
    ineligibilityReasons,
  )
where

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.Key qualified as K
import Data.Text (Text)
import Data.Vector qualified as V
import Hwfi.Ast.Name (Ident)
import Hwfi.Type (Type (..), renderType)

-- | Translate a resolved type to a JSON Schema fragment (spec §6.1.1). Returns
-- 'Left' with a human-readable reason for the three model-ineligible types so
-- the checker can surface a precise @hwfi check@ error.
typeToSchema :: Type -> Either Text Value
typeToSchema = \case
  TyString -> Right (typed "string")
  TyInt -> Right (typed "integer")
  TyDouble -> Right (typed "number")
  TyBool -> Right (typed "boolean")
  TyFileRef -> Right (typed "string")
  TyJson -> Right (object [])
  TyList e -> do
    items <- typeToSchema e
    Right (object ["type" .= ("array" :: Text), "items" .= items])
  TyRecord fs -> recordSchema fs
  -- These context types are never valid /declared/ inputs, but map to an
  -- unconstrained schema defensively rather than crashing the translation.
  TyContext -> Right (object [])
  TyTrace -> Right (object [])
  TyTraceEvent -> Right (object [])
  TySecret t ->
    Left ("Secret<" <> renderType t <> "> must never be supplied to the model (§5.5)")
  TyToolRef a b ->
    Left ("ToolRef<" <> renderType a <> ", " <> renderType b <> "> cannot be model-supplied")
  TyWorkflowRef a b ->
    Left ("WorkflowRef<" <> renderType a <> ", " <> renderType b <> "> cannot be model-supplied")
  TyBytes ->
    Left "Bytes has no implicit text/JSON encoding and cannot be model-supplied (§3.2.1)"
  where
    typed t = object ["type" .= (t :: Text)]

-- | The JSON-Schema @object@ for a record's fields: a @properties@ map plus a
-- @required@ array naming every field (all fields are required in v1, matching
-- the callee's total input record). Fails if any field type is ineligible.
recordSchema :: [(Ident, Type)] -> Either Text Value
recordSchema fs = do
  props <- traverse (\(n, t) -> (,) n <$> typeToSchema t) fs
  Right $
    object
      [ "type" .= ("object" :: Text),
        "properties" .= object [K.fromText name .= schema | (name, schema) <- props],
        "required" .= Array (V.fromList [String name | (name, _) <- fs]),
        "additionalProperties" .= False
      ]

-- | The reasons a callee is ineligible as an agent tool because of its input
-- types (spec §6.1.1, §5.6.9). Empty list ⇒ every input translates and the
-- callee is input-eligible (the separate @builtin/introspect@ reachability
-- rule of §6.1.5 is enforced by the checker, not here).
ineligibilityReasons :: [(Ident, Type)] -> [Text]
ineligibilityReasons inputs =
  [ "input '" <> n <> "': " <> reason
  | (n, t) <- inputs,
    Left reason <- [typeToSchema t]
  ]
