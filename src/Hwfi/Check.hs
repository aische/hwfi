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
  )
where

import Control.Applicative ((<|>))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Set (Set)
import Data.Text qualified as T
import Hwfi.Ast.Name (QName, qnameFromText, renderQName)
import Hwfi.Ast.Project
import Hwfi.Ast.Step (StepStmt, stepTarget)
import Hwfi.Ast.Tool (Tool (..))
import Hwfi.Ast.TypeAlias (TypeAlias (..))
import Hwfi.Ast.Type (TypeExpr)
import Hwfi.Ast.Workflow (Signature (..), Workflow (..), emptySignature)
import Hwfi.Check.Alias (resolveAliasDefs, resolveSigTypeExpr)
import Hwfi.Check.Builtins (Callee (..), isBuiltin, lookupBuiltin)
import Hwfi.Check.Decl (CheckCtx (..), checkDeclBody)
import Hwfi.Check.Error (TypeError, TypeErrorKind (..), renderTypeErrors, typeError)
import Hwfi.Check.Graph (computeFingerprints, detectImportCycles, lookupCalleeFingerprint)
import Hwfi.Project.Manifest (ProjectManifest (..))
import Hwfi.Source (Diagnostic, Pos (..))
import Hwfi.TypedProject
import Hwfi.Type (Type (..), isSecretEnvName)

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
    ctx = mkCtx decls sigMap manifest
    bodyResults =
      [ (q, checkDeclBody ctx q d (sigLookup q))
      | (q, d) <- Map.toList decls
      ]
    bodyErrs = concat [e | (_, (e, _)) <- bodyResults]
    stepMap = Map.fromList [(q, steps) | (q, (_, steps)) <- bodyResults]

    allErrs = aliasErrs <> sigErrs <> importErrs <> cycleErrs <> entrypointErrs <> bodyErrs

    -- Phase 4 (success only): fingerprints and assembly.
    fps = computeFingerprints decls sigMap
    typed =
      TypedProject
        { tpManifest = manifest,
          tpDecls = Map.mapWithKey mkTypedDecl decls,
          tpAliases = aliasMap
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
          ok = [(n, either (const TyJson) id r) | (n, r) <- rs]
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

-- Context assembly -----------------------------------------------------------

mkCtx :: Map QName Declaration -> Map QName ResolvedSignature -> ProjectManifest -> CheckCtx
mkCtx decls sigMap manifest =
  CheckCtx
    { ccCallee = \q -> Map.lookup q calleeMap <|> lookupBuiltin q,
      ccRefType = \q -> Map.lookup q refMap <|> builtinRefType q,
      ccEnvRecord = envRecordType manifest
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
