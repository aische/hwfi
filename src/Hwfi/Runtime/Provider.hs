-- | LLM providers recognised by @hwfi@ and their API-key environment
-- variables. See spec §7.2.
--
-- The set of providers is fixed in v1 (it mirrors @llm-simple@'s
-- @LLM.Providers.*@), so we model it as a closed sum type for
-- exhaustiveness rather than as free-form 'Text'.
module Hwfi.Runtime.Provider
  ( ProviderName (..),
    allProviders,
    providerText,
    parseProvider,
    providerEnvVar,
  )
where

import Data.Text (Text)

-- | A provider supported by the engine.
data ProviderName
  = OpenAI
  | Claude
  | Gemini
  | DeepSeek
  | Ollama
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | All providers, in declaration order.
allProviders :: [ProviderName]
allProviders = [minBound .. maxBound]

-- | The canonical lowercase name used in @model-catalog.json@'s
-- @providerName@ field (matches @llm-simple@).
providerText :: ProviderName -> Text
providerText = \case
  OpenAI -> "openai"
  Claude -> "claude"
  Gemini -> "gemini"
  DeepSeek -> "deepseek"
  Ollama -> "ollama"

-- | Parse a catalog @providerName@ back into a 'ProviderName'.
parseProvider :: Text -> Maybe ProviderName
parseProvider t = lookup t [(providerText p, p) | p <- allProviders]

-- | The environment variable that carries this provider's API key.
-- 'Ollama' needs no key, hence 'Nothing'.
providerEnvVar :: ProviderName -> Maybe Text
providerEnvVar = \case
  OpenAI -> Just "OPENAI_API_KEY"
  Claude -> Just "CLAUDE_API_KEY"
  Gemini -> Just "GEMINI_API_KEY"
  DeepSeek -> Just "DEEPSEEK_API_KEY"
  Ollama -> Nothing
