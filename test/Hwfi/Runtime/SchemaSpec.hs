module Hwfi.Runtime.SchemaSpec (spec) where

import Data.Aeson (Value (..), object, (.=))
import Data.Either (isLeft)
import Data.Vector qualified as V
import Hwfi.Runtime.Schema (ineligibilityReasons, recordSchema, typeToSchema)
import Hwfi.Type (Type (..))
import Test.Hspec

spec :: Spec
spec = do
  describe "typeToSchema — total translation over eligible types (§6.1.1)" $ do
    it "maps primitives to their JSON Schema types" $ do
      typeToSchema TyString `shouldBe` Right (object ["type" .= ("string" :: String)])
      typeToSchema TyInt `shouldBe` Right (object ["type" .= ("integer" :: String)])
      typeToSchema TyDouble `shouldBe` Right (object ["type" .= ("number" :: String)])
      typeToSchema TyBool `shouldBe` Right (object ["type" .= ("boolean" :: String)])

    it "maps FileRef to a string (workspace path)" $
      typeToSchema TyFileRef `shouldBe` Right (object ["type" .= ("string" :: String)])

    it "maps Json to an unconstrained schema" $
      typeToSchema TyJson `shouldBe` Right (object [])

    it "maps List<T> to an array with translated items" $
      typeToSchema (TyList TyInt)
        `shouldBe` Right (object ["type" .= ("array" :: String), "items" .= object ["type" .= ("integer" :: String)]])

    it "maps Record to an object with properties and required" $
      recordSchema [("a", TyString), ("n", TyInt)]
        `shouldBe` Right
          ( object
              [ "type" .= ("object" :: String),
                "properties"
                  .= object
                    [ "a" .= object ["type" .= ("string" :: String)],
                      "n" .= object ["type" .= ("integer" :: String)]
                    ],
                "required" .= Array (V.fromList [String "a", String "n"]),
                "additionalProperties" .= False
              ]
          )

  describe "typeToSchema — rejecting model-ineligible types (§6.1.1, A18)" $ do
    it "rejects Secret<_>" $ typeToSchema (TySecret TyString) `shouldSatisfy` isLeft
    it "rejects ToolRef" $ typeToSchema (TyToolRef TyString TyString) `shouldSatisfy` isLeft
    it "rejects WorkflowRef" $ typeToSchema (TyWorkflowRef TyString TyString) `shouldSatisfy` isLeft
    it "rejects Bytes" $ typeToSchema TyBytes `shouldSatisfy` isLeft
    it "rejects a nested ineligible type" $
      typeToSchema (TyList (TySecret TyString)) `shouldSatisfy` isLeft

  describe "ineligibilityReasons (§5.6.9)" $ do
    it "reports no reasons for an all-eligible input record" $
      ineligibilityReasons [("path", TyFileRef), ("count", TyInt)] `shouldBe` []

    it "reports a reason for each ineligible input" $ do
      let reasons = ineligibilityReasons [("token", TySecret TyString), ("blob", TyBytes)]
      length reasons `shouldBe` 2

    it "still accepts a callee with a nested record of eligible types" $
      ineligibilityReasons [("brief", TyRecord [("title", TyString)])] `shouldBe` []
