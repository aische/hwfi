-- | Command execution for @builtin/exec@ (spec §6.3, §7.5).
--
-- Runs an allowlisted external program in the workspace root as a child
-- process, capturing @stdout@\/@stderr@ and its exit code. The policy
-- (§7.5) is enforced here: only a bare-basename program present in
-- @project.json.exec.allow@ may run; the child receives only the environment
-- variables named in @exec.env@ (read from @hwfi@'s process environment,
-- never provider API keys); each call is bounded by a wall-clock timeout and
-- each captured stream truncated to @max_output_bytes@.
--
-- A non-zero exit is a /value/ (returned in 'eoExitCode'), not a run error, so
-- a workflow or agent can react to a failing build (§6.3). Only allowlist
-- violations and spawn failures are engine-level errors ('sandbox'\/'io').
--
-- v1 relies on the allowlist + empty-environment model rather than OS-level
-- containment (namespaces\/seccomp); see spec §7.5 for the documented limits.
module Hwfi.Runtime.Exec
  ( ExecArgs (..),
    ExecOutcome (..),
    runExec,
  )
where

import Control.Concurrent.STM (atomically)
import Control.Exception (IOException, try)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8With, encodeUtf8)
import Data.Text.Encoding.Error (lenientDecode)
import Hwfi.Project.Manifest (ExecPolicy (..))
import Hwfi.Runtime.Error (RuntimeError, ioError_, sandboxError)
import Hwfi.Runtime.Workspace (Workspace, workspaceRoot)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.Process.Typed
  ( byteStringInput,
    byteStringOutput,
    getStderr,
    getStdout,
    proc,
    setEnv,
    setStderr,
    setStdin,
    setStdout,
    setWorkingDir,
    waitExitCode,
    withProcessTerm,
  )
import System.Timeout (timeout)

-- | The resolved arguments of a @builtin/exec@ call (spec §6.3).
data ExecArgs = ExecArgs
  { eaProgram :: Text,
    eaArgs :: [Text],
    eaStdin :: Text,
    -- | Per-call timeout in ms; @<= 0@ means "use the policy default".
    eaTimeoutMs :: Int
  }
  deriving stock (Eq, Show)

-- | The captured outcome of an @exec@ call (spec §6.3). @eoStdoutBytes@\/
-- @eoStderrBytes@ are the post-truncation captured sizes recorded in the trace.
data ExecOutcome = ExecOutcome
  { eoExitCode :: Int,
    eoStdout :: Text,
    eoStderr :: Text,
    eoTimedOut :: Bool,
    eoStdoutBytes :: Int,
    eoStderrBytes :: Int
  }
  deriving stock (Eq, Show)

-- | Run an allowlisted command (spec §6.3, §7.5). Returns 'Left' only for
-- engine-level failures (program not a basename, not allowlisted, or spawn
-- failure); a non-zero or timed-out run is a successful 'Right' outcome.
runExec :: Workspace -> ExecPolicy -> ExecArgs -> IO (Either RuntimeError ExecOutcome)
runExec ws policy args
  | T.any (== '/') program =
      pure (Left (sandboxError ("exec 'program' must be a bare basename, not a path: '" <> program <> "'")))
  | program `notElem` execAllow policy =
      pure
        ( Left
            ( sandboxError
                ( "program '"
                    <> program
                    <> "' is not allowed by project.json exec.allow (§7.5)"
                )
            )
        )
  | otherwise = do
      childEnv <- currentEnvFor (execEnv policy)
      let micros = max 1 (effectiveTimeout * 1000)
          cfg =
            setStdin (byteStringInput (BSL.fromStrict (encodeUtf8 (eaStdin args))))
              . setStdout byteStringOutput
              . setStderr byteStringOutput
              . setWorkingDir (workspaceRoot ws)
              . setEnv [(T.unpack k, T.unpack v) | (k, v) <- childEnv]
              $ proc (T.unpack program) (map T.unpack (eaArgs args))
      result <-
        try (timeout micros (runIt cfg)) ::
          IO (Either IOException (Maybe (ExitCode, BSL.ByteString, BSL.ByteString)))
      pure $ case result of
        Left ex ->
          Left (ioError_ ("exec spawn failed for '" <> program <> "': " <> T.pack (show ex)))
        Right Nothing -> Right timedOutcome
        Right (Just (ec, out, err)) -> Right (mkOutcome ec out err)
  where
    program = eaProgram args
    cap = execMaxOutputBytes policy
    effectiveTimeout = if eaTimeoutMs args > 0 then eaTimeoutMs args else execTimeoutMs policy

    -- Read the whole conversation with the child: feed stdin, wait, then drain
    -- the fully-buffered output streams (they close when the process exits).
    runIt cfg = withProcessTerm cfg $ \p -> do
      ec <- waitExitCode p
      out <- atomically (getStdout p)
      err <- atomically (getStderr p)
      pure (ec, out, err)

    mkOutcome ec out err =
      let (outText, outBytes) = truncateStream cap out
          (errText, errBytes) = truncateStream cap err
       in ExecOutcome
            { eoExitCode = case ec of
                ExitSuccess -> 0
                ExitFailure n -> n,
              eoStdout = outText,
              eoStderr = errText,
              eoTimedOut = False,
              eoStdoutBytes = outBytes,
              eoStderrBytes = errBytes
            }

    -- A timed-out call: the process group was terminated; v1 does not recover
    -- partial output (spec §7.5 limitation). Exit code 124 mirrors @timeout(1)@.
    timedOutcome =
      ExecOutcome
        { eoExitCode = 124,
          eoStdout = "",
          eoStderr = "",
          eoTimedOut = True,
          eoStdoutBytes = 0,
          eoStderrBytes = 0
        }

-- | Truncate a captured stream to @cap@ bytes and decode leniently (a
-- truncation boundary may split a multi-byte character).
truncateStream :: Int -> BSL.ByteString -> (Text, Int)
truncateStream cap lbs =
  let bs = BS.take (max 0 cap) (BSL.toStrict lbs)
   in (decodeUtf8With lenientDecode bs, BS.length bs)

-- | Resolve the named environment variables from @hwfi@'s own process
-- environment, dropping any that are unset. Nothing else reaches the child.
currentEnvFor :: [Text] -> IO [(Text, Text)]
currentEnvFor names = do
  full <- getEnvironment
  let m = Map.fromList [(T.pack k, T.pack v) | (k, v) <- full]
  pure [(n, v) | n <- names, Just v <- [Map.lookup n m]]
