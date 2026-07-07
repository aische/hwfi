module Hwfi.Parse.TypeSpec (spec) where

import Data.Text (Text)
import Hwfi.Ast.Name (qnameFromText)
import Hwfi.Ast.Type
import Hwfi.Parse.Type (parseTypeExprText)
import Hwfi.Source (Pos (..))
import Test.Hspec

parseT :: Text -> Either String TypeExpr
parseT t = either (Left . show) Right (parseTypeExprText "t" (Pos 1 1) t)

spec :: Spec
spec = describe "parseTypeExprText (spec §3.4)" $ do
  it "parses primitives" $ do
    parseT "String" `shouldBe` Right TString
    parseT "FileRef" `shouldBe` Right TFileRef
    parseT "TraceEvent" `shouldBe` Right TTraceEvent

  it "parses List<...>" $
    parseT "List<String>" `shouldBe` Right (TList TString)

  it "parses nested records with the ':' separator" $
    parseT "Record<{ role: String, content: String }>"
      `shouldBe` Right (TRecord [("role", TString), ("content", TString)])

  it "parses Secret<...>" $
    parseT "Secret<String>" `shouldBe` Right (TSecret TString)

  it "parses ref types with two arguments" $
    parseT "WorkflowRef<Json, Json>" `shouldBe` Right (TWorkflowRef TJson TJson)

  it "parses a qname alias reference" $
    parseT "types/message" `shouldBe` Right (TAlias (qnameFromText "types/message"))

  it "rejects trailing garbage" $
    parseT "String String" `shouldSatisfy` isLeft
  where
    isLeft = either (const True) (const False)
