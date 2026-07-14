-- | Pure qname mention extraction and catalog classification (§13.1.8 Tier 3).
module Hwfi.Text.QnameResolve
  ( MentionKind (..),
    QnameMention (..),
    renderMentionKind,
    resolveQnamesInText,
  )
where

import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Hwfi.Ast.Name (qnameFromText)
import Data.Maybe (fromMaybe)
import Hwfi.Check.Builtins (isBuiltin)
import Text.Regex.TDFA ((=~))

data MentionKind
  = MentionResolved
  | MentionUnresolved
  | MentionBuiltin
  | MentionAmbiguous
  deriving stock (Eq, Show)

data QnameMention = QnameMention
  { qmText :: !Text,
    qmKind :: !MentionKind,
    qmQname :: !Text
  }
  deriving stock (Eq, Show)

qnamePattern :: Text
qnamePattern = "(workflows|tools|skills|types|builtin)/[a-zA-Z0-9._-]+"

-- | Find qualified qname-like tokens in @text@ and classify them against
-- @catalog@. When @includeBuiltins@, shipped @builtin/*@ names classify as
-- 'MentionBuiltin'. When @unresolvedOnly@, omit resolved and builtin mentions.
-- When @excludeStepFences@, strip @```step@ fenced blocks before scanning.
resolveQnamesInText ::
  Text ->
  [Text] ->
  Bool ->
  Bool ->
  Bool ->
  [QnameMention]
resolveQnamesInText text catalog includeBuiltins unresolvedOnly excludeStepFences =
  filter keepKind (dedupeByQname (map classify (findMatches prepared)))
  where
    catalogSet = Set.fromList catalog
    prepared =
      if excludeStepFences
        then stripStepFences text
        else text
    keepKind m
      | unresolvedOnly = qmKind m `elem` [MentionUnresolved, MentionAmbiguous]
      | otherwise = True
    classify raw =
      let q = normalizeMentionQname raw
       in QnameMention
            { qmText = raw,
              qmQname = q,
              qmKind = mentionKind q catalogSet includeBuiltins
            }

normalizeMentionQname :: Text -> Text
normalizeMentionQname q = fromMaybe q (T.stripSuffix ".md" q)

mentionKind :: Text -> Set Text -> Bool -> MentionKind
mentionKind q catalogSet includeBuiltins
  | any (`Set.member` catalogSet) (qnameCandidates q) = MentionResolved
  | includeBuiltins, any isKnownBuiltin (qnameCandidates q) = MentionBuiltin
  | otherwise = MentionUnresolved

qnameCandidates :: Text -> [Text]
qnameCandidates q =
  case T.stripSuffix ".md" q of
    Nothing -> [q]
    Just stripped -> [q, stripped]

isKnownBuiltin :: Text -> Bool
isKnownBuiltin q = isBuiltin (qnameFromText q)

findMatches :: Text -> [Text]
findMatches text =
  [ T.pack (head m)
  | m <- T.unpack text =~ T.unpack qnamePattern,
    not (null m)
  ]

-- | Keep the first occurrence of each qname (stable order).
dedupeByQname :: [QnameMention] -> [QnameMention]
dedupeByQname = go Set.empty
  where
    go _ [] = []
    go seen (m : ms)
      | qmQname m `Set.member` seen = go seen ms
      | otherwise = m : go (Set.insert (qmQname m) seen) ms

stripStepFences :: Text -> Text
stripStepFences = T.unlines . skipStepBlocks . T.lines
  where
    skipStepBlocks [] = []
    skipStepBlocks ("```step" : rest) = skipStepBlocks (dropUntilFence rest)
    skipStepBlocks (l : ls) = l : skipStepBlocks ls
    dropUntilFence [] = []
    dropUntilFence ("```" : ls) = ls
    dropUntilFence (_ : ls) = dropUntilFence ls

renderMentionKind :: MentionKind -> Text
renderMentionKind = \case
  MentionResolved -> "resolved"
  MentionUnresolved -> "unresolved"
  MentionBuiltin -> "builtin"
  MentionAmbiguous -> "ambiguous"
