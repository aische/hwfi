-- | Model catalog loading and provider-key validation. See spec §7.3.
--
-- Every project must ship a @model-catalog.json@ at its root; there is no
-- engine-bundled default. Parsing reuses @llm-simple@'s catalog schema
-- ('LLM.Load.ModelCatalog.loadModelCatalog') so the on-disk format stays in
-- lockstep with the library that ultimately consumes it.
module Hwfi.Runtime.ModelCatalog
  ( ModelCatalogMap,
    ModelCatalogItem (..),
    CatalogError (..),
    renderCatalogError,
    loadCatalog,
    validateProviderKeys,
  )
where

import Control.Monad.Except (runExceptT)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Hwfi.Runtime.KeyStore (KeyStore, lookupKey)
import Hwfi.Runtime.Provider
  ( ProviderName,
    parseProvider,
    providerEnvVar,
    providerText,
  )
import LLM.Load.ModelCatalog
  ( ModelCatalogItem (..),
    ModelCatalogMap,
  )
import LLM.Load.ModelCatalog qualified as Catalog
import System.Directory (doesFileExist)
import System.FilePath ((</>))

-- | Failure modes when loading or validating a catalog.
data CatalogError
  = -- | @model-catalog.json@ was not found at the project root.
    CatalogMissing FilePath
  | -- | The file exists but could not be parsed. Carries the underlying
    -- @llm-simple@ error, rendered to text.
    CatalogParseError Text
  | -- | A catalog entry names a provider string we do not recognise.
    -- Fields: model config name, offending provider string.
    CatalogUnknownProvider Text Text
  | -- | A referenced provider has no discoverable API key (spec A12).
    -- Fields: model config name, provider.
    CatalogMissingKey Text ProviderName
  deriving stock (Eq, Show)

-- | Render a 'CatalogError' as a user-facing message. The 'CatalogMissingKey'
-- wording matches the spec §7.3 example verbatim.
renderCatalogError :: CatalogError -> Text
renderCatalogError = \case
  CatalogMissing path ->
    "error: required model-catalog.json not found at " <> T.pack path
  CatalogParseError msg ->
    "error: could not parse model-catalog.json: " <> msg
  CatalogUnknownProvider m p ->
    "error: model '" <> m <> "' in model-catalog.json names unknown provider '" <> p <> "'"
  CatalogMissingKey m p ->
    let envVar = fromMaybe "(no key)" (providerEnvVar p)
     in "error: model '"
          <> m
          <> "' in model-catalog.json requires provider '"
          <> providerText p
          <> "', but "
          <> envVar
          <> " was not found in --env-file, <project>/.env, the process environment,"
          <> " or $XDG_CONFIG_HOME/hwfi/.env."

-- | Load the project's model catalog, failing if the file is absent or
-- malformed.
loadCatalog :: FilePath -> IO (Either CatalogError ModelCatalogMap)
loadCatalog projectDir = do
  let path = projectDir </> "model-catalog.json"
  exists <- doesFileExist path
  if not exists
    then pure (Left (CatalogMissing path))
    else do
      result <- runExceptT (Catalog.loadModelCatalog path)
      pure $ case result of
        Left err -> Left (CatalogParseError (T.pack (show err)))
        Right catalog -> Right catalog

-- | Validate that every provider referenced by the catalog has a
-- discoverable key in the 'KeyStore' (spec A12). 'Ollama' requires no key.
-- Returns the list of all offending entries so the caller can report them
-- together; an empty list means the catalog is fully satisfiable.
validateProviderKeys :: ModelCatalogMap -> KeyStore -> [CatalogError]
validateProviderKeys catalog keyStore =
  concatMap checkItem (Map.elems catalog)
  where
    checkItem :: ModelCatalogItem -> [CatalogError]
    checkItem item =
      case parseProvider item.providerName of
        Nothing ->
          [CatalogUnknownProvider item.modelConfigName item.providerName]
        Just p -> case providerEnvVar p of
          -- No key required (e.g. Ollama).
          Nothing -> []
          Just _ -> case lookupKey p keyStore of
            Just _ -> []
            Nothing -> [CatalogMissingKey item.modelConfigName p]
