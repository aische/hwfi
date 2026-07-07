-- | A pure glob matcher for @builtin/find-files@ (spec §6.2). The effectful
-- directory walk lives in 'Hwfi.Runtime.Workspace'; this module owns only the
-- matching logic so it is unit-testable in isolation.
--
-- The pure algorithm is ported from @llm-simple@'s @LLM.Tools.FindFiles@ (spec
-- §6.2 permits reusing the pure matcher). Semantics:
--
--   * @**@ matches any number of path segments, including zero;
--   * @*@ matches any run of characters within one segment (never @/@);
--   * @?@ matches exactly one character within one segment;
--   * every other segment must match one path segment exactly.
module Hwfi.Runtime.Glob
  ( splitGlob,
    matchGlob,
    matchSegment,
  )
where

import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T

-- | Split a glob into path segments. A leading @./@ is dropped so callers can
-- write either @**/*.hs@ or @./**/*.hs@.
splitGlob :: Text -> [Text]
splitGlob pat =
  let stripped = fromMaybe pat (T.stripPrefix "./" pat)
   in filter (not . T.null) (T.splitOn "/" stripped)

-- | Match a list of glob segments against a list of path segments. @**@ may
-- match zero or more path segments; other segments each match exactly one via
-- 'matchSegment'.
matchGlob :: [Text] -> [Text] -> Bool
matchGlob [] [] = True
matchGlob [] _ = False
matchGlob ("**" : ps) ss =
  matchGlob ps ss
    || case ss of
      [] -> False
      (_ : rest) -> matchGlob ("**" : ps) rest
matchGlob _ [] = False
matchGlob (p : ps) (s : ss) = matchSegment (T.unpack p) (T.unpack s) && matchGlob ps ss

-- | Match a single glob segment (no @/@ on either side). Supports @*@ (any run
-- of characters, possibly empty) and @?@ (exactly one character).
matchSegment :: String -> String -> Bool
matchSegment [] [] = True
matchSegment ('*' : ps) ss =
  matchSegment ps ss
    || case ss of
      [] -> False
      (_ : rest) -> matchSegment ('*' : ps) rest
matchSegment ('?' : ps) (_ : ss) = matchSegment ps ss
matchSegment (p : ps) (s : ss) = p == s && matchSegment ps ss
matchSegment _ _ = False
