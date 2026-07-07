module Hwfi.SourceSpec (spec) where

import Hwfi.Source
import Test.Hspec

spec :: Spec
spec =
  describe "renderDiagnostic (spec §9.1)" $
    it "formats path:line:col, the source line, and a caret underline" $ do
      let src = "line one\nabc def gh\n"
          d = Diagnostic "f.hs" (Pos 2 3) 4 "boom"
      renderDiagnostic src d
        `shouldBe` "f.hs:2:3: boom\n  |\n2 | abc def gh\n  |   ^^^^"
