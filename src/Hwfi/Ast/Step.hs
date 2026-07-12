-- | The step DSL AST: statements inside @step@ blocks. See spec §3.1, §3.4,
-- and the control-flow constructs (§13, M8; §4.3, M9): @if@\/@else@,
-- @foreach@, @par@, and @while@.
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
    WhileStmt (..),
    WhileBody (..),
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

-- | The @while@ loop body: an external callee (§4.3.1) or an inline block
-- (§4.3.7). Predicate stays a callee in both forms.
data WhileBody
  = -- | @body = workflows/…@ with @body_args@ (§4.3.1).
    WhileBodyCallee
      { wbTarget :: Expr,
        wbArgs :: [Arg]
      }
  | -- | @body = { … }@ — statements run in the iteration scope (§4.3.7).
    WhileBodyInline
      { wbStmts :: [Statement]
      }
  deriving stock (Eq, Show)

-- | A @while(predicate, body)@ predicate/body loop (§4.3, M9). The predicate
-- and body are static callees (qnames or @${ref}@ values); their argument
-- records are evaluated before each invocation. After each body iteration,
-- @${carry}@ holds the previous body result for the next round.
--
-- When 'whileBody' is 'WhileBodyInline', @body_args@ is absent and @${carry}@
-- is in scope inside the block after the first iteration (§4.3.7).
data WhileStmt = WhileStmt
  { whileBinder :: Binder,
    whilePredicate :: Expr,
    whilePredicateArgs :: [Arg],
    whileBody :: WhileBody,
    whileMaxIterations :: Expr,
    whileId :: Ident,
    whileSpan :: Span
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
  | SWhile WhileStmt
  deriving stock (Eq, Show)

-- | The source span of a statement.
statementSpan :: Statement -> Span
statementSpan = \case
  SStep s -> stepSpan s
  SReturn _ sp -> sp
  SIf s -> ifSpan s
  SLoop s -> loopSpan s
  SWhile s -> whileSpan s

-- | The static id of a statement, if it has one (@return@ has none). Step ids
-- and control-flow ids must be unique within each block (§4.2); sibling
-- branches may reuse the same id, disambiguated at runtime by the step-key
-- scope prefix.
statementId :: Statement -> Maybe Ident
statementId = \case
  SStep s -> Just (stepId s)
  SReturn _ _ -> Nothing
  SIf s -> Just (ifId s)
  SLoop s -> Just (loopId s)
  SWhile s -> Just (whileId s)

-- | The immediate child statement blocks of a statement (empty for steps and
-- returns). Used to walk the control-flow tree in the checker and graph.
blockStatements :: Statement -> [[Statement]]
blockStatements = \case
  SStep _ -> []
  SReturn _ _ -> []
  SIf s -> ifThen s : maybe [] pure (ifElse s)
  SLoop s -> [loopBody s]
  SWhile s -> case whileBody s of
    WhileBodyInline stmts -> [stmts]
    WhileBodyCallee _ _ -> []
