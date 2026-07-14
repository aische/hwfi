module Hwfi.Parse.MarkdownSpec (spec) where

import Data.Text (Text)
import Data.Text qualified as T
import Hwfi.Parse.Markdown
import Test.Hspec

sample :: Text
sample =
  T.unlines
    [ "---", -- 1
      "name: workflows/x", -- 2
      "---", -- 3
      "", -- 4
      "## flow", -- 5
      "", -- 6
      "Some prose.", -- 7
      "", -- 8
      "```python", -- 9
      "x = 1", -- 10
      "```", -- 11
      "```step", -- 12
      "a <- foo/bar()", -- 13
      "```" -- 14
    ]

spec :: Spec
spec = describe "parseMarkdown (spec §2.1, §3)" $
  it "splits frontmatter, headings, and step blocks with absolute lines" $
    case parseMarkdown "x.md" sample of
      Left ds -> expectationFailure (show ds)
      Right md -> do
        mdFrontmatter md `shouldBe` Just "name: workflows/x"
        map mhText (mdHeadings md) `shouldBe` ["flow"]
        map mhStartLine (mdHeadings md) `shouldBe` [5]
        map msStartLine (mdStepBlocks md) `shouldBe` [13]
        map (T.strip . msContent) (mdStepBlocks md) `shouldBe` ["a <- foo/bar()"]
        map mfLang (mdFences md) `shouldBe` ["python", "step"]
