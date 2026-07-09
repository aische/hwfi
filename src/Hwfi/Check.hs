-- | The pure type checker (spec §5.6.8, 3.11): a total function
-- @'Project' -> 'Either' ['TypeError'] 'TypedProject'@ with no IO. It is used
-- both at load time (@hwfi check@) and, in v1.1, at runtime over dynamically
-- synthesized workflows (spec §13).
--
-- Checking proceeds in phases so that later phases can assume the invariants
-- established by earlier ones:
--
--   1. resolve type aliases (§2.1) and every declaration signature;
--   2. validate imports and detect call-graph cycles (§5.6.6);
--   3. check each declaration body (steps, references, returns, §5.6);
--   4. only on success, compute Merkle fingerprints (§8.1) — safe because the
--      call graph is now known to be acyclic — and assemble the
--      'TypedProject'.
module Hwfi.Check
  ( checkProject,
    renderCheckErrors,
    renderCheckWarnings,
  )
where

import Control.Applicative ((<|>))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text qualified as T
import Hwfi.Ast.Expr (Expr (..), StringPart (..))
import Hwfi.Ast.Name (QName, qnameFromText, renderQName)
import Hwfi.Ast.Project
import Hwfi.Ast.Step (Arg (..), IfStmt (..), LoopStmt (..), Statement (..), StepStmt (..), stepTarget)
import Hwfi.Ast.Tool (Tool (..))
import Hwfi.Ast.TypeAlias (TypeAlias (..))
import Hwfi.Ast.Type (TypeExpr)
import Hwfi.Ast.Workflow (Signature (..), Workflow (..), emptySignature)
import Hwfi.Check.Alias (resolveAliasDefs, resolveSigTypeExpr)
import Hwfi.Check.Builtins (Callee (..), execQName, introspectQName, isBuiltin, lookupBuiltin)
import Hwfi.Check.Decl (CheckCtx (..), checkDeclBody)
import Hwfi.Check.Error (TypeError, TypeErrorKind (..), typeError, renderTypeErrors, renderCheckWarnings)
import Hwfi.Check.Graph (computeFingerprints, detectImportCycles, directCallees, lookupCalleeFingerprint, projectCallees)
import Data.Set qualified as Set
import Hwfi.Project.Manifest (ExecPolicy (..), ProjectManifest (..))
import Hwfi.SkillCatalog (buildSkillCatalog, skillPolicyFromManifest)
import Hwfi.Source (Diagnostic, Pos (..), spanStart)
import Hwfi.TypedProject
import Hwfi.Type (Type (..), isSecretEnvName)
import Data.Either (fromRight)

-- | Type-check a parsed project. Returns all accumulated errors, or the
-- checked project.
checkProject :: Project -> Either [TypeError] TypedProject
checkProject proj
  | not (null allErrs) = Left allErrs
  | otherwise = Right typed
  where
    decls = projDecls proj
    manifest = projManifest proj

    -- Phase 1: aliases and signatures.
    aliasDefs = Map.fromList (mapMaybe aliasDef (Map.elems decls))
    known = Map.keysSet aliasDefs
    (aliasErrs, aliasMap) = resolveAliasDefs aliasDefs

    sigResults =
      [ (q, resolveSignature known aliasMap (declPath q) (declSignature d))
      | (q, d) <- Map.toList decls
      ]
    sigErrs = concat [e | (_, (e, _)) <- sigResults]
    sigMap = Map.fromList [(q, s) | (q, (_, s)) <- sigResults]

    -- Phase 2: imports and cycles.
    importErrs = concatMap (importErrors decls) (Map.toList decls)
    cycleErrs = detectImportCycles decls
    entrypointErrs = entrypointError decls manifest

    -- Phase 3: declaration bodies.
    ctx = mkCtx decls sigMap manifest (reachesIntrospect decls)
    bodyResults =
      [ (q, checkDeclBody ctx q d (sigLookup q))
      | (q, d) <- Map.toList decls
      ]
    bodyErrs = concat [e | (_, (e, _, _)) <- bodyResults]
    bodyWarnings = concat [w | (_, (_, w, _)) <- bodyResults]
    stepMap = Map.fromList [(q, steps) | (q, (_, _, steps)) <- bodyResults]

    -- §6.3/§7.5/A24: fail-closed rejection of un-permitted builtin/exec calls.
    execErrs = concatMap (execErrors manifest) (Map.toList decls)

    allErrs = aliasErrs <> sigErrs <> importErrs <> cycleErrs <> entrypointErrs <> bodyErrs <> execErrs

    -- Phase 4 (success only): fingerprints and assembly.
    fps = computeFingerprints decls sigMap
    declMap = Map.mapWithKey mkTypedDecl decls
    skillCatalog =
      buildSkillCatalog
        proj
        (Map.keysSet declMap)
        (Map.map (rsigInputs . tdSignature) declMap)
        (reachesIntrospect decls)
    typed =
      TypedProject
        { tpManifest = manifest,
          tpDecls = declMap,
          tpAliases = aliasMap,
          tpSkillCatalog = skillCatalog,
          tpWarnings = bodyWarnings
        }

    sigLookup q = Map.findWithDefault (ResolvedSignature [] [] []) q sigMap

    mkTypedDecl q d =
      TypedDecl
        { tdDeclaration = d,
          tdSignature = sigLookup q,
          tdSteps =
            [ TypedStep
                { tsStmt = stmt,
                  tsCacheable = cacheable,
                  tsCalleeFingerprint = lookupCalleeFingerprint fps (stepTargetOf stmt),
                  tsResultType = resultTy
                }
            | (stmt, cacheable, resultTy) <- Map.findWithDefault [] q stepMap
            ],
          tdFingerprint = Map.findWithDefault (Fingerprint "") q fps
        }

