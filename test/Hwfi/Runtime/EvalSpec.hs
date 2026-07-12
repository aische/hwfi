module Hwfi.Runtime.EvalSpec (spec) where

import Data.Either (isLeft)
import Data.Map.Strict qualified as Map
import Hwfi.Ast.Expr (Accessor (..), Expr (..), RefPath (..), StringPart (..))
import Hwfi.Ast.Name (Slug (..))
import Hwfi.Ast.Workflow (Section (..))
import Hwfi.Runtime.Eval
import Hwfi.Runtime.Value (RValue (..))
import Test.Hspec

env :: EvalEnv
env =
  EvalEnv
    { eeBindings =
        Map.fromList
          [ ("inputs", VRecord (Map.fromList [("name", VString "Ada")])),
            ("xs", VList [VInt 10, VInt 20]),
            ("rec", VRecord (Map.fromList [("k", VString "v")]))
          ],
      eeSections =
        [Section (Slug "system") 2 "system" "You are helpful."],
      eeRefKind = const Nothing
    }

ref :: [Accessor] -> Expr
ref = ERef . RefPath "inputs"

spec :: Spec
spec = describe "Runtime expression evaluator (§5.3, §3.2.1, §8.3.2)" $ do
  it "resolves a bare reference to its exact value" $
    evalExpr env (ref [AField "name"]) `shouldBe` Right (VString "Ada")

  it "renders an interpolated reference into a string" $
    evalExpr env (EString [SLit "Hi ", SInterp (RefPath "inputs" [AField "name"])])
      `shouldBe` Right (VString "Hi Ada")

  it "indexes a list" $
    evalExpr env (ERef (RefPath "xs" [AIndex 1])) `shouldBe` Right (VInt 20)

  it "raises an eval error on list index out of bounds (§8.3.2)" $
    evalExpr env (ERef (RefPath "xs" [AIndex 5])) `shouldSatisfy` isLeft

  it "raises an eval error on a missing record field" $
    evalExpr env (ERef (RefPath "rec" [AField "nope"])) `shouldSatisfy` isLeft

  it "resolves @self#slug to the section's raw content" $
    evalExpr env (ESelf (Slug "system")) `shouldBe` Right (VString "You are helpful.")

  it "builds record and list literals" $
    evalExpr env (ERecord [("a", EInt 1)]) `shouldBe` Right (VRecord (Map.fromList [("a", VInt 1)]))

  it "evaluates range(n) to [0..n-1] (§13.1.3)" $ do
    evalExpr env (ERange (EInt 3)) `shouldBe` Right (VList [VInt 0, VInt 1, VInt 2])
    evalExpr env (ERange (EInt 0)) `shouldBe` Right (VList [])
    evalExpr env (ERange (EInt (-1))) `shouldSatisfy` isLeft
