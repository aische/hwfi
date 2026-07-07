module Hwfi.Runtime.KeyStoreSpec (spec) where

import Hwfi.Runtime.KeyStore
import Hwfi.Runtime.Provider (ProviderName (..))
import Hwfi.Runtime.Secret (exposeSecret)
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

  describe "loadKeyStore robustness" $ do
    it "does not fail when <project>/.env is absent" $
      withSystemTempDirectory "hwfi-keystore" $ \dir -> do
        ks <- loadKeyStore Nothing dir
        -- Ollama never has a key, so it must never appear in the store.
        (Ollama `elem` availableProviders ks) `shouldBe` False
