-- | The /resolved/ type representation used by the type checker. See spec
-- §5.1, §5.2.
--
-- This is distinct from the surface 'Hwfi.Ast.Type.TypeExpr': it has no
-- alias references ('TAlias' is expanded during checking, §2.1/A10) and it is
-- the vocabulary in which the checker reasons about values. Structural
-- equality on records is order-insensitive (spec §3, records "compare
-- structurally").
--
-- The built-in context types ('TyContext', 'TyTrace', 'TyTraceEvent') are
-- kept nominal rather than expanded, because @TraceEvent@ is a tagged union
-- that the v1 type system does not model structurally, and because the
-- interpolation table (§3.2.1) treats @Context@/@Trace@/@TraceEvent@ as
-- distinct renderable types. Field access into a 'TyContext' value is
-- resolved through 'contextFieldType', whose @env@ shape is project-specific
-- (§5.2, §5.7) and therefore supplied by the caller.
module Hwfi.Type
  ( Type (..),
    structEq,
    assignable,
    normalizeType,
    renderType,
    isSecret,
    -- * Ambient context (§5.2)
    contextFieldType,
    runFieldType,
    selfFieldType,
    -- * Secret env auto-tagging (§5.5)
    isSecretEnvName,
  )
where

import Data.Char (toUpper)
import Data.List (sortOn)
import Data.Text (Text)
import Data.Text qualified as T
import Hwfi.Ast.Name (Ident)

-- | A resolved type.
data Type
  = TyString
  | TyInt
  | TyDouble
  | TyBool
  | TyJson
  | TyBytes
  | TyFileRef
  | TyList Type
  | -- | A record with named fields. Equality is order-insensitive (see
    -- 'structEq'); field order is preserved only for rendering.
    TyRecord [(Ident, Type)]
  | TyWorkflowRef Type Type
  | TyToolRef Type Type
  | TySecret Type
  | TyContext
  | TyTrace
  | TyTraceEvent
  deriving stock (Eq, Show)

-- | Recursively sort record fields by name so that derived equality coincides
-- with structural equality. Used by 'structEq' and by fingerprinting
-- (spec §8.1) to obtain a canonical form.
normalizeType :: Type -> Type
normalizeType = \case
  TyList t -> TyList (normalizeType t)
  TyRecord fs -> TyRecord (sortOn fst [(n, normalizeType t) | (n, t) <- fs])
  TyWorkflowRef a b -> TyWorkflowRef (normalizeType a) (normalizeType b)
  TyToolRef a b -> TyToolRef (normalizeType a) (normalizeType b)
  TySecret t -> TySecret (normalizeType t)
  t -> t

-- | Structural type equality (spec §3: records compare structurally,
-- ignoring field order).
structEq :: Type -> Type -> Bool
structEq a b = normalizeType a == normalizeType b

-- | Whether a value of type @actual@ may be supplied where @expected@ is
-- required. This is structural equality plus one deliberate subtyping rule:
-- a 'String' is accepted where a 'FileRef' is expected. A @FileRef@ is
-- fundamentally a workspace path, and literal paths (e.g.
-- @path = "out.txt"@) must be expressible; without this rule a @FileRef@
-- value could only ever originate from a workflow input, which is
-- impractical. The relation is one-way (a @FileRef@ is /not/ accepted where a
-- plain @String@ is expected) and congruent through lists, records, and
-- secrets.
assignable :: Type -> Type -> Bool
assignable expected actual =
  case (expected, actual) of
    (TyFileRef, TyString) -> True
    (TyList e, TyList a) -> assignable e a
    (TySecret e, TySecret a) -> assignable e a
    (TyRecord ef, TyRecord af) ->
      length ef == length af
        && all (\(n, t) -> maybe False (assignable t) (lookup n af)) ef
    _ -> structEq expected actual

-- | Render a type in the surface @TypeExpr@ syntax (§3.4), for diagnostics.
renderType :: Type -> Text
renderType = \case
  TyString -> "String"
  TyInt -> "Int"
  TyDouble -> "Double"
  TyBool -> "Bool"
  TyJson -> "Json"
  TyBytes -> "Bytes"
  TyFileRef -> "FileRef"
  TyList t -> "List<" <> renderType t <> ">"
  TyRecord fs ->
    "Record<{ " <> T.intercalate ", " [n <> ": " <> renderType t | (n, t) <- fs] <> " }>"
  TyWorkflowRef a b -> "WorkflowRef<" <> renderType a <> ", " <> renderType b <> ">"
  TyToolRef a b -> "ToolRef<" <> renderType a <> ", " <> renderType b <> ">"
  TySecret t -> "Secret<" <> renderType t <> ">"
  TyContext -> "Context"
  TyTrace -> "Trace"
  TyTraceEvent -> "TraceEvent"

-- | Whether a type is (a) a 'Secret' wrapper.
isSecret :: Type -> Bool
isSecret = \case
  TySecret _ -> True
  _ -> False

-- | The type of a field of the ambient @ctx : Context@ value (§5.2). @envTy@
-- is the project-specific @ctx.env@ record type (its fields derived from the
-- @project.json@ whitelist, §5.7). Returns 'Nothing' for an unknown field.
contextFieldType :: Type -> Ident -> Maybe Type
contextFieldType envTy = \case
  "workspace" -> Just TyFileRef
  "run" -> Just (TyRecord [("id", TyString), ("started_at", TyString), ("entrypoint", TyString)])
  "self" -> Just (TyRecord [("qname", TyString), ("step_id", TyString)])
  "inputs" -> Just TyJson
  "trace" -> Just TyTrace
  "env" -> Just envTy
  _ -> Nothing

-- | The fields of @ctx.run@ (§5.2). Exposed for reuse by the runtime.
runFieldType :: Ident -> Maybe Type
runFieldType = \case
  "id" -> Just TyString
  "started_at" -> Just TyString
  "entrypoint" -> Just TyString
  _ -> Nothing

-- | The fields of @ctx.self@ (§5.2).
selfFieldType :: Ident -> Maybe Type
selfFieldType = \case
  "qname" -> Just TyString
  "step_id" -> Just TyString
  _ -> Nothing

-- | Whether an environment variable name marks a secret value that must be
-- auto-typed @Secret<String>@ (§5.5). Matches @*_KEY@, @*_TOKEN@,
-- @*_SECRET@, @*_PASSWORD@, case-insensitively.
isSecretEnvName :: Text -> Bool
isSecretEnvName name =
  any (`T.isSuffixOf` upper) ["_KEY", "_TOKEN", "_SECRET", "_PASSWORD"]
  where
    upper = T.map toUpper name
