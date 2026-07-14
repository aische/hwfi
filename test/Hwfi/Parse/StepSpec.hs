module Hwfi.Parse.StepSpec (spec) where

import Data.Text (Text)
import Data.Text qualified as T
import Hwfi.Ast.Expr (Accessor (..), Expr (..), RefPath (..))
import Hwfi.Ast.Name (qnameFromText)
import Hwfi.Ast.Step
import Hwfi.Parse.Step (parseStepBlock)
import Hwfi.Source (Pos (..), spanStart)
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

  it "parses an if/else with a default id from the binder (§13)" $ do
    let src = T.unlines ["x <- if ${c} {", "  a <- foo/bar()", "} else {", "  b <- baz/qux()", "}"]
    case parseB (Pos 1 1) src of
      Right [SIf s] -> do
        ifBinder s `shouldBe` BindName "x"
        ifId s `shouldBe` "x"
        ifCond s `shouldBe` ERef (RefPath "c" [])
        length (ifThen s) `shouldBe` 1
        fmap length (ifElse s) `shouldBe` Just 1
      other -> expectationFailure ("unexpected: " <> show other)

  it "parses an if with no else branch" $ do
    let src = T.unlines ["_ <- if ${c} {", "  a <- foo/bar()", "} @guard"]
    case parseB (Pos 1 1) src of
      Right [SIf s] -> do
        ifBinder s `shouldBe` BindDiscard
        ifId s `shouldBe` "guard"
        ifElse s `shouldBe` Nothing
      other -> expectationFailure ("unexpected: " <> show other)

  it "parses a foreach loop binding the element variable (§13)" $ do
    let src = T.unlines ["rs <- foreach item in ${inputs.xs} {", "  r <- proc/one(v = ${item})", "}"]
    case parseB (Pos 1 1) src of
      Right [SLoop s] -> do
        loopKind s `shouldBe` LoopSeq
        loopVar s `shouldBe` "item"
        loopList s `shouldBe` ERef (RefPath "inputs" [AField "xs"])
        loopId s `shouldBe` "rs"
      other -> expectationFailure ("unexpected: " <> show other)

  it "parses a par loop with an explicit concurrency bound (§13)" $ do
    let src = T.unlines ["rs <- par(max = 4) item in ${inputs.xs} {", "  r <- proc/one(v = ${item})", "} @fan"]
    case parseB (Pos 1 1) src of
      Right [SLoop s] -> do
        loopKind s `shouldBe` LoopPar (ParOpts (Just 4) ParOnErrorFail)
        loopId s `shouldBe` "fan"
      other -> expectationFailure ("unexpected: " <> show other)

  it "parses par(on_error = \"collect\") (§4.1.1)" $ do
    let src =
          T.unlines
            ["rs <- par(on_error = \"collect\") item in ${inputs.xs} {", "  r <- proc/one(v = ${item})", "} @fan"]
    case parseB (Pos 1 1) src of
      Right [SLoop s] ->
        loopKind s `shouldBe` LoopPar (ParOpts Nothing ParOnErrorCollect)
      other -> expectationFailure ("unexpected: " <> show other)

  it "parses try/catch (§4.4)" $ do
    let src =
          T.unlines
            [ "x <- try {",
              "  a <- foo/bar()",
              "} catch {",
              "  b <- baz/qux()",
              "} @safe"
            ]
    case parseB (Pos 1 1) src of
      Right [STry s] -> do
        tryBinder s `shouldBe` BindName "x"
        tryId s `shouldBe` "safe"
        length (tryTry s) `shouldBe` 1
        length (tryCatch s) `shouldBe` 1
      other -> expectationFailure ("unexpected: " <> show other)

  it "requires an explicit @id for a discarding control-flow statement" $
    parseB (Pos 1 1) (T.unlines ["_ <- foreach x in ${xs} {", "  a <- foo/bar()", "}"]) `shouldSatisfy` isLeft

  it "parses nested foreach loops (inner loop as a bound rhs)" $ do
    let src =
          T.unlines
            [ "outer <- foreach x in ${inputs.xs} {",
              "  inner <- foreach y in ${x} {",
              "    r <- foo/bar(v = ${y})",
              "  } @inner",
              "} @outer"
            ]
    case parseB (Pos 1 1) src of
      Right [SLoop outer] -> do
        loopKind outer `shouldBe` LoopSeq
        loopVar outer `shouldBe` "x"
        case loopBody outer of
          [SLoop inner] -> do
            loopVar inner `shouldBe` "y"
            loopId inner `shouldBe` "inner"
          _ -> expectationFailure "expected nested foreach in outer body"
      other -> expectationFailure ("unexpected: " <> show other)

  it "parses a while(predicate, body) loop (§4.3, M9)" $ do
    let src =
          T.unlines
            [ "rs <- while(",
              "  predicate = workflows/pred,",
              "  predicate_args = { stop = false },",
              "  body = workflows/body,",
              "  body_args = {},",
              "  max_iterations = 10",
              ") @loop"
            ]
    case parseB (Pos 1 1) src of
      Right [SWhile s] -> do
        whileBinder s `shouldBe` BindName "rs"
        whileId s `shouldBe` "loop"
        whileMaxIterations s `shouldBe` EInt 10
        length (whilePredicateArgs s) `shouldBe` 1
        case whileBody s of
          WhileBodyCallee _ args -> length args `shouldBe` 0
          _ -> expectationFailure "expected callee body"
      other -> expectationFailure ("unexpected: " <> show other)

  it "parses while with an inline body block (§4.3.7)" $ do
    let src =
          T.unlines
            [ "rs <- while(",
              "  predicate = workflows/pred,",
              "  predicate_args = {},",
              "  body = {",
              "    x <- foo/bar() @step",
              "  },",
              "  max_iterations = 5",
              ") @loop"
            ]
    case parseB (Pos 1 1) src of
      Right [SWhile s] ->
        case whileBody s of
          WhileBodyInline stmts -> length stmts `shouldBe` 1
          _ -> expectationFailure "expected inline body"
      other -> expectationFailure ("unexpected: " <> show other)

  it "rejects body_args with an inline while body (§4.3.7)" $ do
    let src =
          T.unlines
            [ "_ <- while(",
              "  predicate = workflows/pred,",
              "  predicate_args = {},",
              "  body = { x <- foo/bar() @step },",
              "  body_args = {},",
              "  max_iterations = 1",
              ") @loop"
            ]
    parseB (Pos 1 1) src `shouldSatisfy` isLeft
  where
    isLeft = either (const True) (const False)
