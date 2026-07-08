-- | Curated re-exports of the @llm-simple@ API surface that @hwfi@ depends
-- on. See spec §10. Consolidating the imports here keeps the runtime
-- modules decoupled from @llm-simple@'s internal module layout and gives a
-- single place to confirm the dependency wiring compiles (task 1.2).
--
-- @hwfi@ deliberately does /not/ use @LLM.Load.loadGateways@ or the
-- @*OrThrow@ loaders (spec §7.2); it constructs gateways itself from the
-- provider constructors below and joins them with the catalog in
-- 'Hwfi.Runtime.Gateways'.
module Hwfi.Compat
  ( -- * Generation entry points
    generateTextWithFallbacks,
    genObject,
    genObjectUntyped,
    ModelConfig (..),
    ModelWithFallbacks (..),
    GenRequest (..),
    GenerateError (..),
    GenerateErrorResult (..),
    noHooks,
    llmHooks,

    -- * Core generation types
    ChatResponse (..),
    ContentBlock (..),
    Turn (..),
    ToolDef (..),
    ToolCall (..),
    ToolResult (..),
    mkToolCall,
    Usage (..),
    PricingInfo (..),
    estimateCost,
    ThinkingMode (..),
    LLMGateway (..),

    -- * Provider gateways
    openAIGateway,
    claudeGateway,
    geminiGateway,
    deepSeekGateway,
    ollamaGateway,

    -- * Catalog schema
    loadModelCatalog,
    ModelCatalogItem (..),
    ModelCatalogMap,
  )
where

import LLM.Core.Types
  ( ChatResponse (..),
    ContentBlock (..),
    LLMGateway (..),
    ThinkingMode (..),
    ToolCall (..),
    ToolDef (..),
    ToolResult (..),
    Turn (..),
    mkToolCall,
  )
import LLM.Core.Usage (PricingInfo (..), Usage (..), estimateCost)
import LLM.Generate
  ( GenRequest (..),
    GenerateError (..),
    GenerateErrorResult (..),
    ModelConfig (..),
    ModelWithFallbacks (..),
    generateTextWithFallbacks,
    genObject,
    genObjectUntyped,
    llmHooks,
    noHooks,
  )
import LLM.Load.ModelCatalog
  ( ModelCatalogItem (..),
    ModelCatalogMap,
    loadModelCatalog,
  )
import LLM.Providers
  ( claudeGateway,
    deepSeekGateway,
    geminiGateway,
    ollamaGateway,
    openAIGateway,
  )
