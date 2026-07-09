-- | Instruction-only skill declarations (spec §6.6.1, §6.7).
module Hwfi.Ast.InstructionSkill
  ( InstructionSkill (..),
  )
where

import Data.Text (Text)
import Hwfi.Ast.Name (QName)
import Hwfi.Ast.Workflow (Section)

-- | A prose-only skill: no typed signature or executable steps.
data InstructionSkill = InstructionSkill
  { isName :: QName,
    isSummary :: Text,
    isTags :: [Text],
    isBody :: Text,
    isSections :: [Section]
  }
  deriving stock (Eq, Show)
