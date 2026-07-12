-- | Expression type inference and checking (spec §5.6.3, §5.6.4, §5.6.7),
-- including the interpolation-rendering rules (§3.2.1), the secret-flow
-- restriction (§5.5), and @\@self#slug@ existence checks (§5.6.4).
module Hwfi.Check.Expr
  ( Env (..),
    inferExpr,
    checkExpr,
    checkExprWithCarry,
    inferExprWithCarry,
  )
where

import Control.Monad (unless)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Hwfi.Ast.Expr (Accessor (..), Expr (..), RefPath (..), StringPart (..))
import Hwfi.Ast.Name (Ident, QName, renderQName, renderSlug)
import Hwfi.Ast.Workflow (Section)
import Hwfi.Check.Error (TypeError, TypeErrorKind (..), typeError)
import Hwfi.Parse.Section (lookupSection)
import Hwfi.Source (Pos)
import Hwfi.Type

-- | The binding environment for an expression (spec §5.3): the roots in
-- scope, the project-specific @ctx.env@ record type, the current file's
-- addressable sections (for @\@self@), a resolver for bare-qname ref values,
-- and the source path for diagnostics.
data Env = Env
  { -- | Roots in scope: @inputs@ (a record of the workflow's declared
    -- inputs), @ctx@ ('TyContext'), and each prior step's bind name.
    envRoots :: Map Ident Type,
    -- | The @ctx.env@ record type (fields from @project.json@, §5.7).
    envEnv :: Type,
    -- | The current file's H2/H3 sections, for @\@self#slug@ resolution.
    envSections :: [Section],
    -- | Resolve a bare qname used as a first-class value to its
    -- @ToolRef@/@WorkflowRef@ type (§3.2). 'Nothing' if it is not a callable.
    envRefType :: QName -> Maybe Type,
    -- | Source path for diagnostics.
    envPath :: FilePath,
    -- | When checking @while@ argument records, the type of @${carry}@ (§4.3.4).
    envCarryType :: Maybe Type
  }

-- | Like 'inferExpr', but with an optional @${carry}@ type in scope (§4.3.4).
inferExprWithCarry :: Maybe Type -> Env -> Pos -> Expr -> Either [TypeError] Type
inferExprWithCarry mCarry env = inferExpr env {envCarryType = mCarry}

-- | Like 'checkExpr', but with an optional @${carry}@ type in scope (§4.3.4).
checkExprWithCarry :: Maybe Type -> Env -> Pos -> Type -> Expr -> Either [TypeError] ()
checkExprWithCarry mCarry env = checkExpr env {envCarryType = mCarry}

