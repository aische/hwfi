-- | Skill metadata types shared by the parser, checker, and catalog (§6.6–§6.7).
module Hwfi.Ast.Skill
  ( SkillKind (..),
    SkillMeta (..),
    skillKindText,
    parseSkillKind,
  )
where

import Data.Text (Text)
import Data.Text qualified as T

-- | Callable tools vs prose-only instruction guides (§6.6.1).
data SkillKind = SkillCallable | SkillInstruction
  deriving stock (Eq, Show)

data SkillMeta = SkillMeta
  { smKind :: SkillKind,
    smSummary :: Maybe Text,
    smTags :: [Text]
  }
  deriving stock (Eq, Show)

skillKindText :: SkillKind -> Text
skillKindText = \case
  SkillCallable -> "callable"
  SkillInstruction -> "instruction"

parseSkillKind :: Text -> Maybe SkillKind
parseSkillKind t = case T.toLower (T.strip t) of
  "callable" -> Just SkillCallable
  "instruction" -> Just SkillInstruction
  _ -> Nothing
