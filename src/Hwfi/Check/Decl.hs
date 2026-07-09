-- | Per-declaration body checking (spec §5.6): environment building and scope
-- rules (§5.3, §3.4), step-call checking against callee signatures (§5.6.1,
-- §5.6.2), the return rule (§5.6.5), and the static cacheable/non-cacheable
-- classification (§8.1, 3.7).
--
-- This module is IO-free and produces, per declaration, the accumulated type
-- errors and the list of steps paired with their cache classification. Callee
-- fingerprints (§8.1) are attached later by 'Hwfi.Check', once the acyclic
-- call graph is confirmed.
module Hwfi.Check.Decl
  ( CheckCtx (..),
    checkDeclBody,
    classifyCacheable,
  )
where

import Data.List (foldl')
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Hwfi.Ast.Expr (Accessor (..), Expr (..), RefPath (..), StringPart (..))
import Hwfi.Ast.Name (Ident, QName, isBareQName, qnameFromText, qnameSegments, renderQName)
import Hwfi.Ast.InstructionSkill (InstructionSkill (..))
import Hwfi.Ast.Project (Declaration (..))
import Hwfi.Ast.Step
import Hwfi.Ast.Tool (Tool (..))
import Hwfi.Ast.Workflow (Section, Workflow (..))
import Hwfi.Check.Builtins (Callee (..), discoverSkillsQName, evalWorkflowQName, introspectQName, isAgentBuiltin, listRunsQName, loadSkillQName, llmAgentObjectQName, logQName, readRunTraceQName, traceSliceQName)
import Hwfi.Check.Error (TypeError, TypeErrorKind (..), typeError, CheckWarning (..), checkWarning)
import Hwfi.Check.Expr (Env (..), checkExpr, checkExprWithCarry, inferExpr)
import Hwfi.Runtime.Schema (ineligibilityReasons)
import Hwfi.Source (Pos (..), Span (..))
import Hwfi.Type
import Hwfi.TypedProject (ResolvedSignature (..))
import Data.Either (fromLeft)

-- | Ambient information a body check needs about the rest of the project.
data CheckCtx = CheckCtx
  { -- | Resolve a declared/builtin call target to its signature.
    ccCallee :: QName -> Maybe Callee,
    -- | Resolve a bare qname value to its @ToolRef@/@WorkflowRef@ type.
    ccRefType :: QName -> Maybe Type,
    -- | The @ctx.env@ record type (§5.7).
    ccEnvRecord :: Type,
    -- | Whether a callee (transitively) reaches @builtin/introspect@ (§6.1.5).
    -- Used to reject an introspect-reaching callee advertised as an agent tool.
    ccReachesIntrospect :: QName -> Bool
  }

-- | Check a declaration's body. Aliases and prompts have no body and yield no
-- errors or steps.
checkDeclBody ::
  CheckCtx ->
  QName ->
  Declaration ->
  ResolvedSignature ->
  ([TypeError], [CheckWarning], [(StepStmt, Bool, Type)])
checkDeclBody ctx qname decl sig =
  case decl of
    DeclWorkflow w -> checkBody ctx qname sig (wfStatements w) (wfSections w)
    DeclTool t -> checkBody ctx qname sig (toolStatements t) (toolSections t)
    DeclInstruction is -> checkInstructionSkill qname is
    _ -> ([], [], [])

checkInstructionSkill :: QName -> InstructionSkill -> ([TypeError], [CheckWarning], [(StepStmt, Bool, Type)])
checkInstructionSkill qname is =
  if T.null (T.strip (isBody is))
    then
      ( [ typeError
            (declPath qname)
            (Pos 1 1)
            TypeMismatch
            "instruction skill body must not be empty (§6.6.1)"
        ],
        [],
        []
      )
    else ([], [], [])

-- Body checking --------------------------------------------------------------

-- | Accumulator for the linear pass over statements.
data BodyState = BodyState
  { bsRoots :: Map Ident Type,
    bsBound :: [Ident],
    bsErrors :: [TypeError],
    bsWarnings :: [CheckWarning],
    bsSteps :: [(StepStmt, Bool, Type)],
    -- | Result type of the most recent step, for the implicit-return rule.
    bsLastResult :: Maybe Type
  }

checkBody ::
  CheckCtx ->
  QName ->
  ResolvedSignature ->
  [Statement] ->
  [Section] ->
  ([TypeError], [CheckWarning], [(StepStmt, Bool, Type)])
checkBody ctx qname sig statements sections =
  (dupErrs <> bsErrors final <> returnErrs, bsWarnings final, reverse (bsSteps final))
  where
    path = declPath qname
    initialRoots =
      Map.fromList
        [ ("inputs", TyRecord (rsigInputs sig)),
          ("ctx", TyContext)
        ]
    initial = BodyState initialRoots [] [] [] [] Nothing

    -- @return@ is a top-level construct (§5.6.5); the sequence that builds the
    -- binding environment and the implicit-return result excludes it. A
    -- @return@ nested inside a control-flow block is caught by 'checkStmt'.
    seqStmts = filter (not . isReturn) statements
    returns = [(args, sp) | SReturn args sp <- statements]

    final = checkSeq ctx path sections initial seqStmts

    finalEnv = mkEnv ctx path sections (bsRoots final)
    returnErrs = checkReturnRule finalEnv path sig returns (bsLastResult final)

    dupErrs = duplicateIdErrors path statements

isReturn :: Statement -> Bool
isReturn = \case
  SReturn _ _ -> True
  _ -> False

-- | Step/control-flow ids must be unique within each block (§4.2). Sibling
-- branches and unrelated loops may reuse the same static id; the executor
-- disambiguates dynamically via the step-key scope prefix
-- (e.g. @mode?then/notify@ vs @mode?else/notify@).
duplicateIdErrors :: FilePath -> [Statement] -> [TypeError]
duplicateIdErrors path statements =
  dupInBlock statements <> concatMap dupNested statements
  where
    dupNested = \case
      SIf s -> duplicateIdErrors path (ifThen s) <> maybe [] (duplicateIdErrors path) (ifElse s)
      SLoop s -> duplicateIdErrors path (loopBody s)
      SWhile _ -> []
      _ -> []

    dupInBlock stmts = go [] idPositions
      where
        idPositions = [(i, spanStart (statementSpan s)) | s <- stmts, Just i <- [statementId s]]
        go _ [] = []
        go seen ((i, p) : rest)
          | i `elem` seen =
              typeError
                path
                p
                DuplicateBind
                ( "duplicate step/control-flow id '"
                    <> i
                    <> "'; ids must be unique within a block (§4.2)"
                )
                : go seen rest
          | otherwise = go (i : seen) rest

-- Statement-sequence checking (§5.6, §13) -----------------------------------

-- | Check a sequence of statements, threading the binding environment forward.
checkSeq :: CheckCtx -> FilePath -> [Section] -> BodyState -> [Statement] -> BodyState
checkSeq ctx path sections = foldl' (checkStmt ctx path sections)

-- | Check one statement, dispatching on its kind.
checkStmt :: CheckCtx -> FilePath -> [Section] -> BodyState -> Statement -> BodyState
checkStmt ctx path sections st = \case
  SStep s -> checkStep ctx path sections st s
  SIf s -> checkIf ctx path sections st s
  SLoop s -> checkLoop ctx path sections st s
  SWhile s -> checkWhile ctx path sections st s
  SReturn _ sp ->
    st
      { bsErrors =
          bsErrors st
            <> [ typeError
                   path
                   (spanStart sp)
                   ReturnRule
                   "a 'return' block is only allowed at the top level of a workflow body, not inside a control-flow block (§13)"
               ],
        bsLastResult = Nothing
      }

-- | Check a nested block in a /child/ scope (§13). Enclosing binds and roots
-- are visible inside the block, but inner binds do not escape: only the
-- construct's own bind name (handled by the caller) is added to the outer
-- scope. Returns the block's accumulated errors, its (flat) nested steps, and
-- its /tail/ result type (the value the block yields, §5.6.5).
checkChild ::
  CheckCtx ->
  FilePath ->
  [Section] ->
  BodyState ->
  -- | Extra roots visible only inside the block (e.g. a loop variable).
  Map Ident Type ->
  -- | Extra bound names (for no-shadowing) visible only inside the block.
  [Ident] ->
  [Statement] ->
  ([TypeError], [(StepStmt, Bool, Type)], Maybe Type)
checkChild ctx path sections parent extraRoots extraBound stmts =
  (bsErrors res, bsSteps res, bsLastResult res)
  where
    child =
      parent
        { bsRoots = Map.union extraRoots (bsRoots parent),
          bsBound = extraBound <> bsBound parent,
          bsErrors = [],
          bsSteps = [],
          bsLastResult = Nothing
        }
    res = checkSeq ctx path sections child stmts

-- | Check an @if@\/@else@ statement (§13). The condition must be @Bool@. An
-- @if@ that binds a value requires an @else@ branch whose tail type
-- structurally equals the @then@ branch's tail type; the bound value has that
-- type. A discarding @if@ (@_ \<- if …@) needs no @else@ and imposes no branch
-- type constraint.
checkIf :: CheckCtx -> FilePath -> [Section] -> BodyState -> IfStmt -> BodyState
checkIf ctx path sections st s =
  st
    { bsErrors = bsErrors st <> condErrs <> thenErrs <> elseErrs <> branchErrs <> bindErrs,
      bsSteps = thenSteps <> elseSteps <> bsSteps st,
      bsRoots = roots',
      bsBound = bound',
      bsLastResult = resultType
    }
  where
    env = mkEnv ctx path sections (bsRoots st)
    pos = spanStart (ifSpan s)

    condErrs = fromLeft [] (checkExpr env pos TyBool (ifCond s))

    (thenErrs, thenSteps, thenTail) = checkChild ctx path sections st Map.empty [] (ifThen s)
    (elseErrs, elseSteps, elseTail) = case ifElse s of
      Just blk -> checkChild ctx path sections st Map.empty [] blk
      Nothing -> ([], [], Nothing)

    (resultType, branchErrs) = case ifBinder s of
      BindDiscard -> (Nothing, [])
      BindName _ -> case ifElse s of
        Nothing ->
          ( Nothing,
            [ typeError
                path
                pos
                ReturnRule
                "an 'if' that binds a value requires an 'else' branch (§13)"
            ]
          )
        Just _ -> case (thenTail, elseTail) of
          (Just t1, Just t2)
            | structEq t1 t2 -> (Just t1, [])
            | otherwise ->
                ( Nothing,
                  [ typeError
                      path
                      pos
                      TypeMismatch
                      ( "the 'if' branches yield different types: 'then' is "
                          <> renderType t1
                          <> ", 'else' is "
                          <> renderType t2
                          <> " (§13)"
                      )
                  ]
                )
          _ ->
            ( Nothing,
              [ typeError
                  path
                  pos
                  ReturnRule
                  "each branch of a value-binding 'if' must end in a value-producing statement (§13)"
              ]
            )

    (roots', bound', bindErrs) = bindResult path pos (ifBinder s) resultType st

-- | Check a @foreach@\/@par@ loop (§13). The iterated expression must be a
-- @List<T>@; the loop variable is bound to @T@ inside the body. The loop's
-- value is @List<U>@ where @U@ is the body's tail type (map semantics); a
-- discarding loop imposes no body-value constraint.
checkLoop :: CheckCtx -> FilePath -> [Section] -> BodyState -> LoopStmt -> BodyState
checkLoop ctx path sections st s =
  st
    { bsErrors = bsErrors st <> listErrs <> varShadowErrs <> bodyErrs <> resErrs <> bindErrs,
      bsSteps = bodySteps <> bsSteps st,
      bsRoots = roots',
      bsBound = bound',
      bsLastResult = resultType
    }
  where
    env = mkEnv ctx path sections (bsRoots st)
    pos = spanStart (loopSpan s)
    kindLabel = case loopKind s of
      LoopSeq -> "foreach"
      LoopPar _ -> "par"

    (elemTy, listErrs) = case inferExpr env pos (loopList s) of
      Right (TyList e) -> (Just e, [])
      Right other ->
        ( Nothing,
          [ typeError
              path
              pos
              TypeMismatch
              ("'" <> kindLabel <> "' iterates a List<_>, but the expression has type " <> renderType other <> " (§13)")
          ]
        )
      Left es -> (Nothing, es)

    varShadowErrs =
      [ typeError
          path
          pos
          DuplicateBind
          ("loop variable '" <> loopVar s <> "' shadows an existing binding (no shadowing, §3.4)")
      | loopVar s `elem` (Map.keys (bsRoots st) <> bsBound st)
      ]

    childRoots = maybe Map.empty (Map.singleton (loopVar s)) elemTy
    (bodyErrs, bodySteps, bodyTail) =
      checkChild ctx path sections st childRoots [loopVar s] (loopBody s)

    (resultType, resErrs) = case loopBinder s of
      BindDiscard -> (Nothing, [])
      BindName _ -> case bodyTail of
        Just t -> (Just (TyList t), [])
        Nothing ->
          ( Nothing,
            [ typeError
                path
                pos
                ReturnRule
                ("the body of a value-binding '" <> kindLabel <> "' must end in a value-producing statement (§13)")
            ]
          )

    (roots', bound', bindErrs) = bindResult path pos (loopBinder s) resultType st

-- | Check a @while@ loop (§4.3, M9). The predicate must expose @continue@ and
-- @reason@; argument records must match callee inputs; @max_iterations@ must be
-- @Int@; a value-binding @while@ yields @List<U>@ from the body outputs.
checkWhile :: CheckCtx -> FilePath -> [Section] -> BodyState -> WhileStmt -> BodyState
checkWhile ctx path sections st s =
  st
    { bsErrors =
        bsErrors st
          <> targetErrs
          <> predShapeErrs
          <> predArgErrs
          <> bodyArgErrs
          <> maxErrs
          <> resErrs
          <> bindErrs,
      bsRoots = roots',
      bsBound = bound',
      bsLastResult = resultType
    }
  where
    env = mkEnv ctx path sections (bsRoots st)
    pos = spanStart (whileSpan s)

    (mPredCallee, predTargetErrs) = resolveExprTarget ctx env path pos (whilePredicate s)
    (mBodyCallee, bodyTargetErrs) = resolveExprTarget ctx env path pos (whileBody s)
    targetErrs = predTargetErrs <> bodyTargetErrs

    predShapeErrs = case mPredCallee of
      Nothing -> []
      Just callee -> predicateShapeErrors path pos callee

    bodyOutTy = mBodyCallee >>= calleeResultType

    predArgErrs = case mPredCallee of
      Nothing -> []
      Just callee -> checkArgsWithCarry bodyOutTy env callee (whilePredicateArgs s)
    bodyArgErrs = case mBodyCallee of
      Nothing -> []
      Just callee -> checkArgsWithCarry bodyOutTy env callee (whileBodyArgs s)

    maxErrs = fromLeft [] (checkExpr env pos TyInt (whileMaxIterations s))

    (resultType, resErrs) = case whileBinder s of
      BindDiscard -> (Nothing, [])
      BindName _ -> case bodyOutTy of
        Just t -> (Just (TyList t), [])
        Nothing ->
          ( Nothing,
            [ typeError
                path
                pos
                ReturnRule
                "a value-binding 'while' requires a body workflow with known outputs (§4.3.3)"
            ]
          )

    (roots', bound', bindErrs) = bindResult path pos (whileBinder s) resultType st

-- | Resolve a @while@ callee expression (@qname@ or @${ref}@) to a 'Callee'.
resolveExprTarget :: CheckCtx -> Env -> FilePath -> Pos -> Expr -> (Maybe Callee, [TypeError])
resolveExprTarget ctx env path pos = \case
  EQName q -> resolveTarget ctx env path pos q
  ERef (RefPath root [])
    | root `elem` Map.keys (envRoots env) ->
        resolveTarget ctx env path pos (qnameFromText root)
  _ ->
    ( Nothing,
      [ typeError
          path
          pos
          UndeclaredTarget
          "while(...) 'predicate' and 'body' must be a static qname or a bound ToolRef/WorkflowRef (§4.3.1)"
      ]
    )

predicateShapeErrors :: FilePath -> Pos -> Callee -> [TypeError]
predicateShapeErrors path pos callee =
  [ typeError path pos TypeMismatch msg
  | not (hasField outs TyBool "continue" && hasField outs TyString "reason")
  ]
  where
    outs = calleeOutputs callee
    msg =
      "while(...) predicate outputs must structurally include continue: Bool and reason: String (§4.3.2); got "
        <> renderType (TyRecord outs)
    hasField fields ty name = case lookup name fields of
      Just t -> structEq t ty
      Nothing -> False

calleeResultType :: Callee -> Maybe Type
calleeResultType callee = Just (TyRecord (calleeOutputs callee))

checkArgsWithCarry :: Maybe Type -> Env -> Callee -> [Arg] -> [TypeError]
checkArgsWithCarry mCarry env callee args = missingErrs <> extraErrs <> valueErrs
  where
    inputs = calleeInputs callee
    argNames = map argName args
    inputNames = map fst inputs

    missingErrs =
      [ typeError
          (envPath env)
          (envArgPos args)
          ArgMismatch
          ("missing argument '" <> n <> "'")
        | n <- inputNames,
          n `notElem` argNames
      ]

    extraErrs =
      [ typeError
          (envPath env)
          (spanStart (argSpan a))
          ArgMismatch
          ("unexpected argument '" <> argName a <> "'")
        | a <- args,
          argName a `notElem` inputNames
      ]

    valueErrs =
      concat
        [ fromLeft [] (checkExprWithCarry mCarry env (spanStart (argSpan a)) t (argValue a))
        | a <- args,
          Just t <- [lookup (argName a) inputs]
        ]

mkEnv :: CheckCtx -> FilePath -> [Section] -> Map Ident Type -> Env
mkEnv ctx path sections roots =
  Env
    { envRoots = roots,
      envEnv = ccEnvRecord ctx,
      envSections = sections,
      envRefType = ccRefType ctx,
      envPath = path,
      envCarryType = Nothing
    }

-- | Check one step statement and thread the binding environment forward.
checkStep :: CheckCtx -> FilePath -> [Section] -> BodyState -> StepStmt -> BodyState
checkStep ctx path sections st s =
  st
    { bsErrors = bsErrors st <> targetErrs <> argErrs <> bindErrs,
      bsWarnings = bsWarnings st <> argWarnings,
      bsSteps = (s, cacheable, fromMaybe TyJson resultType) : bsSteps st,
      bsRoots = roots',
      bsBound = bound',
      bsLastResult = resultType
    }
  where
    env = mkEnv ctx path sections (bsRoots st)
    pos = spanStart (stepSpan s)
    target = stepTarget s

    -- Resolve the call target to a callee signature.
    (mCallee, targetErrs) = resolveTarget ctx env path pos target

    (argErrs, argWarnings, resultType)
      -- Agent builtins take a heterogeneous @tools@ list and need bespoke
      -- checking (§5.6.9); the generic 'checkArgs' path cannot express it.
      | isAgentBuiltin target = checkAgentCall ctx env path pos target (stepArgs s)
      | otherwise = case mCallee of
          Nothing -> ([], [], Nothing)
          Just callee ->
            ( checkArgs env callee (stepArgs s),
              [],
              Just (TyRecord (calleeOutputs callee))
            )

    cacheable = classifyCacheable target (stepArgs s)

    -- Bind the result (unless discarding), enforcing no-shadowing (§3.4).
    (roots', bound', bindErrs) = bindResult path pos (stepBinder s) resultType st

resolveTarget ::
  CheckCtx -> Env -> FilePath -> Pos -> QName -> (Maybe Callee, [TypeError])
resolveTarget ctx env path pos target
  | isBareQName target =
      -- A bare target must be a first-class ToolRef/WorkflowRef value in scope.
      case Map.lookup (bareIdent target) (envRoots env) of
        Just (TyToolRef inTy outTy) -> refCallee inTy outTy
        Just (TyWorkflowRef inTy outTy) -> refCallee inTy outTy
        Just other ->
          ( Nothing,
            [ typeError
                path
                pos
                UndeclaredTarget
                ( "'"
                    <> renderQName target
                    <> "' is not a ToolRef/WorkflowRef value (it has type "
                    <> renderType other
                    <> ")"
                )
            ]
          )
        Nothing ->
          ( Nothing,
            [ typeError
                path
                pos
                UndeclaredTarget
                ("call target '" <> renderQName target <> "' is not in scope")
            ]
          )
  | otherwise = case ccCallee ctx target of
      Just c -> (Just c, [])
      Nothing ->
        ( Nothing,
          [ typeError
              path
              pos
              UndeclaredTarget
              ("call target '" <> renderQName target <> "' does not resolve to a workflow, tool, or builtin")
          ]
        )
  where
    refCallee inTy outTy =
      case (recordFields inTy, recordFields outTy) of
        (Just ins, Just outs) -> (Just (Callee ins outs), [])
        _ ->
          ( Nothing,
            [ typeError
                path
                pos
                UndeclaredTarget
                ("ref target '" <> renderQName target <> "' does not have record input/output types")
            ]
          )

-- Agent tool-use checking (§5.6.9, §6.1.1, §6.1.5, A18) ----------------------

-- | Check a call to @builtin/llm-agent@\/@builtin/llm-agent-object@ (§6.1). The
-- scalar arguments are checked normally, @max_rounds@ must be a static @Int@
-- ≥ 1, and each element of the @tools@ list must be a bare tool\/workflow name
-- that is **agent-eligible**: none of its declared inputs may be @Secret<_>@,
-- @ToolRef@\/@WorkflowRef@, or @Bytes@ (§6.1.1), and it must not (transitively)
-- reach @builtin/introspect@ (§6.1.5). Ineligible callees are rejected here.
checkAgentCall :: CheckCtx -> Env -> FilePath -> Pos -> QName -> [Arg] -> ([TypeError], [CheckWarning], Maybe Type)
checkAgentCall ctx env path pos target args =
  (missingExtra <> scalarErrs <> toolsErrs, toolsWarnings, Just resultTy)
  where
    isObject = target == llmAgentObjectQName
    resultTy = TyRecord (maybe [] calleeOutputs (ccCallee ctx target))

    expected =
      [("system", TyString), ("prompt", TyString), ("model", TyString)]
        <> [("schema", TyJson) | isObject]
        <> [("max_rounds", TyInt)]
    -- @tools@ is validated separately (not a plain typed field).
    expectedNames = "tools" : map fst expected

    argNames = map argName args
    missingExtra =
      [ typeError path pos ArgMismatch ("missing argument '" <> n <> "'")
      | n <- expectedNames,
        n `notElem` argNames
      ]
        <> [ typeError path (spanStart (argSpan a)) ArgMismatch ("unexpected argument '" <> argName a <> "'")
           | a <- args,
             argName a `notElem` expectedNames
           ]

    scalarErrs =
      concat
        [ fromLeft [] (checkExpr env (spanStart (argSpan a)) t (argValue a))
        | a <- args,
          Just t <- [lookup (argName a) expected]
        ]
        <> maxRoundsErrs

    maxRoundsErrs = case lookup "max_rounds" argMap of
      Just (Arg _ (EInt n) sp)
        | n < 1 ->
            [typeError path (spanStart sp) ArgMismatch "'max_rounds' must be >= 1 (§6.1)"]
      _ -> []

    toolsErrs = case lookup "tools" argMap of
      Nothing -> []
      Just a -> fst (checkToolsExpr ctx env path (spanStart (argSpan a)) (argValue a))

    toolsWarnings = case lookup "tools" argMap of
      Nothing -> []
      Just a -> snd (checkToolsExpr ctx env path (spanStart (argSpan a)) (argValue a))

    argMap = [(argName a, a) | a <- args]

-- | Validate the agent @tools@ argument (§6.1.1, §6.1.6 phase 2).
checkToolsExpr :: CheckCtx -> Env -> FilePath -> Pos -> Expr -> ([TypeError], [CheckWarning])
checkToolsExpr ctx env path pos expr =
  case staticQNameList expr of
    Just qnames ->
      (concatMap (\q -> checkToolElem ctx path pos (EQName q)) qnames, [])
    Nothing ->
      case inferExpr env pos expr of
        Left errs -> (errs, [])
        Right (TyList _) ->
          ( [],
            [ checkWarning
                path
                pos
                "agent tools list is not statically known; tool eligibility is enforced at runtime only (§6.1.6)"
            ]
          )
        Right other ->
          ( [ typeError
                path
                pos
                TypeMismatch
                ( "the 'tools' argument must have type List<...>, got "
                    <> renderType other
                    <> " (§6.1.6)"
                )
            ],
            []
          )

-- | When @tools@ is a list literal of bare qnames, return them for static
-- eligibility checking.
staticQNameList :: Expr -> Maybe [QName]
staticQNameList (EList es) = traverse extractQName es
  where
    extractQName (EQName q) = Just q
    extractQName _ = Nothing
staticQNameList _ = Nothing

-- | Check one element of the @tools@ list: it must be a bare tool\/workflow
-- name resolving to an agent-eligible callee.
checkToolElem :: CheckCtx -> FilePath -> Pos -> Expr -> [TypeError]
checkToolElem ctx path pos = \case
  EQName q
    | q == discoverSkillsQName || q == loadSkillQName -> []
    | isAgentBuiltin q ->
        [err ("'" <> renderQName q <> "' is an agent builtin and cannot be advertised as a tool")]
    | q == introspectQName || ccReachesIntrospect ctx q ->
        [err ("advertised tool '" <> renderQName q <> "' (transitively) calls builtin/introspect, which must not be reachable by the model (§6.1.5)")]
    | otherwise -> case ccCallee ctx q of
        Nothing ->
          [err ("advertised tool '" <> renderQName q <> "' does not resolve to a workflow, tool, or builtin")]
        Just callee ->
          [ err ("advertised tool '" <> renderQName q <> "' is not agent-eligible: " <> reason)
          | reason <- ineligibilityReasons (calleeInputs callee)
          ]
  _ -> [err "each advertised tool must be a bare tool/workflow name (§6.1.1)"]
  where
    err = typeError path pos ArgMismatch

-- | Check a step's arguments against a callee's declared inputs (§5.6.2):
-- every input must be supplied with a matching type, and no unexpected
-- arguments may be given.
checkArgs :: Env -> Callee -> [Arg] -> [TypeError]
checkArgs env callee args = missingErrs <> extraErrs <> valueErrs
  where
    inputs = calleeInputs callee
    argNames = map argName args
    inputNames = map fst inputs

    missingErrs =
      [ typeError
          (envPath env)
          (envArgPos args)
          ArgMismatch
          ("missing argument '" <> n <> "'")
        | n <- inputNames,
          n `notElem` argNames
      ]

    extraErrs =
      [ typeError
          (envPath env)
          (spanStart (argSpan a))
          ArgMismatch
          ("unexpected argument '" <> argName a <> "'")
        | a <- args,
          argName a `notElem` inputNames
      ]

    valueErrs =
      concat
        [ fromLeft [] (checkExpr env (spanStart (argSpan a)) t (argValue a))
          | a <- args,
            Just t <- [lookup (argName a) inputs]
        ]

-- | A fallback position for a "missing argument" error: the first argument's
-- start, or (1,1) when there are no arguments.
envArgPos :: [Arg] -> Pos
envArgPos (a : _) = spanStart (argSpan a)
envArgPos [] = Pos 1 1

bindResult ::
  FilePath ->
  Pos ->
  Binder ->
  Maybe Type ->
  BodyState ->
  (Map Ident Type, [Ident], [TypeError])
bindResult path pos binder resultType st =
  case binder of
    BindDiscard -> (bsRoots st, bsBound st, [])
    BindName n
      | n `elem` ["inputs", "ctx"] ->
          (bsRoots st, bsBound st, [shadow n "the ambient root"])
      | n `elem` bsBound st ->
          (bsRoots st, bsBound st, [shadow n "an earlier step"])
      | otherwise ->
          ( Map.insert n (fromMaybe TyJson resultType) (bsRoots st),
            n : bsBound st,
            []
          )
  where
    shadow n what =
      typeError
        path
        pos
        DuplicateBind
        ("bind name '" <> n <> "' shadows " <> what <> " (no shadowing, §3.4)")

-- Return rule (§5.6.5) ------------------------------------------------------

checkReturnRule ::
  Env ->
  FilePath ->
  ResolvedSignature ->
  [([Arg], Span)] ->
  Maybe Type ->
  [TypeError]
checkReturnRule env path sig returns mLastResult =
  case returns of
    (_ : _ : _) ->
      [ typeError path (returnPos returns) ReturnRule "a workflow may have at most one return block"
      ]
    [(args, sp)] -> checkExplicitReturn env outputs args (spanStart sp)
    [] -> checkImplicitReturn path outputs mLastResult
  where
    outputs = rsigOutputs sig

-- | Check an explicit @return { … }@ against the declared outputs.
checkExplicitReturn :: Env -> [(Ident, Type)] -> [Arg] -> Pos -> [TypeError]
checkExplicitReturn env outputs args pos = nameErrs <> valueErrs
  where
    argNames = map argName args
    outNames = map fst outputs
    missing = filter (`notElem` argNames) outNames
    extra = filter (`notElem` outNames) argNames

    nameErrs =
      [ typeError
          (envPath env)
          pos
          ReturnMismatch
          ( "return fields do not match outputs: expected {"
              <> commas outNames
              <> "}, got {"
              <> commas argNames
              <> "}"
          )
        | not (null missing) || not (null extra)
      ]

    valueErrs =
      concat
        [ fromLeft [] (checkExpr env (spanStart (argSpan a)) t (argValue a))
          | a <- args,
            Just t <- [lookup (argName a) outputs]
        ]

-- | Apply the implicit-return rule: with non-empty outputs and no explicit
-- return, the final step's result type must structurally equal the outputs
-- record (§5.6.5).
checkImplicitReturn :: FilePath -> [(Ident, Type)] -> Maybe Type -> [TypeError]
checkImplicitReturn _ [] _ = []
checkImplicitReturn path outputs mLastResult =
  case mLastResult of
    Just t
      | structEq t (TyRecord outputs) -> []
      | otherwise ->
          [ typeError
              path
              (Pos 1 1)
              ReturnRule
              ( "an explicit 'return { … }' is required: the final step result "
                  <> renderType t
                  <> " does not match outputs "
                  <> renderType (TyRecord outputs)
              )
          ]
    Nothing ->
      [ typeError
          path
          (Pos 1 1)
          ReturnRule
          "an explicit 'return { … }' is required because outputs is non-empty"
      ]

-- Cacheable classification (§8.1, 3.7) --------------------------------------

-- | A step is non-cacheable if it calls @builtin/introspect@, is an agent
-- builtin (a model-driven black box, §8.1), or any of its argument expressions
-- references a volatile @ctx@ field (@ctx.trace@, @ctx.run.started_at@, or
-- @ctx.run.usage@). This is a purely syntactic scan.
classifyCacheable :: QName -> [Arg] -> Bool
classifyCacheable target args =
  not
    ( target == introspectQName
        || isAgentBuiltin target
        || target == evalWorkflowQName
        || target == listRunsQName
        || target == readRunTraceQName
        || target == traceSliceQName
        || target == loadSkillQName
        || target == logQName
        || any (any refPathVolatile . refPaths . argValue) args
    )

-- | Whether a reference path reads a volatile @ctx@ field (§8.1).
refPathVolatile :: RefPath -> Bool
refPathVolatile (RefPath "ctx" (AField "trace" : _)) = True
refPathVolatile (RefPath "ctx" (AField "run" : AField "started_at" : _)) = True
refPathVolatile (RefPath "ctx" (AField "run" : AField "usage" : _)) = True
refPathVolatile _ = False

-- | All reference paths occurring in an expression (bare 'ERef' and in-string
-- 'SInterp' parts), recursively.
refPaths :: Expr -> [RefPath]
refPaths = \case
  EString parts -> [rp | SInterp rp <- parts]
  ERef rp -> [rp]
  EList es -> concatMap refPaths es
  ERecord fs -> concatMap (refPaths . snd) fs
  _ -> []

-- Helpers -------------------------------------------------------------------

recordFields :: Type -> Maybe [(Ident, Type)]
recordFields = \case
  TyRecord fs -> Just fs
  _ -> Nothing

bareIdent :: QName -> Ident
bareIdent q = case qnameSegments q of
  (s : _) -> s
  [] -> ""

returnPos :: [([Arg], Span)] -> Pos
returnPos ((_, sp) : _) = spanStart sp
returnPos [] = Pos 1 1

declPath :: QName -> FilePath
declPath q = T.unpack (renderQName q) <> ".md"

commas :: [Text] -> Text
commas = T.intercalate ", "
