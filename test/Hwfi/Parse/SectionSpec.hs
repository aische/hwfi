module Hwfi.Parse.SectionSpec (spec) where

import Data.Text (Text)
import Data.Text qualified as T
import Hwfi.Ast.Name (Slug (..))
import Hwfi.Parse.Markdown (MarkdownFile (..), parseMarkdown)
import Hwfi.Parse.Section
import Test.Hspec

sample :: Text
sample =
  T.unlines
    [ "---",
      "name: workflows/x",
      "---",
      "",
      "## system",
      "",
      "You are helpful.",
      "",
      "### detail",
      "",
      "Extra detail.",
      "",
      "## flow",
      "",
      "Do the thing."
    ]

spec :: Spec
spec = do
  describe "computeSlug (spec §3.4)" $ do
    it "lowercases and dashes non-word runs" $
      computeSlug "My Heading!" `shouldBe` Slug "my-heading"
    it "trims leading/trailing dashes" $
      computeSlug "  Hello, World  " `shouldBe` Slug "hello-world"

  describe "buildSections / resolveSelf (spec §3.2)" $
    it "extracts raw content per H2/H3 section" $
      case parseMarkdown "x.md" sample of
        Left ds -> expectationFailure (show ds)
        Right md -> do
          let secs = buildSections (mdSourceLines md) (mdHeadings md)
          resolveSelf (Slug "system") secs
            `shouldBe` Just "You are helpful.\n\n### detail\n\nExtra detail."
          resolveSelf (Slug "detail") secs `shouldBe` Just "Extra detail."
          resolveSelf (Slug "flow") secs `shouldBe` Just "Do the thing."
          resolveSelf (Slug "missing") secs `shouldBe` Nothing
