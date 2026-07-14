-- | The checked-project artifact produced by 'Hwfi.Check.checkProject' and
-- consumed by the runtime (M4/M5). It carries the resolved signatures,
-- per-step static classifications (§8.1), and Merkle fingerprints (§8.1) for
-- trace metadata and callee-change detection at check time.
module Hwfi.TypedProject
  ( Fingerprint (..),
    ResolvedSignature (..),
    TypedStep (..),
    TypedDecl (..),
    TypedProject (..),
    lookupTyped,
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Hwfi.Ast.Name (Ident, QName)
import Hwfi.Ast.Project (Declaration)
import Hwfi.Ast.Step (StepStmt)
import Hwfi.Check.Error (CheckWarning)
import Hwfi.Project.Manifest (ProjectManifest)
import Hwfi.SkillCatalog (SkillCatalog)
import Hwfi.Type (Type)

-- | A declaration fingerprint: the hex-encoded SHA-256 Merkle hash over the
-- normalized AST and sorted callee fingerprints (§8.1).
newtype Fingerprint = Fingerprint Text
  deriving stock (Eq, Ord, Show)

-- | A workflow/tool signature with all 'TypeExpr's resolved to 'Type's
-- (aliases expanded, §2.1).
data ResolvedSignature = ResolvedSignature
  { rsigInputs :: [(Ident, Type)],
    rsigOutputs :: [(Ident, Type)],
    rsigImports :: [QName]
  }
  deriving stock (Eq, Show)

-- | A checked step statement with its static cache classification and the
-- fingerprint of its call target (for step-key hashing and trace metadata).
data TypedStep = TypedStep
  { tsStmt :: StepStmt,
    -- | Whether this step is cacheable (§8.1): 'False' if it references a
    -- volatile @ctx@ field or calls @builtin/introspect@.
    tsCacheable :: Bool,
    -- | The fingerprint of the step's call target, when it is statically
    -- known (a builtin or a declared workflow/tool). 'Nothing' when the
    -- target is a first-class @ToolRef@/@WorkflowRef@ value in scope, whose
    -- fingerprint is only determined at runtime from the resolved argument
    -- (§8.1).
    tsCalleeFingerprint :: Maybe Fingerprint,
    -- | The step's statically-inferred result type (the callee's outputs
    -- record).
    tsResultType :: Type
  }
  deriving stock (Eq, Show)

-- | A checked declaration: the original AST, its resolved signature, its
-- typed steps (empty for type aliases and prompts), and its fingerprint.
data TypedDecl = TypedDecl
  { tdDeclaration :: Declaration,
    tdSignature :: ResolvedSignature,
    tdSteps :: [TypedStep],
    tdFingerprint :: Fingerprint
  }
  deriving stock (Show)

-- | A fully type-checked project.
data TypedProject = TypedProject
  { tpManifest :: ProjectManifest,
    tpDecls :: Map QName TypedDecl,
    -- | Resolved type aliases (§2.1), retained for the runtime.
    tpAliases :: Map QName Type,
    -- | Skill catalog built at check time (§6.7).
    tpSkillCatalog :: SkillCatalog,
    -- | Non-fatal warnings (e.g. dynamic agent tool lists, §6.1.6).
    tpWarnings :: [CheckWarning]
  }
  deriving stock (Show)

-- | Look up a checked declaration by qualified name.
lookupTyped :: QName -> TypedProject -> Maybe TypedDecl
lookupTyped q = Map.lookup q . tpDecls
