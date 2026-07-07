{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}

-- | Markdown structural parsing on top of @commonmark-hs@ (spec §2.1, §3).
--
-- Responsibilities:
--
--   * split off the leading YAML frontmatter (delimited by @---@ lines);
--   * parse the body with commonmark, capturing only what the engine needs —
--     H1–H6 headings and fenced @step@ code blocks — each with an absolute
--     source line;
--   * keep the original source lines so @\@self#slug@ raw content can be
--     sliced verbatim later ('Hwfi.Parse.Section').
--
-- To keep commonmark's source positions aligned with the original file, the
-- frontmatter region is blanked (replaced by empty lines) rather than
-- removed before the body is parsed.
module Hwfi.Parse.Markdown
  ( MarkdownFile (..),
    MdHeading (..),
    MdStepBlock (..),
    parseMarkdown,
    sliceLines,
  )
where

import Commonmark
  ( HasAttributes (..),
    IsBlock (..),
    IsInline (..),
    ParseError,
    Rangeable (..),
    SourceRange (..),
    commonmark,
    sourceColumn,
    sourceLine,
    sourceName,
  )
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Hwfi.Source (Diagnostic (..), Pos (..))
import Text.Parsec.Error (errorMessages, errorPos, messageString)

-- Custom commonmark targets -------------------------------------------------

-- | Inline content collapsed to its plain text (used for heading text only).
newtype Inlines = Inlines {inlineText :: Text}
  deriving stock (Show)
  deriving newtype (Semigroup, Monoid)

instance Rangeable Inlines where
  ranged _ = id

instance HasAttributes Inlines where
  addAttributes _ = id

instance IsInline Inlines where
  lineBreak = Inlines " "
  softBreak = Inlines " "
  str = Inlines
  entity = Inlines
  escapedChar c = Inlines (T.singleton c)
  emph = id
  strong = id
  link _ _ x = x
  image _ _ x = x
  code = Inlines
  rawInline _ = Inlines

-- | A single block we care about, carrying its source range.
data BlockItem
  = BHeading Int Text SourceRange
  | BCode Text Text SourceRange
  deriving stock (Show)

-- | The blocks we retain from a document; everything else collapses to
-- 'mempty'.
newtype Blocks = Blocks {blockItems :: [BlockItem]}
  deriving stock (Show)
  deriving newtype (Semigroup, Monoid)

instance Rangeable Blocks where
  ranged r (Blocks items) = Blocks (map setRange items)
    where
      setRange (BHeading l t _) = BHeading l t r
      setRange (BCode i c _) = BCode i c r

instance HasAttributes Blocks where
  addAttributes _ = id

instance IsBlock Inlines Blocks where
  paragraph _ = mempty
  plain _ = mempty
  thematicBreak = mempty
  blockQuote b = b
  codeBlock info content = Blocks [BCode info content (SourceRange [])]
  heading level il = Blocks [BHeading level (inlineText il) (SourceRange [])]
  rawBlock _ _ = mempty
  referenceLinkDefinition _ _ = mempty
  list _ _ bs = mconcat bs

-- Public API ----------------------------------------------------------------

-- | A heading with its (1-based) start and end source lines.
data MdHeading = MdHeading
  { mhLevel :: Int,
    mhText :: Text,
    mhStartLine :: Int,
    mhEndLine :: Int
  }
  deriving stock (Eq, Show)

-- | A fenced @step@ block. @msStartLine@ is the line of the block's first
-- /content/ line (the line after the opening fence), so the step DSL parser
-- can report absolute positions.
data MdStepBlock = MdStepBlock
  { msContent :: Text,
    msStartLine :: Int
  }
  deriving stock (Eq, Show)

-- | The structural parse of one markdown file.
data MarkdownFile = MarkdownFile
  { mdFrontmatter :: Maybe Text,
    mdHeadings :: [MdHeading],
    mdStepBlocks :: [MdStepBlock],
    mdSourceLines :: [Text]
  }
  deriving stock (Eq, Show)

-- | Parse a markdown file's structure.
parseMarkdown :: FilePath -> Text -> Either [Diagnostic] MarkdownFile
parseMarkdown path src =
  let srcLines = T.splitOn "\n" src
      (mfm, maskedBody) = splitFrontmatter srcLines
   in case commonmark path maskedBody :: Either ParseError Blocks of
        Left e -> Left [cmErrorToDiag path e]
        Right (Blocks items) ->
          Right
            MarkdownFile
              { mdFrontmatter = mfm,
                mdHeadings = mapMaybe toHeading items,
                mdStepBlocks = mapMaybe toStep items,
                mdSourceLines = srcLines
              }
  where
    toHeading (BHeading lvl txt r) = do
      sl <- rangeStartLine r
      let el = fromMaybe sl (rangeEndLine r)
      Just (MdHeading lvl (T.strip txt) sl el)
    toHeading _ = Nothing

    toStep (BCode info content r)
      | isStepInfo info = do
          fenceLine <- rangeStartLine r
          Just (MdStepBlock content (fenceLine + 1))
    toStep _ = Nothing

    isStepInfo info = case T.words (T.strip info) of
      ("step" : _) -> True
      _ -> False

-- | Split off leading @---@-delimited frontmatter, returning the YAML text
-- (if any) and a body text of identical line count with the frontmatter
-- region blanked out (to preserve absolute line numbers).
splitFrontmatter :: [Text] -> (Maybe Text, Text)
splitFrontmatter allLines =
  case allLines of
    (l0 : rest)
      | isFence l0 ->
          case break isFence rest of
            (fmLines, closeLine : bodyLines)
              | isFence closeLine ->
                  let blanks = replicate (length fmLines + 2) ""
                   in (Just (T.intercalate "\n" fmLines), T.intercalate "\n" (blanks <> bodyLines))
            _ -> (Nothing, T.intercalate "\n" allLines)
    _ -> (Nothing, T.intercalate "\n" allLines)
  where
    isFence l = T.strip l == "---"

-- | Slice a 1-based inclusive line range from source lines, joined by @\\n@.
-- Out-of-range endpoints are clamped.
sliceLines :: [Text] -> Int -> Int -> Text
sliceLines srcLines from to =
  T.intercalate "\n" (take (hi - lo + 1) (drop (lo - 1) srcLines))
  where
    lo = max 1 from
    hi = min (length srcLines) to

rangeStartLine :: SourceRange -> Maybe Int
rangeStartLine (SourceRange xs) = case xs of
  [] -> Nothing
  ((s, _) : _) -> Just (sourceLine s)

rangeEndLine :: SourceRange -> Maybe Int
rangeEndLine (SourceRange xs) = case xs of
  [] -> Nothing
  _ -> Just (sourceLine (snd (last xs)))

cmErrorToDiag :: FilePath -> ParseError -> Diagnostic
cmErrorToDiag path e =
  Diagnostic
    { diagPath = if null (sourceName pos) then path else sourceName pos,
      diagPos = Pos (sourceLine pos) (sourceColumn pos),
      diagWidth = 1,
      diagMessage = "markdown parse error: " <> msg
    }
  where
    pos = errorPos e
    msg =
      let parts = filter (not . null) (map messageString (errorMessages e))
       in if null parts then "invalid markdown" else T.pack (unwords parts)
