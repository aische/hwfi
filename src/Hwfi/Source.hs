-- | Source positions, spans, and the diagnostic renderer used for all parse
-- and type errors. See spec §9.1.
--
-- The rendered form is copy-pasteable into an editor jump-to-location:
--
-- @
-- \<relative-path>:\<line>:\<col>: \<message>
--   |
-- N | \<source line>
--   |     ^^^^
-- @
module Hwfi.Source
  ( Pos (..),
    Span (..),
    spanFromTo,
    singletonSpan,
    Diagnostic (..),
    mkDiagnostic,
    renderDiagnostic,
    renderDiagnostics,
  )
where

import Data.Text (Text)
import Data.Text qualified as T

-- | A 1-based line/column position within a file.
data Pos = Pos
  { posLine :: !Int,
    posCol :: !Int
  }
  deriving stock (Eq, Ord, Show)

-- | A half-open-ish span; @spanEnd@ points just past the last character of
-- interest. For a single token, @spanEnd@ is on the same line one column
-- past the token's last character.
data Span = Span
  { spanStart :: !Pos,
    spanEnd :: !Pos
  }
  deriving stock (Eq, Ord, Show)

-- | Build a span from two positions.
spanFromTo :: Pos -> Pos -> Span
spanFromTo = Span

-- | A zero-width span at a single position (start == end).
singletonSpan :: Pos -> Span
singletonSpan p = Span p p

-- | A diagnostic: where the problem is and what it is. @diagWidth@ controls
-- the length of the caret underline (minimum 1).
data Diagnostic = Diagnostic
  { diagPath :: FilePath,
    diagPos :: !Pos,
    diagWidth :: !Int,
    diagMessage :: Text
  }
  deriving stock (Eq, Show)

-- | Convenience constructor spanning a single position (width 1).
mkDiagnostic :: FilePath -> Pos -> Text -> Diagnostic
mkDiagnostic path pos = Diagnostic path pos 1

-- | Render a single diagnostic in the spec §9.1 format. @src@ is the full
-- text of the offending file, used to quote the source line and draw the
-- caret. If the line is out of range the source-quote block is omitted.
renderDiagnostic :: Text -> Diagnostic -> Text
renderDiagnostic src Diagnostic {..} =
  T.intercalate "\n" (headerLine : quoteBlock)
  where
    Pos {posLine = line, posCol = col} = diagPos
    headerLine =
      T.pack diagPath
        <> ":"
        <> tshow line
        <> ":"
        <> tshow col
        <> ": "
        <> diagMessage
    srcLines = T.lines src
    quoteBlock =
      case lookupLine line srcLines of
        Nothing -> []
        Just lineText ->
          let gutter = T.replicate gutterWidth " "
              gutterWidth = T.length (tshow line)
              caretIndent = T.replicate (max 0 (col - 1)) " "
              caret = T.replicate (max 1 diagWidth) "^"
           in [ gutter <> " |",
                tshow line <> " | " <> lineText,
                gutter <> " | " <> caretIndent <> caret
              ]

-- | Render several diagnostics against the same source, blank-line separated.
renderDiagnostics :: Text -> [Diagnostic] -> Text
renderDiagnostics src = T.intercalate "\n\n" . map (renderDiagnostic src)

lookupLine :: Int -> [Text] -> Maybe Text
lookupLine n xs
  | n >= 1 && n <= length xs = Just (xs !! (n - 1))
  | otherwise = Nothing

tshow :: (Show a) => a -> Text
tshow = T.pack . show
