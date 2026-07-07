-- | Curated re-exports of the @llm-simple@ API surface that @hwfi@ depends
-- on. See spec §10. Consolidating the imports here keeps the runtime
-- modules decoupled from @llm-simple@'s internal module layout and gives a
-- single place to confirm the dependency wiring compiles (task 1.2).
--
-- @hwfi@ deliberately does /not/ use @LLM.Load.loadGateways@ or the
-- @*OrThrow@ loaders (spec §7.2); it constructs gateways itself from the
-- provider constructors below.
module Hwfi.Compat
  ( -- * Generation entry points
    generateTextWithFallbacks,
    genObject,
    genObjectUntyped,
    ModelConfig (..),
    GenRequest (..),

    -- * Provider gateways
    openAIGateway,

    -- * Catalog schema
    loadModelCatalog,
    ModelCatalogItem (..),
    ModelCatalogMap,
  )
where

import LLM.Generate
  ( GenRequest (..),
    ModelConfig (..),
    generateTextWithFallbacks,
    genObject,
    genObjectUntyped,
  )
import LLM.Load.ModelCatalog
  ( ModelCatalogItem (..),
    ModelCatalogMap,
    loadModelCatalog,
  )
import LLM.Providers.OpenAI (openAIGateway)
