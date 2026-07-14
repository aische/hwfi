-- | The runtime value representation and the conversions the executor needs:
-- to\/from @aeson@ 'Value', the canonical-JSON encoding used for interpolation
-- of structured types (spec §3.2.1) and step-key hashing (§8.1), the total
-- text-rendering table (§3.2.1), and coercion of CLI\/JSON inputs into typed
-- values (§9).
--
-- 'RValue' is deliberately richer than @aeson@'s 'Value' because the engine
-- must distinguish, at runtime, values that JSON conflates: a 'VFileRef'
-- (workspace path) from a plain 'VString', a 'VSecret' (redacted in traces,
-- §5.5) from its payload, and a first-class 'VRef' (a @ToolRef@\/@WorkflowRef@
-- value, §3.2) from the string of its qname. The static types assigned by the
-- checker tell the executor which constructor to build.
module Hwfi.Runtime.Value
  ( RValue (..),
    RefKind (..),
    valueToJson,
    snapshotValueToJson,
    snapshotValueFromJson,
    redactedJson,
    canonicalJson,
    renderValue,
    coerceFromJson,
    coerceFromString,
  )
where

import Data.Aeson (Value (..), object, withObject, (.:), (.:?), (.=))
import Data.Aeson.Types (Parser, parseMaybe)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as BSL
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Scientific (Scientific, floatingOrInteger, fromFloatDigits, toRealFloat)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Vector qualified as V
import Hwfi.Ast.Name (Ident, QName, qnameFromText, renderQName)
import Hwfi.Type (Type (..))

-- | Whether a first-class reference value targets a tool or a workflow (§3.2).
data RefKind = RTool | RWorkflow
  deriving stock (Eq, Show)

-- | A runtime value.
data RValue
  = VString !Text
  | VInt !Integer
  | VDouble !Double
  | VBool !Bool
  | -- | The @null@ literal (§3.2), also the runtime shape of a JSON @null@.
    VNull
  | -- | A workspace-relative file path (§5.1).
    VFileRef !Text
  | VList ![RValue]
  | -- | A record with named fields, stored sorted by key for a canonical form.
    VRecord !(Map Ident RValue)
  | -- | An opaque structured value (§5.1); field\/index access is unchecked.
    VJson !Value
  | -- | A secret wrapper (§5.5). The optional 'Ident' is the source binding
    -- name used to build the trace placeholder @"\<secret:name>"@ (§8.3.4).
    VSecret !(Maybe Ident) !RValue
  | -- | A first-class tool\/workflow reference value (§3.2), used when a bare
    -- qname is passed to a @ToolRef@\/@WorkflowRef@ parameter.
    VRef !RefKind !QName
  deriving stock (Eq, Show)

-- JSON conversion ------------------------------------------------------------

-- | Convert a runtime value to @aeson@ JSON without redacting secrets. Used
-- for step results and bindings that stay inside the engine.
valueToJson :: RValue -> Value
valueToJson = \case
  VString t -> String t
  VInt n -> Number (fromInteger n)
  VDouble d -> Number (fromFloatDigits d)
  VBool b -> Bool b
  VNull -> Null
  VFileRef p -> String p
  VList xs -> Array (V.fromList (map valueToJson xs))
  VRecord m -> Object (KM.fromList [(K.fromText k, valueToJson v) | (k, v) <- Map.toList m])
  VJson v -> v
  VSecret _ inner -> valueToJson inner
  VRef _ q -> String (renderQName q)

-- | Lossless JSON encoding for machine snapshots (@machine.json@). Wraps each
-- 'RValue' constructor in a tagged object so resume can rebuild typed bindings
-- (records with @String@ fields, @VRef@, @VJson@, etc.) instead of collapsing
-- everything to 'VJson'.
snapshotValueToJson :: RValue -> Value
snapshotValueToJson = \case
  VString t -> tagged "str" (object ["v" .= t])
  VInt n -> tagged "int" (object ["v" .= n])
  VDouble d -> tagged "dbl" (object ["v" .= d])
  VBool b -> tagged "bool" (object ["v" .= b])
  VNull -> object ["_hwfi" .= ("null" :: Text)]
  VFileRef p -> tagged "file" (object ["v" .= p])
  VList xs -> tagged "list" (object ["v" .= map snapshotValueToJson xs])
  VRecord m ->
    tagged
      "rec"
      ( object
          [ "v"
              .= object
                [ K.fromText k .= snapshotValueToJson v
                  | (k, v) <- Map.toList m
                ]
          ]
      )
  VJson j -> tagged "json" (object ["v" .= j])
  VSecret mName inner ->
    tagged
      "secret"
      ( object
          [ "name" .= mName,
            "v" .= snapshotValueToJson inner
          ]
      )
  VRef kind q ->
    tagged
      "ref"
      ( object
          [ "kind" .= refKindTag kind,
            "v" .= renderQName q
          ]
      )
  where
    tagged :: Text -> Value -> Value
    tagged tag payload = object ["_hwfi" .= tag, "payload" .= payload]

