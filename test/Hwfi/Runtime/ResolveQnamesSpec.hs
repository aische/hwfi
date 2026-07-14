module Hwfi.Runtime.ResolveQnamesSpec (spec) where

import Data.Aeson (Value (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Hwfi.Ast.Name (QName, qnameFromText)
import Hwfi.Check.Builtins (listConcatQName, resolveQnamesInTextQName)
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
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = describe "resolve-qnames / list-concat builtins" $ do
  it "resolve-qnames-in-text returns classified mentions" $
    withHarness $ \run -> do
      out <-
        run
          resolveQnamesInTextQName
          [ ("text", VString "workflows/main tools/missing"),
            ("catalog", VList [VString "workflows/main"]),
            ("include_builtins", VBool False),
            ("unresolved_only", VBool True),
            ("exclude_step_fences", VBool False)
          ]
      case out of
        VRecord fields -> do
          case Map.lookup "mentions" fields of
            Just (VList [one]) ->
              case one of
                VRecord m ->
                  Map.lookup "qname" m `shouldBe` Just (VString "tools/missing")
                _ -> expectationFailure "mention is not a record"
            _ -> expectationFailure "expected one mention"
        _ -> expectationFailure "expected record result"

  it "list-concat flattens nested lists" $
    withHarness $ \run -> do
      out <-
        run
          listConcatQName
          [ ("lists", VList [VList [VString "a"], VList [VString "b", VString "c"]])
          ]
      case out of
        VRecord fields ->
          Map.lookup "items" fields
            `shouldBe` Just (VList [VString "a", VString "b", VString "c"])
        _ -> expectationFailure "expected record result"

withHarness :: ((QName -> [(Text, RValue)] -> IO RValue) -> IO a) -> IO a
withHarness body =
  withSystemTempDirectory "hwfi-resolve-qnames" $ \dir -> do
    ws <- newWorkspace dir
    benv <- emptyBuiltinEnv dir ws
    let run q args = do
          result <- runBuiltin benv q (Map.fromList args)
          case result of
            Right v -> pure v
            Left e -> fail (show e)
    body run

emptyBuiltinEnv :: FilePath -> Workspace -> IO BuiltinEnv
emptyBuiltinEnv dir ws = do
  tracer <- newTracer
  store <- createRunStore dir "run-resolve-qnames"
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
        beRunId = "run-resolve-qnames",
        beSkillCatalog = emptySkillCatalog defaultSkillPolicy
      }

emptyModelStore :: ModelStore
emptyModelStore = Map.empty
