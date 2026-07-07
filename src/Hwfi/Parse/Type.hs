-- | Parser for the @TypeExpr@ grammar (spec §3.4). Shared by the frontmatter
-- signature parser and the type-alias parser.
--
-- Note the punctuation split (§3.4): record /types/ use @:@ between field and
-- type (@Record<{ name: String }>@), whereas record /values/ use @=@. This
-- parser only ever accepts @:@.
module Hwfi.Parse.Type
  ( typeExpr,
    topTypeExpr,
    parseTypeExprText,
  )
where

import Data.Text (Text)
import Hwfi.Ast.Name (QName)
import Hwfi.Ast.Type (TypeExpr (..))
import Hwfi.Parse.Lexer
import Hwfi.Source (Diagnostic, Pos (..))
import Text.Megaparsec hiding (Pos)

-- | Parse a single 'TypeExpr' (consumes trailing whitespace via its lexemes).
typeExpr :: Parser TypeExpr
typeExpr =
  choice
    [ pList,
      pSecret,
      pWorkflowRef,
      pToolRef,
      pRecord,
      pNullary,
      TAlias <$> pQName
    ]
    <?> "type expression"

-- | Full entry point: optional leading whitespace, a type, then end of input.
topTypeExpr :: Parser TypeExpr
topTypeExpr = scn *> typeExpr <* eof

-- | Parse a 'TypeExpr' from standalone text (e.g. a YAML value). @path@ and
-- @pos@ locate the text within its source file for diagnostics.
parseTypeExprText :: FilePath -> Pos -> Text -> Either [Diagnostic] TypeExpr
parseTypeExprText path pos input =
  case runParserAt topTypeExpr path pos input of
    Left bundle -> Left (bundleToDiagnostics bundle)
    Right t -> Right t

tkw :: Text -> Parser ()
tkw = lexemeN . pKeyword

pQName :: Parser QName
pQName = lexemeN pQNameRaw

angles :: Parser a -> Parser a
angles = between (symbolN "<") (symbolN ">")

pList :: Parser TypeExpr
pList = tkw "List" *> (TList <$> angles typeExpr)

pSecret :: Parser TypeExpr
pSecret = tkw "Secret" *> (TSecret <$> angles typeExpr)

pWorkflowRef :: Parser TypeExpr
pWorkflowRef =
  tkw "WorkflowRef" *> angles (TWorkflowRef <$> typeExpr <* symbolN "," <*> typeExpr)

pToolRef :: Parser TypeExpr
pToolRef =
  tkw "ToolRef" *> angles (TToolRef <$> typeExpr <* symbolN "," <*> typeExpr)

pRecord :: Parser TypeExpr
pRecord = do
  tkw "Record"
  _ <- symbolN "<"
  _ <- symbolN "{"
  fields <- sepBy recordField (symbolN ",")
  _ <- symbolN "}"
  _ <- symbolN ">"
  pure (TRecord fields)
  where
    recordField = do
      n <- lexemeN pIdentRaw
      _ <- symbolN ":"
      t <- typeExpr
      pure (n, t)

pNullary :: Parser TypeExpr
pNullary =
  choice
    [ TString <$ tkw "String",
      TInt <$ tkw "Int",
      TDouble <$ tkw "Double",
      TBool <$ tkw "Bool",
      TJson <$ tkw "Json",
      TBytes <$ tkw "Bytes",
      TFileRef <$ tkw "FileRef",
      TContext <$ tkw "Context",
      TTraceEvent <$ tkw "TraceEvent",
      TTrace <$ tkw "Trace"
    ]
