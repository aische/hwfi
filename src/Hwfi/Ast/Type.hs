-- | The surface type-expression AST (@TypeExpr@). See spec §3.4 and §5.1.
--
-- This is the /parsed/ shape of a type as written in frontmatter. Alias
-- references ('TAlias') are resolved later by the type checker (§2.1, A10);
-- nothing here is resolved or normalised.
module Hwfi.Ast.Type
  ( TypeExpr (..),
  )
where

import Hwfi.Ast.Name (Ident, QName)

-- | A type expression as written by the user.
data TypeExpr
  = TString
  | TInt
  | TDouble
  | TBool
  | TJson
  | TBytes
  | TFileRef
  | TList TypeExpr
  | -- | Record with ordered fields (order preserved as written, though
    -- structural equality ignores it).
    TRecord [(Ident, TypeExpr)]
  | TWorkflowRef TypeExpr TypeExpr
  | TToolRef TypeExpr TypeExpr
  | TSecret TypeExpr
  | TContext
  | TTrace
  | TTraceEvent
  | -- | A reference to a type alias declared under @types/@ (§2.1). Resolved
    -- during type-checking.
    TAlias QName
  deriving stock (Eq, Show)
