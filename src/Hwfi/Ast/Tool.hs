-- | Tool declarations. See spec §2 (@tools/@) and §6.
--
-- In v1 a user-defined tool file has the same structure as a workflow: a
-- typed frontmatter 'Signature' plus a @step@ body and addressable markdown
-- sections. It is kept as a distinct type from 'Hwfi.Ast.Workflow.Workflow'
-- so the checker and runtime can treat the two roles differently even though
-- their surface shape currently coincides. Engine-provided @builtin/*@ tools
-- are not files and are not represented here.
module Hwfi.Ast.Tool
  ( Tool (..),
  )
where

import Data.Text (Text)
import Hwfi.Ast.Name (QName)
import Hwfi.Ast.Step (Statement)
import Hwfi.Ast.Workflow (Section, Signature)
import Hwfi.Ast.Skill (SkillMeta)

-- | A parsed tool declaration.
data Tool = Tool
  { toolName :: QName,
    toolSignature :: Signature,
    toolStatements :: [Statement],
    toolSections :: [Section],
    -- | Optional @skill:@ metadata for files under @skills/@ (§6.6.1).
    toolSkillMeta :: Maybe SkillMeta,
    -- | Markdown body after frontmatter (for summary fallback).
    toolBodyPreview :: Maybe Text
  }
  deriving stock (Eq, Show)
