module Hwfi.Runtime.DataPlumbingSpec (spec) where

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Hwfi.Ast.Name (Ident, QName, qnameFromText)
import Hwfi.Check.Builtins (jsonGetQName, jsonGetStringQName, jsonValuesQName, listUniqueByQName, recordFilterQName, recordMapQName, recordMergeQName)
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
          `shouldBe` Right
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
          `shouldBe` Right (VBool True, VList [VJson (String "x"), VJson (String "y")], "")

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
          `shouldBe` Right (VBool True, VList [VJson (String "a"), VJson (String "b")], "")

    it "treats an empty path as the root value" $
      withJsonValues $ \run -> do
        let root = object ["0" .= String "a", "1" .= String "b"]
        result <- run root ""
        result
          `shouldBe` Right (VBool True, VList [VJson (String "a"), VJson (String "b")], "")

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
          `shouldBe` Right (VBool False, VList [], "expected a JSON object or array")

  describe "builtin/json-get" $ do
    it "still resolves dot-separated object paths" $
      withJsonGet $ \run -> do
        let root = object ["user" .= object ["name" .= String "Ada"]]
        result <- run root "user.name"
        result `shouldBe` Right (VBool True, VJson (String "Ada"), "")

  describe "builtin/json-get-string" $ do
    it "returns a JSON string field as plain text" $
      withJsonGetString $ \run -> do
        let root = object ["mode" .= String "deterministic"]
        result <- run root "mode"
        result `shouldBe` Right (VBool True, VString "deterministic", "")

    it "returns ok=false when the target is not a string" $
      withJsonGetString $ \run -> do
        result <- run (object ["ok" .= Bool True]) "ok"
        result
          `shouldBe` Right (VBool False, VString "", "expected a JSON string")

  describe "record builtins" $ do
    it "record-merge overlays fields with overlay winning on duplicates" $
      withRecordMerge $ \run -> do
        let base = VRecord (Map.fromList [("a", VString "1"), ("b", VString "old")])
            overlay = VRecord (Map.fromList [("b", VString "new"), ("c", VString "3")])
        result <- run base overlay
        result
          `shouldBe` Right
            ( VRecord
                ( Map.fromList
                    [ ("a", VString "1"),
                      ("b", VString "new"),
                      ("c", VString "3")
                    ]
                )
            )

    it "record-filter keeps records whose field equals a value" $
      withRecordFilter $ \run -> do
        let items =
              VList
                [ VRecord (Map.fromList [("id", VString "a"), ("n", VInt 1)]),
                  VRecord (Map.fromList [("id", VString "b"), ("n", VInt 2)]),
                  VRecord (Map.fromList [("id", VString "c"), ("n", VInt 1)])
                ]
        result <- run items "n" (VInt 1)
        result
          `shouldBe` Right
            ( VList
                [ VRecord (Map.fromList [("id", VString "a"), ("n", VInt 1)]),
                  VRecord (Map.fromList [("id", VString "c"), ("n", VInt 1)])
                ]
            )

    it "record-filter supports dot-path field equality" $
      withRecordFilterPath $ \run -> do
        let items =
              VList
                [ VRecord
                    ( Map.fromList
                        [ ("location", VRecord (Map.fromList [("file", VString "a.md"), ("section", VString "flow")]))
                        ]
                    ),
                  VRecord
                    ( Map.fromList
                        [ ("location", VRecord (Map.fromList [("file", VString "b.md"), ("section", VString "flow")]))
                        ]
                    )
                ]
        result <- run items "location.file" (VString "a.md")
        result
          `shouldBe` Right
            ( VList
                [ VRecord
                    ( Map.fromList
                        [ ("location", VRecord (Map.fromList [("file", VString "a.md"), ("section", VString "flow")]))
                        ]
                    )
                ]
            )

    it "record-filter supports nested where records" $
      withRecordFilterWhere $ \run -> do
        let items =
              VList
                [ VRecord
                    ( Map.fromList
                        [ ("force", VString "directive"),
                          ("location", VRecord (Map.fromList [("file", VString "a.md"), ("section", VString "agent")]))
                        ]
                    ),
                  VRecord
                    ( Map.fromList
                        [ ("force", VString "assertive"),
                          ("location", VRecord (Map.fromList [("file", VString "a.md"), ("section", VString "agent")]))
                        ]
                    )
                ]
            whereClause =
              VRecord
                ( Map.fromList
                    [ ("force", VString "directive"),
                      ( "location",
                        VRecord (Map.fromList [("file", VString "a.md"), ("section", VString "agent")])
                      )
                    ]
                )
        result <- run items whereClause
        result
          `shouldBe` Right
            ( VList
                [ VRecord
                    ( Map.fromList
                        [ ("force", VString "directive"),
                          ("location", VRecord (Map.fromList [("file", VString "a.md"), ("section", VString "agent")]))
                        ]
                    )
                ]
            )

    it "list-unique-by deduplicates by field paths and caps results" $
      withListUniqueBy $ \run -> do
        let items =
              VList
                [ VRecord (Map.fromList [("slice_id", VString "a"), ("n", VInt 1)]),
                  VRecord (Map.fromList [("slice_id", VString "a"), ("n", VInt 2)]),
                  VRecord (Map.fromList [("slice_id", VString "b"), ("n", VInt 3)]),
                  VRecord (Map.fromList [("slice_id", VString "c"), ("n", VInt 4)])
                ]
        result <- run items ["slice_id"] 2
        result
          `shouldBe` Right
            ( VList
                [ VRecord (Map.fromList [("slice_id", VString "a"), ("n", VInt 1)]),
                  VRecord (Map.fromList [("slice_id", VString "b"), ("n", VInt 3)])
                ]
            )

    it "record-map plucks a field from each record" $
      withRecordMap $ \run -> do
        let items =
              VList
                [ VRecord (Map.fromList [("id", VString "a")]),
                  VRecord (Map.fromList [("id", VString "b")])
                ]
        result <- run items "id"
        result `shouldBe` Right (VList [VString "a", VString "b"])

