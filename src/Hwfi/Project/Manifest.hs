{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}
{-# HLINT ignore "Use bimap" #-}
-- | The @project.json@ manifest. See spec §2, §5.7, and §7.5.
module Hwfi.Project.Manifest
  ( ProjectManifest (..),
    ExecPolicy (..),
    BudgetPolicy (..),
    SkillPolicy (..),
    defaultSkillPolicy,
    budgetMaxCostUsd,
    defaultExecTimeoutMs,
    defaultExecMaxOutputBytes,
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

-- | The opt-in @exec@ policy governing @builtin/exec@ (spec §2, §6.3, §7.5).
-- Absent by default, in which case @builtin/exec@ is disabled entirely and any
-- call is rejected at @hwfi check@ (A24).
data ExecPolicy = ExecPolicy
  { -- | Whitelist of program /basenames/ (never paths) that @builtin/exec@ may
    -- run. An empty list disables @exec@ (fail-closed, §7.5).
    execAllow :: [Text],
    -- | Process environment variable names passed through to spawned commands
    -- (defaults to @[]@: the child otherwise gets an empty environment).
    execEnv :: [Text],
    -- | Default wall-clock timeout (ms) applied when a call omits its own.
    execTimeoutMs :: Int,
    -- | Cap on captured @stdout@\/@stderr@ per stream; output beyond it is
    -- truncated and flagged.
    execMaxOutputBytes :: Int
  }
  deriving stock (Eq, Show)

-- | Default @exec.timeout_ms@ when the policy omits it (spec §2).
defaultExecTimeoutMs :: Int
defaultExecTimeoutMs = 120000

-- | Default @exec.max_output_bytes@ when the policy omits it (spec §2).
defaultExecMaxOutputBytes :: Int
defaultExecMaxOutputBytes = 1048576

instance FromJSON ExecPolicy where
  parseJSON = withObject "ExecPolicy" $ \o ->
    ExecPolicy
      <$> o .:? "allow" .!= []
      <*> o .:? "env" .!= []
      <*> o .:? "timeout_ms" .!= defaultExecTimeoutMs
      <*> o .:? "max_output_bytes" .!= defaultExecMaxOutputBytes

-- | Optional spend ceiling for LLM provider calls (spec §8.4.6).
newtype BudgetPolicy = BudgetPolicy
  { bpMaxCostUsd :: Double
  }
  deriving stock (Eq, Show)

instance FromJSON BudgetPolicy where
  parseJSON = withObject "BudgetPolicy" $ \o ->
    BudgetPolicy <$> o .: "max_cost_usd"

-- | Optional @project.json@ @skills@ stanza limits (§6.7.3).
data SkillPolicy = SkillPolicy
  { spDirectory :: Text,
    spAllowOverwrite :: Bool,
    spMaxCallableLoads :: Int,
    spMaxInstructionLoads :: Int,
    spMaxInstructionChars :: Int
  }
  deriving stock (Eq, Show)

defaultSkillPolicy :: SkillPolicy
defaultSkillPolicy =
  SkillPolicy
    { spDirectory = "skills",
      spAllowOverwrite = False,
      spMaxCallableLoads = 8,
      spMaxInstructionLoads = 5,
      spMaxInstructionChars = 12000
    }

instance FromJSON SkillPolicy where
  parseJSON = withObject "SkillPolicy" $ \o ->
    SkillPolicy
      <$> o .:? "directory" .!= spDirectory defaultSkillPolicy
      <*> o .:? "allow_overwrite" .!= spAllowOverwrite defaultSkillPolicy
      <*> o .:? "max_callable_loads" .!= spMaxCallableLoads defaultSkillPolicy
      <*> o .:? "max_instruction_loads" .!= spMaxInstructionLoads defaultSkillPolicy
      <*> o .:? "max_instruction_chars" .!= spMaxInstructionChars defaultSkillPolicy

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
    envWhitelist :: [Text],
    -- | The opt-in @exec@ policy (spec §7.5). 'Nothing' disables @builtin/exec@.
    execPolicy :: Maybe ExecPolicy,
    -- | Optional LLM spend ceiling (spec §8.4.6).
    budgetPolicy :: Maybe BudgetPolicy,
    -- | Optional skill-loading policy (§6.7.3).
    pmSkills :: Maybe SkillPolicy
  }
  deriving stock (Eq, Show)

instance FromJSON ProjectManifest where
  parseJSON = withObject "ProjectManifest" $ \o ->
    ProjectManifest
      <$> o .: "name"
      <*> o .: "version"
      <*> o .: "entrypoint"
      <*> o .:? "env" .!= []
      <*> o .:? "exec"
      <*> o .:? "budget"
      <*> o .:? "skills"

-- | Resolve the optional budget ceiling from a manifest.
budgetMaxCostUsd :: ProjectManifest -> Maybe Double
budgetMaxCostUsd manifest = bpMaxCostUsd <$> budgetPolicy manifest

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
