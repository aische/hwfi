-- | Parser for the step DSL: the contents of a @step@ fenced block
-- (spec §3.1, §3.4) plus the M8 control-flow constructs (§13): @if@\/@else@,
-- @foreach@, and @par@.
--
-- Statement-level tokens (binder, @<-@, target qname, @\@id@) are parsed with
-- the horizontal-only lexer so a newline terminates a statement; argument
-- lists, @return@ records, control-flow conditions\/lists, and brace-delimited
-- blocks switch to the newline-crossing lexer because they may span lines
-- (§3.4).
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
import Text.Megaparsec.Char.Lexer qualified as L
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
statement = returnStmt <|> bindingStmt

returnStmt :: Parser Statement
returnStmt = do
  start <- getPos
  _ <- lexeme (pKeyword "return")
  _ <- symbolN "{"
  fields <- sepEndBy argField (symbolN ",")
  _ <- symbol "}"
  end <- getPos
  pure (SReturn fields (spanFromTo start end))

-- | A binding statement: @binder \<- rhs \@id?@, where the right-hand side is a
-- call ('SStep'), an @if@ ('SIf'), or a @foreach@\/@par@ loop ('SLoop').
bindingStmt :: Parser Statement
bindingStmt = do
  start <- getPos
  b <- binder
  _ <- symbol "<-"
  choice [ifRhs start b, loopRhs start b, callRhs start b]

-- | A step call right-hand side: @target(args)@.
callRhs :: Pos -> Binder -> Parser Statement
callRhs start b = do
  target <- lexeme pQNameRaw
  _ <- symbolN "("
  args <- sepEndBy argField (symbolN ",")
  _ <- symbol ")"
  mId <- optional stepIdP
  end <- getPos
  sid <- resolveStepId b mId
  pure (SStep (StepStmt b target args sid (spanFromTo start end)))

-- | An @if \<cond> { … } else { … }@ right-hand side. The @else@ branch is
-- optional; whether it is required is a typing rule enforced by the checker.
ifRhs :: Pos -> Binder -> Parser Statement
ifRhs start b = do
  _ <- keyword "if"
  cond <- expr
  thenBlk <- block
  mElse <- optional (try (scn *> keyword "else") *> block)
  mId <- optional stepIdP
  end <- getPos
  sid <- resolveStepId b mId
  pure (SIf (IfStmt b cond thenBlk mElse sid (spanFromTo start end)))

-- | A @foreach v in \<list> { … }@ / @par v in \<list> { … }@ right-hand side.
loopRhs :: Pos -> Binder -> Parser Statement
loopRhs start b = do
  kind <- loopKindP
  var <- lexemeN pIdentRaw
  _ <- keyword "in"
  lst <- expr
  body <- block
  mId <- optional stepIdP
  end <- getPos
  sid <- resolveStepId b mId
  pure (SLoop (LoopStmt kind b var lst body sid (spanFromTo start end)))

loopKindP :: Parser LoopKind
loopKindP =
  (LoopSeq <$ keyword "foreach")
    <|> (LoopPar <$> (keyword "par" *> optional parMax))
  where
    parMax = between (symbolN "(") (symbolN ")") (keyword "max" *> symbolN "=" *> intLit)

-- | A brace-delimited block of statements. Newlines separate statements just
-- as in the enclosing step block; the block may be empty.
block :: Parser [Statement]
block = do
  _ <- symbolN "{"
  stmts <- sepEndBy statement stmtSep
  _ <- symbol "}"
  pure stmts

-- | Resolve the effective step id: an explicit @\@id@ wins; otherwise the
-- binder name is used. A discarding binder (@_@) must supply an explicit id
-- (§3.1).
resolveStepId :: Binder -> Maybe Ident -> Parser Ident
resolveStepId b mId =
  case mId of
    Just i -> pure i
    Nothing -> case b of
      BindName n -> pure n
      BindDiscard -> fail "a discarding statement ('_ <- ...') requires an explicit '@id'"

binder :: Parser Binder
binder =
  (BindDiscard <$ lexeme (pKeyword "_"))
    <|> (BindName <$> lexeme pIdentRaw)

stepIdP :: Parser Ident
stepIdP = lexeme (single '@' *> pIdentRaw)

-- | Match a keyword and consume trailing whitespace (including newlines), so a
-- condition\/list\/block may follow on the next line.
keyword :: Text -> Parser ()
keyword = lexemeN . pKeyword

intLit :: Parser Int
intLit = lexemeN L.decimal

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
