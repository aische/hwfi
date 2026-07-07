-- | Runtime errors and their kinds. See spec §8.3.2 (the @Error@ trace variant
-- and its @kind@ enumeration) and §9.1 (runtime errors carry the @qname@ and
-- @step_id@ used in the trace, plus a source location where available).
module Hwfi.Runtime.Error
  ( ErrorKind (..),
    errorKindText,
    RuntimeError (..),
    runtimeError,
    evalError,
    ioError_,
    sandboxError,
    llmError,
    userError_,
    internalError,
    renderRuntimeError,
    StepRef (..),
    atStep,
  )
where

import Data.Text (Text)
import Hwfi.Ast.Name (Ident, QName, renderQName)

-- | The @kind@ of a runtime error (spec §8.3.2). @type@ should not occur for
-- statically-checked code; the others correspond to the failure classes the
-- runtime can hit.
data ErrorKind
  = KType
  | KEval
  | KIo
  | KSandbox
  | KLlm
  | KUser
  | KInternal
  deriving stock (Eq, Show)

-- | The wire\/trace spelling of an 'ErrorKind' (spec §8.3.2).
errorKindText :: ErrorKind -> Text
errorKindText = \case
  KType -> "type"
  KEval -> "eval"
  KIo -> "io"
  KSandbox -> "sandbox"
  KLlm -> "llm"
  KUser -> "user"
  KInternal -> "internal"

-- | Which step a runtime error occurred in (spec §9.1): the enclosing
-- workflow's qname and the step id within it.
data StepRef = StepRef
  { srQName :: QName,
    srStepId :: Ident
  }
  deriving stock (Eq, Show)

-- | A runtime error. @reStep@ is 'Nothing' for errors raised before any step
-- executes (e.g. startup validation).
data RuntimeError = RuntimeError
  { reKind :: ErrorKind,
    reMessage :: Text,
    reStep :: Maybe StepRef
  }
  deriving stock (Eq, Show)

-- | Build a step-less runtime error of a given kind.
runtimeError :: ErrorKind -> Text -> RuntimeError
runtimeError k msg = RuntimeError k msg Nothing

evalError :: Text -> RuntimeError
evalError = runtimeError KEval

ioError_ :: Text -> RuntimeError
ioError_ = runtimeError KIo

sandboxError :: Text -> RuntimeError
sandboxError = runtimeError KSandbox

llmError :: Text -> RuntimeError
llmError = runtimeError KLlm

userError_ :: Text -> RuntimeError
userError_ = runtimeError KUser

internalError :: Text -> RuntimeError
internalError = runtimeError KInternal

-- | Attach a step location to an error that does not already have one. Errors
-- raised deep in expression evaluation are tagged with the current step by the
-- executor as they propagate outward.
atStep :: StepRef -> RuntimeError -> RuntimeError
atStep ref e = case reStep e of
  Just _ -> e
  Nothing -> e {reStep = Just ref}

-- | Render a runtime error for the CLI (spec §9.1): includes the @qname@ and
-- @step_id@ when known.
renderRuntimeError :: RuntimeError -> Text
renderRuntimeError (RuntimeError k msg mStep) =
  "error [" <> errorKindText k <> "]" <> loc <> ": " <> msg
  where
    loc = case mStep of
      Nothing -> ""
      Just (StepRef q sid) -> " at " <> renderQName q <> "#" <> sid
