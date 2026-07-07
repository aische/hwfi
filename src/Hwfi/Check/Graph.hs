-- | The direct call graph: import-cycle detection (spec §5.6.6, §12, A2) and
-- Merkle declaration fingerprints (spec §8.1, A13).
--
-- A declaration's /direct callees/ are the multi-segment qnames it statically
-- calls in its step blocks. Bare single-segment targets are first-class
-- @ToolRef@/@WorkflowRef@ /values/ resolved at runtime, not static callees,
-- so they do not participate in the call graph or fingerprint recursion.
module Hwfi.Check.Graph
  ( directCallees,
    projectCallees,
    detectImportCycles,
    computeFingerprints,
    lookupCalleeFingerprint,
    builtinFingerprint,
  )
where

import Crypto.Hash (Digest, SHA256, hash)
import Data.Graph (SCC (..), stronglyConnComp)
import Data.List (nub, sort, sortOn)
import Data.Map.Lazy qualified as MapL
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (encodeUtf8)
import Hwfi.Ast.Expr (Accessor (..), Expr (..), RefPath (..), StringPart (..))
import Hwfi.Ast.Name (QName, isBareQName, renderQName, renderSlug)
import Hwfi.Ast.Project (Declaration (..))
import Hwfi.Ast.Step
  ( Arg (..),
    Binder (..),
    IfStmt (..),
    LoopKind (..),
    LoopStmt (..),
    Statement (..),
    StepStmt (..),
  )
import Hwfi.Ast.Tool (Tool (..))
import Hwfi.Ast.Workflow (Workflow (..))
import Hwfi.Check.Builtins (builtinIdentity, isBuiltin)
import Hwfi.Check.Error (TypeError, TypeErrorKind (..), typeError)
import Hwfi.Source (Pos (..))
import Hwfi.TypedProject (Fingerprint (..), ResolvedSignature (..))
import Hwfi.Type (Type, renderType)

-- | The statements of a declaration (empty for aliases and prompts).
declStatements :: Declaration -> [Statement]
declStatements = \case
  DeclWorkflow w -> wfStatements w
  DeclTool t -> toolStatements t
  _ -> []

-- | All multi-segment call targets of a declaration, deduplicated in source
-- order. Includes builtins; excludes bare first-class refs. Recurses into
-- control-flow blocks (§13) so a call inside an @if@\/@foreach@\/@par@ still
-- participates in the call graph and fingerprint recursion.
directCallees :: Declaration -> [QName]
directCallees d =
  nub [t | t <- callTargets (declStatements d), not (isBareQName t)]

-- | Every step call target reachable in a statement list, recursing through
-- control-flow blocks (spec §13).
callTargets :: [Statement] -> [QName]
callTargets = concatMap go
  where
    go = \case
      SStep s -> [stepTarget s]
      SReturn _ _ -> []
      SIf s -> callTargets (ifThen s) <> maybe [] callTargets (ifElse s)
      SLoop s -> callTargets (loopBody s)

-- | The direct callees that resolve to /project/ declarations (used for cycle
-- detection; builtins are always leaves).
projectCallees :: Map QName Declaration -> Declaration -> [QName]
projectCallees decls d = [c | c <- directCallees d, Map.member c decls]

-- Import-cycle detection -----------------------------------------------------

-- | Detect cycles in the direct call graph across project declarations. Each
-- cyclic strongly-connected component (including a self-recursive
-- declaration) yields one error.
detectImportCycles :: Map QName Declaration -> [TypeError]
detectImportCycles decls =
  [cycleError vs | CyclicSCC vs <- stronglyConnComp nodes]
  where
    nodes = [(q, q, projectCallees decls d) | (q, d) <- Map.toList decls]
    cycleError vs =
      typeError
        (declPath (head vs))
        (Pos 1 1)
        ImportCycle
        ("import cycle in the call graph: " <> T.intercalate " -> " (map renderQName (vs <> [head vs])))

-- Fingerprints ---------------------------------------------------------------

-- | Compute a fingerprint for every project declaration (spec §8.1). Requires
-- the call graph to be acyclic (guaranteed by 'detectImportCycles' passing);
-- the returned map is defined lazily and self-referentially over the acyclic
-- graph.
computeFingerprints ::
  Map QName Declaration ->
  Map QName ResolvedSignature ->
  Map QName Fingerprint
computeFingerprints decls sigs = fps
  where
    -- Built with the lazy 'mapWithKey': 'Fingerprint' is a newtype, so
    -- forcing a value to WHNF forces its hash (and thus its callee lookups
    -- into 'fps'). Strict construction would demand a callee's fingerprint
    -- while 'fps' is still being built, looping. Lazy values let the
    -- self-referential knot resolve over the acyclic graph on demand.
    fps = MapL.mapWithKey fingerprintOf decls

    fingerprintOf q d =
      Fingerprint (sha256Hex payload)
      where
        sig = Map.lookup q sigs
        calleeHashes =
          sort [unFingerprint (resolveCallee c) | c <- directCallees d]
        payload =
          encodeDecl sig (declStatements d)
            <> "\n#callees\n"
            <> T.intercalate "," calleeHashes

    resolveCallee c =
      case Map.lookup c fps of
        Just fp -> fp
        Nothing
          | isBuiltin c -> builtinFingerprint c
          | otherwise -> Fingerprint (sha256Hex ("unresolved:" <> renderQName c))

