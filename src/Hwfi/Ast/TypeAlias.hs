-- | Shared type-alias declarations (@types/*.md@). See spec §2.1.
module Hwfi.Ast.TypeAlias
  ( TypeAlias (..),
  )
where

import Hwfi.Ast.Name (QName)
import Hwfi.Ast.Type (TypeExpr)

-- | A parsed type-alias declaration. @taName@ is the file's qualified name
-- (path minus extension); @taDefinition@ is an unresolved 'TypeExpr' that
-- may reference other aliases by qname (resolved during type-checking).
data TypeAlias = TypeAlias
  { taName :: QName,
    taDefinition :: TypeExpr
  }
  deriving stock (Eq, Show)
