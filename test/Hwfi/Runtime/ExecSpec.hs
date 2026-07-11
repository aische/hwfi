module Hwfi.Runtime.ExecSpec (spec) where

import Control.Monad ((>=>))
import Data.Either (isLeft)
import Data.Text (Text)
import Data.Text qualified as T
import Hwfi.Project.Manifest (ExecPolicy (..), defaultExecMaxOutputBytes, defaultExecTimeoutMs)
import Hwfi.Runtime.Error (ErrorKind (..), reKind)
import Hwfi.Runtime.Exec (ExecArgs (..), ExecOutcome (..), runExec)
import Hwfi.Runtime.Workspace (Workspace, newWorkspace, readTextFile)
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

-- | A policy allowlisting @sh@\/@cat@\/@true@\/@false@ with PATH passed through
-- so the child can resolve the basenames.
policy :: [Text] -> ExecPolicy
policy allow =
  ExecPolicy
    { execAllow = allow,
      execEnv = ["PATH"],
      execTimeoutMs = defaultExecTimeoutMs,
      execMaxOutputBytes = defaultExecMaxOutputBytes
    }

withWs :: (Workspace -> IO a) -> IO a
withWs k = withSystemTempDirectory "hwfi-exec" (newWorkspace >=> k)

execArgs :: Text -> [Text] -> ExecArgs
execArgs program args = ExecArgs program args "" 0

spec :: Spec
spec = describe "builtin/exec runner (§6.3, §7.5)" $ do
  it "runs an allowlisted program and captures stdout + exit 0" $
    withWs $ \ws -> do
      r <- runExec ws (policy ["sh"]) (execArgs "sh" ["-c", "printf hello"])
      case r of
        Right o -> do
          eoExitCode o `shouldBe` 0
          eoStdout o `shouldBe` "hello"
          eoTimedOut o `shouldBe` False
        Left e -> expectationFailure ("expected success, got " <> show e)

  it "returns a non-zero exit as a value, not an error (A24)" $
    withWs $ \ws -> do
      r <- runExec ws (policy ["sh"]) (execArgs "sh" ["-c", "exit 3"])
      fmap eoExitCode r `shouldBe` Right 3

  it "rejects a program absent from the allowlist with a sandbox error" $
    withWs $ \ws -> do
      r <- runExec ws (policy ["cat"]) (execArgs "sh" ["-c", "echo no"])
      r `shouldSatisfy` isLeft
      either reKind (const KInternal) r `shouldBe` KSandbox

  it "rejects a program given as a path (not a bare basename)" $
    withWs $ \ws -> do
      r <- runExec ws (policy ["sh"]) (execArgs "/bin/sh" ["-c", "echo no"])
      either reKind (const KInternal) r `shouldBe` KSandbox

  it "feeds stdin to the child" $
    withWs $ \ws -> do
      r <- runExec ws (policy ["cat"]) (ExecArgs "cat" [] "piped-in" 0)
      fmap eoStdout r `shouldBe` Right "piped-in"

  it "runs in the workspace directory" $
    withWs $ \ws -> do
      r <- runExec ws (policy ["sh"]) (execArgs "sh" ["-c", "printf X > marker.txt"])
      fmap eoExitCode r `shouldBe` Right 0
      -- The marker landed in the workspace root, proving the child's cwd.
      readWs ws "marker.txt" `shouldReturn` "X"

  it "truncates captured output to max_output_bytes" $
    withWs $ \ws -> do
      let p = (policy ["sh"]) {execMaxOutputBytes = 4}
      r <- runExec ws p (execArgs "sh" ["-c", "printf 0123456789"])
      case r of
        Right o -> do
          eoStdoutBytes o `shouldBe` 4
          eoStdout o `shouldBe` "0123"
        Left e -> expectationFailure (show e)

  it "kills a command that exceeds its timeout and flags timed_out" $
    withWs $ \ws -> do
      r <- runExec ws (policy ["sh"]) (ExecArgs "sh" ["-c", "sleep 5"] "" 100)
      fmap eoTimedOut r `shouldBe` Right True

readWs :: Workspace -> FilePath -> IO Text
readWs ws rel = do
  r <- readTextFile ws (T.pack rel)
  pure (either (const "") fst r)
