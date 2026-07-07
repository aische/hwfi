-- | Parser for the expression sub-language (spec §3.2, §3.4).
--
-- All expressions occur inside bracketed contexts (argument lists, list and
-- record literals), so the parser uses the newline-crossing lexer ('scn').
-- The bare-reference vs. interpolated-reference distinction (§3.2.1) is
-- preserved: @${x}@ as a whole expression becomes 'ERef', while @${x}@ inside
-- a string literal becomes an 'SInterp' part.
module Hwfi.Parse.Expr
  ( expr,
    refPath,
  )
where

import Data.Text (Text)
import Data.Text qualified as T
import Hwfi.Ast.Expr
import Hwfi.Ast.Name (Slug (..))
import Hwfi.Parse.Lexer
import Text.Megaparsec
import Text.Megaparsec.Char (hexDigitChar, string)

-- | Parse a single expression, consuming trailing whitespace.
expr :: Parser Expr
expr =
  choice
    [ EString <$> lexemeN stringLit,
      ERef <$> lexemeN refPath,
      eSelf,
      eNumber,
      eBoolNull,
      eList,
      eRecord,
      EQName <$> lexemeN pQNameRaw
    ]
    <?> "expression"

-- | A reference path @root(.field | [index])*@ (no internal whitespace).
refPath :: Parser RefPath
refPath = do
  _ <- string "${"
  root <- pIdentRaw
  accs <- many accessor
  _ <- single '}'
  pure (RefPath root accs)
  where
    accessor =
      (AField <$> (single '.' *> pIdentRaw))
        <|> (AIndex <$> (single '[' *> decimalInt <* single ']'))

decimalInt :: Parser Int
decimalInt = do
  ds <- takeWhile1P (Just "digit") isAsciiDigit
  pure (read (T.unpack ds))

eSelf :: Parser Expr
eSelf = lexemeN $ do
  _ <- string "@self#"
  s <- takeWhile1P (Just "slug character") isSlugChar
  pure (ESelf (Slug s))
  where
    isSlugChar c = isIdentStart c || isAsciiDigit c || c == '-' || c == '_'

eBoolNull :: Parser Expr
eBoolNull =
  lexemeN $
    choice
      [ EBool True <$ pKeyword "true",
        EBool False <$ pKeyword "false",
        ENull <$ pKeyword "null"
      ]

eNumber :: Parser Expr
eNumber = lexemeN $ do
  sign <- option "" (string "-")
  intPart <- takeWhile1P (Just "digit") isAsciiDigit
  mFrac <- optional $ do
    dot <- single '.'
    ds <- takeWhile1P (Just "digit") isAsciiDigit
    pure (T.cons dot ds)
  mExp <- optional expPart
  let txt = sign <> intPart <> maybe "" id mFrac <> maybe "" id mExp
  pure $ case (mFrac, mExp) of
    (Nothing, Nothing) -> EInt (read (T.unpack txt))
    _ -> EDouble (read (T.unpack txt))
  where
    expPart = do
      e <- oneOf ['e', 'E']
      s <- option "" (T.singleton <$> oneOf ['+', '-'])
      ds <- takeWhile1P (Just "digit") isAsciiDigit
      pure (T.cons e (s <> ds))

eList :: Parser Expr
eList = do
  _ <- symbolN "["
  es <- sepEndBy expr (symbolN ",")
  _ <- symbolN "]"
  pure (EList es)

eRecord :: Parser Expr
eRecord = do
  _ <- symbolN "{"
  fs <- sepEndBy recordField (symbolN ",")
  _ <- symbolN "}"
  pure (ERecord fs)
  where
    recordField = do
      n <- lexemeN pIdentRaw
      _ <- symbolN "="
      e <- expr
      pure (n, e)

-- String literals -----------------------------------------------------------

stringLit :: Parser [StringPart]
stringLit = longString <|> shortString

shortString :: Parser [StringPart]
shortString =
  single '"' *> (coalesce <$> manyTill shortUnit (single '"'))

longString :: Parser [StringPart]
longString =
  string "\"\"\"" *> (coalesce <$> manyTill longUnit (string "\"\"\""))

shortUnit :: Parser StringPart
shortUnit =
  choice
    [ SInterp <$> try refPath,
      SLit <$> escapeSeq,
      SLit "$" <$ single '$',
      SLit <$> takeWhile1P (Just "character") isShortOrdinary
    ]
  where
    isShortOrdinary c = c /= '"' && c /= '\\' && c /= '\n' && c /= '$'

longUnit :: Parser StringPart
longUnit =
  choice
    [ SInterp <$> try refPath,
      SLit <$> escapeSeq,
      SLit "$" <$ single '$',
      SLit "\"" <$ single '"',
      SLit <$> takeWhile1P (Just "character") isLongOrdinary
    ]
  where
    isLongOrdinary c = c /= '\\' && c /= '$' && c /= '"'

escapeSeq :: Parser Text
escapeSeq =
  single '\\'
    *> choice
      [ "\"" <$ single '"',
        "\\" <$ single '\\',
        "\n" <$ single 'n',
        "\r" <$ single 'r',
        "\t" <$ single 't',
        unicodeEscape
      ]
  where
    unicodeEscape = do
      _ <- single 'u'
      ds <- count 4 hexDigitChar
      pure (T.singleton (toEnum (read ("0x" <> ds))))

-- | Merge adjacent literal parts so a plain string is a single 'SLit'.
coalesce :: [StringPart] -> [StringPart]
coalesce = foldr step []
  where
    step (SLit a) (SLit b : rest) = SLit (a <> b) : rest
    step p rest = p : rest

isAsciiDigit :: Char -> Bool
isAsciiDigit c = c >= '0' && c <= '9'
