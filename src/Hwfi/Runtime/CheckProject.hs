-- | @builtin/check-project@ — parse and type-check a workspace project,
-- returning structured metadata for semantic review workflows (§13.1.8).
module Hwfi.Runtime.CheckProject
  ( runCheckProject,
  )
where

import Control.Exception (IOException, try)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.Key qualified as K
import Data.List (nub, sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Vector qualified as V
import Hwfi.Ast.Expr (Accessor (..), Expr (..), RefPath (..), StringPart (..))
import Hwfi.Ast.Name (Ident, QName, Slug, renderQName, renderSlug)
import Hwfi.Ast.Project (Declaration (..), Project (..), Prompt (..))
import Hwfi.Ast.Step
  ( Arg (..),
    IfStmt (..),
    LoopStmt (..),
    Statement (..),
    StepStmt (..),
    TryStmt (..),
    WhileBody (..),
    WhileStmt (..),
  )
import Hwfi.Ast.Tool (Tool (..))
import Hwfi.Ast.Workflow (Section (..), Workflow (..))
import Hwfi.Check
  ( checkProjectWithMeta,
    projectPhaseOne,
    renderCheckErrors,
    renderCheckWarnings,
  )
import Hwfi.Check.Builtins (llmAgentObjectQName, llmAgentQName)
import Hwfi.Check.Graph (directCallees)
import Hwfi.Parse.Project (loadProject)
import Hwfi.Runtime.Error (RuntimeError, evalError)
import Hwfi.Runtime.Value (RValue (..))
import Hwfi.Runtime.Workspace (Workspace, resolveContainedPath)
import Hwfi.SkillCatalog (isSkillQName)
import Hwfi.Source (Diagnostic (..), renderDiagnostic)
import Hwfi.Type (Type (..), renderType)
import Hwfi.TypedProject (ResolvedSignature (..))
import System.FilePath ((</>))

runCheckProject :: Workspace -> Map Ident RValue -> IO (Either RuntimeError RValue)
runCheckProject ws args =
  case Map.lookup "path" args >>= fileRefText of
    Nothing ->
      pure (Left (evalError "builtin/check-project requires path: FileRef"))
    Just pathText ->
      resolveContainedPath ws pathText >>= \case
        Left err -> pure (Left err)
        Right projectDir ->
          loadProject projectDir >>= \case
            Left ds -> do
              msgs <- mapM (renderDiag projectDir) ds
              pure (Right (failureResult msgs [] []))
            Right proj -> do
              let (checkErrs, checkWarns, _mtp) = checkProjectWithMeta proj
                  (_, sigMap) = projectPhaseOne proj
                  decls = buildDeclarations proj sigMap
                  graph = buildCallGraph proj
                  ok = null checkErrs
                  summary =
                    if ok
                      then ""
                      else T.pack (show (length checkErrs)) <> " type error(s)"
              errMsgs <- mapM (renderDiag projectDir) (renderCheckErrors checkErrs)
              warnMsgs <- mapM (renderDiag projectDir) (renderCheckWarnings checkWarns)
              pure
                ( Right
                    ( record
                        [ ("ok", VBool ok),
                          ("errors", VList (map VString errMsgs)),
                          ("warnings", VList (map VString warnMsgs)),
                          ("declarations", VList decls),
                          ("call_graph", VJson graph),
                          ("error", VString summary)
                        ]
                    )
                )
  where
    fileRefText (VFileRef t) = Just t
    fileRefText (VString t) = Just t
    fileRefText _ = Nothing

failureResult :: [Text] -> [Text] -> [RValue] -> RValue
failureResult errs warns decls =
  record
    [ ("ok", VBool False),
      ("errors", VList (map VString errs)),
      ("warnings", VList (map VString warnMsgs)),
      ("declarations", VList decls),
      ("call_graph", VJson (object [])),
      ("error", VString (if null errs then "parse failed" else head errs))
    ]
  where
    warnMsgs = warns

buildDeclarations :: Project -> Map QName ResolvedSignature -> [RValue]
buildDeclarations proj sigMap =
  map (\(q, d) -> declSummary q d (Map.lookup q sigMap)) $
    sortOn (renderQName . fst) (Map.toList (projDecls proj))

declSummary :: QName -> Declaration -> Maybe ResolvedSignature -> RValue
declSummary q d mSig =
  record
    [ ("qname", VString (renderQName q)),
      ("kind", VString (declKindText d)),
      ("path", VString (T.pack (declPath q))),
      ("inputs", VJson (sigFieldsJson (maybe [] rsigInputs mSig))),
      ("outputs", VJson (sigFieldsJson (maybe [] rsigOutputs mSig))),
      ("imports", VList (map (VString . renderQName) (maybe [] rsigImports mSig))),
      ("agent_sections", VList (map (VString . renderSlug) (agentSections d))),
      ("steps", VList (map stepSummary (collectSteps d)))
    ]

declKindText :: Declaration -> Text
declKindText = \case
  DeclWorkflow _ -> "workflow"
  DeclTool t
    | isSkillQName (toolName t) -> "skill-callable"
    | otherwise -> "tool"
  DeclInstruction _ -> "skill-instruction"
  DeclTypeAlias _ -> "type"
  DeclPrompt _ -> "prompt"

agentSections :: Declaration -> [Slug]
agentSections = \case
  DeclWorkflow w -> map secSlug (wfSections w)
  DeclPrompt p -> map secSlug (promptSections p)
  _ -> []

collectSteps :: Declaration -> [StepStmt]
collectSteps = concatMap stepStmts . declStatements

declStatements :: Declaration -> [Statement]
declStatements = \case
  DeclWorkflow w -> wfStatements w
  DeclTool t -> toolStatements t
  _ -> []

stepStmts :: Statement -> [StepStmt]
stepStmts = \case
  SStep s -> [s]
  SReturn _ _ -> []
  SIf s -> concatMap stepStmts (ifThen s) <> maybe [] (concatMap stepStmts) (ifElse s)
  SLoop s -> concatMap stepStmts (loopBody s)
  SWhile s -> whileBodySteps (whileBody s)
  STry s -> concatMap stepStmts (tryTry s) <> concatMap stepStmts (tryCatch s)

whileBodySteps :: WhileBody -> [StepStmt]
whileBodySteps = \case
  WhileBodyCallee _ _ -> []
  WhileBodyInline stmts -> concatMap stepStmts stmts

stepSummary :: StepStmt -> RValue
stepSummary s =
  record
    [ ("step_id", VString (stepId s)),
      ("target", VString (renderQName (stepTarget s))),
      ("agent_tools", VList (map (VString . renderQName) (agentTools s))),
      ("interpolations", VList (map refPathText (stepInterpolations s))),
      ("bare_qnames", VList (map (VString . renderQName) (stepBareQnames s)))
    ]

agentTools :: StepStmt -> [QName]
agentTools s
  | stepTarget s == llmAgentQName || stepTarget s == llmAgentObjectQName =
      nub
        [ q
          | Arg {argName = name, argValue = e} <- stepArgs s,
            name == "tools",
            Just elems <- [staticExprList e],
            EQName q <- elems
        ]
  | otherwise = []

staticExprList :: Expr -> Maybe [Expr]
staticExprList (EList es) = Just es
staticExprList _ = Nothing

stepInterpolations :: StepStmt -> [RefPath]
stepInterpolations s =
  nub (concatMap (exprRefPaths . argValue) (stepArgs s))

exprRefPaths :: Expr -> [RefPath]
exprRefPaths = \case
  EString parts -> [rp | SInterp rp <- parts]
  ERef rp -> [rp]
  EList es -> concatMap exprRefPaths es
  ERecord fs -> concatMap (exprRefPaths . snd) fs
  ERange e -> exprRefPaths e
  _ -> []

stepBareQnames :: StepStmt -> [QName]
stepBareQnames s =
  nub [q | Arg {argValue = e} <- stepArgs s, q <- bareQnamesInExpr e]

bareQnamesInExpr :: Expr -> [QName]
bareQnamesInExpr = \case
  EQName q -> [q]
  EList es -> concatMap bareQnamesInExpr es
  ERecord fs -> concatMap (bareQnamesInExpr . snd) fs
  ERange e -> bareQnamesInExpr e
  EString _ -> []
  _ -> []

refPathText :: RefPath -> RValue
refPathText rp = VString (renderRefPath rp)

renderRefPath :: RefPath -> Text
renderRefPath (RefPath root accs) = root <> T.concat (map renderAccessor accs)

renderAccessor :: Accessor -> Text
renderAccessor = \case
  AField f -> "." <> f
  AIndex i -> "[" <> T.pack (show i) <> "]"

sigFieldsJson :: [(Ident, Type)] -> Value
sigFieldsJson fs =
  object [K.fromText n .= String (renderType t) | (n, t) <- fs]

buildCallGraph :: Project -> Value
buildCallGraph proj =
  object
    [ "nodes" .= Array (V.fromList (map (String . renderQName) nodes)),
      "edges" .= Array (V.fromList edges)
    ]
  where
    decls = Map.toList (projDecls proj)
    nodes = sortOn id (map fst decls)
    edges =
      [ object ["from" .= String (renderQName q), "to" .= String (renderQName c)]
        | (q, d) <- decls,
          c <- directCallees d
      ]

declPath :: QName -> FilePath
declPath q = T.unpack (renderQName q) <> ".md"

renderDiag :: FilePath -> Diagnostic -> IO Text
renderDiag projectDir d = do
  src <- readFileOrEmpty (projectDir </> diagPath d)
  pure (renderDiagnostic src d)

readFileOrEmpty :: FilePath -> IO Text
readFileOrEmpty path = do
  result <- try (TIO.readFile path) :: IO (Either IOException Text)
  pure (either (const "") id result)

record :: [(Ident, RValue)] -> RValue
record = VRecord . Map.fromList
