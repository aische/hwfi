module Hwfi.Runtime.GlobSpec (spec) where

import Hwfi.Runtime.Glob (matchGlob, matchSegment, splitGlob)
import Test.Hspec

spec :: Spec
spec = describe "Glob matcher (§6.2)" $ do
  describe "splitGlob" $ do
    it "splits on '/' and drops a leading './'" $ do
      splitGlob "src/**/*.hs" `shouldBe` ["src", "**", "*.hs"]
      splitGlob "./**/*.hs" `shouldBe` ["**", "*.hs"]

  describe "matchSegment" $ do
    it "matches '*' against any run within a segment" $ do
      matchSegment "*.hs" "Main.hs" `shouldBe` True
      matchSegment "*.hs" "Main.md" `shouldBe` False
    it "matches '?' against exactly one char" $ do
      matchSegment "a?c" "abc" `shouldBe` True
      matchSegment "a?c" "ac" `shouldBe` False

  describe "matchGlob" $ do
    it "'**' matches zero or more path segments" $ do
      matchGlob ["**", "*.hs"] ["Main.hs"] `shouldBe` True
      matchGlob ["**", "*.hs"] ["a", "b", "Main.hs"] `shouldBe` True
    it "a fixed prefix must match segment-for-segment" $ do
      matchGlob ["src", "**", "*.hs"] ["src", "Tools", "Grep.hs"] `shouldBe` True
      matchGlob ["src", "**", "*.hs"] ["test", "Spec.hs"] `shouldBe` False
    it "'*' never crosses a '/'" $
      matchGlob ["*.hs"] ["sub", "Main.hs"] `shouldBe` False
