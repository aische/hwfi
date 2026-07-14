module Hwfi.Text.QnameResolveSpec (spec) where

import Data.Text qualified as T
import Hwfi.Text.QnameResolve
  ( MentionKind (..),
    QnameMention (..),
    resolveQnamesInText,
  )
import Test.Hspec

spec :: Spec
spec = describe "Hwfi.Text.QnameResolve" $ do
  it "classifies catalog hits and builtins" $ do
    let text = "See workflows/main and builtin/read-file and tools/missing"
        catalog = ["workflows/main"]
        mentions = resolveQnamesInText text catalog True False False
    map qmKind mentions
      `shouldBe` [ MentionResolved,
                   MentionBuiltin,
                   MentionUnresolved
                 ]

  it "filters to unresolved mentions only" $ do
    let text = "workflows/main tools/missing"
        catalog = ["workflows/main"]
        mentions = resolveQnamesInText text catalog True True False
    map qmQname mentions `shouldBe` ["tools/missing"]

  it "dedupes repeated qnames" $ do
    let text = "workflows/main then workflows/main again"
        catalog = ["workflows/main"]
        mentions = resolveQnamesInText text catalog False False False
    map qmQname mentions `shouldBe` ["workflows/main"]

  it "skips qnames inside step fences when requested" $ do
    let text =
          T.unlines
            [ "Prose tools/outside",
              "```step",
              "x <- tools/inside-step",
              "```",
              "More prose tools/also-outside"
            ]
        catalog = ["tools/outside", "tools/inside-step", "tools/also-outside"]
        mentions = resolveQnamesInText text catalog False False True
    map qmQname mentions
      `shouldBe` ["tools/outside", "tools/also-outside"]
