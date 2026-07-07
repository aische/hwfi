-- | Workflow declarations and the shared 'Signature' / 'Section' types.
-- See spec §3.
module Hwfi.Ast.Workflow
  ( Signature (..),
    emptySignature,
    Section (..),
    Workflow (..),
  )
where

import Hwfi.Ast.Name (Ident, QName, Slug)
import Hwfi.Ast.Step (Statement)
import Hwfi.Ast.Type (TypeExpr)
import Data.Text (Text)

-- | The typed frontmatter signature of a workflow or tool (§3, §3.4).
-- Field order for @inputs@/@outputs@ is preserved as parsed but is not
-- semantically significant (records compare structurally).
data Signature = Signature
  { sigInputs :: [(Ident, TypeExpr)],
    sigOutputs :: [(Ident, TypeExpr)],
    sigImports :: [QName]
  }
  deriving stock (Eq, Show)

-- | The empty signature (no inputs, outputs, or imports).
emptySignature :: Signature
emptySignature = Signature [] [] []

-- | A markdown H2/H3 section, addressable via @\@self#slug@ (§3.2, §3.4).
-- @secRaw@ is the verbatim source text under the heading, used as the value
-- of a matching @\@self#slug@ reference.
data Section = Section
  { secSlug :: Slug,
    secLevel :: Int,
    secHeadingText :: Text,
    secRaw :: Text
  }
  deriving stock (Eq, Show)

-- | A parsed workflow declaration.
data Workflow = Workflow
  { wfName :: QName,
    wfSignature :: Signature,
    wfStatements :: [Statement],
    wfSections :: [Section]
  }
  deriving stock (Eq, Show)
