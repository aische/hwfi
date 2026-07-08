module Hwfi.Runtime.UsageSpec (spec) where

import Hwfi.Runtime.RunUsage
  ( RunUsage (..),
    emptyRunUsage,
    runUsageFromJson,
    runUsageToJson,
  )
import Hwfi.Runtime.Usage (callCostUsd)
import LLM.Core.Types (LLMError (..), LLMGateway (..))
import LLM.Core.Usage (PricingInfo (..), Usage (..))
import LLM.Generate.ModelConfig (ModelConfig (..))
import Test.Hspec

fakeConfig :: PricingInfo -> ModelConfig
fakeConfig pricing =
  ModelConfig
    { mcGateway =
        LLMGateway
          { gwName = "fake",
            gwGenerateText = \_ _ -> pure (Left EmptyResponse),
            gwStreamText = \_ _ _ -> pure (Left EmptyResponse),
            gwGenerateObject = \_ _ _ -> pure (Left EmptyResponse)
          },
      mcModel = "fake",
      mcPricing = pricing,
      mcMaxTokens = 256,
      mcTemperature = Nothing,
      mcThinking = Nothing,
      mcRequestTimeout = Nothing,
      mcThrottleDelay = Nothing,
      mcRetryCount = 0,
      mcJitterBackoff = 0
    }

spec :: Spec
spec = describe "Usage and cost accounting (§8.4)" $ do
  it "round-trips run usage JSON" $ do
    let ru = RunUsage 12 34 0.0567
    runUsageFromJson (runUsageToJson ru) `shouldBe` Just ru

  it "uses provider usageTotalCost when non-zero (§8.4.3)" $ do
    let mc = fakeConfig (PricingInfo 100 100)
        u = Usage 10 10 0.42
    callCostUsd mc u `shouldBe` 0.42

  it "estimates cost from catalog pricing when provider cost is zero (§8.4.3)" $ do
    let mc = fakeConfig (PricingInfo 3 6)
        u = Usage 1000 500 0
    callCostUsd mc u `shouldBe` 0.006

  it "starts from an empty running total" $
    emptyRunUsage `shouldBe` RunUsage 0 0 0
