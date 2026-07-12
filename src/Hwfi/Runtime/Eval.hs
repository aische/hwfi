-- | The runtime expression evaluator (spec §5.3, §3.2.1, task 4.6).
--
-- Evaluates a checked 'Expr' against a binding environment to an 'RValue'.
-- Because the project is fully type-checked before execution, most failures
-- here are impossible; the ones that remain are exactly the runtime @eval@
-- errors the spec admits (§8.3.2): list index out of bounds and missing-field
-- access on an opaque @Json@ value (field access and indexing on @Json@ are
-- deliberately not statically checked, §5.6.7). String interpolation renders
-- each referenced value per the total table in §3.2.1.
module Hwfi.Runtime.Eval
  ( EvalEnv (..),
    evalExpr,
    resolveRefPath,
  )
where

import Data.Aeson (Value (..))
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Hwfi.Ast.Expr (Accessor (..), Expr (..), RefPath (..), StringPart (..))
import Hwfi.Ast.Name (Ident, QName, renderQName, renderSlug)
import Hwfi.Ast.Workflow (Section)
import Hwfi.Parse.Section (resolveSelf)
import Hwfi.Runtime.Error (RuntimeError, evalError)
import Hwfi.Runtime.Value (RValue (..), RefKind, renderValue)

-- | The environment an expression is evaluated in (spec §5.3): the bound roots
-- (@inputs@, @ctx@, prior binds), the current file's addressable sections (for
-- @\@self#slug@), and a classifier that tells whether a bare qname names a
-- tool or a workflow (for first-class @ToolRef@\/@WorkflowRef@ values, §3.2).
data EvalEnv = EvalEnv
  { eeBindings :: Map Ident RValue,
    eeSections :: [Section],
    eeRefKind :: QName -> Maybe RefKind
  }

-- | Evaluate an expression to a runtime value.
evalExpr :: EvalEnv -> Expr -> Either RuntimeError RValue
evalExpr env = \case
  EString parts -> VString . T.concat <$> traverse (renderPart env) parts
  EInt n -> Right (VInt n)
  EDouble d -> Right (VDouble d)
  EBool b -> Right (VBool b)
  ENull -> Right VNull
  ERef rp -> resolveRefPath env rp
  EList es -> VList <$> traverse (evalExpr env) es
  ERecord fs -> VRecord . Map.fromList <$> traverse field fs
  ESelf slug -> case resolveSelf slug (eeSections env) of
    Just raw -> Right (VString raw)
    Nothing ->
      Left (evalError ("@self#" <> renderSlug slug <> " did not resolve at runtime"))
  EQName q -> case eeRefKind env q of
    Just kind -> Right (VRef kind q)
    Nothing ->
      Left (evalError ("bare name '" <> renderQName q <> "' is not a callable at runtime"))
  ERange e -> do
    n <- evalExpr env e
    case n of
      VInt count | count >= 0 -> Right (VList [VInt i | i <- [0 .. count - 1]])
      VInt count ->
        Left (evalError ("range count must be >= 0, got " <> T.pack (show count)))
      _ -> Left (evalError "range(...) requires an Int count")
  where
    field (n, e) = (,) n <$> evalExpr env e

-- | Render one part of a string literal for interpolation (§3.2.1). Literal
-- parts pass through; referenced parts are resolved and rendered to text.
renderPart :: EvalEnv -> StringPart -> Either RuntimeError Text
renderPart _ (SLit t) = Right t
renderPart env (SInterp rp) = do
  v <- resolveRefPath env rp
  case renderValue v of
    Right t -> Right t
    Left msg -> Left (evalError msg)

-- | Resolve a reference path (spec §5.3): a bound root followed by
-- field\/index accessors.
resolveRefPath :: EvalEnv -> RefPath -> Either RuntimeError RValue
resolveRefPath env (RefPath root accs) =
  case Map.lookup root (eeBindings env) of
    Nothing -> Left (evalError ("'" <> root <> "' is not bound at runtime"))
    Just v -> foldAccessors root v accs

foldAccessors :: Text -> RValue -> [Accessor] -> Either RuntimeError RValue
foldAccessors _ v [] = Right v
foldAccessors path v (a : as) = do
  v' <- applyAccessor path v a
  foldAccessors (path <> renderAccessor a) v' as

-- | Apply a single accessor, producing the spec's @eval@ errors for the two
-- cases that escape static checking (§5.6.7, §8.3.2).
applyAccessor :: Text -> RValue -> Accessor -> Either RuntimeError RValue
applyAccessor path v acc = case acc of
  AField f -> case v of
    VRecord m -> case Map.lookup f m of
      Just fv -> Right fv
      Nothing -> Left (evalError ("record '" <> path <> "' has no field '" <> f <> "'"))
    VJson (Object o) -> case KM.lookup (K.fromText f) o of
      Just fv -> Right (VJson fv)
      Nothing ->
        Left (evalError ("Json value '" <> path <> "' has no field '" <> f <> "'"))
    VSecret _ inner -> applyAccessor path inner acc
    _ -> Left (evalError ("cannot access field '" <> f <> "' of '" <> path <> "'"))
  AIndex i -> case v of
    VList xs -> index xs
    VJson (Array a) -> case a V.!? i of
      Just fv -> Right (VJson fv)
      Nothing -> Left (oob (V.length a))
    _ -> Left (evalError ("cannot index '" <> path <> "'"))
    where
      index xs
        | i >= 0 && i < length xs = Right (xs !! i)
        | otherwise = Left (oob (length xs))
      oob n =
        evalError
          ( "index "
              <> T.pack (show i)
              <> " out of bounds for '"
              <> path
              <> "' (length "
              <> T.pack (show n)
              <> ")"
          )

renderAccessor :: Accessor -> Text
renderAccessor = \case
  AField f -> "." <> f
  AIndex i -> "[" <> T.pack (show i) <> "]"