type JsonValuesResult = (RValue, RValue, Text)

type JsonGetResult = (RValue, RValue, Text)

type JsonGetStringResult = (RValue, RValue, Text)

withJsonValues :: ((Value -> Text -> IO (Either Text JsonValuesResult)) -> IO a) -> IO a
withJsonValues = withPlumbingHarness jsonValuesQName extractValues

withJsonGet :: ((Value -> Text -> IO (Either Text JsonGetResult)) -> IO a) -> IO a
withJsonGet = withPlumbingHarness jsonGetQName extractValue

withJsonGetString :: ((Value -> Text -> IO (Either Text JsonGetStringResult)) -> IO a) -> IO a
withJsonGetString = withPlumbingHarness jsonGetStringQName extractString

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

extractString :: Map.Map Ident RValue -> Either Text JsonGetStringResult
extractString m =
  case (Map.lookup "ok" m, Map.lookup "text" m, Map.lookup "error" m) of
    (Just ok, Just text, Just (VString err)) -> Right (ok, text, err)
    _ -> Left "unexpected json-get-string result shape"

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

extractRecord :: Map.Map Ident RValue -> Either Text RValue
extractRecord m =
  case Map.lookup "record" m of
    Just v -> Right v
    _ -> Left "unexpected record-merge result shape"

extractItems :: Map.Map Ident RValue -> Either Text RValue
extractItems m =
  case Map.lookup "items" m of
    Just v -> Right v
    _ -> Left "unexpected record-filter result shape"

extractRecordValues :: Map.Map Ident RValue -> Either Text RValue
extractRecordValues m =
  case Map.lookup "values" m of
    Just v -> Right v
    _ -> Left "unexpected record-map result shape"

withRecordMerge :: ((RValue -> RValue -> IO (Either Text RValue)) -> IO a) -> IO a
withRecordMerge body = withRecordEnv recordMergeQName extractRecord $ \benv parseOut -> do
  let run base overlay = invokeRecord benv recordMergeQName parseOut (Map.fromList [("base", base), ("overlay", overlay)])
  body run

withRecordFilter :: ((RValue -> Text -> RValue -> IO (Either Text RValue)) -> IO a) -> IO a
withRecordFilter body = withRecordEnv recordFilterQName extractItems $ \benv parseOut -> do
  let run items field equals =
        invokeRecord
          benv
          recordFilterQName
          parseOut
          (Map.fromList [("items", items), ("field", VString field), ("equals", equals)])
  body run

withRecordFilterPath :: ((RValue -> Text -> RValue -> IO (Either Text RValue)) -> IO a) -> IO a
withRecordFilterPath = withRecordFilter

withRecordFilterWhere :: ((RValue -> RValue -> IO (Either Text RValue)) -> IO a) -> IO a
withRecordFilterWhere body = withRecordEnv recordFilterQName extractItems $ \benv parseOut -> do
  let run items whereClause =
        invokeRecord
          benv
          recordFilterQName
          parseOut
          (Map.fromList [("items", items), ("where", whereClause)])
  body run

withListUniqueBy :: ((RValue -> [Text] -> Int -> IO (Either Text RValue)) -> IO a) -> IO a
withListUniqueBy body = withRecordEnv listUniqueByQName extractItems $ \benv parseOut -> do
  let run items fields limit =
        invokeRecord
          benv
          listUniqueByQName
          parseOut
          (Map.fromList [("items", items), ("fields", VList (map VString fields)), ("limit", VInt (fromIntegral limit))])
  body run

withRecordMap :: ((RValue -> Text -> IO (Either Text RValue)) -> IO a) -> IO a
withRecordMap body = withRecordEnv recordMapQName extractRecordValues $ \benv parseOut -> do
  let run items field =
        invokeRecord benv recordMapQName parseOut (Map.fromList [("items", items), ("field", VString field)])
  body run

withRecordEnv ::
  QName ->
  (Map.Map Ident RValue -> Either Text RValue) ->
  (BuiltinEnv -> (Map.Map Ident RValue -> Either Text RValue) -> IO a) ->
  IO a
withRecordEnv _ parseOut body =
  withSystemTempDirectory "hwfi-record-plumbing" $ \dir -> do
    ws <- newWorkspace dir
    tracer <- newTracer
    store <- createRunStore dir "run-record"
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
              beRunId = "run-record",
              beSkillCatalog = emptySkillCatalog defaultSkillPolicy
            }
    body benv parseOut

invokeRecord ::
  BuiltinEnv ->
  QName ->
  (Map.Map Ident RValue -> Either Text RValue) ->
  Map.Map Ident RValue ->
  IO (Either Text RValue)
invokeRecord benv q parseOut args = do
  out <- runBuiltin benv q args
  case out of
    Left e -> pure (Left (renderRuntimeError e))
    Right (VRecord m) -> pure (parseOut m)
    Right other -> pure (Left ("unexpected result: " <> T.pack (show other)))
