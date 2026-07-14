module Hwfi.Runtime.ParseMarkdownSpec (spec) where

import Data.Aeson (Value (..))
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Hwfi.Ast.Name (qnameFromText)
import Hwfi.Check.Builtins (parseMarkdownQName)
import Hwfi.Project.Manifest (defaultSkillPolicy)
import Hwfi.Runtime.Builtins (BuiltinEnv (..), runBuiltin)
import Hwfi.Runtime.Error (StepRef (..))
import Hwfi.Runtime.Gateways (ModelStore)
import Hwfi.Runtime.RunStore (createRunStore)
import Hwfi.Runtime.RunUsage (emptyRunUsage)
import Hwfi.Runtime.Trace (newTracer)
import Hwfi.Runtime.Usage (newUsageSeam)
import Hwfi.Runtime.Value (RValue (..))
import Hwfi.Runtime.Workspace (Workspace, newWorkspace, writeTextFile)
import Hwfi.SkillCatalog (emptySkillCatalog)
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

sampleMarkdown :: Text
sampleMarkdown =
  T.unlines
    [ "---",
      "title: demo",
      "tags: [a, b]",
      "---",
      "",
      "# Title",
      "",
      "Intro paragraph.",
      "",
      "## Section One",
      "",
      "Body text.",
      "",
      "```python",
      "print(\"hi\")",
      "```",
      "",
      "```step",
      "x <- workflows/main()",
      "```"
    ]

spec :: Spec
spec = describe "builtin/parse-markdown (§13.1.8)" $ do
  it "extracts frontmatter, sections, and fences" $
    withHarness $ \run -> do
      (ok, fm, sections, fences) <- run "doc.md" True True True
      ok `shouldBe` VBool True
      fm `shouldSatisfy` hasField "title"
      sections `shouldSatisfy` hasSection "section-one"
      fences `shouldSatisfy` hasFenceLang "python"

  it "omits sections when sections=false" $
    withHarness $ \run -> do
      (ok, _fm, sections, _fences) <- run "doc.md" False True True
      ok `shouldBe` VBool True
      sections `shouldBe` VList []

type ParseMarkdownResult = (RValue, RValue, RValue, RValue)

withHarness :: ((Text -> Bool -> Bool -> Bool -> IO ParseMarkdownResult) -> IO a) -> IO a
withHarness body =
  withSystemTempDirectory "hwfi-parse-markdown" $ \dir -> do
    ws <- newWorkspace dir
    _ <- writeTextFile ws "doc.md" sampleMarkdown
    benv <- emptyBuiltinEnv dir ws
    let run path wantSections wantFrontmatter wantFences = do
          out <-
            runBuiltin
              benv
              parseMarkdownQName
              ( Map.fromList
                  [ ("path", VFileRef path),
                    ("sections", VBool wantSections),
                    ("frontmatter", VBool wantFrontmatter),
                    ("fences", VBool wantFences)
                  ]
              )
          case out of
            Right (VRecord m) -> extractResult m
            Right other -> fail ("unexpected result: " <> show other)
            Left e -> fail (show e)
    body run

emptyBuiltinEnv :: FilePath -> Workspace -> IO BuiltinEnv
emptyBuiltinEnv dir ws = do
  tracer <- newTracer
  store <- createRunStore dir "run-parse-markdown"
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
        beRunId = "run-parse-markdown",
        beSkillCatalog = emptySkillCatalog defaultSkillPolicy
      }

emptyModelStore :: ModelStore
emptyModelStore = Map.empty

extractResult :: Map.Map Text RValue -> IO ParseMarkdownResult
extractResult m =
  case
    ( Map.lookup "ok" m,
      Map.lookup "frontmatter" m,
      Map.lookup "sections" m,
      Map.lookup "fences" m
    )
    of
      (Just ok, Just fm, Just sections, Just fences) -> pure (ok, fm, sections, fences)
      _ -> fail "unexpected parse-markdown result shape"

hasField :: Text -> RValue -> Bool
hasField key = \case
  VJson (Object o) ->
    case KM.lookup (K.fromText key) o of
      Just _ -> True
      Nothing -> False
  _ -> False

hasSection :: Text -> RValue -> Bool
hasSection slug = \case
  VList xs ->
    any
      ( \case
          VRecord m ->
            Map.lookup "slug" m == Just (VString slug)
          _ -> False
      )
      xs
  _ -> False

hasFenceLang :: Text -> RValue -> Bool
hasFenceLang lang = \case
  VList xs ->
    any
      ( \case
          VRecord m ->
            Map.lookup "lang" m == Just (VString lang)
          _ -> False
      )
      xs
  _ -> False
