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
                envWhitelist = ["HOME", "USER"],
                execPolicy = Nothing,
                budgetPolicy = Nothing,
                pmSkills = Nothing
              }
          )

    it "parses an exec policy with defaults for omitted fields (§2, §7.5)" $ do
      let json =
            BS.pack $
              unlines
                [ "{",
                  "  \"name\": \"example\",",
                  "  \"version\": \"0.1.0\",",
                  "  \"entrypoint\": \"workflows/main\",",
                  "  \"exec\": { \"allow\": [\"git\", \"cabal\"], \"env\": [\"PATH\"] }",
                  "}"
                ]
      fmap execPolicy (eitherDecodeStrict' json)
        `shouldBe` Right
          ( Just
              ExecPolicy
                { execAllow = ["git", "cabal"],
                  execEnv = ["PATH"],
                  execTimeoutMs = defaultExecTimeoutMs,
                  execMaxOutputBytes = defaultExecMaxOutputBytes
                }
          )

    it "leaves execPolicy Nothing when no exec block is present (fail-closed)" $ do
      let json =
            BS.pack $
              unlines
                [ "{",
                  "  \"name\": \"example\",",
                  "  \"version\": \"0.1.0\",",
                  "  \"entrypoint\": \"workflows/main\"",
                  "}"
                ]
      fmap execPolicy (eitherDecodeStrict' json) `shouldBe` Right Nothing

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

    it "parses an optional budget ceiling (§8.4.6)" $ do
      let json =
            BS.pack $
              unlines
                [ "{",
                  "  \"name\": \"example\",",
                  "  \"version\": \"0.1.0\",",
                  "  \"entrypoint\": \"workflows/main\",",
                  "  \"budget\": { \"max_cost_usd\": 1.5 }",
                  "}"
                ]
      fmap budgetPolicy (eitherDecodeStrict' json)
        `shouldBe` Right (Just (BudgetPolicy {bpMaxCostUsd = 1.5}))

    it "fails when a required field is missing" $ do
      let json = BS.pack "{ \"name\": \"example\" }"
      (eitherDecodeStrict' json :: Either String ProjectManifest) `shouldSatisfy` isLeft
  where
    isLeft = either (const True) (const False)
