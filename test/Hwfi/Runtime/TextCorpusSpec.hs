module Hwfi.Runtime.TextCorpusSpec (spec) where

import Data.Aeson (Value (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Hwfi.Ast.Name (Ident, QName, qnameFromText)
import Hwfi.Check.Builtins (splitTextQName, textGrepQName, textMetricsQName, textSearchCorpusQName, textSimilarityQName)
import Hwfi.Project.Manifest (defaultSkillPolicy)
import Hwfi.Runtime.Builtins (BuiltinEnv (..), runBuiltin)
import Hwfi.Runtime.Error (RuntimeError, StepRef (..))
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
spec = describe "Tier 2 text corpus builtins (§13.1.8)" $ do
  describe "builtin/text-metrics" $ do
    it "returns deterministic metrics for a string" $
      withHarness $ \run -> do
        result <-
          run
            textMetricsQName
            (Map.fromList [("text", VString "aa bb"), ("tokenize", VString "word")])
        case result of
          Right (VRecord m) -> do
            Map.lookup "chars" m `shouldBe` Just (VInt 5)
            Map.lookup "tokens" m `shouldBe` Just (VInt 2)
            Map.lookup "lines" m `shouldBe` Just (VInt 1)
            Map.lookup "paragraphs" m `shouldBe` Just (VInt 1)
            Map.lookup "shannon_entropy" m `shouldSatisfy` isDouble
            Map.lookup "compression_ratio" m `shouldSatisfy` isDouble
          other -> fail ("unexpected result: " <> show other)

  describe "builtin/text-similarity" $ do
    it "returns a jaccard score and token counts" $
      withHarness $ \run -> do
        result <-
          run
            textSimilarityQName
            ( Map.fromList
                [ ("left", VString "a b c"),
                  ("right", VString "b c d"),
                  ("method", VString "jaccard"),
                  ("ngram", VInt 1)
                ]
            )
        case result of
          Right (VRecord m) -> do
            Map.lookup "method" m `shouldBe` Just (VString "jaccard")
            Map.lookup "score" m `shouldSatisfy` isDouble
            Map.lookup "left_tokens" m `shouldBe` Just (VInt 3)
            Map.lookup "right_tokens" m `shouldBe` Just (VInt 3)
          other -> fail ("unexpected result: " <> show other)

  describe "builtin/split-text" $ do
    it "splits prose into sentences" $
      withHarness $ \run -> do
        result <-
          run
            splitTextQName
            ( Map.fromList
                [ ("text", VString "Do this. Then that!"),
                  ("max_chars", VInt 0),
                  ("overlap", VInt 0),
                  ("split_on", VString "sentence")
                ]
            )
        case result of
          Right (VRecord m) ->
            case Map.lookup "chunks" m of
              Just (VList [VString a, VString b]) -> do
                a `shouldBe` "Do this."
                b `shouldBe` "Then that!"
              other -> fail ("unexpected chunks: " <> show other)
          other -> fail ("unexpected result: " <> show other)

  describe "builtin/text-grep" $ do
    it "returns lines that match a regex pattern" $
      withHarness $ \run -> do
        result <-
          run
            textGrepQName
            ( Map.fromList
                [ ("text", VString "plain\nmust verify\nplain"),
                  ("pattern", VString "\\bmust\\b")
                ]
            )
        case result of
          Right (VRecord m) ->
            case Map.lookup "matches" m of
              Just (VList [VString line]) -> line `shouldBe` "must verify"
              other -> fail ("unexpected matches: " <> show other)
          other -> fail ("unexpected result: " <> show other)

  describe "builtin/text-search-corpus" $ do
    it "returns overlap clusters for similar documents" $
      withHarness $ \run -> do
        let docs =
              VList
                [ doc "a" "shared planner guidance",
                  doc "b" "shared planner notes",
                  doc "c" "different topic"
                ]
        result <-
          run
            textSearchCorpusQName
            ( Map.fromList
                [ ("documents", docs),
                  ("method", VString "jaccard"),
                  ("threshold", VDouble 0.2),
                  ("ngram", VInt 1)
                ]
            )
        case result of
          Right (VRecord m) ->
            case Map.lookup "clusters" m of
              Just (VList [VRecord cluster]) -> do
                Map.lookup "members" cluster `shouldSatisfy` membersContain "a"
                Map.lookup "members" cluster `shouldSatisfy` membersContain "b"
                case Map.lookup "span" cluster of
                  Just (VString shared) -> T.length shared `shouldSatisfy` (> 0)
                  _ -> fail "expected non-empty span"
              Just (VList xs) -> fail ("expected one cluster, got: " <> show xs)
              _ -> fail "missing clusters"
          other -> fail ("unexpected result: " <> show other)

withHarness ::
  ((QName -> Map.Map Ident RValue -> IO (Either RuntimeError RValue)) -> IO a) -> IO a
withHarness body =
  withSystemTempDirectory "hwfi-text-corpus" $ \dir -> do
    ws <- newWorkspace dir
    benv <- emptyBuiltinEnv dir ws
    let run q args = runBuiltin benv q args
    body run

emptyBuiltinEnv :: FilePath -> Workspace -> IO BuiltinEnv
emptyBuiltinEnv dir ws = do
  tracer <- newTracer
  store <- createRunStore dir "run-text-corpus"
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
        beRunId = "run-text-corpus",
        beSkillCatalog = emptySkillCatalog defaultSkillPolicy
      }

emptyModelStore :: ModelStore
emptyModelStore = Map.empty

doc :: Text -> Text -> RValue
doc i t =
  VRecord (Map.fromList [("id", VString i), ("text", VString t)])

isDouble :: Maybe RValue -> Bool
isDouble = \case
  Just (VDouble _) -> True
  _ -> False

membersContain :: Text -> Maybe RValue -> Bool
membersContain wanted = \case
  Just (VList xs) ->
    any
      ( \case
          VString s -> s == wanted
          _ -> False
      )
      xs
  _ -> False
