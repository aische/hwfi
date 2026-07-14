module Hwfi.Runtime.ValueSpec (spec) where

import Data.Aeson (Value (..), object)
import Data.Either (isLeft)
import Data.Map.Strict qualified as Map
import Data.Vector (fromList)
import Hwfi.Ast.Name (qnameFromText)
import Hwfi.Runtime.Value
import Hwfi.Type (Type (..))
import Test.Hspec
import Control.Monad (forM_)

spec :: Spec
spec = do
  describe "canonicalJson (§3.2.1, §8.1)" $ do
    it "sorts object keys lexicographically" $
      canonicalJson (object [("b", Number 1), ("a", Number 2)]) `shouldBe` "{\"a\":2,\"b\":1}"

    it "encodes nested arrays and objects compactly" $
      canonicalJson (object [("xs", Array (fromList [Number 1, String "x"]))])
        `shouldBe` "{\"xs\":[1,\"x\"]}"

  describe "renderValue interpolation table (§3.2.1)" $ do
    it "renders scalars canonically" $ do
      renderValue (VInt 5) `shouldBe` Right "5"
      renderValue (VDouble 3.5) `shouldBe` Right "3.5"
      renderValue (VBool True) `shouldBe` Right "true"
      renderValue VNull `shouldBe` Right "null"
      renderValue (VFileRef "out.txt") `shouldBe` Right "out.txt"

    it "renders structured values as compact sorted JSON" $
      renderValue (VRecord (Map.fromList [("b", VInt 1), ("a", VInt 2)]))
        `shouldBe` Right "{\"a\":2,\"b\":1}"

    it "rejects rendering a Secret<_> (§5.5)" $
      renderValue (VSecret (Just "TOKEN") (VString "x")) `shouldSatisfy` isLeft

  describe "redactedJson (§8.3.4)" $
    it "replaces a secret with its named placeholder" $
      redactedJson (VRecord (Map.fromList [("k", VSecret (Just "API_KEY") (VString "hunter2"))]))
        `shouldBe` object [("k", String "<secret:API_KEY>")]

  describe "input coercion (§9)" $ do
    it "coerces a bare string per declared type" $ do
      coerceFromString TyInt "42" `shouldBe` Right (VInt 42)
      coerceFromString TyFileRef "a/b.txt" `shouldBe` Right (VFileRef "a/b.txt")
      coerceFromString TyBool "true" `shouldBe` Right (VBool True)

    it "rejects a malformed scalar string" $
      coerceFromString TyInt "notanint" `shouldSatisfy` isLeft

    it "coerces JSON per declared type" $ do
      coerceFromJson TyFileRef (String "x") `shouldBe` Right (VFileRef "x")
      coerceFromJson TyJson (Number 1) `shouldBe` Right (VJson (Number 1))

  describe "snapshot value encoding (machine.json)" $ do
    it "round-trips every constructor losslessly" $ do
      let values =
            [ VString "hello",
              VInt 42,
              VDouble 1.5,
              VBool True,
              VNull,
              VFileRef "src/main.ts",
              VList [VString "a", VInt 1],
              VRecord (Map.fromList [("line", VString "Task JSON: {}")]),
              VJson (object [("id", String "0")]),
              VSecret (Just "TOKEN") (VString "secret"),
              VRef RTool (qnameFromText "tools/task-line")
            ]
      forM_ values $ \v ->
        snapshotValueFromJson (snapshotValueToJson v) `shouldBe` Right v
