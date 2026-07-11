-- | YAML frontmatter parsing (spec §3, §3.4). Produces a 'Signature' from a
-- workflow/tool file's frontmatter and exposes helpers used by the type-alias
-- parser and the project loader.
--
-- Type strings inside the YAML are parsed with the shared 'TypeExpr' parser
-- ('Hwfi.Parse.Type'), so alias references and nested types are handled
-- identically to the rest of the language.
module Hwfi.Parse.Frontmatter
  ( parseYamlObject,
    stringField,
    frontmatterKind,
    frontmatterName,
    parseSkillBlock,
    signatureFromYaml,
    locateValue,
  )
where

import Data.Aeson (Object, Value (..))
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.Foldable (toList)
import Data.List (findIndex, sortOn)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (encodeUtf8)
import Data.Yaml qualified as Yaml
import Hwfi.Ast.Name (qnameFromText)
import Hwfi.Ast.Skill (SkillKind (..), SkillMeta (..), parseSkillKind)
import Hwfi.Ast.Type (TypeExpr)
import Hwfi.Ast.Workflow (Signature (..))
import Hwfi.Parse.Type (parseTypeExprText)
import Hwfi.Source (Diagnostic (..), Pos (..))

-- | Decode frontmatter YAML into a top-level mapping.
parseYamlObject :: FilePath -> Text -> Either [Diagnostic] Object
parseYamlObject path yamlText =
  case Yaml.decodeEither' (encodeUtf8 yamlText) of
    Left err ->
      Left [diagAt path 1 ("invalid frontmatter YAML: " <> T.pack (Yaml.prettyPrintParseException err))]
    Right val -> case val of
      Object o -> Right o
      _ -> Left [diagAt path 1 "frontmatter must be a YAML mapping"]

-- | Read a string-valued field, if present and a string.
stringField :: Text -> Object -> Maybe Text
stringField key o = case KM.lookup (K.fromText key) o of
  Just (String s) -> Just s
  _ -> Nothing

-- | The @kind@ field, if present.
frontmatterKind :: Object -> Maybe Text
frontmatterKind = stringField "kind"

-- | The @name@ field, if present.
frontmatterName :: Object -> Maybe Text
frontmatterName = stringField "name"

-- | Parse the nested @skill:@ mapping. Missing @skill:@ defaults to callable.
parseSkillBlock :: FilePath -> Text -> Object -> Either [Diagnostic] SkillMeta
parseSkillBlock path yamlText o =
  case KM.lookup (K.fromText "skill") o of
    Nothing -> Right defaultMeta
    Just Null -> Right defaultMeta
    Just (Object skillObj) -> parseSkillObject skillObj
    Just _ -> Left [diagAt path 1 "skill must be a mapping"]
  where
    defaultMeta = SkillMeta SkillCallable Nothing []
    parseSkillObject skillObj = do
      kind <- parseKind skillObj
      let summary = stringField "summary" skillObj
      tags <- parseTags skillObj
      pure SkillMeta {smKind = kind, smSummary = summary, smTags = tags}
    parseKind skillObj =
      case stringField "kind" skillObj of
        Nothing -> Right SkillCallable
        Just k -> case parseSkillKind k of
          Just sk -> Right sk
          Nothing ->
            Left
              [ diagAt
                  path
                  (skillKeyLine "kind")
                  ("unknown skill kind '" <> k <> "' (expected 'callable' or 'instruction')")
              ]
    parseTags skillObj = case KM.lookup (K.fromText "tags") skillObj of
      Nothing -> Right []
      Just Null -> Right []
      Just (Array arr) -> Right [t | String t <- toList arr]
      Just _ -> Left [diagAt path (skillKeyLine "tags") "skill.tags must be a list of strings"]
    skillKeyLine k = posLine (locateNestedValue yamlText "skill" k)

-- | Build a 'Signature' from a workflow/tool frontmatter mapping. @yamlText@
-- is used to locate fields for diagnostics.
signatureFromYaml :: FilePath -> Text -> Object -> Either [Diagnostic] Signature
signatureFromYaml path yamlText o = do
  inputs <- typeMap "inputs"
  outputs <- typeMap "outputs"
  Signature inputs outputs <$> importList
  where
    typeMap :: Text -> Either [Diagnostic] [(Text, TypeExpr)]
    typeMap key = case KM.lookup (K.fromText key) o of
      Nothing -> Right []
      Just Null -> Right []
      Just (Object m) ->
        traverse parseEntry (sortOn fst [(K.toText k, v) | (k, v) <- KM.toList m])
      Just _ -> Left [diagAt path (keyLine key) (key <> " must be a mapping of name to type")]

    parseEntry (n, String tv) =
      case parseTypeExprText path (locateValue yamlText n) tv of
        Left ds -> Left ds
        Right t -> Right (n, t)
    parseEntry (n, _) =
      Left [diagAt path (keyLine n) ("type of '" <> n <> "' must be a string")]

    importList = case KM.lookup (K.fromText "imports") o of
      Nothing -> Right []
      Just Null -> Right []
      Just (Array arr) -> traverse parseImport (toList arr)
      Just _ -> Left [diagAt path (keyLine "imports") "imports must be a list of qualified names"]

    parseImport (String s) = Right (qnameFromText (T.strip s))
    parseImport _ = Left [diagAt path (keyLine "imports") "each import must be a string"]

    keyLine k = posLine (locateValue yamlText k)

-- | Locate the position of a key's /value/ within YAML text. The line is
-- absolute to the enclosing file (frontmatter opens on file line 1). Falls
-- back to @(1,1)@ if the key is not found.
locateValue :: Text -> Text -> Pos
locateValue yamlText key =
  case findIndex matches yamlLines of
    Nothing -> Pos 1 1
    Just i ->
      let line = yamlLines !! i
          indent = T.length line - T.length (T.stripStart line)
          afterKey = T.drop (T.length keyTok) (T.stripStart line)
          spaces = T.length afterKey - T.length (T.stripStart afterKey)
          valCol = indent + T.length keyTok + spaces + 1
       in Pos (i + 2) valCol
  where
    yamlLines = T.splitOn "\n" yamlText
    keyTok = key <> ":"
    matches l = keyTok `T.isPrefixOf` T.stripStart l

-- | Like 'locateValue' but for a nested key under a parent mapping key.
locateNestedValue :: Text -> Text -> Text -> Pos
locateNestedValue yamlText parent child =
  case findIndex ((parentTok `T.isPrefixOf`) . T.stripStart) yamlLines of
    Nothing -> Pos 1 1
    Just parentIx ->
      case findIndex matches (drop (parentIx + 1) yamlLines) of
        Nothing -> Pos (parentIx + 2) 1
        Just rel ->
          let i = parentIx + 1 + rel
              line = yamlLines !! i
              indent = T.length line - T.length (T.stripStart line)
              afterKey = T.drop (T.length childTok) (T.stripStart line)
              spaces = T.length afterKey - T.length (T.stripStart afterKey)
              valCol = indent + T.length childTok + spaces + 1
           in Pos (i + 2) valCol
  where
    yamlLines = T.splitOn "\n" yamlText
    parentTok = parent <> ":"
    childTok = child <> ":"
    matches l = childTok `T.isPrefixOf` T.stripStart l

diagAt :: FilePath -> Int -> Text -> Diagnostic
diagAt path line = Diagnostic path (Pos line 1) 1