-- | Decode a tagged snapshot value written by 'snapshotValueToJson'.
snapshotValueFromJson :: Value -> Either Text RValue
snapshotValueFromJson v = case parseMaybe parseSnapshotValue v of
  Nothing -> Left "not a tagged snapshot value"
  Just r -> Right r

parseSnapshotValue :: Value -> Parser RValue
parseSnapshotValue =
  withObject "snapshot value" $ \o -> do
    tag <- o .: "_hwfi"
    case tag of
      "null" -> pure VNull
      _ -> do
        payload <- o .: "payload"
        case tag of
          "str" -> VString <$> withObject "str" (.: "v") payload
          "int" -> withObject "int" (.: "v") payload >>= parseIntPayload
          "dbl" -> VDouble <$> withObject "dbl" (.: "v") payload
          "bool" -> VBool <$> withObject "bool" (.: "v") payload
          "file" -> VFileRef <$> withObject "file" (.: "v") payload
          "list" ->
            withObject "list" (.: "v") payload >>= \arr ->
              VList <$> traverse parseSnapshotValue (V.toList arr)
          "rec" ->
            withObject "rec" (.: "v") payload >>= \fields ->
              VRecord . Map.fromList <$> traverse parseField (KM.toList fields)
          "json" -> VJson <$> withObject "json" (.: "v") payload
          "secret" -> withObject "secret" parseSecret payload
          "ref" -> withObject "ref" parseRef payload
          other -> fail ("unknown snapshot value tag: " <> T.unpack other)
  where
    parseField (k, v) = (K.toText k,) <$> parseSnapshotValue v
    parseSecret p = do
      inner <- p .: "v" >>= parseSnapshotValue
      name <- p .:? "name"
      pure (VSecret name inner)
    parseRef p = do
      kind <- p .: "kind"
      qn <- p .: "v"
      refKind <- case kind of
        "tool" -> pure RTool
        "workflow" -> pure RWorkflow
        other -> fail ("unknown ref kind: " <> T.unpack other)
      pure (VRef refKind (qnameFromText qn))
    parseIntPayload = \case
      Number n ->
        case floatingOrInteger n :: Either Double Integer of
          Right i -> pure (VInt i)
          Left _ -> fail "int payload is not integral"
      _ -> fail "int payload is not a number"

refKindTag :: RefKind -> Text
refKindTag = \case
  RTool -> "tool"
  RWorkflow -> "workflow"

-- | Convert a runtime value to JSON, replacing every 'VSecret' with its
-- @"\<secret:name>"@ placeholder (spec §8.3.4). Used everywhere a value is
-- about to cross into an observable surface (the trace, @builtin/introspect@).
redactedJson :: RValue -> Value
redactedJson = \case
  VString t -> String t
  VInt n -> Number (fromInteger n)
  VDouble d -> Number (fromFloatDigits d)
  VBool b -> Bool b
  VNull -> Null
  VFileRef p -> String p
  VList xs -> Array (V.fromList (map redactedJson xs))
  VRecord m -> Object (KM.fromList [(K.fromText k, redactedJson v) | (k, v) <- Map.toList m])
  VJson v -> v
  VSecret mName _ -> String ("<secret:" <> fromMaybe "?" mName <> ">")
  VRef _ q -> String (renderQName q)

-- | Compact canonical JSON with lexicographically-sorted object keys. This is
-- the text produced when a structured value is interpolated into a string
-- (spec §3.2.1) and the byte form hashed for step keys (§8.1); both require a
-- stable, order-independent encoding.
canonicalJson :: Value -> Text
canonicalJson = \case
  Object o ->
    "{"
      <> T.intercalate
        ","
        [ encodeString (K.toText k) <> ":" <> canonicalJson v
          | (k, v) <- sortOn fst (KM.toList o)
        ]
      <> "}"
  Array a -> "[" <> T.intercalate "," (map canonicalJson (V.toList a)) <> "]"
  scalar -> encodeLeaf scalar
  where
    encodeLeaf = TE.decodeUtf8 . BSL.toStrict . Aeson.encode
    encodeString = encodeLeaf . String

-- Text rendering (interpolation, §3.2.1) -------------------------------------

-- | Render a value to text for string interpolation (spec §3.2.1). Total for
-- every type the checker admits in an interpolation position; the 'Left' cases
-- can only be reached by @Bytes@ or @Secret<_>@, both rejected at
-- @hwfi check@, so they surface as @eval@ errors if ever hit.
renderValue :: RValue -> Either Text Text
renderValue = \case
  VString t -> Right t
  VInt n -> Right (T.pack (show n))
  VDouble d -> Right (renderDouble d)
  VBool b -> Right (if b then "true" else "false")
  VNull -> Right "null"
  VFileRef p -> Right p
  VSecret _ _ -> Left "cannot render a Secret<_> value as text (§5.5)"
  VRef _ q -> Right (renderQName q)
  v@(VList _) -> Right (canonicalJson (valueToJson v))
  v@(VRecord _) -> Right (canonicalJson (valueToJson v))
  VJson j -> Right (canonicalJson j)

