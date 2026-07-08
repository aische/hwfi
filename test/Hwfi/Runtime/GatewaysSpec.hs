module Hwfi.Runtime.GatewaysSpec (spec) where

import Data.Either (isRight)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Hwfi.Compat (ModelConfig (..))
import Hwfi.Runtime.Error (RuntimeError (..))
import Hwfi.Runtime.Gateways (ModelStore, buildGateways, buildModelStore, lookupModel, availableModelNames, modelCatalogFingerprint, oneShotLlmCtxProjection)
import Hwfi.Runtime.KeyStore (loadKeyStore)
import Hwfi.Runtime.ModelCatalog (loadCatalog)
import Hwfi.Runtime.Value (RValue (..))
import LLM.Core.Types (LLMError (..), LLMGateway (..))
import LLM.Core.Usage (PricingInfo (..))
import Test.Hspec

-- | Reuse the example project's ollama-only catalog (no API key needed).
exampleDir :: FilePath
exampleDir = "examples/summarise"

spec :: Spec
spec = describe "Gateways and model store (§7.3, A11)" $ do
  it "assembles a model store from the catalog and gateways" $ do
    ks <- loadKeyStore Nothing exampleDir
    ecat <- loadCatalog exampleDir
    case ecat of
      Left e -> expectationFailure (show e)
      Right cat -> do
        let store = buildModelStore (buildGateways ks) cat
        isRight store `shouldBe` True
        fmap availableModelNames store `shouldBe` Right ["default"]

  it "resolves a known model name" $ do
    ks <- loadKeyStore Nothing exampleDir
    Right cat <- loadCatalog exampleDir
    let Right store = buildModelStore (buildGateways ks) cat
    isRight (lookupModel "default" store) `shouldBe` True

  it "fails on an unknown model, listing available names (A11)" $ do
    ks <- loadKeyStore Nothing exampleDir
    Right cat <- loadCatalog exampleDir
    let Right store = buildModelStore (buildGateways ks) cat
    case lookupModel "no-such-model" store of
      Right _ -> expectationFailure "expected an unknown-model error"
      Left err -> reMessage err `shouldSatisfy` T.isInfixOf "default"

  describe "model-catalog fingerprint (§8.1, H1.3)" $ do
    it "changes when a catalog entry's scalar fields change" $ do
      let store1 = llmStore fakeGateway 0.1
          store2 = llmStore fakeGateway 0.9
      modelCatalogFingerprint "fast" store1
        `shouldNotBe` modelCatalogFingerprint "fast" store2

    it "feeds one-shot LLM step-keys via ctx-projection" $ do
      let args = Map.fromList [("model", VString "fast")]
          store = llmStore fakeGateway 0.5
      oneShotLlmCtxProjection args store
        `shouldBe` [("model-catalog-fp", modelCatalogFingerprint "fast" store)]

llmStore :: LLMGateway -> Double -> ModelStore
llmStore gw temp = Map.singleton "fast" (fakeConfig gw temp)

fakeConfig :: LLMGateway -> Double -> ModelConfig
fakeConfig gw temp =
  ModelConfig
    { mcGateway = gw,
      mcModel = "provider-model",
      mcPricing = PricingInfo 0 0,
      mcMaxTokens = 256,
      mcTemperature = Just temp,
      mcThinking = Nothing,
      mcRequestTimeout = Just 30000,
      mcThrottleDelay = Just 0,
      mcRetryCount = 3,
      mcJitterBackoff = 1000
    }

fakeGateway :: LLMGateway
fakeGateway =
  LLMGateway
    { gwName = "fake",
      gwGenerateText = \_ _ -> pure (Left EmptyResponse),
      gwStreamText = \_ _ _ -> pure (Left EmptyResponse),
      gwGenerateObject = \_ _ _ -> pure (Left EmptyResponse)
    }
