module Hwfi.Runtime.CheckProjectSpec (spec) where

import Data.Aeson (Value (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Hwfi.Ast.Name (qnameFromText)
import Hwfi.Check.Builtins (checkProjectQName)
import Hwfi.Project.Manifest (defaultSkillPolicy)
import Hwfi.Runtime.Builtins (BuiltinEnv (..), runBuiltin)
import Hwfi.Runtime.Error (StepRef (..))
import Hwfi.Runtime.Gateways (ModelStore)
import Hwfi.Runtime.RunStore (createRunStore)
import Hwfi.Runtime.RunUsage (emptyRunUsage)
import Hwfi.Runtime.Trace (newTracer)
import Hwfi.Runtime.Usage (newUsageSeam)
import Hwfi.Runtime.Value (RValue (..))
import Hwfi.Runtime.Workspace (Workspace, newWorkspace)
import Hwfi.SkillCatalog (emptySkillCatalog)
import System.Directory (getCurrentDirectory)
import System.FilePath ((</>))
import Test.Hspec

spec :: Spec
spec = describe "builtin/check-project (§13.1.8)" $ do
  it "returns ok=true and declaration metadata for a valid project" $
    withFixture "ok" $ \run -> do
      (ok, decls, errs) <- run "."
      ok `shouldBe` VBool True
      decls `shouldSatisfy` notNullList
      errs `shouldBe` VList []

  it "returns ok=false with errors for a type-mismatched project" $
    withFixture "type-mismatch" $ \run -> do
      (ok, _decls, errs) <- run "."
      ok `shouldBe` VBool False
      errs `shouldSatisfy` notNullList

type CheckProjectResult = (RValue, RValue, RValue)

withFixture :: FilePath -> ((Text -> IO CheckProjectResult) -> IO a) -> IO a
withFixture name body = do
  cwd <- getCurrentDirectory
  let fixtureDir = cwd </> "test/fixtures/check" </> name
  ws <- newWorkspace fixtureDir
  benv <- emptyBuiltinEnv fixtureDir ws
  let run path = do
        out <-
          runBuiltin
            benv
            checkProjectQName
            (Map.fromList [("path", VFileRef path)])
        case out of
          Right (VRecord m) -> extractResult m
          Right other -> fail ("unexpected result: " <> show other)
          Left e -> fail (show e)
  body run

emptyBuiltinEnv :: FilePath -> Workspace -> IO BuiltinEnv
emptyBuiltinEnv dir ws = do
  tracer <- newTracer
  store <- createRunStore dir "run-check-project"
  usageSeam <- newUsageSeam store Nothing emptyRunUsage
  pure
    BuiltinEnv
      { beWorkspace = ws,
        beModels = (emptyModelStore :: ModelStore),
        beTracer = tracer,
        beStep = StepRef (qnameFromText "tools/test") "step",
        beExecPolicy = Nothing,
        beUsage = usageSeam,
        beIntrospect = pure Null,
        beEvalWorkflow = Nothing,
        beRunId = "run-check-project",
        beSkillCatalog = emptySkillCatalog defaultSkillPolicy
      }

emptyModelStore :: ModelStore
emptyModelStore = Map.empty

extractResult :: Map.Map Text RValue -> IO CheckProjectResult
extractResult m =
  case (Map.lookup "ok" m, Map.lookup "declarations" m, Map.lookup "errors" m) of
    (Just ok, Just decls, Just errs) -> pure (ok, decls, errs)
    _ -> fail "unexpected check-project result shape"

notNullList :: RValue -> Bool
notNullList = \case
  VList xs -> not (null xs)
  _ -> False
