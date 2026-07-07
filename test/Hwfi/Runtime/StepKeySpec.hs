module Hwfi.Runtime.StepKeySpec (spec) where

import Data.Map.Strict qualified as Map
import Hwfi.Ast.Name (QName, qnameFromText)
import Hwfi.Runtime.StepKey (computeStepKey)
import Hwfi.Runtime.Value (RValue (..), RefKind (..))
import Test.Hspec

noRef :: QName -> Maybe a
noRef _ = Nothing

q :: QName
q = qnameFromText "workflows/main"

-- A baseline cacheable step: read-file with a path argument.
baseKey :: String
baseKey =
  toStr (computeStepKey noRef q "c" (Map.fromList [("path", VString "in.txt")]) [] "fp-readfile")
  where
    toStr = show

spec :: Spec
spec = describe "Step-key hashing (§8.1)" $ do
  it "is deterministic for identical inputs" $
    computeStepKey noRef q "c" args [] "fp"
      `shouldBe` computeStepKey noRef q "c" args [] "fp"

  it "changes when the callee fingerprint changes (A13)" $
    computeStepKey noRef q "c" args [] "fp-1"
      `shouldNotBe` computeStepKey noRef q "c" args [] "fp-2"

  it "changes when a resolved argument changes" $
    computeStepKey noRef q "c" (Map.fromList [("path", VString "a")]) [] "fp"
      `shouldNotBe` computeStepKey noRef q "c" (Map.fromList [("path", VString "b")]) [] "fp"

  it "distinguishes different secret values even though they redact alike" $
    computeStepKey noRef q "c" (secretArg "s1") [] "fp"
      `shouldNotBe` computeStepKey noRef q "c" (secretArg "s2") [] "fp"

  it "changes when the ctx projection changes" $
    computeStepKey noRef q "c" args [("ctx.workspace", "a")] "fp"
      `shouldNotBe` computeStepKey noRef q "c" args [("ctx.workspace", "b")] "fp"

  it "substitutes a ref argument's target fingerprint, not its qname" $ do
    let withFp = computeStepKey (const (Just "callee-fp")) q "c" refArgs [] "fp"
        withoutFp = computeStepKey noRef q "c" refArgs [] "fp"
    withFp `shouldNotBe` withoutFp

  it "produces a stable non-empty digest" $
    length baseKey `shouldSatisfy` (> 0)
  where
    args = Map.fromList [("path", VString "in.txt")]
    secretArg v = Map.fromList [("key", VSecret (Just "api") (VString v))]
    refArgs = Map.fromList [("tool", VRef RTool (qnameFromText "tools/helper"))]
