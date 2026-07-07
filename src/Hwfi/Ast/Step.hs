-- | The step DSL AST: statements inside @step@ blocks. See spec §3.1, §3.4.
module Hwfi.Ast.Step
  ( Binder (..),
    Arg (..),
    StepStmt (..),
    Statement (..),
    statementSpan,
  )
where

import Hwfi.Ast.Expr (Expr)
import Hwfi.Ast.Name (Ident, QName)
import Hwfi.Source (Span)

-- | The left-hand side of a step statement.
data Binder
  = -- | Bind the result to a name.
    BindName Ident
  | -- | Discard the result (@_ \<- ...@); an explicit @\@id@ is required
    -- (§3.1).
    BindDiscard
  deriving stock (Eq, Show)

-- | A single @key = expr@ argument (also reused for @return@ record fields).
data Arg = Arg
  { argName :: Ident,
    argValue :: Expr,
    argSpan :: Span
  }
  deriving stock (Eq, Show)

-- | A step invocation statement.
data StepStmt = StepStmt
  { stepBinder :: Binder,
    stepTarget :: QName,
    stepArgs :: [Arg],
    -- | The resolved step id: the binder name unless an explicit @\@id@ was
    -- given (§3.1).
    stepId :: Ident,
    stepSpan :: Span
  }
  deriving stock (Eq, Show)

-- | A statement within a @step@ block.
data Statement
  = SStep StepStmt
  | -- | An explicit @return { ... }@ block (§3.1).
    SReturn [Arg] Span
  deriving stock (Eq, Show)

-- | The source span of a statement.
statementSpan :: Statement -> Span
statementSpan = \case
  SStep s -> stepSpan s
  SReturn _ sp -> sp
