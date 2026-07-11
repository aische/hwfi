-- | Heading slug computation and @\@self#slug@ raw-content resolution
-- (spec §3.2, §3.4).
--
-- A slug is derived from an H2/H3 heading by lowercasing, replacing runs of
-- non-word characters with @-@, and trimming leading/trailing @-@. A
-- section's raw content is the verbatim source text from the line after the
-- heading up to (but excluding) the next heading of the same or higher level.
module Hwfi.Parse.Section
  ( computeSlug,
    buildSections,
    lookupSection,
    resolveSelf,
  )
where

import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.List (find)
import Data.Text (Text)
import Data.Text qualified as T
import Hwfi.Ast.Name (Slug (..), renderSlug)
import Hwfi.Ast.Workflow (Section (..))
import Hwfi.Parse.Markdown (MdHeading (..), sliceLines)

-- | Compute the slug for a heading's text (§3.4).
computeSlug :: Text -> Slug
computeSlug t = Slug collapsed
  where
    lowered = T.toLower t
    dashed = T.map (\c -> if isWordChar c then c else '-') lowered
    collapsed = T.intercalate "-" (filter (not . T.null) (T.splitOn "-" dashed))

isWordChar :: Char -> Bool
isWordChar c =
  isAsciiLower c
    || isAsciiUpper c
    || isDigit c
    || c == '_'

-- | Build the addressable H2/H3 sections of a file from its heading list and
-- source lines. A section ends at the next heading whose level is less than
-- or equal to its own (so an H2 section spans its nested H3 subsections).
buildSections :: [Text] -> [MdHeading] -> [Section]
buildSections srcLines headings =
  [ mkSection i h
    | (i, h) <- indexed,
      mhLevel h == 2 || mhLevel h == 3
  ]
  where
    indexed = zip [0 ..] headings
    total = length headings

    mkSection i h =
      Section
        { secSlug = computeSlug (mhText h),
          secLevel = mhLevel h,
          secHeadingText = mhText h,
          secRaw = T.strip (sliceLines srcLines contentStart contentEnd)
        }
      where
        contentStart = mhEndLine h + 1
        contentEnd = case laterSameOrHigher i h of
          (nh : _) -> mhStartLine nh - 1
          [] -> length srcLines

    laterSameOrHigher i h =
      [ headings !! j
        | j <- [i + 1 .. total - 1],
          mhLevel (headings !! j) <= mhLevel h
      ]

-- | Find a section by slug (case-insensitive, per §3.4).
lookupSection :: Slug -> [Section] -> Maybe Section
lookupSection (Slug wanted) =
  find (\sec -> T.toLower (renderSlug (secSlug sec)) == T.toLower wanted)

-- | Resolve a @\@self#slug@ reference to its raw section content.
resolveSelf :: Slug -> [Section] -> Maybe Text
resolveSelf slug sections = secRaw <$> lookupSection slug sections
