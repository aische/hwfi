module Hwfi.Runtime.ProviderSpec (spec) where

import Hwfi.Runtime.Provider
import Test.Hspec

spec :: Spec
spec = do
  describe "providerText / parseProvider round-trip" $
    mapM_
      ( \p ->
          it ("round-trips " <> show p) $
            parseProvider (providerText p) `shouldBe` Just p
      )
      allProviders

  describe "parseProvider" $
    it "rejects unknown provider names" $
      parseProvider "anthropic-typo" `shouldBe` Nothing

  describe "providerEnvVar" $ do
    it "maps openai to OPENAI_API_KEY" $
      providerEnvVar OpenAI `shouldBe` Just "OPENAI_API_KEY"

    it "requires no key for ollama" $
      providerEnvVar Ollama `shouldBe` Nothing
