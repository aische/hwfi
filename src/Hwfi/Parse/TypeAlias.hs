-- | Type-alias file parsing (spec §2.1). A @types/*.md@ file declares a
-- single reusable type alias in its frontmatter.
module Hwfi.Parse.TypeAlias
  ( parseTypeAlias,
  )
where

import Data.Text (Text)
import Hwfi.Ast.Name (QName, renderQName)
import Hwfi.Ast.TypeAlias (TypeAlias (..))
import Hwfi.Parse.Frontmatter
  ( frontmatterKind,
    frontmatterName,
    locateValue,
    parseYamlObject,
    stringField,
  )
import Hwfi.Parse.Type (parseTypeExprText)
import Hwfi.Source (Diagnostic (..), Pos (..))

-- | Parse a type-alias file from its frontmatter YAML. @expectedName@ is the
-- qualified name derived from the file path; the declared @name@ must match
-- it (§2.1).
parseTypeAlias :: FilePath -> QName -> Text -> Either [Diagnostic] TypeAlias
parseTypeAlias path expectedName yamlText = do
  o <- parseYamlObject path yamlText
  case frontmatterKind o of
    Just "type-alias" -> Right ()
    Just other -> Left [diag ("expected kind 'type-alias', got '" <> other <> "'")]
    Nothing -> Left [diag "type-alias file must declare 'kind: type-alias'"]
  case frontmatterName o of
    Just n
      | n == renderQName expectedName -> Right ()
      | otherwise ->
          Left
            [ diagAt
                (locateValue yamlText "name")
                ("name '" <> n <> "' must equal the file's qualified name '" <> renderQName expectedName <> "'")
            ]
    Nothing -> Left [diag "type-alias file must declare 'name'"]
  case stringField "definition" o of
    Nothing -> Left [diag "type-alias file must declare a 'definition'"]
    Just def -> do
      t <- parseTypeExprText path (locateValue yamlText "definition") def
      Right (TypeAlias expectedName t)
  where
    diag = Diagnostic path (Pos 1 1) 1
    diagAt pos = Diagnostic path pos 1