-- | Render check errors as spec §9.1 diagnostics.
renderCheckErrors :: [TypeError] -> [Diagnostic]
renderCheckErrors = renderTypeErrors

-- Signature resolution -------------------------------------------------------

resolveSignature ::
  Set QName -> Map QName Type -> FilePath -> Signature -> ([TypeError], ResolvedSignature)
resolveSignature known aliasMap path (Signature ins outs imps) =
  (ie <> oe, ResolvedSignature ins' outs' imps)
  where
    (ie, ins') = resolveFields ins
    (oe, outs') = resolveFields outs
    resolveFields fs =
      let rs = [(n, resolveSigTypeExpr known aliasMap path (Pos 1 1) t) | (n, t) <- fs]
          errs = concat [e | (_, Left e) <- rs]
          ok = [(n, fromRight TyJson r) | (n, r) <- rs]
       in (errs, ok)

-- Imports and entrypoint -----------------------------------------------------

-- | Every import must resolve to a builtin or a declared workflow/tool.
importErrors :: Map QName Declaration -> (QName, Declaration) -> [TypeError]
importErrors decls (q, d) =
  [ typeError
      (declPath q)
      (Pos 1 1)
      UnknownImport
      ("imported name '" <> renderQName imp <> "' does not resolve to a workflow, tool, or builtin")
  | imp <- sigImports (declSignature d),
    not (isBuiltin imp || isCallableDecl (Map.lookup imp decls))
  ]

entrypointError :: Map QName Declaration -> ProjectManifest -> [TypeError]
entrypointError decls manifest =
  case Map.lookup entry decls of
    Just (DeclWorkflow _) -> []
    _ ->
      [ typeError
          "project.json"
          (Pos 1 1)
          BadEntrypoint
          ("entrypoint '" <> manifest.entrypoint <> "' does not name a declared workflow")
      ]
  where
    entry = qnameFromText manifest.entrypoint

-- Command-execution policy (§6.3, §7.5, A24) --------------------------------

-- | Reject every @builtin/exec@ call not permitted by the @exec@ policy: no
-- policy declared, an empty @allow@ list, or a /literal/ @program@ absent from
-- @allow@. A dynamic (non-literal) program passes the static check and is
-- enforced against the allowlist at runtime (§7.5).
execErrors :: ProjectManifest -> (QName, Declaration) -> [TypeError]
execErrors manifest (q, d) =
  concatMap checkStep (execSteps d)
  where
    checkStep s =
      let pos = spanStart (maybe (stepSpan s) argSpan (lookupArg "program" s))
       in case manifest.execPolicy of
            Nothing ->
              [ err pos "builtin/exec is disabled: project.json declares no 'exec' policy (§7.5)"
              ]
            Just policy
              | null (execAllow policy) ->
                  [err pos "builtin/exec is disabled: project.json 'exec.allow' is empty (§7.5)"]
              | otherwise -> case lookupArg "program" s of
                  Just (Arg _ (EString [SLit prog]) _)
                    | prog `notElem` execAllow policy ->
                        [ err
                            pos
                            ( "program '"
                                <> prog
                                <> "' is not in project.json 'exec.allow' (§7.5, A24)"
                            )
                        ]
                  _ -> []
    err pos = typeError (declPath q) pos ExecPolicyViolation
    lookupArg name s = lookup name [(argName a, a) | a <- stepArgs s]

-- | The @builtin/exec@ steps of a declaration's body, including those nested
-- inside control-flow blocks (§13), so the fail-closed policy check (§7.5)
-- cannot be bypassed by placing an @exec@ call inside an @if@\/@foreach@\/@par@.
execSteps :: Declaration -> [StepStmt]
execSteps d = [s | s <- allStepStmts (declStatements d), stepTarget s == execQName]

-- | Every step call in a statement list, recursing through control-flow blocks.
allStepStmts :: [Statement] -> [StepStmt]
allStepStmts = concatMap go
  where
    go = \case
      SStep s -> [s]
      SReturn _ _ -> []
      SIf s -> allStepStmts (ifThen s) <> maybe [] allStepStmts (ifElse s)
      SLoop s -> allStepStmts (loopBody s)
      SWhile _ -> []

declStatements :: Declaration -> [Statement]
declStatements = \case
  DeclWorkflow w -> wfStatements w
  DeclTool t -> toolStatements t
  DeclInstruction _ -> []
  _ -> []

-- Context assembly -----------------------------------------------------------

mkCtx :: Map QName Declaration -> Map QName ResolvedSignature -> ProjectManifest -> (QName -> Bool) -> CheckCtx
mkCtx decls sigMap manifest reaches =
  CheckCtx
    { ccCallee = \q -> Map.lookup q calleeMap <|> lookupBuiltin q,
      ccRefType = \q -> Map.lookup q refMap <|> builtinRefType q,
      ccEnvRecord = envRecordType manifest,
      ccReachesIntrospect = reaches
    }
  where
    calleeMap =
      Map.fromList
        [ (q, Callee (rsigInputs s) (rsigOutputs s))
        | (q, d) <- Map.toList decls,
          isCallableDecl (Just d),
          Just s <- [Map.lookup q sigMap]
        ]
    refMap =
      Map.fromList
        [ (q, refTypeFor d (rsigInputs s) (rsigOutputs s))
        | (q, d) <- Map.toList decls,
          Just s <- [Map.lookup q sigMap]
        ]
    refTypeFor d ins outs = case d of
      DeclTool _ -> TyToolRef (TyRecord ins) (TyRecord outs)
      _ -> TyWorkflowRef (TyRecord ins) (TyRecord outs)
    builtinRefType q = case lookupBuiltin q of
      Just c -> Just (TyToolRef (TyRecord (calleeInputs c)) (TyRecord (calleeOutputs c)))
      Nothing -> Nothing

-- | Whether a callee (transitively) reaches @builtin/introspect@ (§6.1.5). The
-- walk carries a visited set so it terminates even before the acyclic-graph
-- invariant is established (this predicate is consulted during body checking,
-- which also runs on a project that has import cycles).
reachesIntrospect :: Map QName Declaration -> QName -> Bool
reachesIntrospect decls = go Set.empty
  where
    go seen q
      | q `Set.member` seen = False
      | otherwise = case Map.lookup q decls of
          Nothing -> False
          Just d ->
            introspectQName `elem` directCallees d
              || any (go (Set.insert q seen)) (projectCallees decls d)

-- | Build the @ctx.env@ record type from the project's @env@ whitelist
-- (§5.7), auto-tagging secret-named variables as @Secret<String>@ (§5.5).
envRecordType :: ProjectManifest -> Type
envRecordType manifest =
  TyRecord [(v, fieldTy v) | v <- manifest.envWhitelist]
  where
    fieldTy v
      | isSecretEnvName v = TySecret TyString
      | otherwise = TyString

-- Helpers --------------------------------------------------------------------

aliasDef :: Declaration -> Maybe (QName, TypeExpr)
aliasDef = \case
  DeclTypeAlias ta -> Just (taName ta, taDefinition ta)
  _ -> Nothing

declSignature :: Declaration -> Signature
declSignature = \case
  DeclWorkflow w -> wfSignature w
  DeclTool t -> toolSignature t
  _ -> emptySignature

isCallableDecl :: Maybe Declaration -> Bool
isCallableDecl = \case
  Just (DeclWorkflow _) -> True
  Just (DeclTool _) -> True
  _ -> False

stepTargetOf :: StepStmt -> QName
stepTargetOf = stepTarget

declPath :: QName -> FilePath
declPath q = T.unpack (renderQName q) <> ".md"
