-- | A wrapper for sensitive values (API keys, tokens) that must never be
-- shown or serialised in cleartext. See spec §5.5.
--
-- The 'Show' instance deliberately redacts the payload so a 'Secret' can
-- never leak through accidental @show@/@print@ or derived 'Show' instances
-- of enclosing types. Trace redaction (spec §8.3.4), which needs the source
-- binding name, is a separate concern handled by the tracer.
module Hwfi.Runtime.Secret
  ( Secret,
    mkSecret,
    exposeSecret,
    redactedPlaceholder,
  )
where

import Data.Text (Text)

-- | An opaque holder for a sensitive value of type @a@.
newtype Secret a = Secret a

-- | Wrap a value as a secret.
mkSecret :: a -> Secret a
mkSecret = Secret

-- | Extract the underlying value. Callers must ensure the result does not
-- reach any trace, log, or user-visible output without going through the
-- redaction path.
exposeSecret :: Secret a -> a
exposeSecret (Secret a) = a

-- | The generic placeholder used when no source binding name is available.
-- Trace serialisation uses @"\<secret:$name>"@ when a name is known.
redactedPlaceholder :: Text
redactedPlaceholder = "<secret:?>"

instance Show (Secret a) where
  show _ = "Secret <redacted>"
