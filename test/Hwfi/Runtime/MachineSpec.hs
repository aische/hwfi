module Hwfi.Runtime.MachineSpec where

import Data.Aeson (Value (..), object)
import Data.Text qualified as T
import Data.Map.Strict qualified as Map
import Hwfi.Ast.Name (qnameFromText)
import Hwfi.Ast.Step (Binder (..), ParOnError (..))
import Hwfi.Check (checkProject)
import Hwfi.Parse.Project (loadProject)
import Hwfi.Runtime.Executor (projectContentHash)
import Hwfi.Runtime.Machine
import Hwfi.Runtime.MachinePath (StmtContext (..), advancePath, initialStmtPath, resolveStmtPath)
import Hwfi.Runtime.MachineSnapshot (decodeMachine, encodeMachine)
import Hwfi.Runtime.StepDriver (StepOutcome (..), pauseMachine, runMachine, stepMachine)
import Hwfi.Runtime.StepEnv (newStepEnv)
import Hwfi.Runtime.Value (RValue (..))
import Hwfi.Runtime.Workspace (newWorkspace)
import Hwfi.TypedProject (TypedProject)
import LLM.Core.Types (Turn (UserTurn))
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
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
        Right m' -> encodeMachine m' `shouldBe` encodeMachine m

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
        Right m' -> encodeMachine m' `shouldBe` encodeMachine m

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

  describe "StepDriver (M0/M1)" $ do
    it "moves CurReady to CurDispatch on the first step" $
      withSystemTempDirectory "hwfi-m0-ws" $ \ws -> do
        tp <- loadFixture
        workspace <- newWorkspace ws
        env <- newStepEnv tp workspace Map.empty "test" "workflows/main"
        let m0 = initialMachine "" (projectContentHash tp) (qnameFromText "workflows/main") Map.empty
        result <- stepMachine env m0
        case result of
          Left err -> expectationFailure (show err)
          Right (Stepped m1) -> m1.mCurrent `shouldSatisfy` isDispatch
          Right other -> expectationFailure ("unexpected outcome: " <> show other)

    it "pauseMachine sets explicit paused status" $ do
      let m = initialMachine "" "h" (qnameFromText "w") Map.empty
      pauseMachine m `shouldSatisfy` (\m' -> case mStatus m' of MsPaused PauseExplicit -> True; _ -> False)

  describe "StepDriver sequential (M1)" $ do
    it "runs the file-only fixture to completion" $
      withSystemTempDirectory "hwfi-m1-ws" $ \ws -> do
        tp <- loadChecked "test/fixtures/run/file-only"
        createDirectoryIfMissing True ws
        writeFile (ws </> "input.txt") "the source content"
        workspace <- newWorkspace ws
        env <- newStepEnv tp workspace Map.empty "m1-run" "workflows/main"
        let m0 =
              initialMachine
                ""
                (projectContentHash tp)
                (qnameFromText "workflows/main")
                ( Map.fromList
                    [ ("src", VFileRef "input.txt"),
                      ("dst", VFileRef "out.txt")
                    ]
                )
        result <- runMachine env m0
        case result of
          Left err -> expectationFailure (show err)
          Right (RunCompleted (VRecord outs)) ->
            Map.lookup "content" outs `shouldBe` Just (VString "the source content")
          Right other -> expectationFailure ("unexpected outcome: " <> show other)

loadFixture :: IO TypedProject
loadFixture = loadChecked "test/fixtures/check/ok"

loadChecked :: FilePath -> IO TypedProject
loadChecked dir = do
  eproj <- loadProject dir
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
