-- | Provider gateways and model-config assembly (spec §7.2, §7.3, task 4.5).
--
-- @hwfi@ builds its own @Map ProviderName LLMGateway@ from the
-- @LLM.Providers.*@ constructors and its own 'KeyStore', rather than using
-- @LLM.Load.loadGateways@ (§7.2). Each catalog entry is then joined with its
-- provider's gateway to produce a runtime 'ModelConfig' (mirroring
-- @LLM.Load.LoadModels@ but sourcing keys from the typed 'KeyStore'). The
-- resulting 'ModelStore' is what @builtin/llm-*@ resolves a @model@ argument
-- against; an unknown name fails with a message listing the available names
-- (A11).
module Hwfi.Runtime.Gateways
  ( GatewayMap,
    buildGateways,
    ModelStore,
    buildModelStore,
    lookupModel,
    availableModelNames,
    modelCatalogFingerprint,
    oneShotLlmCtxProjection,
    primaryModel,
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Hwfi.Ast.Name (Ident)
import Hwfi.Compat
  ( LLMGateway,
    ModelCatalogItem (..),
    ModelCatalogMap,
    ModelConfig (..),
    ModelWithFallbacks (..),
    ThinkingMode (..),
    claudeGateway,
    deepSeekGateway,
    geminiGateway,
    ollamaGateway,
    openAIGateway,
  )
import Hwfi.Runtime.Error (RuntimeError, userError_)
import Hwfi.Runtime.KeyStore (KeyStore, lookupKey)
import Hwfi.Runtime.ModelCatalog (CatalogError (..))
import Hwfi.Runtime.Provider (ProviderName (..), allProviders, parseProvider)
import Hwfi.Runtime.Secret (exposeSecret)
import Hwfi.Runtime.Value (RValue (..))

-- | Provider gateways available for this run.
type GatewayMap = Map ProviderName LLMGateway

-- | Assembled model configurations, keyed by @modelConfigName@ (§7.3).
type ModelStore = Map Text ModelConfig

-- | Build the gateway map from the key store (spec §7.2). A provider appears
-- only if a key was discovered for it; @ollama@ needs no key and is always
-- present.
buildGateways :: KeyStore -> GatewayMap
buildGateways ks =
  Map.fromList [(p, gw) | p <- allProviders, Just gw <- [gatewayFor p]]
  where
    keyFor p = exposeSecret <$> lookupKey p ks
    gatewayFor = \case
      OpenAI -> openAIGateway <$> keyFor OpenAI
      Claude -> claudeGateway <$> keyFor Claude
      Gemini -> geminiGateway <$> keyFor Gemini
      DeepSeek -> deepSeekGateway <$> keyFor DeepSeek
      Ollama -> Just ollamaGateway

-- | Assemble a 'ModelStore' by joining every catalog entry with its provider's
-- gateway (spec §7.3). Fails on an unrecognised provider string or a provider
-- whose gateway is absent (missing key) — the same conditions
-- 'Hwfi.Runtime.ModelCatalog.validateProviderKeys' reports at startup, so in
-- practice this succeeds once validation has passed.
buildModelStore :: GatewayMap -> ModelCatalogMap -> Either CatalogError ModelStore
buildModelStore gateways catalog =
  Map.fromList <$> traverse entry (Map.toList catalog)
  where
    entry (name, item) = case parseProvider item.providerName of
      Nothing -> Left (CatalogUnknownProvider name item.providerName)
      Just p -> case Map.lookup p gateways of
        Nothing -> Left (CatalogMissingKey name p)
        Just gw -> Right (name, toModelConfig gw item)

-- | Build a runtime 'ModelConfig' from a gateway and a catalog entry (mirrors
-- @LLM.Load.LoadModels@).
toModelConfig :: LLMGateway -> ModelCatalogItem -> ModelConfig
toModelConfig gw item =
  ModelConfig
    { mcGateway = gw,
      mcModel = item.modelName,
      mcPricing = item.pricing,
      mcMaxTokens = item.maxTokens,
      mcTemperature = item.temperature,
      mcThinking = fmap (\x -> ThinkingMode {tmEnabled = True, tmEffort = Just x}) item.thinking,
      mcRequestTimeout = item.requestTimeout,
      mcThrottleDelay = item.throttleDelay,
      mcRetryCount = item.retryCount,
      mcJitterBackoff = item.jitterBackoff
    }

-- | Resolve a @model@ argument to a callable model (no fallbacks in v1).
-- Unknown names fail with the available names listed (spec §7.3, A11).
lookupModel :: Text -> ModelStore -> Either RuntimeError ModelWithFallbacks
lookupModel name store = case Map.lookup name store of
  Just mc -> Right (ModelWithFallbacks mc [])
  Nothing ->
    Left
      ( userError_
          ( "unknown model '"
              <> name
              <> "'; available models: "
              <> T.intercalate ", " (availableModelNames store)
          )
      )

-- | The model-config names available in the store, sorted.
availableModelNames :: ModelStore -> [Text]
availableModelNames = Map.keys

-- | A stable fingerprint of a model-catalog entry, used to sub-key an agent
-- round's model call (§8.2.1). Derived from the catalog scalar fields (not the
-- gateway closure) so editing an entry — provider model id, token cap,
-- temperature, timeouts, retry policy — changes it and invalidates cached
-- model calls on resume. Unknown names fall back to the bare name (the model
-- lookup itself fails later with a listing, A11).
modelCatalogFingerprint :: Text -> ModelStore -> Text
modelCatalogFingerprint name store = case Map.lookup name store of
  Nothing -> name
  Just mc ->
    T.intercalate
      "|"
      [ name,
        mc.mcModel,
        tshow mc.mcMaxTokens,
        tshow mc.mcTemperature,
        tshow mc.mcRequestTimeout,
        tshow mc.mcThrottleDelay,
        tshow mc.mcRetryCount,
        tshow mc.mcJitterBackoff
      ]
  where
    tshow :: (Show a) => a -> Text
    tshow = T.pack . show

-- | Extra stable @ctx-projection@ lines for one-shot LLM builtin step-keys
-- (§8.1). The model name in @resolved-args@ is not enough — repointing a
-- catalog entry or changing its scalar fields must bust the cache.
oneShotLlmCtxProjection :: Map Ident RValue -> ModelStore -> [(Text, Text)]
oneShotLlmCtxProjection args store =
  case resolvedTextArg "model" args of
    Just name -> [("model-catalog-fp", modelCatalogFingerprint name store)]
    Nothing -> []

-- | The primary model config from a @model@ argument (no fallbacks in v1).
primaryModel :: ModelWithFallbacks -> ModelConfig
primaryModel mwf = mwf.mwfModel

-- | Extract a resolved string argument, unwrapping 'VSecret' the same way
-- step-key hashing does for @resolved-args@.
resolvedTextArg :: Ident -> Map Ident RValue -> Maybe Text
resolvedTextArg name args = case Map.lookup name args of
  Just (VString t) -> Just t
  Just (VSecret _ inner) -> resolvedTextArg name (Map.singleton name inner)
  _ -> Nothing
