-- | Dynamic workflow evaluation for @builtin/eval-workflow@ (spec §6.4).
--
-- Parses runtime-synthesized markdown, merges it into the enclosing checked
-- project, type-checks the synthetic project, coerces inputs, and executes the
-- dynamic workflow through the normal executor. Parse, type-check, and input
-- coercion failures return @{ ok = false, errors = [...] }@ without aborting
-- the enclosing run; runtime errors during execution of a checked workflow
-- propagate as fatal failures (§6.4.3).
module Hwfi.Runtime.EvalWorkflow
  ( EvalWorkflowSeam (..),
    runEvalWorkflow,
  )
where

import Data.Aeson (Value (..))
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Hwfi.Ast.Name (Ident, QName, renderQName)
import Hwfi.Ast.Project (Declaration (..), Project (..), declQName)
import Hwfi.Check (checkProject, renderCheckErrors)
import Hwfi.Check.Error (TypeError (..))
import Hwfi.Parse.Project (evalWorkflowDiagPath, parseEvalWorkflowSource)
import Hwfi.Runtime.Error (RuntimeError)
import Hwfi.Runtime.Value (RValue (..), coerceFromJson, valueToJson)
import Hwfi.Source (Diagnostic (..), Pos (..), renderDiagnostic)
import Hwfi.TypedProject (ResolvedSignature (..), TypedDecl (..), TypedProject (..), lookupTyped)

-- | Effectful seam for executing a checked dynamic workflow without importing
-- the executor module (avoids a cycle).
data EvalWorkflowSeam = EvalWorkflowSeam
  { ewsProject :: TypedProject,
    ewsScope :: Text,
    ewsExecute ::
      TypedProject ->
      Text ->
      QName ->
      Map Ident RValue ->
      IO (Either RuntimeError RValue)
  }

-- | Parse, check, and optionally execute dynamically synthesized workflow
-- source. Returns 'Right' with the @{ ok, outputs, errors }@ record for
-- recoverable failures; 'Left' only when a checked workflow aborts at runtime.
runEvalWorkflow :: EvalWorkflowSeam -> Text -> Value -> IO (Either RuntimeError RValue)
runEvalWorkflow seam source inputsJson =
  case parseEvalWorkflowSource source of
    Left ds ->
      pure (Right (failureResult (map (renderDiagnostic source) ds)))
    Right dynDecl ->
      case dynDecl of
        DeclWorkflow _ -> go dynDecl
        _ ->
          pure
            ( Right
                ( failureResult
                    [ renderDiagnostic source (mkDiag "eval-workflow source must be a workflow declaration")
                    ]
                )
            )
  where
    go dynDecl = do
      let dynQ = declQName dynDecl
          parentTp = ewsProject seam
          parentDecls = Map.map tdDeclaration (tpDecls parentTp)
      if Map.member dynQ parentDecls
        then
          pure
            ( Right
                ( failureResult
                    [ T.pack evalWorkflowDiagPath
                        <> ":1:1: name '"
                        <> renderQName dynQ
                        <> "' collides with an existing project declaration (§6.4.2)"
                    ]
                )
            )
        else do
          let synthetic =
                Project
                  { projManifest = tpManifest parentTp,
                    projDecls = Map.insert dynQ dynDecl parentDecls
                  }
          case checkProject synthetic of
            Left errs ->
              pure (Right (failureResult (map (formatTypeError source dynQ) errs)))
            Right mergedTp -> case coerceWorkflowInputs mergedTp dynQ inputsJson of
              Left msg ->
                pure
                  ( Right
                      ( failureResult
                          [ T.pack evalWorkflowDiagPath <> ":1:1: " <> msg
                          ]
                      )
                  )
              Right inputMap -> do
                result <-
                  ewsExecute seam mergedTp (ewsScope seam) dynQ inputMap
                case result of
                  Left err -> pure (Left err)
                  Right outputs ->
                    pure
                      ( Right
                          ( record
                              [ ("ok", VBool True),
                                ("outputs", VJson (valueToJson outputs)),
                                ("errors", VList [])
                              ]
                          )
                      )

coerceWorkflowInputs :: TypedProject -> QName -> Value -> Either Text (Map Ident RValue)
coerceWorkflowInputs tp q v = case lookupTyped q tp of
  Nothing -> Left ("dynamic workflow '" <> renderQName q <> "' not found after check")
  Just td ->
    let ins = rsigInputs (tdSignature td)
     in case v of
          Object o -> Map.fromList <$> traverse (field o) ins
          Null
            | null ins -> Right Map.empty
            | otherwise -> Left "inputs must be a JSON object"
          _ -> Left "inputs must be a JSON object"
  where
    field o (n, ty) = case KM.lookup (K.fromText n) o of
      Just fv -> (,) n <$> coerceFromJson ty fv
      Nothing -> Left ("missing input '" <> n <> "'")

formatTypeError :: Text -> QName -> TypeError -> Text
formatTypeError source dynQ err =
  renderDiagnostic source (remapDynamicDiag dynQ (head (renderCheckErrors [err])))
  where
    remapDynamicDiag q Diagnostic {..}
      | diagPath == dynDeclPath q = Diagnostic evalWorkflowDiagPath diagPos diagWidth diagMessage
      | otherwise = Diagnostic {..}

dynDeclPath :: QName -> FilePath
dynDeclPath q = T.unpack (renderQName q <> ".md")

failureResult :: [Text] -> RValue
failureResult msgs =
  record
    [ ("ok", VBool False),
      ("outputs", VJson (Object KM.empty)),
      ("errors", VList (map VString msgs))
    ]

record :: [(Ident, RValue)] -> RValue
record = VRecord . Map.fromList

mkDiag :: Text -> Diagnostic
mkDiag msg = Diagnostic evalWorkflowDiagPath (Pos 1 1) 1 msg
