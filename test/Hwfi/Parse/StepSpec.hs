module Hwfi.Parse.StepSpec (spec) where

import Data.Text (Text)
import Data.Text qualified as T
import Hwfi.Ast.Expr (Accessor (..), Expr (..), RefPath (..))
import Hwfi.Ast.Name (qnameFromText)
import Hwfi.Ast.Step
import Hwfi.Source (Pos (..), spanStart)
import Hwfi.Parse.Step (parseStepBlock)
import Test.Hspec

parseB :: Pos -> Text -> Either [String] [Statement]
parseB pos t = either (Left . map show) Right (parseStepBlock "s" pos t)

spec :: Spec
spec = describe "step DSL parser (spec §3.1, §3.4)" $ do
  it "parses binders, targets, default and explicit step ids, and return" $ do
    let src = T.unlines ["a <- foo/bar(x = 1)", "_ <- baz/qux(y = 2) @side", "return { r = ${a} }"]
    case parseB (Pos 1 1) src of
      Left errs -> expectationFailure (unlines errs)
      Right stmts -> do
        length stmts `shouldBe` 3
        case stmts of
          [SStep s1, SStep s2, SReturn fields _] -> do
            stepBinder s1 `shouldBe` BindName "a"
            stepId s1 `shouldBe` "a"
            stepTarget s1 `shouldBe` qnameFromText "foo/bar"
            stepBinder s2 `shouldBe` BindDiscard
            stepId s2 `shouldBe` "side"
            map argName fields `shouldBe` ["r"]
          _ -> expectationFailure "unexpected statement shape"

  it "requires an explicit @id for a discarding step" $
    parseB (Pos 1 1) "_ <- foo/bar(x = 1)" `shouldSatisfy` isLeft

  it "ignores -- line comments and blank lines" $ do
    let src = T.unlines ["a <- foo/bar() -- first", "", "-- a comment line", "b <- baz/qux()"]
    fmap length (parseB (Pos 1 1) src) `shouldBe` Right 2

  it "reports positions absolute to the enclosing file" $ do
    case parseB (Pos 10 1) "a <- foo/bar(x = 1)" of
      Right [SStep s] -> posLine (spanStart (stepSpan s)) `shouldBe` 10
      other -> expectationFailure ("unexpected: " <> show other)

  it "parses argument references" $
    case parseB (Pos 1 1) "a <- foo/bar(x = ${inputs.p})" of
      Right [SStep s] -> map argValue (stepArgs s) `shouldBe` [ERef (RefPath "inputs" [AField "p"])]
      other -> expectationFailure ("unexpected: " <> show other)
  where
    isLeft = either (const True) (const False)
