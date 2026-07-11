-- | Type-check errors and their rendering to spec §9.1 diagnostics.
--
-- A 'TypeError' carries a machine-inspectable 'TypeErrorKind' (so tests can
-- assert /what/ went wrong without matching on message text) alongside a
-- fully-rendered human message and a source location. 'renderTypeError'
-- turns it into the same 'Diagnostic' used by the parser, so @hwfi check@
-- prints parse and type errors uniformly.
module Hwfi.Check.Error
  ( TypeError (..),
    TypeErrorKind (..),
    typeError,
    renderTypeError,
    renderTypeErrors,
    CheckWarning (..),
    checkWarning,
    renderCheckWarning,
    renderCheckWarnings,
  )
where

import Data.Text (Text)
import Hwfi.Source (Diagnostic (..), Pos (..))

-- | A coarse classification of a type error, for testing and grouping.
data TypeErrorKind
  = -- | A step target does not resolve to a known workflow, tool, builtin,
    -- or in-scope ref value (§5.6.1).
    UndeclaredTarget
  | -- | A @${...}@ reference does not resolve in the binding environment
    -- (§5.6.3).
    UndeclaredRef
  | -- | A value's type does not match the expected type (§5.6.2/§5.6.3).
    TypeMismatch
  | -- | Two step statements bind the same name, or a bind shadows a reserved
    -- root (@inputs@/@ctx@) (§3.4, no shadowing).
    DuplicateBind
  | -- | A required argument is missing, or an unexpected argument is given
    -- (§5.6.2).
    ArgMismatch
  | -- | Field access on a record names a field that does not exist (§5.6.7).
    UnknownField
  | -- | Indexing a non-list value, or field access on a non-record value.
    BadAccess
  | -- | A type alias reference does not resolve to a @type-alias@ declaration
    -- (§2.1).
    UnknownAlias
  | -- | A cycle among type aliases (§2.1/A10).
    CyclicAlias
  | -- | A cycle in the direct call graph across workflows/tools (§5.6.6/A2).
    ImportCycle
  | -- | An import entry names a declaration that does not exist.
    UnknownImport
  | -- | A @return@ block is required but absent, or present when @outputs@ is
    -- empty (§5.6.5).
    ReturnRule
  | -- | The @return@ value (explicit or implicit) does not match @outputs@
    -- (§5.6.5).
    ReturnMismatch
  | -- | A @\@self#slug@ reference names a heading that does not exist (§5.6.4).
    SelfNotFound
  | -- | A @Secret<_>@ value is used in a string-interpolation position (§5.5).
    SecretInterp
  | -- | A @Bytes@ value is used in a string-interpolation position (§3.2.1).
    BytesInterp
  | -- | A bare qname is used where a @ToolRef@/@WorkflowRef@ value is not
    -- expected (§3.2).
    BadQNameValue
  | -- | The project's @entrypoint@ does not name a declared workflow (§2).
    BadEntrypoint
  | -- | A @builtin/exec@ call is not permitted by the @project.json@ @exec@
    -- policy: no policy is declared, or the (literal) program is not in
    -- @exec.allow@ (§6.3, §7.5, A24). A @sandbox@-category check error.
    ExecPolicyViolation
  deriving stock (Eq, Show)

-- | A type-check error.
data TypeError = TypeError
  { errPath :: FilePath,
    errPos :: !Pos,
    errWidth :: !Int,
    errKind :: TypeErrorKind,
    errMessage :: Text
  }
  deriving stock (Eq, Show)

-- | Construct a 'TypeError' with a caret width of 1.
typeError :: FilePath -> Pos -> TypeErrorKind -> Text -> TypeError
typeError path pos = TypeError path pos 1

-- | Render a 'TypeError' as a 'Diagnostic' (spec §9.1).
renderTypeError :: TypeError -> Diagnostic
renderTypeError TypeError {..} = Diagnostic errPath errPos errWidth errMessage

-- | A non-fatal check warning (spec §6.1.6 phase 2).
data CheckWarning = CheckWarning
  { warnPath :: FilePath,
    warnPos :: !Pos,
    warnMessage :: Text
  }
  deriving stock (Eq, Show)

checkWarning :: FilePath -> Pos -> Text -> CheckWarning
checkWarning = CheckWarning

renderCheckWarning :: CheckWarning -> Diagnostic
renderCheckWarning CheckWarning {..} = Diagnostic warnPath warnPos 1 warnMessage

renderCheckWarnings :: [CheckWarning] -> [Diagnostic]
renderCheckWarnings = map renderCheckWarning

-- | Render a list of type errors as diagnostics, preserving order.
renderTypeErrors :: [TypeError] -> [Diagnostic]
renderTypeErrors = map renderTypeError
