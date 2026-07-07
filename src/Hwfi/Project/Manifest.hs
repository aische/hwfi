-- | The @project.json@ manifest. See spec §2 and §5.7.
module Hwfi.Project.Manifest
  ( ProjectManifest (..),
    loadManifest,
    validateEnvPresence,
  )
where

import Data.Aeson (FromJSON (..), eitherDecodeFileStrict', withObject, (.!=), (.:), (.:?))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import System.Directory (doesFileExist)
import System.Environment (getEnvironment)
import System.FilePath ((</>))

-- | The parsed @project.json@ (v1 shape).
data ProjectManifest = ProjectManifest
  { -- | Project name.
    name :: Text,
    -- | Project version string.
    version :: Text,
    -- | Qualified name of the entry workflow, e.g. @workflows/main@.
    entrypoint :: Text,
    -- | Whitelist of process env vars readable via @ctx.env@ (defaults to
    -- @[]@). Provider API keys must /not/ be listed here (spec §7.2).
    envWhitelist :: [Text]
  }
  deriving stock (Eq, Show)

instance FromJSON ProjectManifest where
  parseJSON = withObject "ProjectManifest" $ \o ->
    ProjectManifest
      <$> o .: "name"
      <*> o .: "version"
      <*> o .: "entrypoint"
      <*> o .:? "env" .!= []

-- | Load and parse @\<project>/project.json@.
loadManifest :: FilePath -> IO (Either Text ProjectManifest)
loadManifest projectDir = do
  let path = projectDir </> "project.json"
  exists <- doesFileExist path
  if not exists
    then pure (Left ("error: project.json not found at " <> T.pack path))
    else do
      result <- eitherDecodeFileStrict' path
      pure $ case result of
        Left err -> Left ("error: could not parse project.json: " <> T.pack err)
        Right manifest -> Right manifest

-- | Enforce strict @env@ presence (spec §5.7, A14): every whitelisted
-- variable must be present in the process environment. Returns the list of
-- missing variable names on failure, or the resolved @name -> value@ map on
-- success. Ordering of the missing list follows the whitelist.
validateEnvPresence :: ProjectManifest -> IO (Either [Text] (Map Text Text))
validateEnvPresence manifest = do
  processEnv <- Map.fromList . fmap (\(k, v) -> (T.pack k, T.pack v)) <$> getEnvironment
  let lookups = [(var, Map.lookup var processEnv) | var <- manifest.envWhitelist]
      missing = [var | (var, Nothing) <- lookups]
      resolved = Map.fromList [(var, val) | (var, Just val) <- lookups]
  pure $
    if null missing
      then Right resolved
      else Left missing
