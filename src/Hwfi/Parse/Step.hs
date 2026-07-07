-- | Parser for the step DSL: the contents of a @step@ fenced block
-- (spec §3.1, §3.4).
--
-- Statement-level tokens (binder, @<-@, target qname, @\@id@) are parsed with
-- the horizontal-only lexer so a newline terminates a statement; argument
-- lists and @return@ records switch to the newline-crossing lexer because
-- @()@/@{}@ may span lines (§3.4).
module Hwfi.Parse.Step
  ( stepBlock,
    parseStepBlock,
  )
where

import Data.Text (Text)
import Hwfi.Ast.Name (Ident)
import Hwfi.Ast.Step
import Hwfi.Parse.Expr (expr)
import Hwfi.Parse.Lexer
import Hwfi.Source (Diagnostic, Pos (..), spanFromTo)
import Text.Megaparsec hiding (Pos)
import Text.Megaparsec.Char (eol)
import Text.Megaparsec.Pos qualified as MP

-- | Parse the full contents of a @step@ block into a list of statements.
stepBlock :: Parser [Statement]
stepBlock = between scn eof (sepEndBy statement stmtSep)

-- | Parse a @step@ block from text, with positions made absolute to the
-- enclosing file via @pos@ (the position of the block's first content line).
parseStepBlock :: FilePath -> Pos -> Text -> Either [Diagnostic] [Statement]
parseStepBlock path pos input =
  case runParserAt stepBlock path pos input of
    Left bundle -> Left (bundleToDiagnostics bundle)
    Right stmts -> Right stmts

-- | Statement separator: at least one line break (optionally after a
-- trailing @--@ comment), then any further blank/comment lines.
stmtSep :: Parser ()
stmtSep = do
  sc
  _ <- optional lineComment
  _ <- eol
  scn

statement :: Parser Statement
statement = returnStmt <|> stepStmt

returnStmt :: Parser Statement
returnStmt = do
  start <- getPos
  _ <- lexeme (pKeyword "return")
  _ <- symbolN "{"
  fields <- sepEndBy field (symbolN ",")
  _ <- symbol "}"
  end <- getPos
  pure (SReturn fields (spanFromTo start end))
  where
    field = argField

stepStmt :: Parser Statement
stepStmt = do
  start <- getPos
  b <- binder
  _ <- symbol "<-"
  target <- lexeme pQNameRaw
  _ <- symbolN "("
  args <- sepEndBy argField (symbolN ",")
  _ <- symbol ")"
  mId <- optional stepIdP
  end <- getPos
  sid <- resolveStepId b mId
  pure (SStep (StepStmt b target args sid (spanFromTo start end)))

-- | Resolve the effective step id: an explicit @\@id@ wins; otherwise the
-- binder name is used. A discarding binder (@_@) must supply an explicit id
-- (§3.1).
resolveStepId :: Binder -> Maybe Ident -> Parser Ident
resolveStepId b mId =
  case mId of
    Just i -> pure i
    Nothing -> case b of
      BindName n -> pure n
      BindDiscard -> fail "a discarding step ('_ <- ...') requires an explicit '@id'"

binder :: Parser Binder
binder =
  (BindDiscard <$ lexeme (pKeyword "_"))
    <|> (BindName <$> lexeme pIdentRaw)

stepIdP :: Parser Ident
stepIdP = lexeme (single '@' *> pIdentRaw)

-- | A @key = expr@ field, used both for step arguments and @return@ records.
argField :: Parser Arg
argField = do
  start <- getPos
  n <- lexemeN pIdentRaw
  _ <- symbolN "="
  e <- expr
  end <- getPos
  pure (Arg n e (spanFromTo start end))

getPos :: Parser Pos
getPos = do
  sp <- getSourcePos
  pure (Pos (MP.unPos (MP.sourceLine sp)) (MP.unPos (MP.sourceColumn sp)))
