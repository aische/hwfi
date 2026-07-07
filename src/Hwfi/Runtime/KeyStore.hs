-- | Provider API-key store. See spec §7.2.
--
-- @hwfi@ builds its own key store rather than using
-- @llm-simple@'s @LLM.Load.loadGateways@, so that keys stay typed as
-- @'Secret' 'Text'@ throughout the engine and never depend on the process
-- working directory.
--
-- Key sources, highest precedence first:
--
--   1. the file named by @--env-file \<path>@ on the CLI, if given;
--   2. @\<project>/.env@, if it exists;
--   3. the existing process environment.
--
-- @.env@ files are parsed with 'Configuration.Dotenv.parseFile', which does
-- /not/ inject anything into the process environment. A missing @.env@ at
-- levels 1 or 2 is not an error on its own; only a key actually required by
-- the effective model catalog fails startup (validated elsewhere, §7.3).
module Hwfi.Runtime.KeyStore
  ( KeyStore,
    loadKeyStore,
    lookupKey,
    availableProviders,
  )
where

import Configuration.Dotenv qualified as Dotenv
import Control.Exception (SomeException, try)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Hwfi.Runtime.Provider
  ( ProviderName,
    allProviders,
    providerEnvVar,
  )
import Hwfi.Runtime.Secret (Secret, mkSecret)
import System.Directory (doesFileExist)
import System.Environment (getEnvironment)
import System.FilePath ((</>))

-- | Discovered provider keys. 'Ollama' never appears here (it needs no key).
newtype KeyStore = KeyStore (Map ProviderName (Secret Text))

-- | Build a 'KeyStore' by merging the three key sources with the precedence
-- documented above.
loadKeyStore ::
  -- | @--env-file@ path, if supplied.
  Maybe FilePath ->
  -- | Project directory (used to find @\<project>/.env@).
  FilePath ->
  IO KeyStore
loadKeyStore mEnvFile projectDir = do
  cliVars <- maybe (pure []) parseDotenv mEnvFile
  projectVars <- do
    let dotenvPath = projectDir </> ".env"
    exists <- doesFileExist dotenvPath
    if exists then parseDotenv dotenvPath else pure []
  processVars <- fmap (\(k, v) -> (T.pack k, T.pack v)) <$> getEnvironment
  -- 'Map.unions' is left-biased, so earlier (higher-precedence) sources win.
  let merged =
        Map.unions
          [ Map.fromList cliVars,
            Map.fromList projectVars,
            Map.fromList processVars
          ]
  pure . KeyStore . Map.fromList $
    mapMaybe (resolveProvider merged) allProviders

-- | For a provider that has an env-var name, look that var up in the merged
-- source map and, if found, produce a @(provider, secret)@ entry.
resolveProvider :: Map Text Text -> ProviderName -> Maybe (ProviderName, Secret Text)
resolveProvider merged provider = do
  envVar <- providerEnvVar provider
  value <- Map.lookup envVar merged
  pure (provider, mkSecret value)

-- | Parse a @.env@ file into text pairs. Parse/IO failures degrade to an
-- empty list rather than aborting: a malformed or unreadable optional
-- @.env@ must not crash startup before catalog validation runs.
parseDotenv :: FilePath -> IO [(Text, Text)]
parseDotenv path = do
  result <- try (Dotenv.parseFile path) :: IO (Either SomeException [(String, String)])
  pure $ case result of
    Left _ -> []
    Right pairs -> [(T.pack k, T.pack v) | (k, v) <- pairs]

-- | Look up a provider's key. The result stays wrapped in 'Secret'.
lookupKey :: ProviderName -> KeyStore -> Maybe (Secret Text)
lookupKey provider (KeyStore m) = Map.lookup provider m

-- | Providers for which a key was discovered.
availableProviders :: KeyStore -> [ProviderName]
availableProviders (KeyStore m) = Map.keys m
