-- | The whole-project AST: the set of declarations keyed by qualified name.
-- See spec §2.
module Hwfi.Ast.Project
  ( Declaration (..),
    Prompt (..),
    declQName,
    declKind,
    DeclKind (..),
    Project (..),
  )
where

import Data.Map.Strict (Map)
import Hwfi.Ast.Name (QName)
import Hwfi.Ast.Tool (Tool (..))
import Hwfi.Ast.TypeAlias (TypeAlias (..))
import Hwfi.Ast.Workflow (Section, Workflow (..))
import Hwfi.Project.Manifest (ProjectManifest)

-- | A prompt-fragment declaration: a markdown file that contributes only
-- addressable sections (no steps, no typed signature). Referenced via
-- @\@self#slug@ within its own file (§3.2).
data Prompt = Prompt
  { promptName :: QName,
    promptSections :: [Section]
  }
  deriving stock (Eq, Show)

-- | One top-level declaration. Each project file holds exactly one (§2).
data Declaration
  = DeclWorkflow Workflow
  | DeclTool Tool
  | DeclTypeAlias TypeAlias
  | DeclPrompt Prompt
  deriving stock (Eq, Show)

-- | A coarse classification tag for a declaration.
data DeclKind = KindWorkflow | KindTool | KindTypeAlias | KindPrompt
  deriving stock (Eq, Show)

-- | The qualified name of a declaration.
declQName :: Declaration -> QName
declQName = \case
  DeclWorkflow w -> wfName w
  DeclTool t -> toolName t
  DeclTypeAlias a -> taName a
  DeclPrompt p -> promptName p

-- | The kind tag of a declaration.
declKind :: Declaration -> DeclKind
declKind = \case
  DeclWorkflow _ -> KindWorkflow
  DeclTool _ -> KindTool
  DeclTypeAlias _ -> KindTypeAlias
  DeclPrompt _ -> KindPrompt

-- | A fully parsed project: its manifest plus all declarations indexed by
-- qualified name.
data Project = Project
  { projManifest :: ProjectManifest,
    projDecls :: Map QName Declaration
  }
  deriving stock (Show)