-- | Render a 'Double' as a canonical decimal literal (spec §3.2.1), dropping
-- the redundant trailing @.0@ that 'show' produces for integral values.
renderDouble :: Double -> Text
renderDouble d
  | d == fromIntegral r = T.pack (show r)
  | otherwise = T.pack (show d)
  where
    r = round d :: Integer

-- Input coercion (§9) --------------------------------------------------------

-- | Coerce a JSON value to a typed runtime value under a declared type (spec
-- §9, @--input k=@file.json@ and @--input-json@). Fails with a message when
-- the JSON shape does not match the declared type.
coerceFromJson :: Type -> Value -> Either Text RValue
coerceFromJson ty v = case ty of
  TyString -> asString v
  TyFileRef -> VFileRef <$> asText "FileRef" v
  TyInt -> case v of
    Number n -> VInt <$> asInteger n
    _ -> mismatch "Int" v
  TyDouble -> case v of
    Number n -> Right (VDouble (toRealFloat n))
    _ -> mismatch "Double" v
  TyBool -> case v of
    Bool b -> Right (VBool b)
    _ -> mismatch "Bool" v
  TyJson -> Right (VJson v)
  TyList e -> case v of
    Array a -> VList <$> traverse (coerceFromJson e) (V.toList a)
    _ -> mismatch "List" v
  TyRecord fs -> case v of
    Object o -> VRecord . Map.fromList <$> traverse (field o) fs
    _ -> mismatch "Record" v
  TySecret e -> VSecret Nothing <$> coerceFromJson e v
  TyBytes -> Left "Bytes inputs are not supported in v1 (§12)"
  _ -> Right (VJson v)
  where
    field o (n, ft) = case KM.lookup (K.fromText n) o of
      Just fv -> (,) n <$> coerceFromJson ft fv
      Nothing -> Left ("missing record field '" <> n <> "'")
    asString (String t) = Right (VString t)
    asString other = mismatch "String" other

-- | Coerce a bare @--input k=v@ string to a typed value (spec §9). Scalars are
-- parsed from their textual form; @Json@ attempts a JSON parse and falls back
-- to a string; records\/lists require the @=@'file.json'@ form and are
-- rejected here.
coerceFromString :: Type -> Text -> Either Text RValue
coerceFromString ty raw = case ty of
  TyString -> Right (VString raw)
  TyFileRef -> Right (VFileRef raw)
  TyInt -> case readMaybeInt raw of
    Just n -> Right (VInt n)
    Nothing -> Left ("expected an integer, got '" <> raw <> "'")
  TyDouble -> case readMaybeDouble raw of
    Just d -> Right (VDouble d)
    Nothing -> Left ("expected a number, got '" <> raw <> "'")
  TyBool -> case raw of
    "true" -> Right (VBool True)
    "false" -> Right (VBool False)
    _ -> Left ("expected 'true' or 'false', got '" <> raw <> "'")
  TyJson -> case Aeson.decodeStrict (TE.encodeUtf8 raw) of
    Just v -> Right (VJson v)
    Nothing -> Right (VJson (String raw))
  TySecret e -> VSecret Nothing <$> coerceFromString e raw
  _ ->
    Left
      ( "input of type "
          <> T.pack (show ty)
          <> " must be supplied as JSON via --input k=@file.json or --input-json"
      )

-- Helpers --------------------------------------------------------------------

asText :: Text -> Value -> Either Text Text
asText _ (String t) = Right t
asText what other = mismatch what other

asInteger :: Scientific -> Either Text Integer
asInteger n = case floatingOrInteger n :: Either Double Integer of
  Right i -> Right i
  Left _ -> Left "expected an integer, got a fractional number"

mismatch :: Text -> Value -> Either Text a
mismatch what v = Left ("expected " <> what <> ", got " <> jsonKind v)

jsonKind :: Value -> Text
jsonKind = \case
  String _ -> "a string"
  Number _ -> "a number"
  Bool _ -> "a boolean"
  Null -> "null"
  Array _ -> "an array"
  Object _ -> "an object"

readMaybeInt :: Text -> Maybe Integer
readMaybeInt t = case reads (T.unpack t) of
  [(n, "")] -> Just n
  _ -> Nothing

readMaybeDouble :: Text -> Maybe Double
readMaybeDouble t = case reads (T.unpack t) of
  [(d, "")] -> Just d
  _ -> Nothing
