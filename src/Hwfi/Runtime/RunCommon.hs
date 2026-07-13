-- | Shared run orchestration types and helpers for the v2 runtime.
module Hwfi.Runtime.RunCommon
  ( RunResult (..),
    projectContentHash,
    reconstructInputs,
    defaultParallelism,
  )
where

import Data.Aeson (Value (..))
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Hwfi.Ast.Name (Ident, QName, qnameFromText, renderQName)
import Hwfi.Runtime.Error (RuntimeError (..))
import Hwfi.Runtime.StepKey (sha256Hex)
import Hwfi.Runtime.Trace (TraceEvent)
import Hwfi.Runtime.Value (RValue (..), coerceFromJson, valueToJson)
import Hwfi.TypedProject
  ( Fingerprint (..),
    ResolvedSignature (..),
    TypedDecl (..),
    TypedProject (..),
    lookupTyped,
    tdFingerprint,
    tpDecls,
  )
import Data.List (sort)

-- | The outcome of a run plus the events it produced (for @hwfi show@\/tests).
data RunResult = RunResult
  { rrOutcome :: Either RuntimeError RValue,
    rrEvents :: [TraceEvent],
    -- | 'True' when the machine stopped at an explicit halt point (@step@).
    rrHalted :: Bool
  }

-- | The default @par@ concurrency bound when @par(max = N)@ is not given (§13).
defaultParallelism :: Int
defaultParallelism = 4

-- | Reconstruct typed root inputs from the JSON persisted in @run.json@.
reconstructInputs :: TypedProject -> QName -> Value -> Either Text (Map Ident RValue)
reconstructInputs tp entry v = case v of
  Object o -> case lookupTyped entry tp of
    Nothing -> Left ("entrypoint '" <> renderQName entry <> "' not found on resume")
    Just td -> Map.fromList <$> traverse (field o) (rsigInputs (tdSignature td))
  _ -> Left "run.json 'inputs' is not an object"
  where
    field o (n, ty) = case KM.lookup (K.fromText n) o of
      Just fv -> (,) n <$> tagInput n (coerceFromJson ty fv)
      Nothing -> Left ("missing persisted input '" <> n <> "'")
    tagInput n = either (\m -> Left ("input '" <> n <> "': " <> m)) Right

-- | Content hash of the checked project for staleness checks on continue.
projectContentHash :: TypedProject -> Text
projectContentHash tp =
  sha256Hex (T.intercalate ";" (sort entries))
  where
    entries = [renderQName q <> ":" <> fpText (tdFingerprint d) | (q, d) <- Map.toList (tpDecls tp)]

fpText :: Fingerprint -> Text
fpText (Fingerprint t) = t
