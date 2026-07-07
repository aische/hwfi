-- | The step DSL AST: statements inside @step@ blocks. See spec §3.1, §3.4,
-- and the control-flow constructs (§13, M8): @if@\/@else@, @foreach@, and
-- @par@.
--
-- Every statement other than @return@ shares the @binder \<- rhs \@id@ shape,
-- where the right-hand side is either a call ('SStep') or a control-flow
-- construct ('SIf'\/'SLoop'). A control-flow construct binds a /value/ just
-- like a step: an @if@ yields the value of the taken branch; a @foreach@\/@par@
-- yields the list of its body's per-iteration values (map semantics). A
-- construct may discard its value (@_ \<- ...@) when it is run purely for its
-- side effects, exactly as a step may.
module Hwfi.Ast.Step
  ( Binder (..),
    Arg (..),
    StepStmt (..),
    LoopKind (..),
    IfStmt (..),
    LoopStmt (..),
    Statement (..),
    statementSpan,
    statementId,
    blockStatements,
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

-- | Whether a @foreach@\/@par@ loop runs its iterations sequentially or
-- concurrently (§13, M8). 'LoopPar' carries an optional bound on the number of
-- iterations run at once (@par(max = N) ...@); 'Nothing' uses the engine
-- default. Result ordering is always the input order regardless of kind, so a
-- loop is deterministic.
data LoopKind
  = LoopSeq
  | LoopPar (Maybe Int)
  deriving stock (Eq, Show)

-- | An @if \<cond> { … } else { … }@ conditional statement (§13, M8). The
-- @else@ block is optional only when the value is discarded; a value-binding
-- @if@ requires both branches (checked in 'Hwfi.Check.Decl').
data IfStmt = IfStmt
  { ifBinder :: Binder,
    ifCond :: Expr,
    ifThen :: [Statement],
    -- | 'Nothing' when there is no @else@ branch.
    ifElse :: Maybe [Statement],
    ifId :: Ident,
    ifSpan :: Span
  }
  deriving stock (Eq, Show)

-- | A @foreach v in \<list> { … }@ / @par v in \<list> { … }@ iteration
-- statement (§13, M8). @loopVar@ is bound to each element inside the body;
-- the statement's value is the list of the body's per-iteration values.
data LoopStmt = LoopStmt
  { loopKind :: LoopKind,
    loopBinder :: Binder,
    loopVar :: Ident,
    loopList :: Expr,
    loopBody :: [Statement],
    loopId :: Ident,
    loopSpan :: Span
  }
  deriving stock (Eq, Show)

-- | A statement within a @step@ block or a control-flow block.
data Statement
  = SStep StepStmt
  | -- | An explicit @return { ... }@ block (§3.1). Only valid at the top level
    -- of a workflow\/tool body, never inside a control-flow block.
    SReturn [Arg] Span
  | SIf IfStmt
  | SLoop LoopStmt
  deriving stock (Eq, Show)

-- | The source span of a statement.
statementSpan :: Statement -> Span
statementSpan = \case
  SStep s -> stepSpan s
  SReturn _ sp -> sp
  SIf s -> ifSpan s
  SLoop s -> loopSpan s

-- | The static id of a statement, if it has one (@return@ has none). Step ids
-- and control-flow ids share one namespace and must be unique within a
-- declaration (§13, M8), so the executor can key per-step data and the
-- step-key scope path stays unambiguous.
statementId :: Statement -> Maybe Ident
statementId = \case
  SStep s -> Just (stepId s)
  SReturn _ _ -> Nothing
  SIf s -> Just (ifId s)
  SLoop s -> Just (loopId s)

-- | The immediate child statement blocks of a statement (empty for steps and
-- returns). Used to walk the control-flow tree in the checker and graph.
blockStatements :: Statement -> [[Statement]]
blockStatements = \case
  SStep _ -> []
  SReturn _ _ -> []
  SIf s -> ifThen s : maybe [] pure (ifElse s)
  SLoop s -> [loopBody s]
