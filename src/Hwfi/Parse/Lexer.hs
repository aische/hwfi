-- | Shared megaparsec lexer for the step DSL, expression, and type-expression
-- parsers. See spec §3.4 (lexical rules).
--
-- Two space consumers are provided because newline handling differs by
-- context (§3.4):
--
--   * 'sc' consumes horizontal whitespace only — used /within/ a statement,
--     so a newline terminates the statement;
--   * 'scn' consumes horizontal whitespace, newlines, and @--@ line comments
--     — used inside brackets @()@, @[]@, @{}@ and between statements, where
--     newlines are insignificant.
module Hwfi.Parse.Lexer
  ( Parser,
    sc,
    scn,
    lineComment,
    lexeme,
    lexemeN,
    symbol,
    symbolN,
    reservedWords,
    isReserved,
    pIdentRaw,
    pQNameRaw,
    pKeyword,
    isIdentStart,
    isIdentCont,
    runParserAt,
    bundleToDiagnostics,
  )
where

import Control.Monad (void, when)
import Data.Char (isAsciiLower, isAsciiUpper)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Text (Text)
import Data.Text qualified as T
import Data.Void (Void)
import Hwfi.Ast.Name (QName (..))
import Hwfi.Source (Diagnostic (..), Pos (..))
import Text.Megaparsec hiding (Pos)
import Text.Megaparsec.Char (space1, string)
import Text.Megaparsec.Char.Lexer qualified as L

-- | The concrete parser monad: megaparsec over strict 'Text' with no custom
-- error component.
type Parser = Parsec Void Text

-- | Horizontal whitespace consumer (spaces and tabs only).
sc :: Parser ()
sc = L.space (void horizontalSpace) empty empty
  where
    horizontalSpace = takeWhile1P (Just "white space") (\c -> c == ' ' || c == '\t')

-- | Whitespace consumer that also crosses newlines and @--@ line comments.
scn :: Parser ()
scn = L.space space1 lineComment empty

-- | A @--@ line comment, up to (not including) the newline.
lineComment :: Parser ()
lineComment = L.skipLineComment "--"

-- | Wrap a parser as a lexeme, consuming trailing horizontal whitespace.
lexeme :: Parser a -> Parser a
lexeme = L.lexeme sc

-- | Wrap a parser as a lexeme, consuming trailing whitespace incl. newlines.
lexemeN :: Parser a -> Parser a
lexemeN = L.lexeme scn

-- | A fixed symbol token, consuming trailing horizontal whitespace.
symbol :: Text -> Parser Text
symbol = L.symbol sc

-- | A fixed symbol token, consuming trailing whitespace incl. newlines.
symbolN :: Text -> Parser Text
symbolN = L.symbol scn

-- | Reserved keywords that cannot be used as identifiers (§3.4, plus the M8
-- control-flow keywords, §13).
reservedWords :: [Text]
reservedWords =
  ["return", "true", "false", "null", "_", "if", "else", "foreach", "par", "while", "in"]

-- | Whether a word is reserved.
isReserved :: Text -> Bool
isReserved = (`elem` reservedWords)

-- | First-character predicate for identifiers (ASCII letter only, §3.4).
isIdentStart :: Char -> Bool
isIdentStart c = isAsciiUpper c || isAsciiLower c

-- | Continuation-character predicate for identifiers.
isIdentCont :: Char -> Bool
isIdentCont c = isIdentStart c || isAsciiDigit c || c == '-' || c == '_'

isAsciiDigit :: Char -> Bool
isAsciiDigit c = c >= '0' && c <= '9'

-- | Parse a bare identifier (no trailing whitespace consumed). Fails without
-- consuming input if the word is a reserved keyword.
pIdentRaw :: Parser Text
pIdentRaw = try $ do
  c <- satisfy isIdentStart <?> "identifier"
  cs <- takeWhileP Nothing isIdentCont
  let w = T.cons c cs
  when (isReserved w) (fail ("unexpected keyword " <> T.unpack w))
  pure w

-- | Parse a qualified name @seg("/"seg)*@ with no whitespace around the
-- separators (no trailing whitespace consumed).
pQNameRaw :: Parser QName
pQNameRaw = do
  s0 <- pIdentRaw
  ss <- many (single '/' *> pIdentRaw)
  pure (QName (s0 :| ss))

-- | Match a specific keyword, ensuring it is not a prefix of a longer
-- identifier (no trailing whitespace consumed).
pKeyword :: Text -> Parser ()
pKeyword kw = void $ try (string kw <* notFollowedBy (satisfy isIdentCont))

-- | Run a parser starting at a given source position (used to make
-- positions inside @step@ blocks absolute to the enclosing file).
runParserAt :: Parser a -> FilePath -> Pos -> Text -> Either (ParseErrorBundle Text Void) a
runParserAt p file (Pos line col) input =
  snd (runParser' p initialState)
  where
    initialState =
      State
        { stateInput = input,
          stateOffset = 0,
          statePosState =
            PosState
              { pstateInput = input,
                pstateOffset = 0,
                pstateSourcePos = SourcePos file (mkPos line) (mkPos col),
                pstateTabWidth = defaultTabWidth,
                pstateLinePrefix = ""
              },
          stateParseErrors = []
        }

-- | Convert a megaparsec error bundle into spec §9.1 diagnostics, one per
-- error, preserving the file path and source positions.
bundleToDiagnostics :: ParseErrorBundle Text Void -> [Diagnostic]
bundleToDiagnostics bundle =
  [toDiag e sp | (e, sp) <- NE.toList errsWithPos]
  where
    (errsWithPos, _) =
      attachSourcePos errorOffset (bundleErrors bundle) (bundlePosState bundle)
    toDiag e sp =
      Diagnostic
        { diagPath = sourceName sp,
          diagPos = Pos (unPos (sourceLine sp)) (unPos (sourceColumn sp)),
          diagWidth = 1,
          diagMessage = T.strip (T.pack (parseErrorTextPretty e))
        }
