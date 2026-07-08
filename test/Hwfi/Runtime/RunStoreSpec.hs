module Hwfi.Runtime.RunStoreSpec (spec) where

import Data.Aeson (object, (.=))
import Data.Either (isLeft)
import Hwfi.Runtime.RunStore
  ( RunMeta (..),
    RunPhase (..),
    cacheStepResult,
    createRunStore,
    isResumable,
    lookupCachedResult,
    openRunStore,
    readRunMeta,
    updateRunPhase,
    withWorkspaceLock,
    writeRunMeta,
  )
import Hwfi.Runtime.RunUsage (emptyRunUsage)
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
import Control.Monad (join)

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

  describe "workspace lock (§12)" $ do
    it "grants the lock to a single holder" $
      withSystemTempDirectory "hwfi-rs" $ \root ->
        withWorkspaceLock root (pure (42 :: Int)) `shouldReturn` Right 42

    it "rejects a second concurrent holder" $
      withSystemTempDirectory "hwfi-rs" $ \root -> do
        outer <- withWorkspaceLock root $ do
          withWorkspaceLock root (pure ())
        join outer `shouldSatisfy` isLeft
