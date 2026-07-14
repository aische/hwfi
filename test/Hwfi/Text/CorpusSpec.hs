module Hwfi.Text.CorpusSpec (spec) where

import Data.Text qualified as T
import Hwfi.Text.Corpus
  ( CorpusCluster (..),
    CorpusDocument (..),
    SimilarityMethod (..),
    SimilarityResult (..),
    TextMetrics (..),
    TokenizeMode (..),
    searchCorpus,
    textMetrics,
    textSimilarity,
  )
import Test.Hspec

spec :: Spec
spec = describe "Hwfi.Text.Corpus (§13.1.8 Tier 2)" $ do
  describe "textMetrics" $ do
    it "counts chars, words, lines, and paragraphs" $ do
      let TextMetrics {..} = textMetrics "alpha beta\n\ngamma" TokenizeWord
      tmChars `shouldBe` 17
      tmTokens `shouldBe` 3
      tmLines `shouldBe` 3
      tmParagraphs `shouldBe` 2
      tmShannonEntropy `shouldSatisfy` (> 0)
      tmCompressionRatio `shouldSatisfy` (> 0)

  describe "textSimilarity" $ do
    it "scores identical strings as 1.0 with jaccard word unigrams" $ do
      let SimilarityResult {..} = textSimilarity "a b c" "a b c" SimilarityJaccard 1
      srScore `shouldBe` 1
      srMethod `shouldBe` "jaccard"

    it "scores partial overlap with jaccard" $ do
      let SimilarityResult {..} = textSimilarity "a b c" "b c d" SimilarityJaccard 1
      srScore `shouldSatisfy` (\s -> s > 0 && s < 1)

    it "scores shared substrings with lcs" $ do
      let SimilarityResult {..} = textSimilarity "abcdef" "xxcdeyyy" SimilarityLcs 3
      srScore `shouldSatisfy` (\s -> s > 0 && s < 1)

  describe "searchCorpus" $ do
    it "clusters documents above the similarity threshold" $ do
      let docs =
            [ CorpusDocument "a" "shared guidance for planner",
              CorpusDocument "b" "shared guidance for reviewer",
              CorpusDocument "c" "unrelated content"
            ]
          clusters = searchCorpus docs SimilarityJaccard 0.2 1
      length clusters `shouldBe` 1
      ccMembers (head clusters) `shouldMatchList` ["a", "b"]
      T.length (ccSpan (head clusters)) `shouldSatisfy` (> 0)
