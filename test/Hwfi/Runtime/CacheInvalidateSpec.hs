module Hwfi.Runtime.CacheInvalidateSpec (spec) where

import Data.Aeson (object, (.=))
import Hwfi.Ast.Name (qnameFromText)
import Hwfi.Runtime.CacheInvalidate
  ( InvalidateFrom (..),
    invalidateCacheFrom,
    parseStepRef,
  )
import Hwfi.Runtime.RunStore
  ( cacheStepResult,
    createRunStore,
    lookupCachedResult,
    registerAgentSubCache,
  )
import Hwfi.Runtime.Trace (EventBody (..), TraceEvent (..))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = do
  describe "parseStepRef" $ do
    it "parses qname#step-id" $
      parseStepRef "workflows/main#read"
        `shouldBe` Right (qnameFromText "workflows/main", "read")

    it "rejects a missing step-id" $
      parseStepRef "workflows/main" `shouldSatisfy` (either (const True) (const False))

  describe "invalidateCacheFrom (§13.1.4)" $ do
    it "drops only the chosen suffix by step ref" $
      withSystemTempDirectory "hwfi-inv" $ \root -> do
        store <- createRunStore root "run-1"
        cacheStepResult store "key-a" (object ["n" .= (1 :: Int)])
        cacheStepResult store "key-b" (object ["n" .= (2 :: Int)])
        cacheStepResult store "key-c" (object ["n" .= (3 :: Int)])
        let events =
              [ TraceEvent 1 "t" (StepStart (qnameFromText "workflows/main") "a" (object []) True (Just "key-a")),
                TraceEvent 2 "t" (StepEnd (qnameFromText "workflows/main") "a" (object []) 1 (Just "key-a")),
                TraceEvent 3 "t" (StepStart (qnameFromText "workflows/main") "b" (object []) True (Just "key-b")),
                TraceEvent 4 "t" (StepEnd (qnameFromText "workflows/main") "b" (object []) 1 (Just "key-b")),
                TraceEvent 5 "t" (StepStart (qnameFromText "workflows/main") "c" (object []) True (Just "key-c")),
                TraceEvent 6 "t" (StepEnd (qnameFromText "workflows/main") "c" (object []) 1 (Just "key-c"))
              ]
        n <- invalidateCacheFrom store events (FromStepRef (qnameFromText "workflows/main") "b")
        n `shouldBe` Right 2
        lookupCachedResult store "key-a" `shouldReturn` Just (object ["n" .= (1 :: Int)])
        lookupCachedResult store "key-b" `shouldReturn` Nothing
        lookupCachedResult store "key-c" `shouldReturn` Nothing

    it "matches a step-key prefix from hwfi show" $
      withSystemTempDirectory "hwfi-inv" $ \root -> do
        store <- createRunStore root "run-1"
        let fullKey = "abcdef0123456789deadbeef0123456789abcdef0123456789abcdef01"
        cacheStepResult store fullKey (object ["ok" .= True])
        let events =
              [ TraceEvent 1 "t" (StepEnd (qnameFromText "workflows/main") "x" (object []) 1 (Just fullKey))
              ]
        n <- invalidateCacheFrom store events (FromStepKey "abcdef012345")
        n `shouldBe` Right 1
        lookupCachedResult store fullKey `shouldReturn` Nothing

    it "purges registered agent sub-keys from an agent step onward" $
      withSystemTempDirectory "hwfi-inv" $ \root -> do
        store <- createRunStore root "run-1"
        cacheStepResult store "upstream" (object ["n" .= (1 :: Int)])
        cacheStepResult store "agent-key" (object ["n" .= (2 :: Int)])
        cacheStepResult store "agent-sub-1" (object ["n" .= (3 :: Int)])
        registerAgentSubCache store "agent-key" "agent-sub-1"
        let events =
              [ TraceEvent 1 "t" (StepEnd (qnameFromText "workflows/main") "prep" (object []) 1 (Just "upstream")),
                TraceEvent 2 "t" (StepStart (qnameFromText "workflows/main") "agent" (object []) False (Just "agent-key")),
                TraceEvent 3 "t" (StepEnd (qnameFromText "workflows/main") "agent" (object []) 1 Nothing)
              ]
        n <- invalidateCacheFrom store events (FromStepRef (qnameFromText "workflows/main") "agent")
        n `shouldBe` Right 2
        lookupCachedResult store "upstream" `shouldReturn` Just (object ["n" .= (1 :: Int)])
        lookupCachedResult store "agent-key" `shouldReturn` Nothing
        lookupCachedResult store "agent-sub-1" `shouldReturn` Nothing
