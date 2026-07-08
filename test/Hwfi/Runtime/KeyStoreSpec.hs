module Hwfi.Runtime.KeyStoreSpec (spec) where

import Control.Exception (bracket)
import Data.Maybe (isNothing)
import Hwfi.Runtime.KeyStore
import Hwfi.Runtime.Provider (ProviderName (..))
import Hwfi.Runtime.Secret (exposeSecret)
import System.Directory (createDirectoryIfMissing)
import System.Environment (getEnvironment, setEnv, unsetEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = do
  describe "loadKeyStore precedence" $ do
    it "prefers --env-file over <project>/.env" $
      withSystemTempDirectory "hwfi-keystore" $ \dir -> do
        writeFile (dir </> ".env") "OPENAI_API_KEY=from-project\n"
        let cliEnv = dir </> "cli.env"
        writeFile cliEnv "OPENAI_API_KEY=from-cli\n"
        ks <- loadKeyStore (Just cliEnv) dir
        fmap exposeSecret (lookupKey OpenAI ks) `shouldBe` Just "from-cli"

    it "reads <project>/.env when no --env-file is given" $
      withSystemTempDirectory "hwfi-keystore" $ \dir -> do
        writeFile (dir </> ".env") "CLAUDE_API_KEY=proj-claude\n"
        ks <- loadKeyStore Nothing dir
        fmap exposeSecret (lookupKey Claude ks) `shouldBe` Just "proj-claude"

    it "prefers <project>/.env over the user config .env" $
      withSystemTempDirectory "hwfi-keystore" $ \dir ->
        withXdgConfigHome dir $ do
          createDirectoryIfMissing True (dir </> "hwfi")
          writeFile (dir </> "hwfi" </> ".env") "OPENAI_API_KEY=from-user\n"
          writeFile (dir </> ".env") "OPENAI_API_KEY=from-project\n"
          ks <- loadKeyStore Nothing dir
          fmap exposeSecret (lookupKey OpenAI ks) `shouldBe` Just "from-project"

    it "prefers the process environment over the user config .env" $
      withSystemTempDirectory "hwfi-keystore" $ \dir ->
        withXdgConfigHome dir $
          withEnvVar "OPENAI_API_KEY" "from-process" $ do
            createDirectoryIfMissing True (dir </> "hwfi")
            writeFile (dir </> "hwfi" </> ".env") "OPENAI_API_KEY=from-user\n"
            ks <- loadKeyStore Nothing dir
            fmap exposeSecret (lookupKey OpenAI ks) `shouldBe` Just "from-process"

    it "reads $XDG_CONFIG_HOME/hwfi/.env when no higher source has the key" $
      withSystemTempDirectory "hwfi-keystore" $ \dir ->
        withXdgConfigHome dir $ do
          createDirectoryIfMissing True (dir </> "hwfi")
          writeFile (dir </> "hwfi" </> ".env") "GEMINI_API_KEY=user-gemini\n"
          ks <- loadKeyStore Nothing dir
          fmap exposeSecret (lookupKey Gemini ks) `shouldBe` Just "user-gemini"

  describe "loadKeyStore robustness" $ do
    it "does not fail when <project>/.env is absent" $
      withSystemTempDirectory "hwfi-keystore" $ \dir -> do
        ks <- loadKeyStore Nothing dir
        -- Ollama never has a key, so it must never appear in the store.
        (Ollama `elem` availableProviders ks) `shouldBe` False

    it "does not fail when the user config .env is absent" $
      withSystemTempDirectory "hwfi-keystore" $ \dir ->
        withXdgConfigHome dir $ do
          ks <- loadKeyStore Nothing dir
          isNothing (lookupKey OpenAI ks) `shouldBe` True

-- | Point @XDG_CONFIG_HOME@ at a temp directory for the duration of an action.
withXdgConfigHome :: FilePath -> IO a -> IO a
withXdgConfigHome dir action =
  bracket getXdg restore $ \_ -> do
    setEnv "XDG_CONFIG_HOME" dir
    action
  where
    getXdg = lookup "XDG_CONFIG_HOME" <$> getEnvironment
    restore (Just v) = setEnv "XDG_CONFIG_HOME" v
    restore Nothing = unsetEnv "XDG_CONFIG_HOME"

-- | Set a process environment variable for the duration of an action.
withEnvVar :: String -> String -> IO a -> IO a
withEnvVar name value action =
  bracket getVar restore $ \_ -> do
    setEnv name value
    action
  where
    getVar = lookup name <$> getEnvironment
    restore (Just v) = setEnv name v
    restore Nothing = unsetEnv name
