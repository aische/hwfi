module Hwfi.Project.ManifestSpec (spec) where

import Data.Aeson (eitherDecodeStrict')
import Data.ByteString.Char8 qualified as BS
import Hwfi.Project.Manifest
import Test.Hspec

spec :: Spec
spec = do
  describe "ProjectManifest JSON parsing" $ do
    it "parses a full manifest" $ do
      let json =
            BS.pack $
              unlines
                [ "{",
                  "  \"name\": \"example\",",
                  "  \"version\": \"0.1.0\",",
                  "  \"entrypoint\": \"workflows/main\",",
                  "  \"env\": [\"HOME\", \"USER\"]",
                  "}"
                ]
      eitherDecodeStrict' json
        `shouldBe` Right
          ( ProjectManifest
              { name = "example",
                version = "0.1.0",
                entrypoint = "workflows/main",
                envWhitelist = ["HOME", "USER"]
              }
          )

    it "defaults env to [] when omitted" $ do
      let json =
            BS.pack $
              unlines
                [ "{",
                  "  \"name\": \"example\",",
                  "  \"version\": \"0.1.0\",",
                  "  \"entrypoint\": \"workflows/main\"",
                  "}"
                ]
      fmap envWhitelist (eitherDecodeStrict' json) `shouldBe` Right []

    it "fails when a required field is missing" $ do
      let json = BS.pack "{ \"name\": \"example\" }"
      (eitherDecodeStrict' json :: Either String ProjectManifest) `shouldSatisfy` isLeft
  where
    isLeft = either (const True) (const False)
