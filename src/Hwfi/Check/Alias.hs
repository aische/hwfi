-- | Type-alias resolution and cycle detection (spec §2.1, A10).
--
-- Aliases declared under @types/@ may reference one another. This module
-- expands every alias into a resolved 'Type', rejecting cyclic definitions,
-- and provides a resolver for the 'TypeExpr's found in workflow/tool
-- signatures.
module Hwfi.Check.Alias
  ( resolveAliasDefs,
    resolveSigTypeExpr,
    resolveTypeExprWith,
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text qualified as T
import Hwfi.Ast.Name (QName, renderQName)
import Hwfi.Ast.Type (TypeExpr (..))
import Hwfi.Check.Error (TypeError, TypeErrorKind (..), typeError)
import Hwfi.Source (Pos (..))
import Hwfi.Type (Type (..))

-- | Resolve every alias definition, detecting cycles. Returns the errors
-- encountered together with the map of successfully-resolved aliases. Aliases
-- involved in a cycle (or referencing an unknown alias) are omitted from the
-- map but reported in the error list.
resolveAliasDefs :: Map QName TypeExpr -> ([TypeError], Map QName Type)
resolveAliasDefs defs = (errs, ok)
  where
    results = [(name, resolveAliasName defs [] name) | name <- Map.keys defs]
    errs = concat [e | (_, Left e) <- results]
    ok = Map.fromList [(n, t) | (n, Right t) <- results]

-- | Resolve a single alias by name, tracking the chain of ancestors currently
-- being resolved to detect cycles.
resolveAliasName :: Map QName TypeExpr -> [QName] -> QName -> Either [TypeError] Type
resolveAliasName defs visiting name =
  case Map.lookup name defs of
    Nothing -> Left [typeError (aliasPath name) (Pos 1 1) UnknownAlias notFound]
    Just def -> resolveTypeExprWith onAlias def
  where
    notFound = "type alias '" <> renderQName name <> "' is not declared under types/"
    onAlias q
      | q `elem` (name : visiting) =
          Left
            [ typeError
                (aliasPath name)
                (Pos 1 1)
                CyclicAlias
                ("cyclic type alias: '" <> renderQName name <> "' transitively references itself via '" <> renderQName q <> "'")
            ]
      | Map.member q defs = resolveAliasName defs (name : visiting) q
      | otherwise =
          Left
            [ typeError
                (aliasPath name)
                (Pos 1 1)
                UnknownAlias
                ("type alias '" <> renderQName q <> "' referenced by '" <> renderQName name <> "' is not declared under types/")
            ]

-- | Resolve a 'TypeExpr' from a workflow/tool signature using the resolved
-- alias map. @known@ is the set of all declared alias names, used to suppress
-- cascading errors: a reference to an alias that /is/ declared but failed to
-- resolve (e.g. it is part of a cycle) is silently treated as 'TyJson' here,
-- because the underlying alias error was already reported by
-- 'resolveAliasDefs'.
resolveSigTypeExpr :: Set QName -> Map QName Type -> FilePath -> Pos -> TypeExpr -> Either [TypeError] Type
resolveSigTypeExpr known aliasMap path pos = resolveTypeExprWith onAlias
  where
    onAlias q = case Map.lookup q aliasMap of
      Just t -> Right t
      Nothing
        | Set.member q known -> Right TyJson
        | otherwise ->
            Left
              [ typeError
                  path
                  pos
                  UnknownAlias
                  ("type alias '" <> renderQName q <> "' is not declared under types/")
              ]

-- | Structurally resolve a 'TypeExpr' into a 'Type', delegating alias
-- references to the supplied callback.
resolveTypeExprWith :: (QName -> Either [TypeError] Type) -> TypeExpr -> Either [TypeError] Type
resolveTypeExprWith onAlias = go
  where
    go = \case
      TString -> Right TyString
      TInt -> Right TyInt
      TDouble -> Right TyDouble
      TBool -> Right TyBool
      TJson -> Right TyJson
      TBytes -> Right TyBytes
      TFileRef -> Right TyFileRef
      TList t -> TyList <$> go t
      TRecord fs -> TyRecord <$> traverse (\(n, t) -> (,) n <$> go t) fs
      TWorkflowRef a b -> TyWorkflowRef <$> go a <*> go b
      TToolRef a b -> TyToolRef <$> go a <*> go b
      TSecret t -> TySecret <$> go t
      TContext -> Right TyContext
      TTrace -> Right TyTrace
      TTraceEvent -> Right TyTraceEvent
      TAlias q -> onAlias q

aliasPath :: QName -> FilePath
aliasPath q = T.unpack (renderQName q) <> ".md"
