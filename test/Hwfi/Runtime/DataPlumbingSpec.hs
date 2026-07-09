{-# LANGUAGE OverloadedRecordDot #-}

module Hwfi.Runtime.DataPlumbingSpec (spec) where

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Hwfi.Ast.Name (Ident, QName, qnameFromText)
import Hwfi.Check.Builtins (jsonGetQName, jsonValuesQName)
import Hwfi.Project.Manifest (defaultSkillPolicy)
import Hwfi.Runtime.Builtins (BuiltinEnv (..), runBuiltin)
import Hwfi.Runtime.Error (StepRef (..), renderRuntimeError)
import Hwfi.Runtime.Gateways (ModelStore)
import Hwfi.Runtime.RunStore (createRunStore)
import Hwfi.Runtime.RunUsage (emptyRunUsage)
import Hwfi.Runtime.Trace (newTracer)
import Hwfi.Runtime.Usage (newUsageSeam)
import Hwfi.Runtime.Value (RValue (..))
import Hwfi.Runtime.Workspace (newWorkspace)
import Hwfi.SkillCatalog (emptySkillCatalog)
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = describe "data plumbing builtins (§13.1.2)" $ do
  describe "builtin/json-values" $ do
    it "collects object values in numeric key order and drops null" $
      withJsonValues $ \run -> do
        let plan =
              object
                [ "tasks"
                    .= object
                      [ "2" .= object ["id" .= ("c" :: Text)],
                        "0" .= object ["id" .= ("a" :: Text)],
                        "1" .= Null,
                        "3" .= object ["id" .= ("d" :: Text)]
                      ]
                ]
        result <- run plan "tasks"
        result
          `shouldBe`
            Right
              ( VBool True,
                VList
                  [ VJson (Object (KM.fromList [("id", String "a")])),
                    VJson (Object (KM.fromList [("id", String "c")])),
                    VJson (Object (KM.fromList [("id", String "d")]))
                  ],
                ""
              )

    it "collects array elements in order and drops null" $
      withJsonValues $ \run -> do
        let items = object ["items" .= Array (V.fromList [String "x", Null, String "y"])]
        result <- run items "items"
        result
          `shouldBe`
            Right (VBool True, VList [VJson (String "x"), VJson (String "y")], "")

    it "uses lexicographic key order when keys are not all integers" $
      withJsonValues $ \run -> do
        let tagged =
              object
                [ "tags"
                    .= object
                      [ "beta" .= String "b",
                        "alpha" .= String "a"
                      ]
                ]
        result <- run tagged "tags"
        result
          `shouldBe`
            Right (VBool True, VList [VJson (String "a"), VJson (String "b")], "")

    it "treats an empty path as the root value" $
      withJsonValues $ \run -> do
        let root = object ["0" .= String "a", "1" .= String "b"]
        result <- run root ""
        result
          `shouldBe`
            Right (VBool True, VList [VJson (String "a"), VJson (String "b")], "")

    it "returns ok=false when the path is missing" $
      withJsonValues $ \run -> do
        result <- run (object ["goal" .= String "x"]) "tasks"
        case result of
          Right (VBool False, VList [], err) -> err `shouldSatisfy` ("missing key" `T.isInfixOf`)
          other -> expectationFailure ("expected failure, got " <> show other)

    it "returns ok=false when the target is neither object nor array" $
      withJsonValues $ \run -> do
        result <- run (object ["goal" .= String "x"]) "goal"
        result
          `shouldBe`
            Right (VBool False, VList [], "expected a JSON object or array")

  describe "builtin/json-get" $ do
    it "still resolves dot-separated object paths" $
      withJsonGet $ \run -> do
        let root = object ["user" .= object ["name" .= String "Ada"]]
        result <- run root "user.name"
        result `shouldBe` Right (VBool True, VJson (String "Ada"), "")

type JsonValuesResult = (RValue, RValue, Text)

type JsonGetResult = (RValue, RValue, Text)

withJsonValues :: ((Value -> Text -> IO (Either Text JsonValuesResult)) -> IO a) -> IO a
withJsonValues body = withPlumbingHarness jsonValuesQName extractValues body

withJsonGet :: ((Value -> Text -> IO (Either Text JsonGetResult)) -> IO a) -> IO a
withJsonGet body = withPlumbingHarness jsonGetQName extractValue body

extractValues :: Map.Map Ident RValue -> Either Text JsonValuesResult
extractValues m =
  case (Map.lookup "ok" m, Map.lookup "values" m, Map.lookup "error" m) of
    (Just ok, Just values, Just (VString err)) -> Right (ok, values, err)
    _ -> Left "unexpected json-values result shape"

extractValue :: Map.Map Ident RValue -> Either Text JsonGetResult
extractValue m =
  case (Map.lookup "ok" m, Map.lookup "value" m, Map.lookup "error" m) of
    (Just ok, Just value, Just (VString err)) -> Right (ok, value, err)
    _ -> Left "unexpected json-get result shape"

withPlumbingHarness ::
  QName ->
  (Map.Map Ident RValue -> Either Text result) ->
  ((Value -> Text -> IO (Either Text result)) -> IO a) ->
  IO a
withPlumbingHarness q parseOut body =
  withSystemTempDirectory "hwfi-json-values" $ \dir -> do
    ws <- newWorkspace dir
    tracer <- newTracer
    store <- createRunStore dir "run-json"
    usageSeam <- newUsageSeam store Nothing emptyRunUsage
    let benv =
          BuiltinEnv
            { beWorkspace = ws,
              beModels = emptyModelStore,
              beTracer = tracer,
              beStep = StepRef (qnameFromText "tools/test") "step",
              beExecPolicy = Nothing,
              beUsage = usageSeam,
              beIntrospect = pure Null,
              beEvalWorkflow = Nothing,
              beRunId = "run-json",
              beSkillCatalog = emptySkillCatalog defaultSkillPolicy
            }
        run json path = do
          out <-
            runBuiltin
              benv
              q
              (Map.fromList [("json", VJson json), ("path", VString path)])
          case out of
            Left e -> pure (Left (renderRuntimeError e))
            Right (VRecord m) -> pure (parseOut m)
            Right other -> pure (Left ("unexpected result: " <> T.pack (show other)))
    body run

emptyModelStore :: ModelStore
emptyModelStore = Map.empty