unFingerprint :: Fingerprint -> Text
unFingerprint (Fingerprint t) = t

-- | The fixed fingerprint of a builtin tool (§8.1), derived from the engine
-- version and the builtin's signature.
builtinFingerprint :: QName -> Fingerprint
builtinFingerprint q =
  Fingerprint (sha256Hex (fromMaybe (renderQName q) (builtinIdentity q)))

-- | Resolve the fingerprint of a step's call target for step-key hashing
-- (M5). Returns 'Nothing' for a bare first-class ref target, whose
-- fingerprint is only known at runtime.
lookupCalleeFingerprint :: Map QName Fingerprint -> QName -> Maybe Fingerprint
lookupCalleeFingerprint fps q
  | isBareQName q = Nothing
  | Just fp <- Map.lookup q fps = Just fp
  | isBuiltin q = Just (builtinFingerprint q)
  | otherwise = Nothing

-- Canonical AST encoding -----------------------------------------------------

-- | Encode a declaration's normalized AST (spec §8.1): the typed signature
-- (inputs/outputs, sorted) plus its statements with source positions,
-- comments, and whitespace stripped. Imports are excluded deliberately: they
-- do not affect behaviour beyond the calls they enable, and those calls are
-- already captured both as statements and via callee fingerprints.
encodeDecl :: Maybe ResolvedSignature -> [Statement] -> Text
encodeDecl msig stmts =
  "#sig\n" <> sigPart <> "\n#body\n" <> T.intercalate "\n" (map encodeStmt stmts)
  where
    sigPart = case msig of
      Nothing -> ""
      Just s ->
        "in:" <> encodeFields (rsigInputs s) <> ";out:" <> encodeFields (rsigOutputs s)
    encodeFields :: [(Text, Type)] -> Text
    encodeFields fs =
      T.intercalate "," [n <> ":" <> renderType t | (n, t) <- sortOn fst fs]

encodeStmt :: Statement -> Text
encodeStmt = \case
  SStep s ->
    "step "
      <> encodeBinder (stepBinder s)
      <> " @"
      <> stepId s
      <> " <- "
      <> renderQName (stepTarget s)
      <> "("
      <> encodeArgs (stepArgs s)
      <> ")"
  SReturn args _ -> "return{" <> encodeArgs args <> "}"
  SIf s ->
    "if "
      <> encodeBinder (ifBinder s)
      <> " @"
      <> ifId s
      <> " cond="
      <> encodeExpr (ifCond s)
      <> " then{"
      <> encodeStmts (ifThen s)
      <> "}"
      <> maybe "" (\b -> " else{" <> encodeStmts b <> "}") (ifElse s)
  SLoop s ->
    "loop:"
      <> encodeLoopKind (loopKind s)
      <> " "
      <> encodeBinder (loopBinder s)
      <> " @"
      <> loopId s
      <> " var="
      <> loopVar s
      <> " in="
      <> encodeExpr (loopList s)
      <> " body{"
      <> encodeStmts (loopBody s)
      <> "}"

encodeStmts :: [Statement] -> Text
encodeStmts = T.intercalate ";" . map encodeStmt

encodeLoopKind :: LoopKind -> Text
encodeLoopKind = \case
  LoopSeq -> "seq"
  LoopPar Nothing -> "par"
  LoopPar (Just n) -> "par(" <> T.pack (show n) <> ")"

encodeBinder :: Binder -> Text
encodeBinder = \case
  BindName n -> n
  BindDiscard -> "_"

-- | Encode arguments in canonical (name-sorted) order: named arguments are
-- order-insensitive, so sorting yields a stable form.
encodeArgs :: [Arg] -> Text
encodeArgs args =
  T.intercalate "," [argName a <> "=" <> encodeExpr (argValue a) | a <- sortOn argName args]

encodeExpr :: Expr -> Text
encodeExpr = \case
  EString parts -> "str[" <> T.concat (map encodePart parts) <> "]"
  EInt n -> "int:" <> T.pack (show n)
  EDouble d -> "dbl:" <> T.pack (show d)
  EBool b -> "bool:" <> (if b then "true" else "false")
  ENull -> "null"
  ERef rp -> "ref:" <> encodeRefPath rp
  EList es -> "list[" <> T.intercalate "," (map encodeExpr es) <> "]"
  ERecord fs -> "rec{" <> T.intercalate "," [n <> "=" <> encodeExpr e | (n, e) <- sortOn fst fs] <> "}"
  ESelf slug -> "self:" <> renderSlug slug
  EQName q -> "qn:" <> renderQName q

encodePart :: StringPart -> Text
encodePart = \case
  SLit t -> "L(" <> t <> ")"
  SInterp rp -> "I(" <> encodeRefPath rp <> ")"

encodeRefPath :: RefPath -> Text
encodeRefPath (RefPath root accs) = root <> T.concat (map encodeAccessor accs)

encodeAccessor :: Accessor -> Text
encodeAccessor = \case
  AField f -> "." <> f
  AIndex i -> "[" <> T.pack (show i) <> "]"

-- Hashing --------------------------------------------------------------------

sha256Hex :: Text -> Text
sha256Hex t = T.pack (show digest)
  where
    digest = hash (encodeUtf8 t) :: Digest SHA256

declPath :: QName -> FilePath
declPath q = T.unpack (renderQName q) <> ".md"
