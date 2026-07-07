module Hwfi.Runtime.GatewaysSpec (spec) where

import Data.Either (isRight)
import Data.Text qualified as T
import Hwfi.Runtime.Error (RuntimeError (..))
import Hwfi.Runtime.Gateways
import Hwfi.Runtime.KeyStore (loadKeyStore)
import Hwfi.Runtime.ModelCatalog (loadCatalog)
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
