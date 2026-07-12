-- | Non-fatal checker hints for common @ToolRef@\/@WorkflowRef@ mistakes (§13.1.6).
--
-- See @docs/workflow-refs.md@ for the patterns these hints point authors toward.
module Hwfi.Check.RefHints
  ( isRefType,
    refArgWarnings,
    bareCallTargetHints,
    toolsListElemHint,
  )
where

import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Hwfi.Ast.Expr (Expr (..), RefPath (..))
import Hwfi.Ast.Name (Ident, QName, isBareQName, qnameSegments, renderQName)
import Hwfi.Ast.Step (Arg (..))
import Hwfi.Check.Builtins (Callee (..))
import Hwfi.Check.Error (CheckWarning, checkWarning)
import Hwfi.Check.Expr (Env (..))
import Hwfi.Source (Pos (..), Span (..), spanStart)
import Hwfi.Type (Type (..), assignable)

-- | Whether a type is a first-class callable reference (§5.1).
isRefType :: Type -> Bool
isRefType = \case
  TyToolRef _ _ -> True
  TyWorkflowRef _ _ -> True
  _ -> False

-- | Warn when a bare qname is passed as an argument value where a step call was
-- likely intended (§13.1.6).
refArgWarnings ::
  (QName -> Maybe Type) ->
  FilePath ->
  Env ->
  Callee ->
  [Arg] ->
  [CheckWarning]
refArgWarnings refType path _env callee args =
  [ w
    | a <- args,
      Just expected <- [lookup (argName a) (calleeInputs callee)],
      not (isRefType expected),
      Just w <- [bareQNameArgHint refType path (spanStart (argSpan a)) expected (argValue a)]
  ]

bareQNameArgHint ::
  (QName -> Maybe Type) ->
  FilePath ->
  Pos ->
  Type ->
  Expr ->
  Maybe CheckWarning
bareQNameArgHint refType path pos expected = \case
  EQName q
    | Just refTy <- refType q,
      not (assignable expected refTy) ->
        Just $
          checkWarning
            path
            pos
            ( "hint: bare name '"
                <> renderQName q
                <> "' is a ToolRef/WorkflowRef value, not a step call — use 'result <- "
                <> renderQName q
                <> "(...)' to invoke it, or pass the ref only where a ToolRef/WorkflowRef parameter is expected (docs/workflow-refs.md)"
            )
  _ -> Nothing

-- | When a bare identifier is used as a step target but is not a bound ref,
-- suggest full qnames for static callees (§13.1.6).
bareCallTargetHints ::
  [QName] ->
  (QName -> Maybe Callee) ->
  FilePath ->
  Pos ->
  QName ->
  Env ->
  [CheckWarning]
bareCallTargetHints qnames resolve path pos target env
  | not (isBareQName target) = []
  | Map.member (bareIdent target) (envRoots env) = []
  | otherwise =
      case qnamesWithSuffix qnames resolve (bareIdent target) of
        [q] ->
          [ checkWarning
              path
              pos
              ( "hint: '"
                  <> bareIdent target
                  <> "' is not a ToolRef/WorkflowRef bind name — did you mean the static step call '"
                  <> renderQName q
                  <> "(...)'? (docs/workflow-refs.md)"
              )
          ]
        qs | length qs > 1 ->
          [ checkWarning
              path
              pos
              ( "hint: '"
                  <> bareIdent target
                  <> "' is ambiguous; declared callees include "
                  <> commas (map renderQName qs)
                  <> ". Use a full qname for static calls"
              )
          ]
        _ -> []

-- | Hint for a non-bare-qname element in a static agent @tools@ list.
toolsListElemHint :: FilePath -> Pos -> Expr -> Maybe CheckWarning
toolsListElemHint path pos = \case
  EQName _ -> Nothing
  ERef (RefPath "inputs" _) ->
    Just $
      checkWarning
        path
        pos
        "hint: a static agent tools list expects bare qnames (tools/search), not ${inputs...}; pass a runtime List<ToolRef | WorkflowRef> expression instead (§6.1.6, docs/workflow-refs.md)"
  ERef _ ->
    Just $
      checkWarning
        path
        pos
        "hint: a static agent tools list expects bare qnames like tools/search, not ${...} references — use bare names here or build the list dynamically (§6.1.6)"
  _ ->
    Just $
      checkWarning
        path
        pos
        "hint: each element of a static agent tools list must be a bare tool/workflow qname (§6.1.1)"

qnamesWithSuffix :: [QName] -> (QName -> Maybe Callee) -> Ident -> [QName]
qnamesWithSuffix qnames resolve ident =
  [ q
  | q <- qnames,
    resolve q /= Nothing,
    case reverse (qnameSegments q) of
      (seg : _) | seg == ident -> True
      _ -> False
  ]

bareIdent :: QName -> Ident
bareIdent q = case qnameSegments q of
  (s : _) -> s
  [] -> ""

commas :: [Text] -> Text
commas [] = ""
commas [x] = x
commas (x : xs) = x <> ", " <> commas xs
