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
import Hwfi.Ast.Name (Ident, QName, isBareQName, qnameSegments, renderQName)
import Hwfi.Ast.Project (Declaration (..))
import Hwfi.Ast.Step
import Hwfi.Ast.Tool (Tool (..))
import Hwfi.Ast.Workflow (Section, Workflow (..))
import Hwfi.Check.Builtins (Callee (..), introspectQName)
import Hwfi.Check.Error (TypeError, TypeErrorKind (..), typeError)
import Hwfi.Check.Expr (Env (..), checkExpr)
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
    ccEnvRecord :: Type
  }

-- | Check a declaration's body. Aliases and prompts have no body and yield no
-- errors or steps.
checkDeclBody ::
  CheckCtx ->
  QName ->
  Declaration ->
  ResolvedSignature ->
  ([TypeError], [(StepStmt, Bool, Type)])
checkDeclBody ctx qname decl sig =
  case decl of
    DeclWorkflow w -> checkBody ctx qname sig (wfStatements w) (wfSections w)
    DeclTool t -> checkBody ctx qname sig (toolStatements t) (toolSections t)
    _ -> ([], [])

-- Body checking --------------------------------------------------------------

-- | Accumulator for the linear pass over statements.
data BodyState = BodyState
  { bsRoots :: Map Ident Type,
    bsBound :: [Ident],
    bsErrors :: [TypeError],
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
  ([TypeError], [(StepStmt, Bool, Type)])
checkBody ctx qname sig statements sections =
  (bsErrors final <> returnErrs, reverse (bsSteps final))
  where
    path = declPath qname
    initialRoots =
      Map.fromList
        [ ("inputs", TyRecord (rsigInputs sig)),
          ("ctx", TyContext)
        ]
    initial = BodyState initialRoots [] [] [] Nothing

    steps = [s | SStep s <- statements]
    returns = [(args, sp) | SReturn args sp <- statements]

    final = foldl' (checkStep ctx path sections) initial steps

    finalEnv = mkEnv ctx path sections (bsRoots final)
    returnErrs = checkReturnRule finalEnv path sig returns (bsLastResult final)

mkEnv :: CheckCtx -> FilePath -> [Section] -> Map Ident Type -> Env
mkEnv ctx path sections roots =
  Env
    { envRoots = roots,
      envEnv = ccEnvRecord ctx,
      envSections = sections,
      envRefType = ccRefType ctx,
      envPath = path
    }

-- | Check one step statement and thread the binding environment forward.
checkStep :: CheckCtx -> FilePath -> [Section] -> BodyState -> StepStmt -> BodyState
checkStep ctx path sections st s =
  st
    { bsErrors = bsErrors st <> targetErrs <> argErrs <> bindErrs,
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

    (argErrs, resultType) = case mCallee of
      Nothing -> ([], Nothing)
      Just callee ->
        ( checkArgs env callee (stepArgs s),
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

-- | A step is non-cacheable if it calls @builtin/introspect@ or any of its
-- argument expressions references a volatile @ctx@ field (@ctx.trace@ or
-- @ctx.run.started_at@). This is a purely syntactic scan.
classifyCacheable :: QName -> [Arg] -> Bool
classifyCacheable target args =
  not (target == introspectQName || any (any refPathVolatile . refPaths . argValue) args)

-- | Whether a reference path reads a volatile @ctx@ field (§8.1).
refPathVolatile :: RefPath -> Bool
refPathVolatile (RefPath "ctx" (AField "trace" : _)) = True
refPathVolatile (RefPath "ctx" (AField "run" : AField "started_at" : _)) = True
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
