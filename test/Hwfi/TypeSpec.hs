module Hwfi.TypeSpec (spec) where

import Hwfi.Type
import Test.Hspec

spec :: Spec
spec = do
  describe "structEq (records compare structurally, §3)" $ do
    it "ignores record field order" $
      structEq
        (TyRecord [("a", TyString), ("b", TyInt)])
        (TyRecord [("b", TyInt), ("a", TyString)])
        `shouldBe` True

    it "distinguishes differing field types" $
      structEq
        (TyRecord [("a", TyString)])
        (TyRecord [("a", TyInt)])
        `shouldBe` False

    it "recurses through lists" $
      structEq (TyList (TyRecord [("a", TyInt)])) (TyList (TyRecord [("a", TyInt)]))
        `shouldBe` True

  describe "assignable (String is accepted where FileRef is expected)" $ do
    it "accepts String where FileRef is expected" $
      assignable TyFileRef TyString `shouldBe` True

    it "does not accept FileRef where String is expected" $
      assignable TyString TyFileRef `shouldBe` False

    it "is congruent through List" $
      assignable (TyList TyFileRef) (TyList TyString) `shouldBe` True

    it "is congruent through Record fields" $
      assignable
        (TyRecord [("p", TyFileRef)])
        (TyRecord [("p", TyString)])
        `shouldBe` True

    it "keeps distinct scalars unassignable" $
      assignable TyInt TyString `shouldBe` False

  describe "isSecretEnvName (§5.5 auto-tagging)" $ do
    it "matches secret suffixes case-insensitively" $ do
      isSecretEnvName "OPENAI_API_KEY" `shouldBe` True
      isSecretEnvName "session_token" `shouldBe` True
      isSecretEnvName "DB_PASSWORD" `shouldBe` True
      isSecretEnvName "app_secret" `shouldBe` True

    it "does not match ordinary names" $ do
      isSecretEnvName "USER_NAME" `shouldBe` False
      isSecretEnvName "HOME" `shouldBe` False
