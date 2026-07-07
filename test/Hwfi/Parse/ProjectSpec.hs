module Hwfi.Parse.ProjectSpec (spec) where

import Data.Map.Strict qualified as Map
import Hwfi.Ast.Name (qnameFromText)
import Hwfi.Ast.Project
import Hwfi.Ast.Type (TypeExpr (..))
import Hwfi.Ast.TypeAlias (TypeAlias (..))
import Hwfi.Ast.Workflow (Workflow (..))
import Hwfi.Source (Diagnostic (..), Pos (..))
import Hwfi.Parse.Project (loadProject)
import Test.Hspec

spec :: Spec
spec = describe "loadProject (spec §2)" $ do
  it "loads a well-formed project and classifies declarations" $ do
    res <- loadProject "test/fixtures/parse/ok"
    case res of
      Left ds -> expectationFailure (show ds)
      Right proj -> do
        Map.keys (projDecls proj)
          `shouldMatchList` map qnameFromText ["workflows/main", "tools/greet", "types/message"]
        -- workflow: two step calls + one return
        case Map.lookup (qnameFromText "workflows/main") (projDecls proj) of
          Just (DeclWorkflow wf) -> length (wfStatements wf) `shouldBe` 3
          other -> expectationFailure ("expected workflow, got " <> show other)
        -- type alias resolves to a record type
        case Map.lookup (qnameFromText "types/message") (projDecls proj) of
          Just (DeclTypeAlias ta) ->
            taDefinition ta `shouldBe` TRecord [("role", TString), ("content", TString)]
          other -> expectationFailure ("expected type alias, got " <> show other)

  it "reports a step parse error with file and line" $ do
    res <- loadProject "test/fixtures/parse/bad-step"
    case res of
      Right _ -> expectationFailure "expected a parse error"
      Left ds -> do
        ds `shouldSatisfy` (not . null)
        let d = head ds
        diagPath d `shouldBe` "workflows/broken.md"
        posLine (diagPos d) `shouldBe` 12
