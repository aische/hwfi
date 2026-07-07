module Hwfi.CliSpec (spec) where

import Control.Exception (try)
import Hwfi.Cli (CheckOpts (..), runCheck)
import System.Exit (ExitCode (..))
import Test.Hspec

-- | Run @hwfi check@ over a fixture, capturing the exit behaviour. A
-- successful check returns @Right ()@ (no exit); any error raises an
-- 'ExitCode'.
runCheck' :: FilePath -> IO (Either ExitCode ())
runCheck' dir = try (runCheck (CheckOpts dir))

spec :: Spec
spec = describe "hwfi check (§9, A1/A2)" $ do
  it "exits 0 on a well-formed project" $ do
    r <- runCheck' "test/fixtures/check/ok"
    r `shouldBe` Right ()

  it "exits non-zero on a project with type errors" $ do
    r <- runCheck' "test/fixtures/check/type-mismatch"
    r `shouldBe` Left (ExitFailure 1)
