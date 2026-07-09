module Hwfi.Runtime.RunStoreSpec (spec) where

import Control.Monad (join)
import Data.Aeson (object, (.=))
import Data.Either (isLeft)
import Data.Text (Text)
import Data.Text qualified as T
import Hwfi.Runtime.RunStore
  ( RunMeta (..),
    RunPhase (..),
    RunSummary (..),
    cacheStepResult,
    createRunStore,
    isResumable,
    listRuns,
    lookupCachedResult,
    openRunStore,
    readRunMeta,
    readRunTrace,
    updateRunPhase,
    withWorkspaceLock,
    writeRunMeta,
  )
import Hwfi.Runtime.RunUsage (emptyRunUsage)
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

sampleMeta :: RunMeta
sampleMeta =
  RunMeta
    { rmRunId = "run-1",
      rmEntrypoint = "workflows/main",
      rmProjectDir = "/tmp/proj",
      rmStartedAt = "2026-07-07T00:00:00.000Z",
      rmProjectHash = "abc123",
      rmInputs = object ["src" .= ("in.txt" :: String)],
      rmPhase = PhaseRunning,
      rmUsage = emptyRunUsage
    }

spec :: Spec
spec = do
  describe "run.json (§8)" $ do
    it "round-trips run metadata" $
      withSystemTempDirectory "hwfi-rs" $ \root -> do
        store <- createRunStore root "run-1"
        writeRunMeta store sampleMeta
        readRunMeta store `shouldReturn` Right sampleMeta

    it "updates only the phase" $
      withSystemTempDirectory "hwfi-rs" $ \root -> do
        store <- createRunStore root "run-1"
        writeRunMeta store sampleMeta
        updateRunPhase store PhaseCompleted
        m <- readRunMeta store
        fmap rmPhase m `shouldBe` Right PhaseCompleted

    it "reports resumability by phase (§8.2)" $ do
      map isResumable [PhaseRunning, PhaseAborted, PhaseCrashed] `shouldBe` [True, True, True]
      isResumable PhaseCompleted `shouldBe` False

  describe "step result cache (§8.1)" $ do
    it "returns Nothing for an absent key" $
      withSystemTempDirectory "hwfi-rs" $ \root -> do
        store <- createRunStore root "run-1"
        lookupCachedResult store "missing" `shouldReturn` Nothing

    it "round-trips a cached result value" $
      withSystemTempDirectory "hwfi-rs" $ \root -> do
        store <- createRunStore root "run-1"
        let v = object ["text" .= ("hello" :: String)]
        cacheStepResult store "abc" v
        lookupCachedResult store "abc" `shouldReturn` Just v

  describe "openRunStore" $
    it "fails for a run directory that does not exist" $
      withSystemTempDirectory "hwfi-rs" $ \root ->
        openRunStore root "nope" >>= (`shouldSatisfy` isLeft)

  describe "cross-run helpers (§6.5)" $ do
    it "listRuns orders by started_at descending" $
      withSystemTempDirectory "hwfi-rs" $ \root -> do
        forMRuns root
        runs <- listRuns root 10
        map rsId runs `shouldBe` ["run-new", "run-mid", "run-old"]

    it "readRunTrace rejects invalid run_id" $
      withSystemTempDirectory "hwfi-rs" $ \root ->
        readRunTrace root "current" ".."
          >>= (`shouldSatisfy` \case
                Left err -> ".." `T.isInfixOf` err
                _ -> False)

  describe "workspace lock (§12)" $ do
    it "grants the lock to a single holder" $
      withSystemTempDirectory "hwfi-rs" $ \root ->
        withWorkspaceLock root (pure (42 :: Int)) `shouldReturn` Right 42

    it "rejects a second concurrent holder" $
      withSystemTempDirectory "hwfi-rs" $ \root -> do
        outer <- withWorkspaceLock root $ do
          withWorkspaceLock root (pure ())
        join outer `shouldSatisfy` isLeft

forMRuns :: FilePath -> IO ()
forMRuns root = do
  writeSample root "run-old" "2026-07-01T00:00:00.000Z" PhaseCompleted
  writeSample root "run-mid" "2026-07-02T00:00:00.000Z" PhaseAborted
  writeSample root "run-new" "2026-07-03T00:00:00.000Z" PhaseRunning

writeSample :: FilePath -> Text -> Text -> RunPhase -> IO ()
writeSample root runId startedAt phase = do
  store <- createRunStore root runId
  writeRunMeta
    store
    sampleMeta
      { rmRunId = runId,
        rmStartedAt = startedAt,
        rmPhase = phase
      }