-- | Infer the type of an expression. @pos@ is the location errors are
-- attributed to (expressions carry no spans of their own; the enclosing
-- argument's span is used).
inferExpr :: Env -> Pos -> Expr -> Either [TypeError] Type
inferExpr env pos = \case
  EString parts -> do
    mapM_ (checkInterpPart env pos) parts
    Right TyString
  EInt _ -> Right TyInt
  EDouble _ -> Right TyDouble
  EBool _ -> Right TyBool
  -- The @null@ literal has no dedicated type in v1; it is an opaque JSON
  -- value (§3.2.1 renders it identically to a Json @null@).
  ENull -> Right TyJson
  ERef rp -> resolveRef env pos rp
  EList es -> inferList env pos es
  ERecord fs -> TyRecord <$> traverse (\(n, e) -> (,) n <$> inferExpr env pos e) fs
  ESelf slug ->
    case lookupSection slug (envSections env) of
      Just _ -> Right TyString
      Nothing ->
        Left
          [ typeError
              (envPath env)
              pos
              SelfNotFound
              ("@self#" <> renderSlug slug <> " does not match any H2/H3 heading in this file")
          ]
  EQName q ->
    case envRefType env q of
      Just t -> Right t
      Nothing ->
        Left
          [ typeError
              (envPath env)
              pos
              BadQNameValue
              ("bare name '" <> renderQ q <> "' does not refer to a callable workflow or tool")
          ]
  ERange e -> do
    checkExpr env pos TyInt e
    Right (TyList TyInt)

-- | Check an expression against an expected type. Handles empty and nested
-- list/record literals structurally (so @[]@ checks against any @List<_>@),
-- and otherwise infers and compares structurally.
checkExpr :: Env -> Pos -> Type -> Expr -> Either [TypeError] ()
checkExpr env pos expected e =
  case (e, expected) of
    (EList es, TyList elemT) -> mapM_ (checkExpr env pos elemT) es
    (ERecord fs, TyRecord expFs) -> checkRecord env pos fs expFs
    _ -> do
      actual <- inferExpr env pos e
      unless (assignable expected actual) $
        Left
          [ typeError
              (envPath env)
              pos
              TypeMismatch
              ( "type mismatch: expected "
                  <> renderType expected
                  <> ", got "
                  <> renderType actual
              )
          ]

checkRecord :: Env -> Pos -> [(Ident, Expr)] -> [(Ident, Type)] -> Either [TypeError] ()
checkRecord env pos got expected = do
  let gotNames = map fst got
      expNames = map fst expected
      missing = filter (`notElem` gotNames) expNames
      extra = filter (`notElem` expNames) gotNames
  unless (null missing && null extra) $
    Left
      [ typeError
          (envPath env)
          pos
          TypeMismatch
          ( "record fields do not match: expected {"
              <> commas expNames
              <> "}, got {"
              <> commas gotNames
              <> "}"
          )
      ]
  mapM_ checkField expected
  where
    checkField (n, t) = case lookup n got of
      Just e -> checkExpr env pos t e
      Nothing -> Right ()

inferList :: Env -> Pos -> [Expr] -> Either [TypeError] Type
inferList _ _ [] = Right (TyList TyJson)
inferList env pos (e : es) = do
  t0 <- inferExpr env pos e
  mapM_ (checkExpr env pos t0) es
  Right (TyList t0)

-- | Validate a single string part. Literal parts are always fine;
-- interpolated references must render to text (§3.2.1): every type is
-- allowed except @Bytes@ and @Secret<_>@.
checkInterpPart :: Env -> Pos -> StringPart -> Either [TypeError] ()
checkInterpPart _ _ (SLit _) = Right ()
checkInterpPart env pos (SInterp rp) = do
  t <- resolveRef env pos rp
  case t of
    TySecret _ ->
      Left
        [ typeError
            (envPath env)
            pos
            SecretInterp
            "a Secret<_> value cannot be interpolated into a string; pass it to a Secret<_> parameter instead (§5.5)"
        ]
    TyBytes ->
      Left
        [ typeError
            (envPath env)
            pos
            BytesInterp
            "a Bytes value cannot be interpolated into a string (no implicit text encoding, §3.2.1)"
        ]
    _ -> Right ()

-- | Resolve a reference path (§5.3): a root in scope followed by field/index
-- accessors. Field access on records and 'TyContext' is checked; access on an
-- opaque 'TyJson' is not (§5.6.7).
resolveRef :: Env -> Pos -> RefPath -> Either [TypeError] Type
resolveRef env pos (RefPath root accs)
  | root == "carry" =
      case envCarryType env of
        Just t -> foldAccessors env pos "carry" t accs
        Nothing ->
          case Map.lookup "carry" (envRoots env) of
            Just t -> foldAccessors env pos "carry" t accs
            Nothing ->
              Left
                [ typeError
                    (envPath env)
                    pos
                    UndeclaredRef
                    "'carry' is not in scope; it is only available in while(...) predicate_args/body_args or an inline body block after the first body iteration (§4.3.4)"
                ]
  | otherwise =
      case Map.lookup root (envRoots env) of
        Nothing ->
          Left
            [ typeError
                (envPath env)
                pos
                UndeclaredRef
                ("'" <> root <> "' is not in scope")
            ]
        Just rootTy -> foldAccessors env pos root rootTy accs

foldAccessors :: Env -> Pos -> Text -> Type -> [Accessor] -> Either [TypeError] Type
foldAccessors _ _ _ ty [] = Right ty
foldAccessors env pos path ty (a : as) = do
  ty' <- applyAccessor env pos path ty a
  foldAccessors env pos (path <> renderAccessor a) ty' as

applyAccessor :: Env -> Pos -> Text -> Type -> Accessor -> Either [TypeError] Type
applyAccessor env pos path ty acc = case acc of
  AField f -> case ty of
    TyRecord fs -> case lookup f fs of
      Just t -> Right t
      Nothing -> Left [fieldErr f]
    TyContext -> case contextFieldType (envEnv env) f of
      Just t -> Right t
      Nothing -> Left [fieldErr f]
    -- Field access on an opaque Json (or a TraceEvent union) is not
    -- statically checked; it yields Json and may fail at runtime (§5.6.7).
    TyJson -> Right TyJson
    TyTraceEvent -> Right TyJson
    _ -> Left [accessErr ("field '" <> f <> "'")]
  AIndex _ -> case ty of
    TyList t -> Right t
    TyTrace -> Right TyTraceEvent
    TyJson -> Right TyJson
    _ -> Left [accessErr "an index"]
  where
    fieldErr f =
      typeError
        (envPath env)
        pos
        UnknownField
        ("'" <> path <> "' (" <> renderType ty <> ") has no field '" <> f <> "'")
    accessErr what =
      typeError
        (envPath env)
        pos
        BadAccess
        ("cannot take " <> what <> " of '" <> path <> "' (" <> renderType ty <> ")")

renderAccessor :: Accessor -> Text
renderAccessor = \case
  AField f -> "." <> f
  AIndex i -> "[" <> tshow i <> "]"

renderQ :: QName -> Text
renderQ = renderQName

commas :: [Text] -> Text
commas = T.intercalate ", "

tshow :: (Show a) => a -> Text
tshow = T.pack . show
