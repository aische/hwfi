-- | @builtin/parse-markdown@ — extract structure from a markdown file without
-- workflow-specific knowledge (§13.1.8).
module Hwfi.Runtime.ParseMarkdown
  ( runParseMarkdown,
  )
where

import Data.Aeson (Value (..), object)
import Data.Aeson.KeyMap qualified as KM
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Hwfi.Ast.Name (Ident)
import Hwfi.Parse.Frontmatter (parseYamlObject)
import Hwfi.Parse.Markdown (MarkdownFile (..), MdFence (..), parseMarkdown)
import Hwfi.Parse.Section (MarkdownSection (..), buildMarkdownSections)
import Hwfi.Runtime.Error (RuntimeError, evalError)
import Hwfi.Runtime.Value (RValue (..))
import Hwfi.Runtime.Workspace (Workspace, readTextFile)
import Hwfi.Source (renderDiagnostic)

runParseMarkdown :: Workspace -> Map Ident RValue -> IO (Either RuntimeError RValue)
runParseMarkdown ws args =
  case (Map.lookup "path" args >>= fileRefText, argBool args "sections", argBool args "frontmatter", argBool args "fences") of
    (Nothing, _, _, _) ->
      pure (Left (evalError "builtin/parse-markdown requires path: FileRef"))
    (Just _pathText, Left e, _, _) -> pure (Left e)
    (Just _pathText, _, Left e, _) -> pure (Left e)
    (Just _pathText, _, _, Left e) -> pure (Left e)
    (Just pathText, Right wantSections, Right wantFrontmatter, Right wantFences) ->
      readTextFile ws pathText >>= \case
        Left e -> pure (Left e)
        Right (text, _) ->
          case parseMarkdown (T.unpack pathText) text of
            Left ds ->
              pure
                ( Right
                    ( failureResult
                        (T.intercalate "\n" (map (renderDiagnostic text) ds))
                    )
                )
            Right md ->
              pure
                ( Right
                    ( record
                        [ ("ok", VBool True),
                          ("frontmatter", VJson (frontmatterJson md wantFrontmatter)),
                          ("sections", VList (if wantSections then sectionValues md else [])),
                          ("fences", VList (if wantFences then fenceValues md else [])),
                          ("error", VString "")
                        ]
                    )
                )
  where
    fileRefText (VFileRef t) = Just t
    fileRefText (VString t) = Just t
    fileRefText _ = Nothing

argBool :: Map Ident RValue -> Ident -> Either RuntimeError Bool
argBool args name = case Map.lookup name args of
  Just (VBool b) -> Right b
  Nothing -> Left (evalError ("builtin/parse-markdown requires " <> name <> ": Bool"))
  Just v -> Left (evalError ("argument '" <> name <> "' is not a boolean: " <> T.pack (show v)))

frontmatterJson :: MarkdownFile -> Bool -> Value
frontmatterJson md want =
  if not want
    then object []
    else case mdFrontmatter md of
      Nothing -> object []
      Just yamlText ->
        case parseYamlObject "frontmatter" yamlText of
          Left _ -> object []
          Right o -> Object o

sectionValues :: MarkdownFile -> [RValue]
sectionValues md =
  map sectionValue (buildMarkdownSections (mdSourceLines md) (mdHeadings md))

sectionValue :: MarkdownSection -> RValue
sectionValue MarkdownSection {..} =
  record
    [ ("level", VInt (fromIntegral msLevel)),
      ("title", VString msTitle),
      ("slug", VString msSlug),
      ("body", VString msBody)
    ]

fenceValues :: MarkdownFile -> [RValue]
fenceValues md =
  map
    ( \MdFence {..} ->
        record
          [ ("lang", VString mfLang),
            ("body", VString mfBody)
          ]
    )
    (mdFences md)

failureResult :: Text -> RValue
failureResult msg =
  record
    [ ("ok", VBool False),
      ("frontmatter", VJson (Object KM.empty)),
      ("sections", VList []),
      ("fences", VList []),
      ("error", VString msg)
    ]

record :: [(Ident, RValue)] -> RValue
record = VRecord . Map.fromList
