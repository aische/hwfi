-- | The expression sub-language AST. See spec §3.2 and §3.4.
--
-- The two @${...}@ reference positions of §3.2.1 are represented distinctly:
--
--   * a /bare reference/ is 'ERef' (the whole expression is a reference);
--   * an /interpolated reference/ is a 'SInterp' part inside 'EString'.
--
-- This distinction is load-bearing for typing (bare = exact type;
-- interpolated = rendered to text), so it is preserved syntactically.
module Hwfi.Ast.Expr
  ( Expr (..),
    StringPart (..),
    RefPath (..),
    Accessor (..),
  )
where

import Data.Text (Text)
import Hwfi.Ast.Name (Ident, QName, Slug)

-- | An expression appearing as an argument value, list element, or record
-- field value.
data Expr
  = -- | A string literal (short or long) as an ordered list of literal and
    -- interpolated parts. A plain string with no interpolation is a single
    -- 'SLit'.
    EString [StringPart]
  | EInt Integer
  | EDouble Double
  | EBool Bool
  | ENull
  | -- | A bare reference @${path}@ that is the entire expression (§3.2.1).
    ERef RefPath
  | EList [Expr]
  | ERecord [(Ident, Expr)]
  | -- | @\@self#slug@ — raw markdown content of a heading section (§3.2).
    ESelf Slug
  | -- | A bare qualified name, permitted only where a @ToolRef@/@WorkflowRef@
    -- value is expected (§3.2, §3.4).
    EQName QName
  deriving stock (Eq, Show)

-- | One piece of a string literal.
data StringPart
  = -- | Literal text (escapes already decoded).
    SLit Text
  | -- | An interpolated reference @${path}@ rendered to text at runtime
    -- (§3.2.1).
    SInterp RefPath
  deriving stock (Eq, Show)

-- | A reference path: a root identifier followed by field/index accessors,
-- e.g. @contents.text@ or @ctx.trace[0]@.
data RefPath = RefPath
  { refRoot :: Ident,
    refAccessors :: [Accessor]
  }
  deriving stock (Eq, Show)

-- | A single step in a reference path.
data Accessor
  = AField Ident
  | AIndex Int
  deriving stock (Eq, Show)
