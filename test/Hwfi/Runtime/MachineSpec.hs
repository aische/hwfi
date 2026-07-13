module Hwfi.Runtime.MachineSpec where

import Data.Aeson (Value (..), object)
import Data.Text qualified as T
import Data.Map.Strict qualified as Map
import Hwfi.Ast.Name (qnameFromText)
import Hwfi.Ast.Step (Binder (..), ParOnError (..))
import Hwfi.Check (checkProject)
import Hwfi.Parse.Project (loadProject)
import Hwfi.Runtime.Machine
import Hwfi.Runtime.MachinePath (StmtContext (..), advancePath, initialStmtPath, resolveStmtPath)
import Hwfi.Runtime.MachineSnapshot (decodeMachine, encodeMachine)
import Hwfi.Runtime.StepDriver (StepOutcome (..), pauseMachine, stepMachine)
import Hwfi.Runtime.Value (RValue (..))
import Hwfi.TypedProject (TypedProject)
import LLM.Core.Types (Turn (UserTurn))
import Test.Hspec

spec :: Spec
spec = do
  describe "Machine snapshot (M0)" $ do
    it "round-trips a minimal running machine" $ do
      let m =
            initialMachine
              ""
              "abc123"
              (qnameFromText "workflows/main")
              Map.empty
      case decodeMachine (encodeMachine m) of
        Left err -> expectationFailure (T.unpack err)
        Right m' -> m' `shouldBe` m

    it "round-trips par and agent-heavy state" $ do
      let confirm =
            ConfirmRequest
              { crBranchIndex = Just 1,
                crQName = qnameFromText "builtin/exec",
                crStepId = "run",
                crTitle = "Run tests?",
                crDetail = object []
              }
          branch =
            initialMachine "loop#0/" "hash" (qnameFromText "workflows/inner") Map.empty
          par =
            ParJoinState
              { pjsLoopId = "items",
                pjsScope = "",
                pjsBinder = BindDiscard,
                pjsMaxConcurrency = 4,
                pjsOnError = ParOnErrorFail,
                pjsItems = [VJson (Number 1), VJson (Number 2)],
                pjsSlots = [ParSlotDone (VJson (Number 10)), ParSlotRunning],
                pjsActive = Map.singleton 1 (mkBranch branch),
                pjsNextIndex = 2,
                pjsPhase = ParDraining,
                pjsConfirmQueue = [confirm]
              }
          agent =
            AgentState
              { agStepRef = StepRef (qnameFromText "workflows/main") "agent",
                agPending =
                  PendingAgent
                    { paSystem = "sys",
                      paPrompt = "go",
                      paHistory = [UserTurn "hi"],
                      paToolRounds = [],
                      paActiveToolIds = ["builtin/read-file"],
                      paLoadedInstructionIds = []
                    },
                agRound = 2,
                agSubmitRequired = True
              }
          m =
            (initialMachine "" "hash" (qnameFromText "workflows/main") Map.empty)
              { mStatus = MsPaused (PauseAwaitingConfirm confirm),
                mCurrent = CurAgent agent,
                mFrames = [FrPar par]
              }
      case decodeMachine (encodeMachine m) of
        Left err -> expectationFailure (T.unpack err)
        Right m' -> m' `shouldBe` m

  describe "MachinePath (M0)" $ do
    it "resolves the first statement of a fixture workflow" $ do
      tp <- loadFixture
      case initialStmtPath tp (qnameFromText "workflows/main") of
        Left err -> expectationFailure (T.unpack err)
        Right path ->
          case resolveStmtPath tp path of
            Left err -> expectationFailure (T.unpack err)
            Right ctx -> scIndex ctx `shouldBe` 0

    it "advances to the next sibling index" $ do
      tp <- loadFixture
      path0 <- case initialStmtPath tp (qnameFromText "workflows/main") of
        Left err -> fail (T.unpack err)
        Right p -> pure p
      let path1 = advancePath path0
      case resolveStmtPath tp path1 of
        Left err -> expectationFailure (T.unpack err)
        Right ctx -> scIndex ctx `shouldBe` 1

  describe "StepDriver stub (M0)" $ do
    it "moves CurReady to CurDispatch on the first step" $ do
      tp <- loadFixture
      let m0 = initialMachine "" "hash" (qnameFromText "workflows/main") Map.empty
      result <- stepMachine tp m0
      case result of
        Left err -> expectationFailure (show err)
        Right (Stepped m1) -> m1.mCurrent `shouldSatisfy` isDispatch
        Right other -> expectationFailure ("unexpected outcome: " <> show other)

    it "pauseMachine sets explicit paused status" $ do
      let m = initialMachine "" "h" (qnameFromText "w") Map.empty
      pauseMachine m `shouldSatisfy` (\m' -> case mStatus m' of MsPaused PauseExplicit -> True; _ -> False)

loadFixture :: IO TypedProject
loadFixture = do
  eproj <- loadProject "test/fixtures/check/ok"
  project <- case eproj of
    Left ds -> fail (show ds)
    Right p -> pure p
  case checkProject project of
    Left errs -> fail (show errs)
    Right tp -> pure tp

isDispatch :: Current -> Bool
isDispatch = \case
  CurDispatch _ -> True
  _ -> False
