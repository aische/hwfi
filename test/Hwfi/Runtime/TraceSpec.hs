module Hwfi.Runtime.TraceSpec (spec) where

import Data.Aeson (Value (..), object, (.=))
import Data.Text qualified as T
import Hwfi.Ast.Name (QName, qnameFromText)
import Hwfi.Runtime.Error (ErrorKind (..))
import Hwfi.Runtime.Trace
  ( EventBody (..),
    FileOp (..),
    RunStatus (..),
    TraceEvent (..),
    eventFromJson,
    eventToJson,
    renderEvent,
  )
import Test.Hspec

q :: EventBody -> TraceEvent
q = TraceEvent 3 "2026-07-07T10:20:30.500Z"

wf :: QName
wf = qnameFromText "workflows/main"

sampleEvents :: [TraceEvent]
sampleEvents =
  [ q (RunStart "run-1" "workflows/main" (object ["src" .= ("x" :: String)]) "deadbeef"),
    q (StepStart wf "c" (object ["path" .= ("in.txt" :: String)]) True),
    q (StepEnd wf "c" (object ["text" .= ("hi" :: String)]) 42),
    q (LlmCall wf "g" "gpt" "sys" "prompt" "response" 10 20 0.0012),
    q (FileIo wf "w" OpWrite "out.txt" 7),
    q (FileIo wf "l" OpList "dir" 0),
    q (ErrorEvent wf "x" "boom" KEval),
    q (AgentRoundStart wf "agent" 0),
    q (AgentToolCall wf "agent" 0 1 "tools/search" (object ["query" .= ("q" :: String)])),
    q (AgentToolResult wf "agent" 0 1 "tools/search" (object ["hits" .= (2 :: Int)]) False),
    q (AgentToolResult wf "agent" 1 0 "submit" (String "bad args") True),
    q (AgentRoundEnd wf "agent" 1 True),
    q (IfBranch wf "choose" "then"),
    q (IfBranch wf "choose" "none"),
    q (LoopStart wf "loop" "foreach" (Just 3)),
    q (LoopIter wf "loop" 2),
    q (LoopEnd wf "loop" 3),
    q (LoopStart wf "fan" "par" (Just 0)),
    q (LoopStart wf "refine" "while" Nothing),
    q (WhilePred wf "refine" 1 True "needs another pass"),
    q (TryBranch wf "safe" "try"),
    q (TryBranch wf "safe" "catch"),
    q (WorkflowLog wf "note" "checkpoint" (object ["n" .= (1 :: Int)])),
    q (Resumed "run-1" 12),
    q (RunEnd "run-1" Completed)
  ]

spec :: Spec
spec = describe "Trace JSON round-trip (§8.3)" $ do
  it "decodes every emitted variant back to the same event" $
    mapM_ (\e -> eventFromJson (eventToJson e) `shouldBe` Just e) sampleEvents

  it "round-trips a crashed run-end status" $
    eventFromJson (eventToJson (q (RunEnd "run-1" Crashed))) `shouldBe` Just (q (RunEnd "run-1" Crashed))

  it "rejects an object without a known tag" $
    eventFromJson (object ["seq" .= (0 :: Int), "at" .= ("t" :: String), "tag" .= ("nope" :: String)])
      `shouldBe` Nothing

  it "rejects a non-object" $
    eventFromJson (String "not an event") `shouldBe` Nothing

  it "renders a one-line summary carrying the qname and step id" $ do
    let line = renderEvent (q (StepStart wf "c" Null True))
    line `shouldSatisfy` T.isInfixOf "workflows/main#c"
    line `shouldSatisfy` T.isInfixOf "step-start"
