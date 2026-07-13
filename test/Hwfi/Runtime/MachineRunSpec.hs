module Hwfi.Runtime.MachineRunSpec where

import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Hwfi.Ast.Name (Ident, qnameFromText)
import Hwfi.Check (checkProject)
import Hwfi.Parse.Project (loadProject)
import Hwfi.Runtime.Executor (RunResult (..))
import Hwfi.Runtime.MachineRun (performContinueToEnd, performRun)
import Hwfi.Runtime.RunStore (hasMachineSnapshot, openRunStore, rsRunDir)
import Hwfi.Runtime.Value (RValue (..))
import Hwfi.Runtime.Workspace (newWorkspace, workspaceRoot)
import Hwfi.TypedProject (TypedProject)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec =
  describe "MachineRun (M4)" $ do
    it "persists machine.json on performRun" $
      withSystemTempDirectory "hwfi-m4-proj" $ \proj ->
        withSystemTempDirectory "hwfi-m4-ws" $ \ws -> do
          createDirectoryIfMissing True (proj </> "workflows")
          writeFile (proj </> "project.json") projectJson
          writeFile (proj </> "model-catalog.json") "[]\n"
          writeFile (proj </> "workflows" </> "main.md") mainMd
          writeFile (ws </> "input.txt") "hello"
          tp <- loadChecked proj
          workspace <- newWorkspace ws
          let runId = "m4-run"
              entry = qnameFromText "workflows/main"
          r1 <- performRun tp workspace Map.empty Map.empty proj runId entry inputs
          case r1 of
            Left err -> expectationFailure (T.unpack err)
            Right res
              | rrHalted res -> expectationFailure "expected completed run"
              | otherwise ->
                  case rrOutcome res of
                    Left e -> expectationFailure (show e)
                    Right (VRecord outs) ->
                      Map.lookup "content" outs `shouldBe` Just (VString "hello")
                    Right _ -> expectationFailure "unexpected output shape"
          eStore <- openRunStore (workspaceRoot workspace) runId
          case eStore of
            Left err -> expectationFailure (T.unpack err)
            Right store -> do
              hasMachineSnapshot store `shouldReturn` True
              doesFileExist (rsRunDir store </> "machine.json") `shouldReturn` True
              r2 <- performContinueToEnd tp workspace Map.empty Map.empty runId False
              case r2 of
                Left err -> err `shouldSatisfy` ("not resumable" `T.isInfixOf`)
                Right _ -> expectationFailure "completed run should not be continuable"

projectJson :: String
projectJson =
  unlines
    [ "{",
      "  \"name\": \"m4\",",
      "  \"version\": \"0.1.0\",",
      "  \"entrypoint\": \"workflows/main\",",
      "  \"env\": []",
      "}"
    ]

mainMd :: String
mainMd =
  unlines
    [ "---",
      "name: workflows/main",
      "inputs:",
      "  src: FileRef",
      "outputs:",
      "  content: String",
      "imports:",
      "  - builtin/read-file",
      "---",
      "",
      "## flow",
      "",
      "```step",
      "c <- builtin/read-file(path = ${inputs.src}) @read",
      "return { content = ${c.text} }",
      "```"
    ]

inputs :: Map.Map Ident RValue
inputs = Map.singleton "src" (VFileRef "input.txt")

loadChecked :: FilePath -> IO TypedProject
loadChecked dir = do
  eproj <- loadProject dir
  project <- case eproj of
    Left ds -> fail (show ds)
    Right p -> pure p
  case checkProject project of
    Left errs -> fail (show errs)
    Right tp -> pure tp
